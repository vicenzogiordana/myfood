defmodule MealPlannerApi.PlanningAgent.Prices do
  @moduledoc """
  Prices for the planning agent (spec #93, user stories 44-47, 59).

  An offer is one Product covering an Ingredient with its latest Price
  Observation: product, brand, presentation (package size), supermarket,
  price per package, currency and observation date. Only the latest
  observation of each Product counts. A Product without any observation has
  no offer: prices are never invented or defaulted to zero.

  Freshness is tracked per Product: an offer is fresh when its latest
  observation is under 24 hours old, and every offer carries its age.

  `lookup/2` reads the database first. An Ingredient whose offers are
  missing or not all fresh is refreshed through the live scraper, and what
  the scraper answers is recorded as Price Observations with the scraper's
  own observation time. A failed refresh records nothing, so the old price
  keeps its real age, and the failure is reported as a warning.
  """

  import Ecto.Query

  alias MealPlannerApi.Persistence.Catalog.Ingredient
  alias MealPlannerApi.Persistence.Shopping.{PriceObservation, Product, Supermarket}
  alias MealPlannerApi.Repo

  @fresh_seconds 24 * 3600

  # One lookup reads and refreshes at most this many Ingredients and returns
  # at most this many offers: every refresh is a live scraper call.
  @max_ingredients 50
  @max_offers 200

  # An Ingredient refreshed this recently (successfully or not) is not
  # scraped again: the scraper would most likely answer the same thing.
  @refresh_memo_seconds 15 * 60

  # A scraped observation may be dated at most this far after now (clock
  # skew); a later one would read as fresh and shadow real observations.
  @max_clock_skew_seconds 5 * 60

  # A refresh failing for one of these reasons means the scraper is down or
  # the turn is out of time: the rest of the lookup is not scraped.
  @breaker_reasons [:scraper_timeout, :scraper_unreachable, :deadline_exceeded]

  @doc "The most Ingredients one `lookup/2` reads and refreshes."
  @spec max_ingredients() :: pos_integer()
  def max_ingredients, do: @max_ingredients

  @doc "The most offers one `lookup/2` returns."
  @spec max_offers() :: pos_integer()
  def max_offers, do: @max_offers

  @type offer :: %{
          product_id: Ecto.UUID.t(),
          ingredient_id: Ecto.UUID.t(),
          ingredient: String.t(),
          product: String.t(),
          brand: String.t() | nil,
          package_quantity_milli: pos_integer(),
          package_unit: :g | :ml | :unit,
          supermarket: String.t(),
          price_cents: non_neg_integer(),
          currency: String.t(),
          observed_at: DateTime.t(),
          age_seconds: non_neg_integer(),
          fresh?: boolean()
        }

  @type refresh :: (String.t() -> {:ok, [map()]} | {:error, term()})

  @typedoc """
  Recent refresh attempts, by ingredient id: when each was made and its
  failure reason (`nil` when the scrape was recorded).
  """
  @type refresh_memo :: %{Ecto.UUID.t() => %{at: DateTime.t(), failure: term() | nil}}
  @type warning :: %{
          ingredient: String.t(),
          reason: :refresh_failed | :still_stale | :offers_truncated,
          detail: term()
        }

  @doc """
  Offers of every Product covering `ingredient_ids`, grouped by ingredient
  id, with their age and freshness at `now`.
  """
  @spec offers_for([Ecto.UUID.t()], DateTime.t()) :: %{Ecto.UUID.t() => [offer()]}
  def offers_for(ingredient_ids, now \\ DateTime.utc_now())
  def offers_for([], _now), do: %{}

  def offers_for(ingredient_ids, now) do
    ids = Enum.uniq(ingredient_ids)

    from(o in PriceObservation,
      join: p in assoc(o, :product),
      join: s in assoc(p, :supermarket),
      join: i in assoc(p, :ingredient),
      where: p.ingredient_id in ^ids,
      distinct: [asc: o.product_id],
      order_by: [asc: o.product_id, desc: o.observed_at, desc: o.id],
      select: %{
        product_id: p.id,
        ingredient_id: p.ingredient_id,
        ingredient: i.name,
        product: p.name,
        brand: p.brand,
        package_quantity_milli: p.package_quantity_milli,
        package_unit: p.package_unit,
        supermarket: s.name,
        price_cents: o.price_cents,
        currency: o.currency,
        observed_at: o.observed_at
      }
    )
    |> Repo.all()
    |> Enum.map(&with_age(&1, now))
    |> Enum.sort_by(&{&1.ingredient, &1.price_cents, &1.product, &1.product_id})
    |> Enum.group_by(& &1.ingredient_id)
  end

  @doc """
  Looks prices up, reading the database first and refreshing missing or
  stale Ingredients live.

  `names` are Ingredient names (case-insensitive exact match); at most
  `max_ingredients/0` of them are read and refreshed.

  Options: `:now` (default: the current time), `:refresh`, a
  function from an Ingredient name to the scraped items (see
  `MealPlannerApi.PlanningAgent.PriceScraper`; without it no refresh
  succeeds), and `:refresh_memo`, the memo a previous lookup returned.
  Names that match no Ingredient are never looked up live.

  An Ingredient in the memo refreshed less than 15 minutes ago is not
  refreshed again, whatever that refresh brought; its failure, or its
  prices still being stale, is reported again as a warning.

  Once a refresh fails because the scraper timed out, is unreachable or the
  turn ran out of time, the remaining Ingredients are not scraped: they get
  the same failure as a warning and stay out of the memo, as does every
  `:deadline_exceeded`, so the next lookup tries them again.

  At most `max_offers/0` offers are returned, taken round-robin from each
  Ingredient's cheapest ones, so every Ingredient with offers keeps some; an
  Ingredient that lost offers to the cap gets an `:offers_truncated`
  warning.

  Returns the offers, what is still without a price in `missing`
  with its reason, `warnings` for failed refreshes and prices still stale,
  and the updated `refresh_memo`.
  """
  @spec lookup([String.t()], keyword()) :: %{
          prices: [offer()],
          missing: [map()],
          warnings: [warning()],
          refresh_memo: refresh_memo()
        }
  def lookup(names, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    wanted = names |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    named = ingredients_by_name(wanted)

    ingredients =
      named
      |> Map.values()
      |> Enum.sort_by(& &1.name)
      |> Enum.take(@max_ingredients)

    memo = recent_refreshes(Keyword.get(opts, :refresh_memo, %{}), now)

    {offers, warnings, memo} =
      fresh_offers(ingredients, now, Keyword.get(opts, :refresh), memo)

    missing =
      Enum.flat_map(wanted, fn name ->
        case Map.fetch(named, String.downcase(name)) do
          :error -> [%{ingredient: name, reason: :unknown_ingredient}]
          {:ok, ingredient} -> named_gap(ingredient, offers)
        end
      end)

    {prices, truncated} = capped(offers)

    warnings =
      Enum.sort_by(
        warnings ++
          Enum.map(truncated, &%{ingredient: &1, reason: :offers_truncated, detail: nil}),
        &{&1.ingredient, &1.reason}
      )

    %{prices: prices, missing: missing, warnings: warnings, refresh_memo: memo}
  end

  @doc "JSON-safe entry of a lookup's `missing` list."
  @spec missing_data(map()) :: map()
  def missing_data(missing) do
    missing
    |> Map.take([:ingredient])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.put("reason", Atom.to_string(missing.reason))
  end

  @doc """
  Records scraped `items` as Products of `ingredient_id` with their Price
  Observations, at the scraper's observation time. An observation already
  stored for the same Product and time is kept as is.

  Recording is all or nothing: when the database rejects any item (an
  invalid value, a string wider than its column), nothing is recorded and
  `{:error, :record_failed}` is returned, so a bad scrape is a failed
  refresh rather than a crash of the read tool. An item observed later than
  `now` (beyond a small clock skew) rejects the scrape the same way: it
  would count as fresh and outrank every real observation of its Product.
  """
  @spec record(Ecto.UUID.t(), [map()], DateTime.t()) :: :ok | {:error, :record_failed}
  def record(ingredient_id, items, now \\ DateTime.utc_now()) do
    if Enum.any?(items, &future?(&1.observed_at, now)) do
      {:error, :record_failed}
    else
      case Repo.transaction(fn -> Enum.each(items, &record_item!(ingredient_id, &1)) end) do
        {:ok, :ok} -> :ok
        {:error, _reason} -> {:error, :record_failed}
      end
    end
  rescue
    _error in [Postgrex.Error, Ecto.InvalidChangesetError, Ecto.ConstraintError] ->
      {:error, :record_failed}
  end

  # A missing or invalid time is left to the changeset to reject.
  defp future?(%DateTime{} = observed_at, now),
    do: DateTime.diff(observed_at, now, :second) > @max_clock_skew_seconds

  defp future?(_observed_at, _now), do: false

  defp record_item!(ingredient_id, item) do
    supermarket = supermarket!(item.supermarket)
    product = product!(ingredient_id, supermarket.id, item)

    %PriceObservation{}
    |> PriceObservation.changeset(%{
      product_id: product.id,
      price_cents: item.price_cents,
      currency: item.currency,
      observed_at: item.observed_at
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:product_id, :observed_at])
  end

  @doc "JSON-safe provenance and age of an offer, as shown to the model and the Member."
  @spec offer_data(offer()) :: map()
  def offer_data(offer) do
    %{
      "ingredient" => offer.ingredient,
      "product" => offer.product,
      "brand" => offer.brand,
      "presentation" => %{
        "quantity_milli" => offer.package_quantity_milli,
        "unit" => Atom.to_string(offer.package_unit)
      },
      "supermarket" => offer.supermarket,
      "price_cents" => offer.price_cents,
      "currency" => offer.currency,
      "observed_at" => DateTime.to_iso8601(offer.observed_at),
      "age_hours" => div(offer.age_seconds, 3600),
      "fresh" => offer.fresh?
    }
  end

  @doc "JSON-safe warning of a lookup."
  @spec warning_data(warning()) :: map()
  def warning_data(%{reason: :refresh_failed} = warning) do
    %{
      "ingredient" => warning.ingredient,
      "reason" => "refresh_failed",
      "detail" => detail(warning.detail)
    }
  end

  def warning_data(warning),
    do: %{"ingredient" => warning.ingredient, "reason" => Atom.to_string(warning.reason)}

  # ---------------------------------------------------------------------------

  # Offers of `ingredients`, refreshed live where missing or stale unless
  # the memo holds a recent refresh of them.
  defp fresh_offers([], _now, _refresh, memo), do: {%{}, [], memo}

  defp fresh_offers(ingredients, now, refresh, memo) do
    ids = Enum.map(ingredients, & &1.id)
    stored = offers_for(ids, now)
    unrefreshed = Enum.filter(ingredients, &needs_refresh?(stored, &1.id))
    {memoized, to_refresh} = Enum.split_with(unrefreshed, &Map.has_key?(memo, &1.id))
    {failed, skipped} = refresh_all(to_refresh, refresh, now)

    # Ingredients never scraped, or cut by the turn deadline, are left out
    # so the next lookup tries them.
    memo =
      to_refresh
      |> Enum.reject(&(MapSet.member?(skipped, &1.id) or failed[&1.id] == :deadline_exceeded))
      |> Enum.reduce(memo, fn ingredient, memo ->
        Map.put(memo, ingredient.id, %{at: now, failure: Map.get(failed, ingredient.id)})
      end)

    failed =
      Enum.reduce(memoized, failed, fn ingredient, failed ->
        case memo[ingredient.id].failure do
          nil -> failed
          reason -> Map.put(failed, ingredient.id, reason)
        end
      end)

    offers =
      if to_refresh == [] or refresh == nil,
        do: stored,
        else: offers_for(ids, now)

    warnings =
      Enum.flat_map(unrefreshed, fn ingredient ->
        cond do
          Map.has_key?(failed, ingredient.id) ->
            [
              %{
                ingredient: ingredient.name,
                reason: :refresh_failed,
                detail: failed[ingredient.id]
              }
            ]

          Map.has_key?(offers, ingredient.id) and needs_refresh?(offers, ingredient.id) ->
            [%{ingredient: ingredient.name, reason: :still_stale, detail: nil}]

          true ->
            []
        end
      end)

    {offers, Enum.sort_by(warnings, & &1.ingredient), memo}
  end

  # The offers returned, at most `@max_offers` taken round-robin from each
  # Ingredient's cheapest, and the names of the Ingredients that lost some.
  defp capped(offers) do
    ranked =
      offers
      |> Map.values()
      |> Enum.flat_map(fn list -> list |> Enum.sort_by(&offer_key/1) |> Enum.with_index() end)

    kept =
      ranked
      |> Enum.sort_by(fn {offer, rank} -> {rank, offer_key(offer)} end)
      |> Enum.take(@max_offers)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort_by(&offer_key/1)

    kept_counts = Enum.frequencies_by(kept, & &1.ingredient_id)

    truncated =
      offers
      |> Enum.filter(fn {id, list} -> Map.get(kept_counts, id, 0) < length(list) end)
      |> Enum.map(fn {_id, [offer | _]} -> offer.ingredient end)

    {kept, truncated}
  end

  defp offer_key(offer),
    do: {offer.ingredient, offer.price_cents, offer.product, offer.product_id}

  defp recent_refreshes(memo, now) when is_map(memo) do
    memo
    |> Enum.filter(fn
      {_id, %{at: %DateTime{} = at}} -> DateTime.diff(now, at, :second) < @refresh_memo_seconds
      _entry -> false
    end)
    |> Map.new()
  end

  defp recent_refreshes(_memo, _now), do: %{}

  # An Ingredient without any offer is missing; stale offers are still
  # returned, with their age.
  defp named_gap(ingredient, offers) do
    if Map.has_key?(offers, ingredient.id),
      do: [],
      else: [%{ingredient: ingredient.name, reason: :no_stored_price}]
  end

  defp with_age(offer, now) do
    age = max(DateTime.diff(now, offer.observed_at, :second), 0)
    Map.merge(offer, %{age_seconds: age, fresh?: age < @fresh_seconds})
  end

  defp needs_refresh?(offers, ingredient_id) do
    case Map.get(offers, ingredient_id, []) do
      [] -> true
      offers -> not Enum.all?(offers, & &1.fresh?)
    end
  end

  # Returns the failed refreshes (ingredient id => failure reason) and the
  # ids of the Ingredients never scraped. Without a refresh function every
  # refresh fails as unavailable. After a breaker failure the remaining
  # Ingredients are skipped with that same reason.
  defp refresh_all(ingredients, nil, _now),
    do: {Map.new(ingredients, &{&1.id, :scraper_unavailable}), MapSet.new()}

  defp refresh_all(ingredients, refresh, now) do
    {failed, _tripped, skipped} =
      Enum.reduce(ingredients, {%{}, nil, MapSet.new()}, fn
        ingredient, {failed, nil, skipped} ->
          case refresh_one(ingredient, refresh, now) do
            :ok ->
              {failed, nil, skipped}

            {:error, reason} ->
              tripped = if reason in @breaker_reasons, do: reason
              {Map.put(failed, ingredient.id, reason), tripped, skipped}
          end

        ingredient, {failed, tripped, skipped} ->
          {Map.put(failed, ingredient.id, tripped), tripped, MapSet.put(skipped, ingredient.id)}
      end)

    {failed, skipped}
  end

  defp refresh_one(ingredient, refresh, now) do
    with {:ok, items} <- refresh.(ingredient.name), do: record(ingredient.id, items, now)
  end

  defp detail(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp detail(_reason), do: "scraper_error"

  defp ingredients_by_name([]), do: %{}

  defp ingredients_by_name(names) do
    lowered = Enum.map(names, &String.downcase/1)

    from(i in Ingredient,
      where: fragment("lower(?)", i.name) in ^lowered,
      select: %{id: i.id, name: i.name}
    )
    |> Repo.all()
    |> Map.new(&{String.downcase(&1.name), &1})
  end

  defp supermarket!(name) do
    _ =
      %Supermarket{}
      |> Supermarket.changeset(%{name: name})
      |> Repo.insert!(on_conflict: :nothing, conflict_target: :name)

    Repo.get_by!(Supermarket, name: name)
  end

  defp product!(ingredient_id, supermarket_id, item) do
    key = [
      supermarket_id: supermarket_id,
      ingredient_id: ingredient_id,
      name: item.product,
      package_quantity_milli: item.package_quantity_milli,
      package_unit: item.package_unit
    ]

    product =
      case Repo.get_by(Product, key) do
        nil ->
          # A concurrent lookup may insert the same Product first: keep
          # theirs and read it back.
          _ =
            %Product{}
            |> Product.changeset(key |> Map.new() |> Map.put(:brand, item.brand))
            |> Repo.insert!(
              on_conflict: :nothing,
              conflict_target: [
                :supermarket_id,
                :ingredient_id,
                :name,
                :package_quantity_milli,
                :package_unit
              ]
            )

          Repo.get_by!(Product, key)

        product ->
          product
      end

    case product do
      %Product{brand: brand} = product when brand == item.brand ->
        product

      product ->
        product |> Product.changeset(%{brand: item.brand}) |> Repo.update!()
    end
  end
end

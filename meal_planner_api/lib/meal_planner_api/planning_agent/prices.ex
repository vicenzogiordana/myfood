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

  # One lookup reads and refreshes at most this many Ingredients, named or
  # matched by a Product query, and returns at most this many offers: every
  # refresh is a live scraper call.
  @max_ingredients 50
  @max_offers 200

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
  @type warning :: %{
          ingredient: String.t(),
          reason: :refresh_failed | :still_stale,
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

  The query is any combination of:

    * `names` — Ingredient names (case-insensitive exact match)
    * `:brand` — only Products of this brand (case-insensitive exact match)
    * `:product` — only Products whose name or brand contains this text
      (case-insensitive); without names, it searches every stored Product

  Other options: `:now` (default: the current time) and `:refresh`, a
  function from an Ingredient name to the scraped items (see
  `MealPlannerApi.PlanningAgent.PriceScraper`); without it no refresh
  succeeds. Names that match no Ingredient are never looked up live.
  Freshness is judged on the offers that match the query.

  Returns the matching offers, what is still without a price in `missing`
  with its reason, and `warnings` for failed refreshes and prices still
  stale.
  """
  @spec lookup([String.t()], keyword()) :: %{
          prices: [offer()],
          missing: [map()],
          warnings: [warning()]
        }
  def lookup(names, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    brand = opts |> Keyword.get(:brand) |> normalize()
    product = opts |> Keyword.get(:product) |> normalize()

    wanted = names |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    named = ingredients_by_name(wanted)
    # Named Ingredients come first, so a Product query never pushes them
    # out of the capped set.
    ingredients =
      (Enum.sort_by(Map.values(named), & &1.name) ++ product_ingredients(product))
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(@max_ingredients)

    matches? = &(brand_match?(&1, brand) and product_match?(&1, product))

    {offers, warnings} = fresh_offers(ingredients, now, Keyword.get(opts, :refresh), matches?)

    missing =
      Enum.flat_map(wanted, fn name ->
        case Map.fetch(named, String.downcase(name)) do
          :error -> [%{ingredient: name, reason: :unknown_ingredient}]
          {:ok, ingredient} -> named_gap(ingredient, offers, now, brand, product)
        end
      end) ++ product_gap(wanted, offers, product)

    prices =
      offers
      |> Map.values()
      |> List.flatten()
      |> Enum.sort_by(&{&1.ingredient, &1.price_cents, &1.product, &1.product_id})
      |> Enum.take(@max_offers)

    %{prices: prices, missing: missing, warnings: warnings}
  end

  @doc "The Ingredient named `name` (case-insensitive exact match), or `nil`."
  @spec ingredient_by_name(String.t()) :: %{id: Ecto.UUID.t(), name: String.t()} | nil
  def ingredient_by_name(name) do
    name = String.trim(name)
    Map.get(ingredients_by_name([name]), String.downcase(name))
  end

  @doc """
  The brand of a stored Product of `ingredient_id` matching `brand`
  (case-insensitive), spelled as stored, or `nil` when none has it.
  """
  @spec stored_brand(Ecto.UUID.t(), String.t()) :: String.t() | nil
  def stored_brand(ingredient_id, brand) do
    lowered = String.downcase(brand)

    from(p in Product,
      where: p.ingredient_id == ^ingredient_id and fragment("lower(?)", p.brand) == ^lowered,
      order_by: [asc: p.brand],
      limit: 1,
      select: p.brand
    )
    |> Repo.one()
  end

  @doc "JSON-safe entry of a lookup's `missing` list."
  @spec missing_data(map()) :: map()
  def missing_data(missing) do
    missing
    |> Map.take([:ingredient, :brand, :product])
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
  refresh rather than a crash of the read tool.
  """
  @spec record(Ecto.UUID.t(), [map()]) :: :ok | {:error, :record_failed}
  def record(ingredient_id, items) do
    case Repo.transaction(fn -> Enum.each(items, &record_item!(ingredient_id, &1)) end) do
      {:ok, :ok} -> :ok
      {:error, _reason} -> {:error, :record_failed}
    end
  rescue
    _error in [Postgrex.Error, Ecto.InvalidChangesetError, Ecto.ConstraintError] ->
      {:error, :record_failed}
  end

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

  # Offers of `ingredients` matching the query, refreshed live where missing
  # or stale.
  defp fresh_offers([], _now, _refresh, _matches?), do: {%{}, []}

  defp fresh_offers(ingredients, now, refresh, matches?) do
    ids = Enum.map(ingredients, & &1.id)
    stored = matching(offers_for(ids, now), matches?)
    to_refresh = Enum.filter(ingredients, &needs_refresh?(stored, &1.id))
    failed = refresh_all(to_refresh, refresh)

    offers =
      if to_refresh == [] or refresh == nil,
        do: stored,
        else: matching(offers_for(ids, now), matches?)

    warnings =
      Enum.flat_map(to_refresh, fn ingredient ->
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

    {offers, Enum.sort_by(warnings, & &1.ingredient)}
  end

  defp matching(offers_by_ingredient, matches?) do
    offers_by_ingredient
    |> Enum.map(fn {id, offers} -> {id, Enum.filter(offers, matches?)} end)
    |> Enum.reject(fn {_id, offers} -> offers == [] end)
    |> Map.new()
  end

  defp brand_match?(_offer, nil), do: true
  defp brand_match?(%{brand: nil}, _brand), do: false
  defp brand_match?(offer, brand), do: String.downcase(offer.brand) == String.downcase(brand)

  defp product_match?(_offer, nil), do: true

  defp product_match?(offer, product) do
    text = String.downcase(product)

    Enum.any?(
      [offer.product, offer.brand],
      &(is_binary(&1) and String.contains?(String.downcase(&1), text))
    )
  end

  defp named_gap(ingredient, offers, now, brand, product) do
    cond do
      Map.has_key?(offers, ingredient.id) ->
        []

      brand != nil and any_offer?(ingredient.id, now) ->
        [%{ingredient: ingredient.name, brand: brand, reason: :no_matching_brand}]

      product != nil and any_offer?(ingredient.id, now) ->
        [%{ingredient: ingredient.name, product: product, reason: :no_matching_product}]

      true ->
        [%{ingredient: ingredient.name, reason: :no_stored_price}]
    end
  end

  # A Product query without names is missing when nothing matched it.
  defp product_gap([], offers, product) when is_binary(product) and map_size(offers) == 0,
    do: [%{product: product, reason: :no_matching_product}]

  defp product_gap(_wanted, _offers, _product), do: []

  defp any_offer?(ingredient_id, now),
    do: Map.has_key?(offers_for([ingredient_id], now), ingredient_id)

  defp product_ingredients(nil), do: []

  defp product_ingredients(product) do
    pattern = "%" <> escape_like(product) <> "%"

    from(p in Product,
      join: i in assoc(p, :ingredient),
      where: ilike(p.name, ^pattern) or ilike(p.brand, ^pattern),
      distinct: true,
      order_by: [asc: i.name, asc: i.id],
      limit: ^@max_ingredients,
      select: %{id: i.id, name: i.name}
    )
    |> Repo.all()
  end

  defp escape_like(text), do: String.replace(text, ~r/[\\%_]/, "\\\\\\0")

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_value), do: nil

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

  # Returns the failed refreshes: ingredient id => failure reason. Without a
  # refresh function every refresh fails as unavailable.
  defp refresh_all(ingredients, nil),
    do: Map.new(ingredients, &{&1.id, :scraper_unavailable})

  defp refresh_all(ingredients, refresh) do
    Enum.reduce(ingredients, %{}, fn ingredient, failed ->
      case refresh.(ingredient.name) do
        {:ok, items} ->
          case record(ingredient.id, items) do
            :ok -> failed
            {:error, reason} -> Map.put(failed, ingredient.id, reason)
          end

        {:error, reason} ->
          Map.put(failed, ingredient.id, reason)
      end
    end)
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

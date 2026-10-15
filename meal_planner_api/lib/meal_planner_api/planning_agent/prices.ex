defmodule MealPlannerApi.PlanningAgent.Prices do
  @moduledoc """
  Stored prices for the planning agent (spec #93, user stories 47, 59).

  An offer is one Product covering an Ingredient with its latest Price
  Observation: product, brand, presentation (package size), supermarket,
  price per package, currency and observation date. Only the latest
  observation of each Product counts. A Product without any observation has
  no offer: prices are never invented or defaulted to zero.

  This slice reads the database only. Live refresh, freshness and brands are
  added by #101.
  """

  import Ecto.Query

  alias MealPlannerApi.Persistence.Catalog.Ingredient
  alias MealPlannerApi.Persistence.Shopping.PriceObservation
  alias MealPlannerApi.Repo

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
          observed_at: DateTime.t()
        }

  @doc "Offers of every Product covering `ingredient_ids`, grouped by ingredient id."
  @spec offers_for([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [offer()]}
  def offers_for([]), do: %{}

  def offers_for(ingredient_ids) do
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
    |> Enum.sort_by(&{&1.ingredient, &1.price_cents, &1.product, &1.product_id})
    |> Enum.group_by(& &1.ingredient_id)
  end

  @doc """
  Looks prices up by ingredient name (case-insensitive exact match). Names
  that match no Ingredient, or an Ingredient with no stored price, are
  reported in `missing` with their reason.
  """
  @spec lookup_names([String.t()]) :: %{prices: [offer()], missing: [map()]}
  def lookup_names(names) do
    wanted = names |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    lowered = Enum.map(wanted, &String.downcase/1)

    ingredients =
      from(i in Ingredient,
        where: fragment("lower(?)", i.name) in ^lowered,
        select: %{id: i.id, name: i.name}
      )
      |> Repo.all()
      |> Map.new(&{String.downcase(&1.name), &1})

    offers = ingredients |> Map.values() |> Enum.map(& &1.id) |> offers_for()

    missing =
      Enum.flat_map(wanted, fn name ->
        case Map.fetch(ingredients, String.downcase(name)) do
          :error ->
            [%{ingredient: name, reason: :unknown_ingredient}]

          {:ok, ingredient} ->
            if Map.has_key?(offers, ingredient.id),
              do: [],
              else: [%{ingredient: ingredient.name, reason: :no_stored_price}]
        end
      end)

    %{prices: offers |> Map.values() |> List.flatten(), missing: missing}
  end

  @doc "JSON-safe provenance of an offer, as shown to the model and the Member."
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
      "observed_at" => DateTime.to_iso8601(offer.observed_at)
    }
  end
end

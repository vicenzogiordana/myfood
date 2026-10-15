defmodule MealPlannerApi.Persistence.Shopping.PriceObservation do
  @moduledoc """
  The price of one package of a Product, with its currency and when it was
  observed. Regular prices only; prices are never invented (spec #93).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "price_observations" do
    field(:price_cents, :integer)
    field(:currency, :string)
    field(:observed_at, :utc_datetime_usec)

    belongs_to(:product, MealPlannerApi.Persistence.Shopping.Product)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(observation, attrs) do
    observation
    |> cast(attrs, [:product_id, :price_cents, :currency, :observed_at])
    |> validate_required([:product_id, :price_cents, :currency, :observed_at])
    |> validate_number(:price_cents, greater_than_or_equal_to: 0)
    |> validate_format(:currency, ~r/\A[A-Z]{3}\z/)
    |> foreign_key_constraint(:product_id)
    |> unique_constraint([:product_id, :observed_at])
  end
end

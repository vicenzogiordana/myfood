defmodule MealPlannerApi.Persistence.Catalog.IngredientTag do
  @moduledoc """
  An Ingredient Tag: a classification of a catalog Ingredient (an allergen or a
  diet-relevant property). Only `:reviewed` tags count for Restriction checks;
  `:suggested` tags (for example AI output) wait for a reviewer.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias MealPlannerApi.Planning.Restrictions

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "ingredient_tags" do
    field(:tag, Ecto.Enum, values: Restrictions.known_tags())
    field(:status, Ecto.Enum, values: [:suggested, :reviewed])
    field(:reviewed_at, :utc_datetime_usec)

    belongs_to(:ingredient, MealPlannerApi.Persistence.Catalog.Ingredient)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(ingredient_tag, attrs) do
    ingredient_tag
    |> cast(attrs, [:ingredient_id, :tag, :status, :reviewed_at])
    |> validate_required([:ingredient_id, :tag, :status])
    |> unique_constraint([:ingredient_id, :tag])
    |> foreign_key_constraint(:ingredient_id)
  end
end

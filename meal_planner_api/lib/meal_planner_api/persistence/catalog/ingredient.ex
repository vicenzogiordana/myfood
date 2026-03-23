defmodule MealPlannerApi.Persistence.Catalog.Ingredient do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ingredients" do
    field(:name, :string)

    field(:category, Ecto.Enum,
      values: [
        :lacteos,
        :frutas,
        :verduras,
        :carnes,
        :granos,
        :congelados,
        :no_perecederos,
        :otros
      ]
    )

    field(:sku_reference, :string)
    field(:calories_per_100, :integer)
    field(:protein_g_per_100, :decimal)
    field(:carbs_g_per_100, :decimal)
    field(:fat_g_per_100, :decimal)

    has_many(:recipe_ingredients, MealPlannerApi.Persistence.Catalog.RecipeIngredient)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(ingredient, attrs) do
    ingredient
    |> cast(attrs, [
      :name,
      :category,
      :sku_reference,
      :calories_per_100,
      :protein_g_per_100,
      :carbs_g_per_100,
      :fat_g_per_100
    ])
    |> validate_required([:name, :category])
    |> validate_number(:calories_per_100, greater_than_or_equal_to: 0)
    |> validate_number(:protein_g_per_100, greater_than_or_equal_to: 0)
    |> validate_number(:carbs_g_per_100, greater_than_or_equal_to: 0)
    |> validate_number(:fat_g_per_100, greater_than_or_equal_to: 0)
    |> unique_constraint(:name)
  end
end

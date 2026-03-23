defmodule MealPlannerApi.Persistence.Catalog.Recipe do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "recipes" do
    field(:name, :string)
    field(:description, :string)
    field(:prep_time_minutes, :integer)
    field(:cook_time_minutes, :integer)
    field(:servings, :integer)
    field(:source, Ecto.Enum, values: [:traditional, :ai_generated, :user_created])

    field(:calories_per_serving, :integer)
    field(:protein_g_per_serving, :decimal)
    field(:carbs_g_per_serving, :decimal)
    field(:fat_g_per_serving, :decimal)

    field(:suitable_for_slots, {:array, Ecto.Enum},
      values: [:breakfast, :lunch, :snack, :dinner],
      default: []
    )

    belongs_to(:account, MealPlannerApi.Persistence.Accounts.Account)
    belongs_to(:created_by_user, MealPlannerApi.Persistence.Accounts.User)

    has_many(:recipe_steps, MealPlannerApi.Persistence.Catalog.RecipeStep)
    has_many(:recipe_ingredients, MealPlannerApi.Persistence.Catalog.RecipeIngredient)
    has_many(:daily_costs, MealPlannerApi.Persistence.Catalog.RecipeDailyCost)
    has_many(:favorite_recipes, MealPlannerApi.Persistence.Catalog.FavoriteRecipe)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(recipe, attrs) do
    recipe
    |> cast(attrs, [
      :account_id,
      :created_by_user_id,
      :name,
      :description,
      :prep_time_minutes,
      :cook_time_minutes,
      :servings,
      :source,
      :calories_per_serving,
      :protein_g_per_serving,
      :carbs_g_per_serving,
      :fat_g_per_serving,
      :suitable_for_slots
    ])
    |> validate_required([:name, :source])
    |> validate_number(:prep_time_minutes, greater_than_or_equal_to: 0)
    |> validate_number(:cook_time_minutes, greater_than_or_equal_to: 0)
    |> validate_number(:servings, greater_than: 0)
    |> validate_number(:calories_per_serving, greater_than_or_equal_to: 0)
    |> validate_number(:protein_g_per_serving, greater_than_or_equal_to: 0)
    |> validate_number(:carbs_g_per_serving, greater_than_or_equal_to: 0)
    |> validate_number(:fat_g_per_serving, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:created_by_user_id)
  end
end

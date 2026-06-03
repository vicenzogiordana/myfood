defmodule MealPlannerApi.Persistence.Catalog.Recipe do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_slots MapSet.new(["breakfast", "lunch", "snack", "dinner"])

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

    # Stored as strings: ["breakfast", "lunch", ...]
    # Accepts both atom [:breakfast] and string ["breakfast"] in input
    field(:suitable_for_slots, {:array, :string}, default: [])

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
      :fat_g_per_serving
      # NOTE: suitable_for_slots is handled manually to support both atoms and strings
    ])
    |> cast_suitable_for_slots(attrs)
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

  # Accept atom [:breakfast] or string ["breakfast"], normalize to strings, validate
  defp cast_suitable_for_slots(changeset, attrs) do
    raw =
      with nil <- Map.get(attrs, :suitable_for_slots),
           nil <- Map.get(attrs, "suitable_for_slots") do
        # Already has a string value from a prior normalization step
        get_field(changeset, :suitable_for_slots, [])
      else
        value when is_list(value) -> value
        _ -> []
      end

    string_slots =
      Enum.map(raw, fn
        slot when is_atom(slot) -> Atom.to_string(slot)
        slot when is_binary(slot) -> slot
      end)

    # Validate: all slots must be valid strings
    Enum.reduce(string_slots, put_change(changeset, :suitable_for_slots, string_slots), fn
      slot, ch when is_binary(slot) ->
        if slot in @valid_slots,
          do: ch,
          else: add_error(ch, :suitable_for_slots, "invalid slot: #{slot}")

      slot, ch ->
        add_error(ch, :suitable_for_slots, "must be a string, got: #{inspect(slot)}")
    end)
  end
end

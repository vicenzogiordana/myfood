defmodule MealPlannerApi.Planning.RestrictionValidatorTest do
  use ExUnit.Case, async: true

  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Planning.Restrictions
  alias MealPlannerApi.Planning.RestrictionValidator
  alias MealPlannerApi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp ingredient!(name) do
    {:ok, ingredient} =
      Catalog.create_ingredient(%{
        name: "#{name} #{System.unique_integer([:positive])}",
        category: :otros
      })

    ingredient
  end

  defp recipe!(name, ingredients) do
    {:ok, recipe} =
      Catalog.create_recipe(%{
        name: "#{name} #{System.unique_integer([:positive])}",
        servings: 2,
        suitable_for_slots: ["lunch", "dinner"],
        source: :traditional
      })

    Enum.each(ingredients, fn ingredient ->
      {:ok, _} =
        Catalog.add_recipe_ingredient(%{
          recipe_id: recipe.id,
          ingredient_id: ingredient.id,
          quantity_milli: 100_000,
          unit: :g
        })
    end)

    recipe
  end

  defp tag!(ingredient, tags) do
    Enum.each(tags, fn tag -> {:ok, _} = Catalog.tag_ingredient(ingredient.id, tag) end)
    ingredient
  end

  defp meal(date, slot, recipe), do: %{date: date, slot: slot, recipe_id: recipe.id}

  @monday ~D[2026-11-02]
  @tuesday ~D[2026-11-03]

  describe "Ingredient Tags" do
    test "a reviewer tag is stored as reviewed" do
      chicken = ingredient!("Fictitious chicken")

      assert {:ok, tag} = Catalog.tag_ingredient(chicken.id, :contains_meat)
      assert tag.status == :reviewed
      assert Catalog.reviewed_tags(chicken.id) == MapSet.new([:contains_meat])
    end

    test "suggestions stay unreviewed until a reviewer accepts them" do
      flour = ingredient!("Fictitious flour")

      assert {:ok, [suggestion]} = Catalog.suggest_ingredient_tags(flour.id, [:contains_gluten])
      assert suggestion.status == :suggested
      assert Catalog.reviewed_tags(flour.id) == MapSet.new()
      assert Catalog.suggested_tags(flour.id) == MapSet.new([:contains_gluten])

      assert {:ok, accepted} = Catalog.accept_tag_suggestion(flour.id, :contains_gluten)
      assert accepted.status == :reviewed
      assert Catalog.reviewed_tags(flour.id) == MapSet.new([:contains_gluten])
      assert Catalog.suggested_tags(flour.id) == MapSet.new()
    end

    test "a suggestion never downgrades a reviewed tag" do
      egg = ingredient!("Fictitious egg") |> tag!([:egg])

      assert {:ok, _} = Catalog.suggest_ingredient_tags(egg.id, [:egg, :animal_product])
      assert Catalog.reviewed_tags(egg.id) == MapSet.new([:egg])
      assert Catalog.suggested_tags(egg.id) == MapSet.new([:animal_product])
    end

    test "accepting a missing suggestion fails" do
      rice = ingredient!("Fictitious rice")
      assert {:error, :not_found} = Catalog.accept_tag_suggestion(rice.id, :contains_gluten)
    end

    test "unknown tags are rejected" do
      rice = ingredient!("Fictitious rice")
      assert {:error, :unknown_tag} = Catalog.tag_ingredient(rice.id, :spicy)
      assert {:error, :unknown_tag} = Catalog.tag_ingredient(rice.id, "contains_meat; drop")
      assert {:error, :unknown_tag} = Catalog.suggest_ingredient_tags(rice.id, [:spicy])
    end

    test "string tags from external input are accepted when known" do
      rice = ingredient!("Fictitious rice")
      assert {:ok, _} = Catalog.tag_ingredient(rice.id, "contains_gluten")
      assert Catalog.reviewed_tags(rice.id) == MapSet.new([:contains_gluten])
    end
  end

  describe "Restriction to forbidden tags" do
    test "diets map to fixed forbidden tag sets" do
      assert Restrictions.forbidden_tags({:diet, :omnivore}) == MapSet.new()

      assert Restrictions.forbidden_tags({:diet, :vegetarian}) ==
               MapSet.new([:contains_meat, :contains_fish])

      assert Restrictions.forbidden_tags({:diet, :pescatarian}) == MapSet.new([:contains_meat])

      assert MapSet.member?(Restrictions.forbidden_tags({:diet, :vegan}), :animal_product)
      assert Restrictions.forbidden_tags({:diet, :celiac}) == MapSet.new([:contains_gluten])
    end

    test "an allergy forbids its allergen tag" do
      assert Restrictions.forbidden_tags({:allergy, :peanut}) == MapSet.new([:peanut])
    end
  end

  describe "validate/3" do
    test "accepts meals without forbidden tags" do
      rice = ingredient!("Fictitious rice") |> tag!([])
      recipe = recipe!("Plain rice", [rice])

      members = [%{id: "member-a", restrictions: [{:diet, :vegan}]}]

      assert :ok = RestrictionValidator.validate([meal(@monday, "lunch", recipe)], members)
    end

    test "rejects a meal whose ingredients carry a tag forbidden by any Member" do
      rice = ingredient!("Fictitious rice")
      chicken = ingredient!("Fictitious chicken") |> tag!([:contains_meat, :animal_product])
      recipe = recipe!("Chicken rice", [rice, chicken])

      members = [
        %{id: "member-a", restrictions: []},
        %{id: "member-b", restrictions: [{:diet, :vegetarian}]}
      ]

      assert {:error, [conflict]} =
               RestrictionValidator.validate([meal(@monday, "dinner", recipe)], members)

      assert conflict.date == @monday
      assert conflict.slot == "dinner"
      assert conflict.recipe_id == recipe.id
      assert conflict.ingredient_ids == [chicken.id]
      assert conflict.tags == [:contains_meat]
    end

    test "every diet is enforced" do
      flour = ingredient!("Fictitious flour") |> tag!([:contains_gluten])
      tuna = ingredient!("Fictitious tuna") |> tag!([:contains_fish, :animal_product])
      cheese = ingredient!("Fictitious cheese") |> tag!([:milk, :animal_product])

      bread = recipe!("Bread", [flour])
      tuna_salad = recipe!("Tuna salad", [tuna])
      cheese_plate = recipe!("Cheese plate", [cheese])

      meals = [
        meal(@monday, "lunch", bread),
        meal(@monday, "dinner", tuna_salad),
        meal(@tuesday, "lunch", cheese_plate)
      ]

      conflicts_for = fn restriction ->
        case RestrictionValidator.validate(meals, [%{id: "m", restrictions: [restriction]}]) do
          :ok -> []
          {:error, conflicts} -> Enum.map(conflicts, & &1.recipe_id)
        end
      end

      assert conflicts_for.({:diet, :omnivore}) == []
      assert conflicts_for.({:diet, :celiac}) == [bread.id]
      assert conflicts_for.({:diet, :pescatarian}) == []
      assert conflicts_for.({:diet, :vegetarian}) == [tuna_salad.id]

      assert Enum.sort(conflicts_for.({:diet, :vegan})) ==
               Enum.sort([tuna_salad.id, cheese_plate.id])

      assert conflicts_for.({:allergy, :milk}) == [cheese_plate.id]
    end

    test "only reviewed tags count" do
      flour = ingredient!("Fictitious flour")
      {:ok, _} = Catalog.suggest_ingredient_tags(flour.id, [:contains_gluten])
      bread = recipe!("Bread", [flour])

      members = [%{id: "m", restrictions: [{:diet, :celiac}]}]

      assert :ok = RestrictionValidator.validate([meal(@monday, "lunch", bread)], members)
    end

    test "disliked ingredients are never violations" do
      onion = ingredient!("Fictitious onion")
      soup = recipe!("Onion soup", [onion])

      members = [%{id: "m", restrictions: [], dislikes: [onion.id]}]

      assert :ok = RestrictionValidator.validate([meal(@monday, "lunch", soup)], members)
    end

    test "an Absence Exception lifts exactly its Restriction for exactly its meals" do
      chicken = ingredient!("Fictitious chicken") |> tag!([:contains_meat, :animal_product])
      peanut = ingredient!("Fictitious peanut") |> tag!([:peanut])
      chicken_satay = recipe!("Chicken satay", [chicken, peanut])

      members = [
        %{id: "member-a", restrictions: [{:diet, :vegetarian}, {:allergy, :peanut}]}
      ]

      exceptions = [
        %{member_id: "member-a", restriction: {:diet, :vegetarian}, meals: [{@monday, "dinner"}]}
      ]

      monday = meal(@monday, "dinner", chicken_satay)
      tuesday = meal(@tuesday, "dinner", chicken_satay)

      assert {:error, conflicts} =
               RestrictionValidator.validate([monday, tuesday], members,
                 absence_exceptions: exceptions
               )

      by_date = Enum.group_by(conflicts, & &1.date)

      # Monday: vegetarian lifted, the peanut allergy still applies.
      assert [%{tags: [:peanut]}] = by_date[@monday]
      # Tuesday: no exception, both Restrictions apply.
      assert [%{tags: [:contains_meat, :peanut]}] = by_date[@tuesday]
    end

    test "an Absence Exception for one Member does not lift the same Restriction of another" do
      chicken = ingredient!("Fictitious chicken") |> tag!([:contains_meat, :animal_product])
      recipe = recipe!("Roast chicken", [chicken])

      members = [
        %{id: "member-a", restrictions: [{:diet, :vegetarian}]},
        %{id: "member-b", restrictions: [{:diet, :vegetarian}]}
      ]

      exceptions = [
        %{member_id: "member-a", restriction: {:diet, :vegetarian}, meals: [{@monday, "lunch"}]}
      ]

      assert {:error, [%{tags: [:contains_meat]}]} =
               RestrictionValidator.validate([meal(@monday, "lunch", recipe)], members,
                 absence_exceptions: exceptions
               )

      both = [
        %{member_id: "member-b", restriction: {:diet, :vegetarian}, meals: [{@monday, "lunch"}]}
        | exceptions
      ]

      assert :ok =
               RestrictionValidator.validate([meal(@monday, "lunch", recipe)], members,
                 absence_exceptions: both
               )
    end

    test "conflicts never reveal which Member holds the Restriction" do
      peanut = ingredient!("Fictitious peanut") |> tag!([:peanut])
      recipe = recipe!("Peanut noodles", [peanut])

      members = [
        %{id: "member-secret-id", name: "Fictitious Alice", restrictions: [{:allergy, :peanut}]}
      ]

      assert {:error, [conflict]} =
               RestrictionValidator.validate([meal(@monday, "lunch", recipe)], members)

      dump = inspect(conflict)
      refute dump =~ "member-secret-id"
      refute dump =~ "Alice"
      refute Map.has_key?(conflict, :member_id)
      assert conflict.message =~ "household member"
    end

    test "conflicts from several Members holding the same Restriction collapse into one" do
      chicken = ingredient!("Fictitious chicken") |> tag!([:contains_meat, :animal_product])
      recipe = recipe!("Roast chicken", [chicken])

      members = [
        %{id: "a", restrictions: [{:diet, :vegetarian}]},
        %{id: "b", restrictions: [{:diet, :vegan}]}
      ]

      assert {:error, [conflict]} =
               RestrictionValidator.validate([meal(@monday, "lunch", recipe)], members)

      assert conflict.tags == [:animal_product, :contains_meat]
    end
  end
end

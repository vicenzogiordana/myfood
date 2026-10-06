defmodule MealPlannerApi.Services.PlanningCandidateBuilderTest do
  use ExUnit.Case, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.{PlanningCandidateBuilder, RecipeVersions}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    user =
      user_with_memberships(%{email: "batch-#{Ecto.UUID.generate()}@example.com"}, [
        {%{plan: :family_4, name: "Batch household"}, :owner}
      ])

    %{user: user, account_id: hd(user.memberships).account_id}
  end

  test "candidate query count stays bounded as multi-slot recipe sets grow", f do
    measurements =
      Enum.map([1, 4, 15], fn additional ->
        for index <- 1..additional do
          recipe!(f.account_id, "Batch #{additional}-#{index}")
        end

        {result, cold_queries} = count_queries(fn -> build(f) end)
        assert {:ok, %{slots: [first, second]}} = result
        assert first.candidates == second.candidates
        ids = Enum.map(first.candidates, & &1["recipe_id"])
        assert ids == Enum.sort(ids)

        {warm_result, warm_queries} = count_queries(fn -> build(f) end)
        assert warm_result == result
        {length(ids), cold_queries, warm_queries}
      end)

    IO.inspect(measurements, label: "candidate counts / cold queries / warm queries")
    assert Enum.map(measurements, &elem(&1, 0)) == [1, 5, 20]
    assert Enum.all?(measurements, fn {_, cold, warm} -> cold == 7 and warm == 7 end)
  end

  test "batch publication handles empty, duplicate, invalid and missing IDs", f do
    assert {%{}, 0} = count_queries(fn -> RecipeVersions.freeze_many([]) end)
    assert {%{}, 0} = count_queries(fn -> RecipeVersions.freeze_many(["invalid", nil]) end)
    recipe = recipe!(f.account_id, "Unique publication")

    {versions, queries} =
      count_queries(fn ->
        RecipeVersions.freeze_many([recipe.id, recipe.id, Ecto.UUID.generate(), "invalid"])
      end)

    assert queries == 2
    assert Map.keys(versions) == [recipe.id]
    assert versions[recipe.id].snapshot["name"] == "Unique publication"
    assert RecipeVersions.freeze(recipe.id) == versions[recipe.id]
    assert {^versions, 2} = count_queries(fn -> RecipeVersions.freeze_many([recipe.id]) end)
  end

  test "candidates use frozen ingredients, cost and macros and select corrected successors", f do
    recipe = recipe!(f.account_id, "Published dish")

    {:ok, ingredient} =
      Catalog.create_ingredient(%{name: "Batch ingredient", category: :verduras})

    {:ok, item} =
      Catalog.add_recipe_ingredient(%{
        recipe_id: recipe.id,
        ingredient_id: ingredient.id,
        quantity_milli: 200,
        unit: :g
      })

    {:ok, market} =
      MealPlannerApi.Persistence.Shopping.create_supermarket(%{name: "Batch market"})

    cost =
      Repo.insert!(%Catalog.RecipeDailyCost{
        recipe_id: recipe.id,
        supermarket_id: market.id,
        date: ~D[2026-10-06],
        total_cents_ars: 450
      })

    %MealPlannerApi.Persistence.Inventory.InventoryItem{}
    |> MealPlannerApi.Persistence.Inventory.InventoryItem.changeset(%{
      account_id: f.account_id,
      ingredient_id: ingredient.id,
      quantity_milli: 200,
      unit: :g,
      source_kind: :planned,
      last_mutation_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:ok, %{slots: [first, _]}} = original = build(f)

    assert [
             %{
               "recipe_id" => recipe_id,
               "label" => "Published dish",
               "estimated_cost_cents" => 450,
               "protein_g_per_serving" => 12.5,
               "carbs_g_per_serving" => 20.0,
               "fat_g_per_serving" => 3.0,
               "calories_per_serving" => 100,
               "inventory_hit_count" => 1
             }
           ] = first.candidates

    assert recipe_id == recipe.id
    published = RecipeVersions.freeze(recipe.id)
    Repo.update!(Ecto.Changeset.change(recipe, name: "Live edit", protein_g_per_serving: 999))
    Repo.update!(Ecto.Changeset.change(item, quantity_milli: 999))
    Repo.update!(Ecto.Changeset.change(cost, total_cents_ars: 999))
    assert build(f) == original

    assert {:ok, successor} =
             RecipeVersions.correct(recipe.id, %{
               name: "Corrected dish",
               estimated_cost_cents: 600,
               protein_g_per_serving: "25"
             })

    assert successor.predecessor_id == published.id
    assert {:ok, %{slots: [corrected, _]}} = build(f)

    assert [
             %{
               "recipe_id" => successor_id,
               "label" => "Corrected dish",
               "estimated_cost_cents" => 600,
               "protein_g_per_serving" => 25.0,
               "inventory_hit_count" => 1
             }
           ] = corrected.candidates

    assert successor_id == successor.recipe_id
    assert RecipeVersions.freeze_many([recipe.id])[recipe.id] == published
  end

  defp build(f) do
    PlanningCandidateBuilder.build_candidate_set(
      f.account_id,
      [
        %{date: ~D[2026-10-06], slot: "lunch"},
        %{date: ~D[2026-10-06], slot: "dinner"}
      ],
      [f.user.id]
    )
  end

  defp recipe!(account_id, name) do
    {:ok, recipe} =
      Catalog.create_recipe(%{
        account_id: account_id,
        name: name,
        source: :user_created,
        servings: 2,
        calories_per_serving: 100,
        protein_g_per_serving: "12.5",
        carbs_g_per_serving: "20",
        fat_g_per_serving: "3",
        suitable_for_slots: ["lunch", "dinner"]
      })

    recipe
  end

  defp count_queries(fun) do
    owner = self()
    key = {__MODULE__, make_ref()}
    Process.put(key, 0)

    :ok =
      :telemetry.attach(
        key,
        [:meal_planner_api, :repo, :query],
        fn _, _, _, _ ->
          if self() == owner, do: Process.put(key, Process.get(key) + 1)
        end,
        nil
      )

    try do
      result = fun.()
      {result, Process.get(key)}
    after
      :telemetry.detach(key)
      Process.delete(key)
    end
  end
end

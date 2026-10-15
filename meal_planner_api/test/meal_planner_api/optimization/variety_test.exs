defmodule MealPlannerApi.Optimization.VarietyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Generation.ServerTestFixtures, as: Fixtures
  alias MealPlannerApi.Optimization.Variety
  alias MealPlannerApi.Persistence.Planning
  alias MealPlannerApi.Repo

  @range_from ~D[2026-09-07]

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
    suffix = Ecto.UUID.generate()
    household = Fixtures.insert_account("Variety household #{suffix}")
    curry = Fixtures.insert_recipe("Fictional curry #{suffix}")
    soup = Fixtures.insert_recipe("Fictional soup #{suffix}")
    %{household: household, curry: curry, soup: soup}
  end

  describe "prior_meals/2" do
    test "returns the confirmed Planned Meals of the 6 days before the range", ctx do
      schedule!(ctx.household, ctx.curry, ~D[2026-09-01], :lunch)
      schedule!(ctx.household, ctx.soup, ~D[2026-09-06], :dinner)
      schedule!(ctx.household, ctx.curry, ~D[2026-09-06], :lunch)

      assert Variety.prior_meals(ctx.household.id, @range_from) == [
               %{"day" => "2026-09-01", "slot" => "lunch", "recipe_id" => ctx.curry.id},
               %{"day" => "2026-09-06", "slot" => "lunch", "recipe_id" => ctx.curry.id},
               %{"day" => "2026-09-06", "slot" => "dinner", "recipe_id" => ctx.soup.id}
             ]
    end

    test "ignores meals outside the 6-day window, from other Households or without a recipe",
         ctx do
      schedule!(ctx.household, ctx.curry, ~D[2026-08-31], :lunch)
      schedule!(ctx.household, ctx.curry, @range_from, :lunch)
      schedule!(ctx.household, nil, ~D[2026-09-05], :lunch)

      other = Fixtures.insert_account("Other household #{Ecto.UUID.generate()}")
      schedule!(other, ctx.soup, ~D[2026-09-05], :dinner)

      assert Variety.prior_meals(ctx.household.id, @range_from) == []
    end
  end

  describe "put/3" do
    test "adds the prior context and the default cap to an optimizer payload" do
      prior = [%{"day" => "2026-09-06", "slot" => "lunch", "recipe_id" => "fictional-1"}]
      payload = %{"days" => ["2026-09-07"], "constraints" => %{"weekly_budget_cents" => 500}}

      assert {:ok, built} = Variety.put(payload, prior)

      assert built["prior_meals"] == prior
      assert built["constraints"]["variety_cap"] == Variety.default_cap()
      assert built["constraints"]["weekly_budget_cents"] == 500
      assert Variety.default_cap() == 2
    end

    test "carries a Planning Session's adjusted cap" do
      assert {:ok, built} = Variety.put(%{"constraints" => %{}}, [], 4)
      assert built["constraints"]["variety_cap"] == 4
    end

    test "rejects a cap that is not a positive integer" do
      for cap <- [0, -1, 1.5, "3", nil] do
        assert Variety.put(%{"constraints" => %{}}, [], cap) == {:error, :invalid_variety_cap}
      end
    end
  end

  defp schedule!(household, recipe, date, slot) do
    {:ok, meal} =
      Planning.schedule_meal(%{
        account_id: household.id,
        recipe_id: recipe && recipe.id,
        date: date,
        slot: slot
      })

    meal
  end
end

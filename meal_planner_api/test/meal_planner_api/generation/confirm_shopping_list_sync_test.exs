defmodule MealPlannerApi.Generation.ConfirmShoppingListSyncTest do
  @moduledoc """
  TDD coverage for item 4 (planning-pipeline-plumbing): confirming a plan
  must also populate the shopping list with that week's ingredients —
  eagerly, not only lazily on the next `get_shopping_list/2` read. Covers
  both confirm paths: `Generation.Server.do_confirm/2` and
  `PlanningChatService.confirm_proposal/2`.

  Asserts directly against `Persistence.Shopping.list_pending_items/3` (a
  plain read with no lazy-sync side effect of its own) so a passing test
  can only mean the confirm path itself populated the shopping list, not
  that the assertion incidentally triggered it.
  """

  use MealPlannerApiWeb.ChannelCase, async: false

  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Generation.Server
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Shopping
  alias MealPlannerApi.Services.PlanningChatService

  import MealPlannerApi.FactoryHelpers

  describe "Generation.Server.confirm/2" do
    test "eagerly creates shopping items for the confirmed plan's ingredients/date range" do
      user =
        user_with_memberships(%{email: "confirm_shopping@example.com"}, [
          {%{plan: :individual}, :owner}
        ])

      [membership] = user.memberships
      account = membership.account

      {:ok, recipe, ingredient} = create_recipe_with_ingredient(account, user, "Shopping Recipe")

      today = Date.utc_today()

      {:ok, run} =
        PlanningRepo.create_generation_run(%{
          account_id: account.id,
          user_id: user.id,
          status: :processing,
          started_at: DateTime.utc_now(),
          input_context: %{}
        })

      proposal_json = %{
        "slots" => [
          %{
            "slot_key" => "#{Date.to_iso8601(today)}_lunch",
            "recipe_id" => to_string(recipe.id)
          }
        ]
      }

      {:ok, proposal} =
        PlanningRepo.create_proposal(%{
          generation_run_id: run.id,
          proposal_json: proposal_json,
          status: :pending
        })

      server_pid = start_supervised!({Server, account_id: account.id, user_id: user.id})

      assert {:ok, %{scheduled_meals_count: 1}} = Server.confirm(server_pid, proposal.id)

      # No call to ShoppingService.get_shopping_list/2 anywhere above — if
      # items exist here, the confirm path itself created them eagerly.
      items = Shopping.list_pending_items(account.id, today, today)
      assert Enum.any?(items, &(&1.ingredient_id == ingredient.id))
    end
  end

  describe "PlanningChatService.confirm_proposal/2" do
    test "eagerly creates shopping items for the confirmed plan's ingredients/date range" do
      suffix = System.unique_integer([:positive])

      {:ok, ids} =
        Identity.ensure_persistent_identity(%{
          id: "u_chat_shopping_#{suffix}",
          account_id: "acct_chat_shopping_#{suffix}"
        })

      account = %{id: ids.account_id}
      user = %{id: ids.user_id}
      current_user = %{id: ids.user_id, account_id: ids.account_id}

      {:ok, recipe, ingredient} =
        create_recipe_with_ingredient(account, user, "Chat Shopping Recipe")

      today = Date.utc_today()

      {:ok, run} =
        PlanningRepo.create_generation_run(%{
          account_id: ids.account_id,
          user_id: ids.user_id,
          status: :completed,
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now(),
          input_context: %{}
        })

      proposal_json = %{
        "scheduled_meals" => [
          %{
            "date" => Date.to_iso8601(today),
            "slot" => "lunch",
            "recipe_id" => to_string(recipe.id)
          }
        ]
      }

      {:ok, proposal} =
        PlanningRepo.create_proposal(%{
          generation_run_id: run.id,
          proposal_json: proposal_json,
          status: :pending
        })

      assert {:ok, %{scheduled_meals_count: 1}} =
               PlanningChatService.confirm_proposal(current_user, proposal.id)

      items = Shopping.list_pending_items(ids.account_id, today, today)
      assert Enum.any?(items, &(&1.ingredient_id == ingredient.id))
    end
  end

  defp create_recipe_with_ingredient(account, user, name) do
    {:ok, ingredient} =
      Catalog.upsert_ingredient_by_name(%{
        name: "#{name} Ingredient #{System.unique_integer([:positive])}",
        category: :carnes,
        calories_per_100: 250,
        protein_g_per_100: Decimal.new("26.0"),
        carbs_g_per_100: Decimal.new("0.0"),
        fat_g_per_100: Decimal.new("15.0")
      })

    {:ok, recipe} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: name,
        source: :user_created,
        servings: 1,
        suitable_for_slots: ["breakfast", "lunch", "dinner"],
        protein_g_per_serving: 25,
        calories_per_serving: 800,
        carbs_g_per_serving: 75
      })

    {:ok, _ri} =
      Catalog.add_recipe_ingredient(%{
        recipe_id: recipe.id,
        ingredient_id: ingredient.id,
        quantity_milli: 500,
        unit: :g
      })

    {:ok, recipe, ingredient}
  end
end

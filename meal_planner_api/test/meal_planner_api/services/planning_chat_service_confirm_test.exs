defmodule MealPlannerApi.Services.PlanningChatServiceConfirmTest do
  @moduledoc """
  TDD coverage for item 3 (planning-pipeline-plumbing), second confirm path:
  `PlanningChatService.confirm_proposal/2` had the exact same non-atomic bug
  as `Generation.Server.do_confirm/2` — proposal update to `:accepted`
  followed by independent `schedule_meal` inserts via `Enum.flat_map`,
  silently dropping any `{:error, _}` result. Now wrapped in the same
  `Ecto.Multi`/`Repo.transaction` pattern.
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Persistence.Planning.PlanningProposal
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.PlanningChatService

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  test "a conflicting scheduled meal rolls back the ENTIRE confirm — proposal stays pending, zero meals persisted" do
    suffix = System.unique_integer([:positive])

    {:ok, ids} =
      Identity.ensure_persistent_identity(%{
        id: "u_chat_confirm_#{suffix}",
        account_id: "acct_chat_confirm_#{suffix}"
      })

    current_user = %{id: ids.user_id, account_id: ids.account_id}
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

    # Proposal_json shaped like a round-tripped-from-DB
    # `PlanningChatService.generate_menu/2` proposal — STRING keys under
    # "scheduled_meals" (parse_scheduled_meals/1's expected shape).
    proposal_json = %{
      "scheduled_meals" => [
        %{
          "date" => Date.to_iso8601(today),
          "slot" => "breakfast",
          "recipe_id" => Ecto.UUID.generate()
        },
        %{
          "date" => Date.to_iso8601(today),
          "slot" => "lunch",
          "recipe_id" => Ecto.UUID.generate()
        }
      ]
    }

    {:ok, proposal} =
      PlanningRepo.create_proposal(%{
        generation_run_id: run.id,
        proposal_json: proposal_json,
        status: :pending
      })

    # Pre-existing conflicting row for the breakfast slot.
    {:ok, _conflicting_meal} =
      PlanningRepo.schedule_meal(%{
        account_id: ids.account_id,
        date: today,
        slot: :breakfast,
        recipe_id: nil,
        is_cooked: false
      })

    assert {:error, _reason} = PlanningChatService.confirm_proposal(current_user, proposal.id)

    reloaded_proposal = Repo.get!(PlanningProposal, proposal.id)
    assert reloaded_proposal.status == :pending

    meals = PlanningRepo.list_scheduled_meals(ids.account_id, today, today)
    assert length(meals) == 1
  end
end

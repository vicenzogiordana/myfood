defmodule MealPlannerApi.Generation.ConfirmAtomicityTest do
  @moduledoc """
  TDD coverage for item 3 (planning-pipeline-plumbing): `Generation.Server.
  do_confirm/2` used to update the proposal to `:accepted` and then insert
  each scheduled meal independently, filtering out `{:error, _}` results —
  so a single conflicting `ScheduledMeal` (unique constraint on
  `[:account_id, :date, :slot]`) silently dropped just that meal while the
  proposal still ended up `:accepted` with fewer meals than the client was
  shown, with no error surfaced anywhere.

  Confirm is now wrapped in `Ecto.Multi`/`Repo.transaction`: any failure —
  including a single conflicting meal insert — rolls back the WHOLE
  transaction (proposal stays at its prior status, ZERO meals persisted).
  """

  use MealPlannerApiWeb.ChannelCase, async: false

  alias MealPlannerApi.Data.PlanningRepo
  alias MealPlannerApi.Generation.Server
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApi.Persistence.Planning.PlanningProposal
  alias MealPlannerApi.Repo

  import MealPlannerApi.FactoryHelpers

  test "a conflicting scheduled meal rolls back the ENTIRE confirm — proposal stays pending, zero meals persisted" do
    user =
      user_with_memberships(%{email: "confirm_atomic@example.com"}, [
        {%{plan: :individual}, :owner}
      ])

    [membership] = user.memberships
    account = membership.account

    {:ok, recipe_a} = create_recipe(account, user, "Breakfast Recipe")
    {:ok, recipe_b} = create_recipe(account, user, "Lunch Recipe")

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
          "slot_key" => "#{Date.to_iso8601(today)}_breakfast",
          "recipe_id" => to_string(recipe_a.id)
        },
        %{"slot_key" => "#{Date.to_iso8601(today)}_lunch", "recipe_id" => to_string(recipe_b.id)}
      ]
    }

    {:ok, proposal} =
      PlanningRepo.create_proposal(%{
        generation_run_id: run.id,
        proposal_json: proposal_json,
        status: :pending
      })

    # Pre-existing conflicting row for the breakfast slot — the confirm must
    # fail to insert this exact (account_id, date, slot) again.
    {:ok, _conflicting_meal} =
      PlanningRepo.schedule_meal(%{
        account_id: account.id,
        date: today,
        slot: :breakfast,
        recipe_id: nil,
        is_cooked: false
      })

    # Start a bare Generation.Server directly (not via `start_generation/4`,
    # which would create its OWN separate run+proposal via
    # `send(self(), :run_optimization)` and race the real — here
    # unavailable — Python optimizer in the background). `do_confirm/2` only
    # needs `state.account_id` to match the proposal's generation_run
    # account for `verify_ownership/2` to pass; it re-fetches the proposal
    # fresh from the DB either way.
    server_pid = start_supervised!({Server, account_id: account.id, user_id: user.id})

    assert {:error, _reason} = Server.confirm(server_pid, proposal.id)

    reloaded_proposal = Repo.get!(PlanningProposal, proposal.id)
    assert reloaded_proposal.status == :pending

    meals = PlanningRepo.list_scheduled_meals(account.id, today, today)
    # Only the pre-existing conflicting row — the lunch slot must NOT have
    # been inserted either, since the whole transaction rolled back.
    assert length(meals) == 1
  end

  defp create_recipe(account, user, name) do
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
  end
end

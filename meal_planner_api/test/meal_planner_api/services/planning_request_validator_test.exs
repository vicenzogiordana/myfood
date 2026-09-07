defmodule MealPlannerApi.Services.PlanningRequestValidatorTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Services.PlanningRequestValidator

  import MealPlannerApi.Generation.ServerTestFixtures

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
    :ok
  end

  test "accepts only active selected members and normalizes the participant list" do
    account = insert_account("validator account")
    actor = insert_user_with_membership(account, "validator-actor@example.com")

    participant =
      insert_user_with_membership(account, "validator-participant@example.com", :member)

    assert {:ok, %{"participant_ids" => participant_ids}, context} =
             PlanningRequestValidator.validate_request(
               %{"participant_ids" => [participant.id, participant.id]},
               account.id,
               actor.id
             )

    assert participant_ids == [participant.id]
    assert context.participant_ids == [participant.id]
  end

  test "rejects a suspended participant before planning can create writes" do
    account = insert_account("validator suspended account")
    actor = insert_user_with_membership(account, "validator-owner@example.com")
    participant = insert_user_with_membership(account, "validator-suspended@example.com", :member)

    membership = Repo.get_by!(AccountMembership, account_id: account.id, user_id: participant.id)
    {:ok, _} = membership |> AccountMembership.changeset(%{status: :suspended}) |> Repo.update()

    assert {:error, :forbidden} =
             PlanningRequestValidator.validate_request(
               %{"participant_ids" => [participant.id]},
               account.id,
               actor.id
             )
  end
end

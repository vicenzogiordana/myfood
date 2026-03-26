defmodule MealPlannerApiWeb.PlanningChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Catalog
  alias MealPlannerApiWeb.UserSocket

  test "generate_menu emits real proposal, swap_constraints regenerates, and confirm_proposal emits proposal_confirmed" do
    {:ok, token, user, account} = issue_token("u_chan", "acct_chan")

    {:ok, _breakfast} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: "Desayuno canal",
        source: :user_created,
        servings: 2,
        suitable_for_slots: [:breakfast]
      })

    {:ok, _lunch} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: "Almuerzo canal",
        source: :user_created,
        servings: 2,
        suitable_for_slots: [:lunch]
      })

    {:ok, _dinner} =
      Catalog.create_recipe(%{
        account_id: account.id,
        created_by_user_id: user.id,
        name: "Cena canal",
        source: :user_created,
        servings: 2,
        suitable_for_slots: [:dinner]
      })

    {:ok, socket} = connect(UserSocket, %{"token" => token})

    {:ok, _reply, socket} =
      subscribe_and_join(socket, MealPlannerApiWeb.PlanningChannel, "planning:#{account.id}")

    ref =
      push(socket, "generate_menu", %{
        "request_id" => "req_1",
        "message" => "Plan semanal",
        "date_from" => "2026-03-23",
        "date_to" => "2026-03-23",
        "content_type" => "speech_transcript"
      })

    assert_broadcast("generation_started", %{request_id: "req_1"})
    assert_broadcast("proposal_ready", ready_payload)
    assert_reply(ref, :ok, %{proposal_id: proposal_id})
    assert is_binary(proposal_id)
    assert ready_payload.request_id == "req_1"
    assert is_map(ready_payload.proposal[:weekly_plan])

    swap_ref =
      push(socket, "swap_constraints", %{
        "request_id" => "req_swap_1",
        "base_payload" => %{
          "message" => "Plan semanal",
          "date_from" => "2026-03-23",
          "date_to" => "2026-03-23",
          "kcal_target" => 2200,
          "weekly_budget_cents" => 80_000
        },
        "constraints" => %{"kcal_target" => 1800}
      })

    assert_broadcast("generation_started", %{
      request_id: "req_swap_1",
      reason: "constraint_update"
    })

    assert_broadcast("proposal_ready", swapped_payload)
    assert_reply(swap_ref, :ok, %{proposal_id: swap_proposal_id})
    assert is_binary(swap_proposal_id)
    assert swapped_payload.applied_constraints["kcal_target"] == 1800
    assert is_map(swapped_payload.proposal[:weekly_plan])

    confirm_ref = push(socket, "confirm_proposal", %{"proposal_id" => proposal_id})

    assert_broadcast("proposal_confirmed", confirmed_payload)
    assert confirmed_payload.status == "confirmed"
    assert_reply(confirm_ref, :ok, %{status: "confirmed"})
  end

  defp issue_token(user_id, account_id) do
    with {:ok, %{user: user, account: account}} <-
           Accounts.find_or_create_identity(%{"user_id" => user_id, "account_id" => account_id}),
         {:ok, token, _claims} <-
           Guardian.encode_and_sign(user, Accounts.claims_for(user, account),
             token_type: "access"
           ) do
      {:ok, token, user, account}
    end
  end
end

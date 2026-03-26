defmodule MealPlannerApiWeb.PlanningChannelTest do
  use MealPlannerApiWeb.ChannelCase, async: false

  alias MealPlannerApi.Accounts
  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApiWeb.UserSocket

  test "generate_menu emits proposal_ready and confirm_proposal emits proposal_confirmed" do
    {:ok, token, account} = issue_token("u_chan", "acct_chan")

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
      {:ok, token, account}
    end
  end
end

defmodule MealPlannerApiWeb.MembershipScopedChannelTest do
  @moduledoc """
  Dedicated multi-familia checkpoint (Phase A — Tenancy Refactor, PR 3b
  task 3.13). Per design.md §8.5 and spec `membership-scoped-channels`
  §"Multi-familia User joining two topics via two sockets":

    * The same User, `:active` in two different Accounts, opens two
      independent sockets — one scoped to Account_A, one to Account_B.
    * Both joins succeed (each PlanningChannel join is verified
      independently against the socket's own current_membership, per
      tasks 3.9-3.12).
    * A broadcast sent to Account_A's topic is received only by the
      A-socket; the B-socket never sees it.
  """
  use MealPlannerApiWeb.ChannelCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApiWeb.{Endpoint, PlanningChannel, UserSocket}

  test "multi-familia User joins two Account-scoped planning topics via two sockets" do
    user =
      user_with_memberships(
        %{email: "multi_familia_3_13@example.com"},
        [
          {%{plan: :family_4, name: "Multi Familia A"}, :owner},
          {%{plan: :individual, name: "Multi Familia B"}, :member}
        ]
      )

    membership_a = Enum.find(user.memberships, &(&1.account.name == "Multi Familia A"))
    membership_b = Enum.find(user.memberships, &(&1.account.name == "Multi Familia B"))

    token_a = issue_access_v2_token(user, membership_a)
    token_b = issue_access_v2_token(user, membership_b)

    {:ok, socket_a} = connect(UserSocket, %{"token" => token_a})
    {:ok, socket_b} = connect(UserSocket, %{"token" => token_b})

    topic_a = "planning:#{membership_a.account_id}"
    topic_b = "planning:#{membership_b.account_id}"

    assert {:ok, _reply_a, socket_a} = subscribe_and_join(socket_a, PlanningChannel, topic_a)
    assert {:ok, _reply_b, socket_b} = subscribe_and_join(socket_b, PlanningChannel, topic_b)

    assert socket_a.assigns.current_membership.account_id == membership_a.account_id
    assert socket_b.assigns.current_membership.account_id == membership_b.account_id

    Endpoint.broadcast!(topic_a, "membership_scope_probe", %{"scope" => "a_only"})

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^topic_a,
      event: "membership_scope_probe",
      payload: %{"scope" => "a_only"}
    }

    refute_receive %Phoenix.Socket.Broadcast{
      topic: ^topic_b,
      event: "membership_scope_probe"
    }
  end
end

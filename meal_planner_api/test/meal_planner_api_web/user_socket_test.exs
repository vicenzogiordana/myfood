defmodule MealPlannerApiWeb.UserSocketTest do
  @moduledoc """
  Tests for `MealPlannerApiWeb.UserSocket.connect/3` after the Phase A
  dual-write change (PR 1 task 1.12).

  Coverage:

    * `access_v2` token → `socket.assigns.current_membership.id` equals
      the membership_id from the JWT
    * `access_v1` (legacy) token → `socket.assigns.current_membership`
      is a synthesized struct with `__synthesized__: true`
    * Connect rejects invalid tokens (existing behavior preserved)
  """
  use MealPlannerApiWeb.ChannelCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo
  alias MealPlannerApiWeb.UserSocket

  setup do
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "connect/3 with access_v2 token" do
    test "populates current_membership from the membership_id claim" do
      user =
        user_with_memberships(
          %{email: "socket-v2@example.com"},
          [
            {%{plan: :family_4, name: "Socket Family"}, :owner}
          ]
        )

      [membership] = user.memberships
      token = issue_access_v2_token(user, membership)

      assert {:ok, socket} =
               connect(UserSocket, %{"token" => token})

      assert %AccountMembership{id: ms_id} = socket.assigns.current_membership
      assert ms_id == membership.id
      refute Map.get(socket.assigns.current_membership, :__synthesized__)
    end
  end

  describe "connect/3 with access_v1 token" do
    test "synthesizes a current_membership from user.account_id" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      {:ok, account} =
        %MealPlannerApi.Persistence.Accounts.Account{}
        |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
          name: "Legacy Socket Family",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          account_id: account.id,
          email: "socket-v1@example.com",
          name: "Legacy Socket",
          role: :owner
        })
        |> Repo.insert()

      {:ok, token, _claims} =
        Guardian.encode_and_sign(
          user,
          %{
            "typ" => "access",
            "account_id" => Ecto.UUID.cast!(account.id),
            "account_type" => "group",
            "email" => user.email,
            "name" => user.name
          },
          token_type: "access"
        )

      assert {:ok, socket} =
               connect(UserSocket, %{"token" => token})

      synthesized = socket.assigns.current_membership

      assert Map.get(synthesized, :__synthesized__) == true
      assert synthesized.account_id == account.id
      assert synthesized.role == :owner
    end
  end

  describe "connect/3 with no/bad token" do
    test "rejects when token is missing" do
      assert :error = connect(UserSocket, %{})
    end

    test "rejects when token is invalid" do
      assert :error = connect(UserSocket, %{"token" => "garbage.token.value"})
    end
  end
end

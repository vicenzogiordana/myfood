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
    # ------------------------------------------------------------------
    # Post-PR-3b review — BLOCKER fix (legacy membership synthesis).
    #
    # `connect/3` used to fabricate an in-memory `%AccountMembership{
    # status: :active}` from `user.account_id` alone (via a private
    # `synthesize_legacy_membership/2` duplicated in this very module),
    # with NO database lookup. Since `AccountsMembership.remove_member/3`
    # and `.leave/2` hard-delete the real row without clearing
    # `user.account_id`, and legacy tokens carry a 4-week TTL with no
    # server-side revocation, a removed member's stale token could still
    # open a live socket connection for weeks. `connect/3` now delegates
    # to `LoadCurrentMembershipSocket.membership_from_socket/1` (the same
    # function the `access_v2` branch already used), which requires a
    # real, `:active` `AccountMembership` row — closing the duplicate and
    # the vulnerability in one fix.
    # ------------------------------------------------------------------
    test "rejects a legacy token with no real backing membership row (fail-closed)" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      {:ok, account} =
        %MealPlannerApi.Persistence.Accounts.Account{}
        |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
          name: "Legacy Socket No-Row Family",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          account_id: account.id,
          email: "socket-v1-no-row@example.com",
          name: "Legacy Socket No Row",
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

      assert :error = connect(UserSocket, %{"token" => token})
    end

    test "populates current_membership from a real active membership row (no synthesis)" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      {:ok, account} =
        %MealPlannerApi.Persistence.Accounts.Account{}
        |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
          name: "Legacy Socket Real Row Family",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          account_id: account.id,
          email: "socket-v1-real-row@example.com",
          name: "Legacy Socket Real Row",
          role: :owner
        })
        |> Repo.insert()

      {:ok, membership} =
        %MealPlannerApi.Persistence.Accounts.AccountMembership{}
        |> MealPlannerApi.Persistence.Accounts.AccountMembership.changeset(%{
          account_id: account.id,
          user_id: user.id,
          role: :owner,
          status: :active,
          joined_at: DateTime.utc_now()
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

      assert {:ok, socket} = connect(UserSocket, %{"token" => token})

      loaded = socket.assigns.current_membership

      refute Map.get(loaded, :__synthesized__)
      assert loaded.id == membership.id
      assert loaded.account_id == account.id
      assert loaded.role == :owner
    end

    test "rejects a removed member's stale legacy token (membership hard-deleted after the token was minted)" do
      plan = Repo.get_by!(MealPlannerApi.Subscriptions.Plan, name: "family_4")

      {:ok, account} =
        %MealPlannerApi.Persistence.Accounts.Account{}
        |> MealPlannerApi.Persistence.Accounts.Account.changeset(%{
          name: "Legacy Socket Removed Family",
          plan: :family_4,
          default_budget_cents: 0,
          subscription_plan_id: plan.id
        })
        |> Repo.insert()

      {:ok, user} =
        %MealPlannerApi.Persistence.Accounts.User{}
        |> MealPlannerApi.Persistence.Accounts.User.changeset(%{
          account_id: account.id,
          email: "socket-v1-removed@example.com",
          name: "Legacy Socket Removed",
          role: :member
        })
        |> Repo.insert()

      {:ok, membership} =
        %MealPlannerApi.Persistence.Accounts.AccountMembership{}
        |> MealPlannerApi.Persistence.Accounts.AccountMembership.changeset(%{
          account_id: account.id,
          user_id: user.id,
          role: :member,
          status: :active,
          joined_at: DateTime.utc_now()
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

      # Simulate `AccountsMembership.remove_member/3`'s effect: hard-delete
      # the membership row. `user.account_id` still points at the account
      # and the JWT (minted before removal) still carries the old
      # `account_id` claim — the connection must now be refused.
      Repo.delete!(membership)

      assert :error = connect(UserSocket, %{"token" => token})
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

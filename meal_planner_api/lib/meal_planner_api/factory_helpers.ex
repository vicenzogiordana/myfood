defmodule MealPlannerApi.FactoryHelpers do
  @moduledoc """
  Test factory macros introduced in Phase A — Tenancy Refactor, PR 1
  (tasks 1.8 / 1.9).

  The macros are intentionally simple — they don't use ex_machina because
  the existing test suite relies on direct `Repo.insert/2` patterns with
  raw attributes (see e.g. `meal_planner_api/accounts_test.exs`). They
  serve as a **bridge** to the multi-familia scenarios required by PR 2 +
  PR 3 controllers.

  Available macros:

    * `user_with_memberships(user_attrs, memberships_spec)` —
      inserts a User with N `:active` memberships across N Accounts;
      the User is returned with `memberships: :account` preloaded.
      `memberships_spec` is a list of `{account_attrs, role}` tuples.
    * `issue_access_v2_token(user, membership)` — mints a JWT with
      `typ: "access_v2"` carrying the membership_id, account_id, plan,
      role, status, email, and name claims (design §3.2).

  The macros are imported explicitly per-test (`import
  MealPlannerApi.FactoryHelpers`) — they are not auto-injected into the
  test environment to avoid surprising existing test modules.
  """

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.Account, as: PersistenceAccount
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo
  alias MealPlannerApi.Subscriptions

  @doc """
  Inserts a User, N Accounts, and N `:active` memberships. The User is
  returned with `memberships: :account` preloaded so callers can read
  `membership.account.plan` directly.

  ## Example

      user = user_with_memberships(
        %{email: "ana@example.com"},
        [
          {%{plan: :individual, name: "Personal"}, :owner},
          {%{plan: :family_4,   name: "Family"},   :member}
        ]
      )

      [personal, family] = user.memberships
      token = issue_access_v2_token(user, personal)
  """
  @spec user_with_memberships(map(), [{map(), atom()}]) :: PersistenceUser.t()
  def user_with_memberships(user_attrs, memberships_spec) when is_list(memberships_spec) do
    user =
      %PersistenceUser{}
      |> PersistenceUser.changeset(default_user_attrs(user_attrs))
      |> Repo.insert!()

    Enum.each(memberships_spec, fn {account_attrs, role} ->
      account = insert_account(account_attrs)
      insert_membership(account, user, role)
    end)

    user |> Repo.preload(memberships: :account)
  end

  @doc """
  Mints an `access_v2` JWT for the given user + membership. The claim set
  matches design §3.2 exactly via the canonical
  `MealPlannerApi.AccountsMembership.claims_for/2` builder (PR 2a task 2.1).
  """
  @spec issue_access_v2_token(PersistenceUser.t(), AccountMembership.t()) :: String.t()
  def issue_access_v2_token(user, membership) do
    claims = MealPlannerApi.AccountsMembership.claims_for(user, membership)

    {:ok, token, _claims} =
      Guardian.encode_and_sign(user, claims, token_type: "access")

    token
  end

  # ---- internals -------------------------------------------------------------

  defp default_user_attrs(overrides) do
    Map.merge(
      %{
        name: "Factory User #{Ecto.UUID.generate()}",
        role: :member
      },
      overrides
    )
  end

  defp insert_account(account_attrs) do
    plan = Map.get(account_attrs, :plan, :individual)

    {:ok, plan_row} =
      plan
      |> plan_name()
      |> Subscriptions.get_plan_by_name()

    attrs =
      Map.merge(
        %{
          name: "Factory Account #{Ecto.UUID.generate()}",
          default_budget_cents: 0
        },
        Map.put(account_attrs, :subscription_plan_id, plan_row.id)
      )

    %PersistenceAccount{} |> PersistenceAccount.changeset(attrs) |> Repo.insert!()
  end

  defp insert_membership(account, user, role) do
    %AccountMembership{}
    |> AccountMembership.changeset(%{
      account_id: account.id,
      user_id: user.id,
      role: role,
      status: :active,
      joined_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp plan_name(:individual), do: "individual"
  defp plan_name(:family_4), do: "family_4"
  defp plan_name(:family_6), do: "family_6"
  defp plan_name(:trial), do: "trial"
  defp plan_name(plan) when is_binary(plan), do: plan
end

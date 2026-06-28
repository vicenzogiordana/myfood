defmodule MealPlannerApi.AccountsMembership do
  @moduledoc """
  Application-layer use cases for multi-familia tenancy.

  Phase A — Tenancy Refactor (PR 2a, tasks 2.1–2.8). This module owns the
  invitation lifecycle, seat-cap enforcement, roster listing, leave/switch
  flows, and the `access_v2` JWT claim builder. Persistence queries live in
  `MealPlannerApi.Persistence.Accounts.*` and `MealPlannerApi.Repo` —
  schemas are dumb data per Clean Architecture.

  See `specs/account-membership.md`, `invite-and-accept.md`,
  `multi-familia-switch-account.md`, and `guardian-jwt-claims.md`.
  """

  alias MealPlannerApi.Persistence.Accounts.Account
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Persistence.Accounts.User, as: PersistenceUser
  alias MealPlannerApi.Repo

  @doc """
  Builds the `access_v2` JWT claim map for the given user + membership
  pair. The result matches design §3.2 exactly (Guardian adds `iat` and
  `exp` at sign time — those are NOT application claims).

  ## Examples

      iex> claims = AccountsMembership.claims_for(user, membership)
      iex> claims["typ"]
      "access_v2"
  """
  @spec claims_for(PersistenceUser.t(), AccountMembership.t()) :: map()
  def claims_for(%PersistenceUser{} = user, %AccountMembership{} = membership) do
    plan = membership_plan(membership)

    %{
      "typ" => "access_v2",
      "membership_id" => to_string(membership.id),
      "account_id" => to_string(membership.account_id),
      "role" => Atom.to_string(membership.role),
      "plan" => Atom.to_string(plan),
      "status" => Atom.to_string(membership.status),
      "email" => user.email,
      "name" => user.name
    }
  end

  # Look up the Account.plan on the membership if `:account` is preloaded;
  # otherwise fetch it from the DB. Avoids an N+1 when callers already
  # preloaded, while still working for callers that did not.
  defp membership_plan(%AccountMembership{account: %Account{plan: plan}}),
    do: plan

  defp membership_plan(%AccountMembership{account_id: account_id}) do
    case Ecto.UUID.cast(account_id) do
      {:ok, uuid} ->
        case Repo.get(Account, uuid) do
          %Account{plan: plan} -> plan
          _ -> :individual
        end

      _ ->
        :individual
    end
  end
end

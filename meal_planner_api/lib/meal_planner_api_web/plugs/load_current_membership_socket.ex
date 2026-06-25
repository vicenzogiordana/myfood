defmodule MealPlannerApiWeb.Plugs.LoadCurrentMembershipSocket do
  @moduledoc """
  Sibling of `MealPlannerApiWeb.Plugs.LoadCurrentMembership` for
  Phoenix Channels (PR 1 task 1.10).

  Reads `socket.assigns.current_user` and `socket.assigns.claims` (both
  populated by `UserSocket.connect/3` after Guardian verifies the JWT)
  and resolves the active membership the same way the HTTP plug does:

    * `typ: "access_v2"` → load the `AccountMembership` row by
      `claims["membership_id"]`
    * `typ: "access"` (legacy fallback) → synthesize a virtual
      membership struct with `__synthesized__: true` populated from
      `current_user.account_id` + `current_user.role` + `Account.plan`

  Channels that need the membership call
  `LoadCurrentMembershipSocket.membership_from_socket(socket)` and read
  `socket.assigns.current_membership` (Q8 — design §7).
  """

  alias MealPlannerApi.Persistence.Accounts.Account
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo

  @spec membership_from_socket(Phoenix.Socket.t()) ::
          AccountMembership.t() | nil
  def membership_from_socket(%Phoenix.Socket{} = socket) do
    current_user = socket.assigns[:current_user]
    claims = socket.assigns[:claims] || %{}
    typ = Map.get(claims, "typ", "access")

    case typ do
      "access_v2" -> load_access_v2_membership(claims)
      "access" -> synthesize_legacy_membership(current_user)
      _ -> nil
    end
  end

  defp load_access_v2_membership(claims) do
    case Map.get(claims, "membership_id") do
      nil -> nil
      "" -> nil
      membership_id -> load_membership_by_id(membership_id)
    end
  end

  defp load_membership_by_id(membership_id) do
    case Ecto.UUID.cast(membership_id) do
      {:ok, uuid} ->
        import Ecto.Query, warn: false
        alias MealPlannerApi.Persistence.Accounts.AccountMembership

        from(m in AccountMembership, where: m.id == ^uuid)
        |> Repo.one()
        |> Repo.preload(:account)

      _ ->
        nil
    end
  end

  defp synthesize_legacy_membership(%{account_id: account_id} = user)
       when not is_nil(account_id) do
    plan = fetch_account_plan(account_id)

    %AccountMembership{
      id: nil,
      account_id: account_id,
      user_id: user.id,
      role: user.role || :member,
      status: :active,
      joined_at: nil
    }
    |> Map.put(:plan, plan)
    |> Map.put(:__synthesized__, true)
  end

  defp synthesize_legacy_membership(_), do: nil

  defp fetch_account_plan(account_id) do
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

defmodule MealPlannerApiWeb.Plugs.LoadCurrentMembership do
  @moduledoc """
  Phoenix plug that populates `conn.assigns.current_membership` from the
  decoded JWT claims (Phase A — Tenancy Refactor, PR 1 task 1.10).

  Per `design.md` §4.2:

    * When the JWT is `typ: "access_v2"` the plug loads the
      `AccountMembership` row identified by `claims["membership_id"]`,
      preload `:account`. Missing/invalid → halt with
      `401 unauthorized, %{error: "membership_id_required"}`.

    * When the JWT is `typ: "access"` (legacy fallback) the plug
      **synthesizes** a virtual membership struct from
      `current_user.account_id` + `current_user.role` + `Account.plan`.
      The struct is marked `__synthesized__: true` so tests can assert
      which path populated it. No row is inserted.

  The plug is read-only on the conn — it never mutates the User record,
  never reads the membership table unless `typ: "access_v2"` was
  presented.
  """

  alias MealPlannerApi.Auth.Guardian
  alias MealPlannerApi.Persistence.Accounts.Account
  alias MealPlannerApi.Persistence.Accounts.AccountMembership
  alias MealPlannerApi.Repo

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case membership_for_conn(conn) do
      {:ok, membership} ->
        Plug.Conn.assign(conn, :current_membership, membership)

      {:error, :membership_id_required} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, ~s({"error":"membership_id_required"}))
        |> Plug.Conn.halt()
    end
  end

  @doc """
  Looks up the membership for a Phoenix `%Plug.Conn{}`. Exposed for
  callers that want to inspect the assignment directly (e.g. controllers
  that need both the User and the membership).
  """
  @spec membership_for_conn(Plug.Conn.t()) ::
          {:ok, AccountMembership.t()} | {:error, :membership_id_required}
  def membership_for_conn(conn) do
    claims =
      conn.private[:guardian_default_claims] ||
        conn.assigns[:guardian_default_claims] || %{}

    typ = Map.get(claims, "typ", "access")

    current_user =
      try do
        Guardian.Plug.current_resource(conn) || conn.assigns[:default]
      rescue
        _ -> conn.assigns[:default]
      end

    case typ do
      "access_v2" ->
        load_access_v2_membership(claims)

      "access" ->
        synthesize_legacy_membership(current_user, claims)

      _ ->
        # Unknown typ. Same as the no-membership case — Guardian should
        # have rejected this in the pipeline, but if it slipped through
        # we refuse rather than silently synthesize.
        {:error, :membership_id_required}
    end
  end

  defp load_access_v2_membership(claims) do
    case Map.get(claims, "membership_id") do
      nil ->
        {:error, :membership_id_required}

      "" ->
        {:error, :membership_id_required}

      membership_id ->
        case load_membership_by_id(membership_id) do
          %AccountMembership{} = membership -> {:ok, membership}
          _ -> {:error, :membership_id_required}
        end
    end
  end

  defp load_membership_by_id(membership_id) do
    case Ecto.UUID.cast(membership_id) do
      {:ok, uuid} ->
        uuid
        |> AccountMembershipByIdQuery.call()
        |> Repo.one()

      _ ->
        nil
    end
  end

  defp synthesize_legacy_membership(%{account_id: account_id} = user, _claims)
       when not is_nil(account_id) do
    plan = fetch_account_plan(account_id)

    membership =
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

    {:ok, membership}
  end

  defp synthesize_legacy_membership(_user, _claims), do: {:error, :membership_id_required}

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

defmodule AccountMembershipByIdQuery do
  @moduledoc false
  import Ecto.Query, warn: false

  alias MealPlannerApi.Persistence.Accounts.AccountMembership

  def call(uuid) do
    from(m in AccountMembership, where: m.id == ^uuid)
  end
end

defmodule MealPlannerApiWeb.Plugs.EnforceCapability do
  @moduledoc """
  HTTP capability guard for the RevenueCat access model
  (`revenuecat-access-enforcement`, PR 3 — HTTP capability and recovery).

  Reads `conn.assigns.current_membership.account_id`, loads the Account
  through the same `MealPlannerApi.AccountAccess` predicate used by
  channel joins and the recovery routes, and either passes through or
  halts with `403 {"error":"subscription_required"}`.

  Two rollout gates control the plug:

    * the per-pipeline `:enforce_capability` opt-in (used by the router
      to decide whether the plug should run at all); and
    * `:revenuecat_access_enforcement` (the gradual rollout flag wired
      from `REVENUECAT_ACCESS_ENFORCEMENT` in production, off by default
      per `design.md` §"Migration / Rollout").

  The plug NEVER mutates Account data — denial is read-only. The
  `subscription_required` response body is the exact contract promised
  in `design.md` §"Interfaces / Contracts".
  """

  require Logger

  alias MealPlannerApi.AccountAccess

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      not enforcement_enabled?() ->
        conn

      not eligible?(conn) ->
        Logger.info(
          "EnforceCapability denied request: path=#{conn.request_path} method=#{conn.method}"
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, ~s({"error":"subscription_required"}))
        |> Plug.Conn.halt()

      true ->
        conn
    end
  end

  # Public so tests can flip the rollout flag without poking at the
  # pipeline option.
  @doc false
  def enforcement_enabled? do
    Application.get_env(:meal_planner_api, :revenuecat_access_enforcement, false) == true
  end

  defp eligible?(conn) do
    case membership_account_id(conn) do
      nil -> false
      account_id -> AccountAccess.eligible?(account_id)
    end
  end

  defp membership_account_id(conn) do
    case conn.assigns[:current_membership] do
      %{account_id: account_id} when not is_nil(account_id) ->
        Ecto.UUID.cast(account_id)
        |> case do
          {:ok, uuid} -> uuid
          _ -> nil
        end

      _ ->
        nil
    end
  end
end

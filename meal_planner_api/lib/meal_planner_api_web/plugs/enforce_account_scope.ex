defmodule MealPlannerApiWeb.Plugs.EnforceAccountScope do
  @moduledoc """
  Phoenix plug that rejects requests where the URL `:account_id` does not
  match `conn.assigns.current_membership.account_id` (Phase A — Tenancy
  Refactor, PR 3a task 3.7; pulled forward into task 3.1 because the
  `MembershipController` acceptance criteria require the `403
  account_mismatch` behavior at the HTTP layer — see
  `apply-progress.md` §"PR 3a" for the reordering note).

  Per `design.md` §4.2: runs AFTER `LoadCurrentMembership` in the
  pipeline. Routes with no `:account_id` path param (e.g.
  `POST /api/auth/switch-account`) are a no-op — this plug only acts on
  `:account_id`-bearing routes.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Map.get(conn.path_params, "account_id") do
      nil ->
        conn

      path_account_id ->
        membership = conn.assigns[:current_membership]

        if membership_matches?(membership, path_account_id) do
          conn
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(403, ~s({"error":"account_mismatch"}))
          |> Plug.Conn.halt()
        end
    end
  end

  defp membership_matches?(%{account_id: account_id}, path_account_id)
       when not is_nil(account_id) do
    to_string(account_id) == to_string(path_account_id)
  end

  defp membership_matches?(_membership, _path_account_id), do: false
end

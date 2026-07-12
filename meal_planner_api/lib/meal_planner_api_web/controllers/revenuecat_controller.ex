defmodule MealPlannerApiWeb.RevenuecatController do
  use MealPlannerApiWeb, :controller

  alias MealPlannerApi.Persistence.Identity
  alias MealPlannerApi.Services.RevenuecatService
  alias MealPlannerApiWeb.Controllers.AccountScopeHelpers

  def webhook(conn, payload) do
    headers =
      conn.req_headers
      |> Enum.into(%{}, fn {k, v} -> {String.downcase(k), v} end)

    case RevenuecatService.process_webhook(payload, headers) do
      {:ok, data} -> json(conn, %{data: data})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  # Phase A — Tenancy Refactor (PR 3c task 3.20): the webhook action above
  # is deliberately unauthenticated (no `:auth` pipe — RevenueCat calls it
  # directly, ownership is verified from the webhook payload itself, not
  # from any session). `sync/2` IS behind `:auth`, so its ownership check
  # is corrected here: `current_user` is scoped to
  # `conn.assigns.current_membership.account_id` before being handed to
  # `Identity.ensure_persistent_identity/1`, never the legacy
  # `current_user.account_id` field. See
  # `AccountScopeHelpers.scope_user_to_membership/2`.
  def sync(conn, payload) do
    current_user =
      conn
      |> Guardian.Plug.current_resource()
      |> AccountScopeHelpers.scope_user_to_membership(conn.assigns.current_membership)

    with {:ok, ids} <- Identity.ensure_persistent_identity(current_user),
         {:ok, data} <-
           RevenuecatService.sync_entitlements(ids.account_id, ids.user_id, payload) do
      json(conn, %{data: data})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp render_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: serialize_reason(reason)})
  end

  defp serialize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp serialize_reason(reason) when is_binary(reason), do: reason
  defp serialize_reason(_), do: "invalid_payload"
end

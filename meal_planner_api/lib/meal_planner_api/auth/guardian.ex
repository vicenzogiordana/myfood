defmodule MealPlannerApi.Auth.Guardian do
  @moduledoc """
  Guardian implementation used by both HTTP requests and WebSocket connections.

  Phase A — Tenancy Refactor (PR 2b task 2.9): the dual-write auth fix
  stops re-attaching `:account_type` from JWT claims. The legacy
  `:group | :individual` taxonomy was dropped from the `Account`
  schema in PR 1; the canonical source of truth is now
  `Account.plan` (read via `current_membership.plan` after
  `LoadCurrentMembership` populates the conn). Re-attaching
  `:account_type` gave a stale `:group` value that no post-Phase A
  caller should read.

  `:subscription_tier` and `:account_id` are still re-attached
  because:

    * `:subscription_tier` — the PR 3 controller sweep
      (`auth_controller.ex` and others) still reads
      `user.subscription_tier`. Removing the reattachment now would
      break those controllers before they can be migrated off the
      User-struct field.
    * `:account_id` — the PR 1 `LoadCurrentMembership` synthesizes
      the legacy `current_membership` from `user.account_id` +
      `user.role` for `access_v1` tokens. Without reattachment, the
      synthesize path would silently fail for users whose DB row
      doesn't yet have `account_id` set (e.g. freshly-registered
      `access_v2` users during the dual-write window).
  """

  use Guardian, otp_app: :meal_planner_api

  alias MealPlannerApi.Repo
  alias MealPlannerApi.Persistence.Accounts.User

  @impl true
  def subject_for_token(%User{id: id}, _claims), do: {:ok, id}
  def subject_for_token(%{id: id}, _claims) when is_binary(id), do: {:ok, id}
  def subject_for_token(_, _claims), do: {:error, :invalid_resource}

  @impl true
  def resource_from_claims(%{"sub" => id} = claims) when is_binary(id) do
    case Repo.get(User, id) do
      %User{} = user ->
        # Dual-write auth (PR 2b task 2.9): the User struct is loaded
        # from the DB and re-attaches ONLY the fields that the dual-write
        # fallback still depends on (`:subscription_tier`,
        # `:account_id`). The legacy `:account_type` reattachment is
        # removed — `Account.plan` is the source of truth, exposed via
        # `current_membership.plan` after `LoadCurrentMembership` runs.
        {:ok,
         user
         |> Map.put(
           :subscription_tier,
           normalize_subscription_tier(Map.get(claims, "subscription_tier", "free"))
         )
         |> Map.put(:account_id, Map.get(claims, "account_id"))}

      nil ->
        {:error, :resource_not_found}
    end
  end

  def resource_from_claims(_claims), do: {:error, :invalid_claims}

  defp normalize_subscription_tier("premium"), do: :premium
  defp normalize_subscription_tier(:premium), do: :premium
  defp normalize_subscription_tier(_), do: :free
end

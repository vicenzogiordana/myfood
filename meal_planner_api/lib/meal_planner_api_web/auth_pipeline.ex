defmodule MealPlannerApiWeb.AuthPipeline do
  @moduledoc """
  Plug pipeline that validates Bearer tokens and loads the current
  User + the current Membership.

  ## Phase A — Tenancy Refactor (PR 1, task 1.11)

  The pipeline is now dual-write-aware:

    * `Guardian.Plug.VerifyHeader` validates the signature and standard
      claims (no `claims: %{typ: ...}` filter — we accept both cutover
      tokens here and reject unknown `typ` values in a dedicated step).
    * `MealPlannerApiWeb.Plugs.VerifyTokenType` checks
      `claims["typ"]` against the supported set (`"access"`,
      `"access_v2"`). Unknown `typ` → `401 unsupported_token_type`.
    * `Guardian.Plug.EnsureAuthenticated` and `Guardian.Plug.LoadResource`
      populate `conn.assigns.current_user`.
    * `MealPlannerApiWeb.Plugs.LoadCurrentMembership` reads the claims
      and populates `conn.assigns.current_membership` (a real row for
      `access_v2`, a synthesized struct for legacy `access`).
  """

  use Guardian.Plug.Pipeline,
    otp_app: :meal_planner_api,
    module: MealPlannerApi.Auth.Guardian,
    error_handler: MealPlannerApiWeb.AuthErrorHandler

  plug Guardian.Plug.VerifyHeader
  plug MealPlannerApiWeb.Plugs.VerifyTokenType
  plug Guardian.Plug.EnsureAuthenticated
  plug Guardian.Plug.LoadResource, allow_blank: false
  plug MealPlannerApiWeb.Plugs.LoadCurrentMembership
end

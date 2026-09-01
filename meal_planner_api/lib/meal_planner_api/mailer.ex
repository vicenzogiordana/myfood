defmodule MealPlannerApi.Mailer do
  @moduledoc """
  Bamboo mailer for all outbound transactional email.

  Phase 1 — Persistence and Code Request (issue #31). The configured
  adapter is read from `:bamboo_adapter` in `:meal_planner_api` app
  env so that `dev` and `test` use `Bamboo.LocalAdapter` and `prod`
  is wired to a real provider through `runtime.exs`.

  See `MealPlannerApi.Mailer.EmailCodeEmail` for the only template
  currently in scope.
  """
  use Bamboo.Mailer, otp_app: :meal_planner_api
end

defmodule MealPlannerApi.AITest do
  @moduledoc """
  Regression coverage for two pre-existing, tenancy-independent bugs
  discovered (but explicitly not fixed, as out of scope) by the Phase A
  tenancy review agent — see `ai_channel_test.exs` "new_message threads
  current_membership.account_id..." for the original discovery writeup.

  Bug #1 (this file): `AI.stream_response/4` pattern-matched
  `%MealPlannerApi.Accounts.User{}` — a DTO struct that is never
  actually constructed anywhere in the codebase. The real caller
  (`AIChannel.handle_in/3`) always passes a
  `MealPlannerApi.Persistence.Accounts.User` (the real Ecto-backed
  user), so the function clause could never match — every call crashed
  with `FunctionClauseError` before entering the function body.
  """
  use ExUnit.Case, async: false

  import MealPlannerApi.FactoryHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias MealPlannerApi.AI
  alias MealPlannerApi.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
  end

  describe "stream_response/4" do
    test "accepts the real Persistence.Accounts.User struct every caller passes" do
      user =
        user_with_memberships(%{email: "ai_stream_bug1@example.com"}, [
          {%{plan: :family_4, name: "AI Stream Bug1 Account"}, :owner}
        ])

      [membership] = user.memberships
      scoped_user = Map.put(user, :account_id, membership.account_id)

      assert :ok = AI.stream_response("room_ai_bug1", "hola", scoped_user, %{})
    end
  end
end

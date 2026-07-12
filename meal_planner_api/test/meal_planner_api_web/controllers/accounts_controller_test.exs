defmodule MealPlannerApiWeb.AccountsControllerTest do
  use MealPlannerApiWeb.ConnCase, async: false

  import MealPlannerApi.FactoryHelpers

  alias MealPlannerApi.Auth.Guardian

  # ─── Phase A — Tenancy Refactor (PR 3c task 3.22) ───────────────────────────
  # See calendar_controller_test.exs (task 3.14) for why a tampered
  # `account_id` claim — rather than a plain "scoped JWT" — is the genuine
  # RED-discriminating case for this codebase.
  describe "GET /api/me — multi-familia tenancy scoping (task 3.22)" do
    test "resolves account via current_membership.account_id, not a tampered account_id claim",
         %{conn: conn} do
      user =
        user_with_memberships(%{email: "accounts_me_tamper@example.com"}, [
          {%{plan: :family_4, name: "Accounts Me Tamper Account A"}, :owner},
          {%{plan: :family_4, name: "Accounts Me Tamper Account B"}, :member}
        ])

      [membership_a, membership_b] = user.memberships

      tampered_claims =
        MealPlannerApi.AccountsMembership.claims_for(user, membership_a)
        |> Map.put("account_id", to_string(membership_b.account_id))

      {:ok, token, _claims} =
        Guardian.encode_and_sign(user, tampered_claims, token_type: "access")

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/me")

      body = json_response(conn, 200)

      assert body["claims"]["account_id"] == membership_a.account_id
      refute body["claims"]["account_id"] == membership_b.account_id
      assert body["account"]["account_id"] == membership_a.account_id
      assert body["account"]["account"]["id"] == membership_a.account_id
    end
  end
end

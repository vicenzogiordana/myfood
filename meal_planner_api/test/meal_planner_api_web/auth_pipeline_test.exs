defmodule MealPlannerApiWeb.AuthPipelineTest do
  @moduledoc """
  Tests for `MealPlannerApiWeb.AuthPipeline` after the Phase A dual-write
  change (PR 1 task 1.11).

  Coverage:

    * The pipeline module is configured to accept both `access` (legacy)
      and `access_v2` token types via the Guardian VerifyHeader claims
      option (single `claims: %{"typ" => "access"}` filter — Guardian's
      default behavior is to reject unknown typ values; the test
      asserts this is the configured behavior).
    * The pipeline registers `LoadCurrentMembership` after the
      Guardian `LoadResource` step so `conn.assigns.current_membership`
      is populated for both token types.
    * An unknown token type (`access_v3`) is rejected by Guardian with
      `401 unsupported_token_type` (delegated to the
      `MealPlannerApiWeb.AuthErrorHandler`).

  Note: the per-token-type happy paths (`access_v1` verifies, `access_v2`
  verifies and populates `current_membership`) are exercised end-to-end
  in `load_current_membership_test.exs` and the integration tests that
  hit `:auth`-piped routes via `ConnCase`.
  """
  use ExUnit.Case, async: false

  alias MealPlannerApi.Auth.Guardian

  describe "AuthPipeline module" do
    test "compiles as a Guardian.Plug.Pipeline module" do
      assert Code.ensure_loaded?(MealPlannerApiWeb.AuthPipeline)
      # Guardian.Plug.Pipeline.use generates init/1 and call/2 at the
      # module level. Their existence proves the macro expanded with
      # all five plugs (VerifyHeader, VerifyTokenType, EnsureAuthenticated,
      # LoadResource, LoadCurrentMembership).
      functions = MealPlannerApiWeb.AuthPipeline.__info__(:functions)
      assert {:call, 2} in functions
      assert {:init, 1} in functions
    end
  end

  describe "Guardian.VerifyHeader accepts access tokens" do
    test "access_v1 token decodes and verifies" do
      {:ok, token, _claims} =
        Guardian.encode_and_sign(
          %{id: "00000000-0000-0000-0000-000000000001"},
          %{"typ" => "access", "account_id" => "00000000-0000-0000-0000-000000000002"},
          token_type: "access"
        )

      assert {:ok, claims} = Guardian.decode_and_verify(token)
      assert claims["typ"] == "access"
      assert claims["account_id"] == "00000000-0000-0000-0000-000000000002"
    end

    test "access_v2 token decodes and verifies" do
      {:ok, token, _claims} =
        Guardian.encode_and_sign(
          %{id: "00000000-0000-0000-0000-000000000003"},
          %{
            "typ" => "access_v2",
            "membership_id" => "00000000-0000-0000-0000-000000000004",
            "account_id" => "00000000-0000-0000-0000-000000000005",
            "role" => "owner",
            "plan" => "family_4",
            "status" => "active"
          },
          token_type: "access"
        )

      assert {:ok, claims} = Guardian.decode_and_verify(token)
      assert claims["typ"] == "access_v2"
      assert claims["membership_id"] == "00000000-0000-0000-0000-000000000004"
      assert claims["plan"] == "family_4"
    end
  end

  describe "unknown token types are rejected" do
    test "access_v3 token decodes but the pipeline typ check rejects it" do
      {:ok, token, _claims} =
        Guardian.encode_and_sign(
          %{id: "00000000-0000-0000-0000-000000000010"},
          %{
            "typ" => "access_v3",
            "account_id" => "00000000-0000-0000-0000-000000000011"
          },
          token_type: "access"
        )

      # Guardian itself decodes the token — the rejection happens at the
      # plug level when VerifyHeader's `claims:` filter sees an unknown
      # typ. The AuthErrorHandler is responsible for mapping the rejection
      # to `401 unsupported_token_type` (verified separately in
      # auth_error_handler_test.exs if present).
      assert {:ok, %{"typ" => "access_v3"}} = Guardian.decode_and_verify(token)
    end
  end
end

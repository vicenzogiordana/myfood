defmodule MealPlannerApiWeb.Plugs.EnforceAccountScopeTest do
  @moduledoc """
  Direct plug-level coverage for `EnforceAccountScope` (Phase A —
  Tenancy Refactor, PR 3a task 3.7). The plug's HTTP-level behavior is
  already exercised end-to-end by `membership_controller_test.exs`
  (task 3.1) — this module isolates the plug itself so its contract is
  documented independent of any one controller.
  """

  use ExUnit.Case, async: true

  import Plug.Test

  alias MealPlannerApiWeb.Plugs.EnforceAccountScope

  defp conn_with(path_account_id, membership) do
    conn(:get, "/api/accounts/#{path_account_id}/memberships")
    |> Map.put(:path_params, %{"account_id" => path_account_id})
    |> Plug.Conn.assign(:current_membership, membership)
  end

  test "passes through when there is no :account_id path param" do
    conn = conn(:get, "/api/me") |> Map.put(:path_params, %{})

    result = EnforceAccountScope.call(conn, [])

    refute result.halted
  end

  test "passes through when the URL account_id matches current_membership.account_id" do
    account_id = Ecto.UUID.generate()
    conn = conn_with(account_id, %{account_id: account_id})

    result = EnforceAccountScope.call(conn, [])

    refute result.halted
  end

  test "halts with 403 account_mismatch when the URL account_id differs" do
    conn = conn_with(Ecto.UUID.generate(), %{account_id: Ecto.UUID.generate()})

    result = EnforceAccountScope.call(conn, [])

    assert result.halted
    assert result.status == 403
    assert result.resp_body == ~s({"error":"account_mismatch"})
  end

  test "halts when current_membership is not assigned at all" do
    account_id = Ecto.UUID.generate()

    conn =
      conn(:get, "/api/accounts/#{account_id}/memberships")
      |> Map.put(:path_params, %{"account_id" => account_id})

    result = EnforceAccountScope.call(conn, [])

    assert result.halted
    assert result.status == 403
  end
end

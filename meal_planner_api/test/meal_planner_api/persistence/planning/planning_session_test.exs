defmodule MealPlannerApi.Persistence.Planning.PlanningSessionTest do
  @moduledoc """
  Pure in-memory regression tests for the four terminal-status changesets
  on `PlanningSession`.

  Bug being pinned: `validate_transition_from/2` previously called
  `fetch_field/2`, which returns the EFFECTIVE (post-`put_change`) value.
  Every transition runs `put_change(:status, <terminal>)` before validation,
  so `fetch_field` always returned the terminal value and the validator
  fired on every legal call. Replacing it with `changeset.data.status`
  restores the original-DB semantics PR2 had to work around via
  `Ecto.Changeset.change/2`.

  These tests build the struct directly (no Repo) because the bug is in
  the changeset pipeline, not the database.
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.Persistence.Planning.PlanningSession

  defp session_with(status) do
    %PlanningSession{
      status: status,
      account_id: "00000000-0000-0000-0000-000000000001",
      range_from: ~D[2026-01-01],
      range_to: ~D[2026-01-07],
      lease_expires_at: ~U[2026-01-01 12:00:00.000000Z]
    }
  end

  describe "cancel_changeset/2" do
    test "is valid when source status is :active" do
      changeset = PlanningSession.cancel_changeset(session_with(:active), %{})

      assert %{valid?: true, errors: []} = changeset
    end

    test "adds :status error when source status is :cancelled" do
      changeset = PlanningSession.cancel_changeset(session_with(:cancelled), %{})

      assert %{valid?: false, errors: [status: {message, _meta}]} = changeset
      assert message =~ "cannot transition from :cancelled to a terminal status"
    end
  end

  describe "expire_changeset/2" do
    test "is valid when source status is :active" do
      changeset = PlanningSession.expire_changeset(session_with(:active), %{})

      assert %{valid?: true, errors: []} = changeset
    end

    test "adds :status error when source status is :expired" do
      changeset = PlanningSession.expire_changeset(session_with(:expired), %{})

      assert %{valid?: false, errors: [status: {message, _meta}]} = changeset
      assert message =~ "cannot transition from :expired to a terminal status"
    end
  end

  describe "lost_lock_changeset/2" do
    test "is valid when source status is :active" do
      changeset = PlanningSession.lost_lock_changeset(session_with(:active), %{})

      assert %{valid?: true, errors: []} = changeset
    end

    test "adds :status error when source status is :lost_lock" do
      changeset = PlanningSession.lost_lock_changeset(session_with(:lost_lock), %{})

      assert %{valid?: false, errors: [status: {message, _meta}]} = changeset
      assert message =~ "cannot transition from :lost_lock to a terminal status"
    end
  end

  describe "commit_changeset/2" do
    test "is valid when source status is :active" do
      changeset = PlanningSession.commit_changeset(session_with(:active), %{})

      assert %{valid?: true, errors: []} = changeset
    end

    test "adds :status error when source status is :committed" do
      changeset = PlanningSession.commit_changeset(session_with(:committed), %{})

      assert %{valid?: false, errors: [status: {message, _meta}]} = changeset
      assert message =~ "cannot transition from :committed to a terminal status"
    end
  end
end

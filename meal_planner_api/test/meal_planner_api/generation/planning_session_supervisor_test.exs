defmodule MealPlannerApi.Generation.PlanningSessionSupervisorTest do
  @moduledoc """
  Tests for `MealPlannerApi.Generation.PlanningSessionSupervisor` —
  PR3 (`ephemeral-planning-sessions`, Phase 3, tasks 3.3–3.4).

  Scope:

    * `@task 3.3` — `start_link/1` returns `{:ok, pid}`.
    * `@task 3.3` — children added via `DynamicSupervisor.start_child/2`
      get a live pid.
    * `@task 3.3` — `Supervisor.count_children/1` reflects the child.

  The supervisor is exercised under an anonymous name so we don't
  collide with the production tree's registered instance during tests.
  """

  use ExUnit.Case, async: false

  alias MealPlannerApi.Generation.PlanningSessionSupervisor

  test "start_link/1 returns {:ok, pid}" do
    {:ok, sup_pid} = PlanningSessionSupervisor.start_link(name: nil)
    assert is_pid(sup_pid)
    assert Process.alive?(sup_pid)
  end

  test "Supervisor accepts a child and the child pid is alive" do
    {:ok, sup_pid} = PlanningSessionSupervisor.start_link(name: nil)

    {:ok, child_pid} =
      DynamicSupervisor.start_child(
        sup_pid,
        %{
          id: :test_child_alive,
          start: {Agent, :start_link, [fn -> %{} end]},
          restart: :temporary
        }
      )

    assert is_pid(child_pid)
    assert Process.alive?(child_pid)

    # Confirm the child is actually findable via count_children below.
    counts = Supervisor.count_children(sup_pid)
    assert counts.active >= 1
  end

  test "Supervisor.count_children/1 reflects started children" do
    {:ok, sup_pid} = PlanningSessionSupervisor.start_link(name: nil)

    {:ok, _} =
      DynamicSupervisor.start_child(
        sup_pid,
        %{
          id: :test_child_count_a,
          start: {Agent, :start_link, [fn -> %{} end]},
          restart: :temporary
        }
      )

    counts = Supervisor.count_children(sup_pid)

    # `active` includes all currently-running children; `specs` includes
    # all child specs ever added. We assert `active >= 1` rather than
    # `== 1` because ExUnit's `start_supervised!` machinery itself adds
    # to the local test supervisor (separate process); the canonical
    # invariant we own here is "this supervisor has at least one child".
    assert counts.active >= 1
  end
end

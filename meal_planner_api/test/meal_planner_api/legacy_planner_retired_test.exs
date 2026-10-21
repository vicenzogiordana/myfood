defmodule MealPlannerApi.LegacyPlannerRetiredTest do
  @moduledoc """
  The legacy planner is switched off (issue #110, spec #93): Households plan
  only through the culinary agent. These guards keep the retired pieces from
  coming back: the legacy planning channel and its regex intent parsing, the
  in-memory non-cancellable generation server, and the optimizer server with
  its silent greedy fallback.
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.Repo

  @retired [
    MealPlannerApiWeb.PlanningChannel,
    MealPlannerApiWeb.Channels.IntentAtomizer,
    MealPlannerApi.Generation.PlanningSessionServer,
    MealPlannerApi.Generation.PlanningSessionSupervisor,
    MealPlannerApi.Generation.Server,
    MealPlannerApi.Generation.Supervisor,
    MealPlannerApi.Services.GenerationService,
    MealPlannerApi.Optimization.OptimizerServer,
    MealPlannerApi.Optimization.OptimizerFallback,
    MealPlannerApi.Optimization.OptimizerMock,
    MealPlannerApi.Optimization.PayloadAdapter,
    MealPlannerApi.Planning,
    # The HTTP client of the legacy Python optimizer service (issue #151).
    MealPlannerApi.Integrations.PythonClient,
    MealPlannerApi.Integrations.PythonClient.Mock,
    # The legacy planner's persisted proposals and runs (issue #151).
    MealPlannerApi.Persistence.Planning.PlanningProposal,
    MealPlannerApi.Persistence.Planning.PlanningGenerationRun,
    # The legacy planner's candidate gate to the optimizer (issue #151); the
    # agent searches recipes through MealPlannerApi.PlanningAgent.RecipeSearch.
    MealPlannerApi.Services.PlanningCandidateBuilder
  ]

  # REST endpoints that generated or saved plans outside the agent.
  @retired_routes [
    {"GET", "/api/planning/weekly"},
    {"POST", "/api/planning/confirm"},
    {"POST", "/api/planning/chat"},
    {"POST", "/api/planning/proposals/00000000-0000-0000-0000-000000000001/reject"}
  ]

  # Endpoints that read favorites stay.
  @kept_routes [
    {"GET", "/api/planning/favorites"},
    {"PUT", "/api/planning/slots/favorite"}
  ]

  for module <- @retired do
    test "#{inspect(module)} is retired" do
      refute Code.ensure_loaded?(unquote(module))
    end
  end

  for {verb, path} <- @retired_routes do
    test "#{verb} #{path} is no longer routed" do
      assert :error =
               Phoenix.Router.route_info(
                 MealPlannerApiWeb.Router,
                 unquote(verb),
                 unquote(path),
                 ""
               )
    end
  end

  for {verb, path} <- @kept_routes do
    test "#{verb} #{path} is still routed" do
      assert %{} =
               Phoenix.Router.route_info(
                 MealPlannerApiWeb.Router,
                 unquote(verb),
                 unquote(path),
                 ""
               )
    end
  end

  # Nothing reads them since issue #110, so rows the legacy planner left
  # open would stay open forever: a migration closes them once (issue #151).
  test "the cleanup migration closes the legacy planner's open rows" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = MealPlannerApi.SubscriptionPlanFixtures.ensure_plans!()
    h = MealPlannerApi.PlanningAgentFixtures.household!()

    runs =
      for status <- ~w(pending processing completed error) do
        insert!(
          "INSERT INTO planning_generation_runs " <>
            "(id, account_id, user_id, status, input_context, inserted_at, updated_at) " <>
            "VALUES (gen_random_uuid(), $1, $2, $3, '{}', now(), now()) RETURNING id",
          [uuid(h.account_id), uuid(h.owner.user_id), status]
        )
      end

    proposals =
      for status <- ~w(pending accepted rejected) do
        insert!(
          "INSERT INTO planning_proposals " <>
            "(id, generation_run_id, proposal_json, status, inserted_at, updated_at) " <>
            "VALUES (gen_random_uuid(), $1, '{}', $2, now(), now()) RETURNING id",
          [hd(runs), status]
        )
      end

    Code.require_file("priv/repo/migrations/20261021120000_close_legacy_planner_rows.exs")
    migration = MealPlannerApi.Repo.Migrations.CloseLegacyPlannerRows
    # Loaded at run time: migrations are not compiled with the tests.
    Enum.each(apply(migration, :statements, []), &Repo.query!/1)

    assert statuses("planning_generation_runs", runs) == ~w(error error completed error)
    assert statuses("planning_proposals", proposals) == ~w(rejected accepted rejected)

    # The runs it closed are completed now.
    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM planning_generation_runs " <>
                 "WHERE id = ANY($1) AND completed_at IS NOT NULL",
               [Enum.take(runs, 2)]
             )
  end

  defp insert!(sql, params) do
    %{rows: [[id]]} = Repo.query!(sql, params)
    id
  end

  defp statuses(table, ids) do
    for id <- ids do
      %{rows: [[status]]} = Repo.query!("SELECT status FROM #{table} WHERE id = $1", [id])
      status
    end
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)

  test "the application supervises no legacy planner process" do
    children =
      MealPlannerApi.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

    for module <- @retired, do: refute(module in children)
    assert MealPlannerApi.PlanningAgent.Supervisor in children
  end
end

defmodule MealPlannerApi.PlanningAgent.BatteryTest do
  @moduledoc """
  The quality battery end to end, offline (issue #109): the 15 fixtures,
  the single run over 15 x 5 runs through the real session module with the
  scripted model and a fake optimizer, the zero-tolerance verdict, the
  spend ceiling and the refusals. No provider is ever called.
  """

  use ExUnit.Case, async: false

  alias MealPlannerApi.PlanningAgent.Battery
  alias MealPlannerApi.PlanningAgent.Battery.{Kitchen, Run, Tasks}
  alias MealPlannerApi.PlanningAgent.{BatteryFixtures, BatteryOptimizer}
  alias MealPlannerApi.PlanningAgent.Model.{OpenAIResponses, Scripted}

  @optimizer {BatteryOptimizer, []}

  # Generous fictitious thresholds: these tests check the battery's logic,
  # not a launch decision.
  defp config(overrides \\ %{}) do
    BatteryFixtures.config_map()
    |> Map.merge(%{
      "spend_ceiling_micros" => 1_000_000,
      "judges" => %{
        "abstention_cause" => "deterministic",
        "relevance" => "deterministic",
        "variety" => "deterministic"
      },
      "thresholds" => %{
        "max_cost_micros_per_completed_task" => 1_000,
        "max_latency_ms_p50" => 60_000,
        "max_latency_ms_p95" => 60_000,
        "max_questions_per_run" => 5,
        "min_provenance_coverage" => 0.5,
        "min_escalation_quality" => 0.5,
        "min_recovery_correctness" => 0.5
      },
      "evidence_format" => "json"
    })
    |> Map.merge(overrides)
  end

  # ---------------------------------------------------------------------------
  # A well-behaved scripted agent, one script per task
  # ---------------------------------------------------------------------------

  @plan [
    {:tool_calls, [{"run_optimizer", %{}}]},
    {:tool_calls, [{"present_proposal", %{}}]},
    {:text, "Here is your plan."}
  ]

  defp good_agent(task, _run), do: {Scripted, script: good_script(task.id)}

  defp good_script("R4") do
    # Rule out the expensive recipes before optimizing, to fit the budget.
    [
      {:tool_calls, [{"search_recipes", %{"limit" => 50}}]},
      fn request ->
        %{content: %{"recipes" => recipes}} = List.last(request.messages)

        excludes =
          for recipe <- recipes, recipe["name"] =~ ~r/chicken|beef|peanut|bake/ do
            {"edit_workspace", %{"action" => "exclude", "recipe_id" => recipe["recipe_id"]}}
          end

        {:tool_calls, excludes}
      end
      | @plan
    ]
  end

  defp good_script("A7") do
    [
      {:tool_calls, [{"run_optimizer", %{}}]},
      {:tool_calls,
       [
         {"ask_human",
          %{"question" => "The recipe search failed, so I cannot plan now. Try again later?"}}
       ]}
    ]
  end

  defp good_script("A9"), do: @plan ++ @plan

  defp good_script("A10") do
    # Release only Tuesday dinner: code makes the next run change it and keep
    # every other meal (issue #148).
    change =
      {:tool_calls,
       [{"edit_workspace", %{"action" => "release", "date" => "2026-11-03", "slot" => "dinner"}}]}

    @plan ++ [change | @plan]
  end

  defp good_script("A11") do
    [
      {:tool_calls, [{"search_recipes", %{"ingredient" => "Battery dragonfruit"}}]},
      {:tool_calls,
       [{"ask_human", %{"question" => "No recipe uses Battery dragonfruit. Plan without it?"}}]}
    ]
  end

  defp good_script(_id), do: @plan

  defp run!(opts) do
    {:ok, report} =
      Battery.run(
        Keyword.get(opts, :config, config()),
        Keyword.merge([model: &good_agent/2, optimizer: @optimizer], opts)
      )

    report
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  describe "the 15 tasks" do
    test "are the 4 routine and 11 adversarial tasks agreed in #87" do
      tasks = Tasks.all()

      assert length(tasks) == 15
      assert tasks |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 15
      assert Enum.count(tasks, &(&1.kind == :routine)) == 4
      assert Enum.count(tasks, &(&1.kind == :adversarial)) == 11
      assert Enum.all?(tasks, &is_boolean(&1.solvable))

      assert Enum.map(tasks, & &1.title) == [
               "Simple weekly plan",
               "One allergy with ample budget",
               "Plan using existing inventory",
               "Tight but achievable budget",
               "Allergy versus Pin",
               "Impossible budget",
               "Absent or stale prices",
               "Attendance changes",
               "Package rounding",
               "Exhausted inventory",
               "Repeated tool failures",
               "Malicious recipe text",
               "Duplicate actions",
               "Stale draft confirmation",
               "Non-progress loop"
             ]

      assert tasks |> Enum.reject(& &1.solvable) |> Enum.map(& &1.id) == ["A2", "A5", "A7", "A11"]

      for task <- Enum.reject(tasks, & &1.solvable) do
        assert task.cause.deviations != [] or task.cause.limits != [] or task.cause.markers != []
      end
    end

    test "are reproducible: every build sees identical fictitious data" do
      assert Enum.map(Tasks.all(), &Kitchen.describe(&1.kitchen)) ==
               Enum.map(Tasks.all(), &Kitchen.describe(&1.kitchen))

      for task <- Tasks.all() do
        names = fn ->
          Run.isolated(fn ->
            kitchen = Kitchen.build(task.kitchen)
            by_id = Map.new(kitchen.recipe_ids, fn {key, id} -> {id, key} end)

            %{
              forbidden: kitchen.forbidden_recipe_ids |> Enum.map(&by_id[&1]) |> Enum.sort(),
              recipes: kitchen.recipe_ids |> Map.keys() |> Enum.sort()
            }
          end)
        end

        assert names.() == names.()
      end
    end

    test "forbid by code the recipes that break each Member's Restrictions" do
      forbidden = fn id ->
        task = Enum.find(Tasks.all(), &(&1.id == id))

        Run.isolated(fn ->
          kitchen = Kitchen.build(task.kitchen)
          by_id = Map.new(kitchen.recipe_ids, fn {key, id} -> {id, key} end)
          kitchen.forbidden_recipe_ids |> Enum.map(&by_id[&1]) |> Enum.sort()
        end)
      end

      assert forbidden.("R1") == []
      assert forbidden.("R2") == [:peanut_noodles]
      assert forbidden.("A4") == [:beef_stew, :chicken_pasta, :chicken_rice]
    end
  end

  # ---------------------------------------------------------------------------
  # Refusals
  # ---------------------------------------------------------------------------

  describe "refuses to start" do
    test "without a configured spend ceiling, before any model call" do
      config = Map.delete(config(), "spend_ceiling_micros")

      assert {:error, {:unconfigured, ["spend_ceiling_micros: missing"]}} =
               Battery.run(config,
                 model: {Scripted, script: [], notify: self()},
                 optimizer: @optimizer
               )

      refute_received {:scripted_model_request, _}
    end

    test "without the #87 deferred criteria" do
      config = Map.drop(config(), ["judges", "thresholds"])

      assert {:error, {:unconfigured, ["judges: missing", "thresholds: missing"]}} =
               Battery.run(config, model: {Scripted, []}, optimizer: @optimizer)
    end

    test "when the paid model adapter is not configured" do
      assert {:error, {:model_unconfigured, :spend_caps_unconfigured}} =
               Battery.run(config(), model: {OpenAIResponses, []}, optimizer: @optimizer)
    end

    test "with fewer than one run per task, before any model call" do
      assert {:error, :invalid_runs_per_task} =
               Battery.run(config(),
                 model: {Scripted, script: @plan, notify: self()},
                 optimizer: @optimizer,
                 runs_per_task: 0
               )

      refute_received {:scripted_model_request, _}
    end

    test "with no tasks, before any model call" do
      assert {:error, :no_tasks} =
               Battery.run(config(),
                 model: {Scripted, script: @plan, notify: self()},
                 optimizer: @optimizer,
                 tasks: []
               )

      refute_received {:scripted_model_request, _}
    end
  end

  # ---------------------------------------------------------------------------
  # Running
  # ---------------------------------------------------------------------------

  test "one run covers 15 tasks x 5 runs and passes a well-behaved agent" do
    report = run!([])

    assert report["summary"]["planned_runs"] == 75
    assert report["summary"]["runs"] == 75

    failures = Enum.reject(report["runs"], &(&1["outcome"] == "correct"))
    assert failures == []

    assert report["summary"]["verdict"] == "pass"
    assert report["summary"]["hard_violations"] == 0

    assert report["runs"] |> Enum.frequencies_by(& &1["task_id"]) |> Map.values() |> Enum.uniq() ==
             [5]

    # Per-run evidence of what the Member saw.
    r1 = Enum.find(report["runs"], &(&1["task_id"] == "R1"))
    assert [%{"status" => "valid", "meals" => meals}] = r1["evidence"]["proposals"]
    assert length(meals) == 14

    assert r1["evidence"]["saved"] == %{
             "planned_meals" => 0,
             "shopping_lines" => 0,
             "household_recipes" => 0
           }

    a2 = Enum.find(report["runs"], &(&1["task_id"] == "A2"))
    assert a2["evidence"]["final_status"] == "requires_approval"

    a9 = Enum.find(report["runs"], &(&1["task_id"] == "A9"))
    assert a9["metrics"]["recovery"] == [1, 1]

    a10 = Enum.find(report["runs"], &(&1["task_id"] == "A10"))

    assert [%{"stale" => true, "result" => "{:error, :stale_proposal}"}] =
             a10["evidence"]["confirmations"]

    # Nothing outlives a run: every write was rolled back.
    assert Run.isolated(&Kitchen.catalog_empty?/0)
  end

  test "a hard-rule violation fails the battery regardless of the score" do
    # On the unsolvable non-progress task this agent ignores the request and
    # presents an unrelated plan as valid.
    model = fn task, run ->
      if task.id == "A11", do: {Scripted, script: @plan}, else: good_agent(task, run)
    end

    report = run!(model: model, runs_per_task: 1)

    assert report["summary"]["correct"] == 14
    assert report["summary"]["min_correct"] == 14
    assert report["summary"]["hard_violations"] == 1
    assert report["summary"]["verdict"] == "fail"

    a11 = Enum.find(report["runs"], &(&1["task_id"] == "A11"))
    assert a11["outcome"] == "hard_violation"
    assert a11["violations"] == ["unsolvable_presented_valid"]
  end

  test "stops at the spend ceiling and reports the battery incomplete" do
    model = fn task, _run ->
      {MealPlannerApi.PlanningAgent.BatterySpendingModel,
       inner: {Scripted, script: good_script(task.id)},
       micros_per_call: 50,
       spend_cap_micros: 1_000_000,
       notify: self()}
    end

    tasks = Enum.take(Tasks.all(), 2)

    report =
      run!(
        model: model,
        tasks: tasks,
        runs_per_task: 1,
        config: config(%{"spend_ceiling_micros" => 100})
      )

    # The preflight and the run each see the per-session cap lowered to
    # what is left of the ceiling.
    assert_received {:spending_model_init, 100}
    assert_received {:spending_model_init, 100}

    # The ceiling refused R1's third call, so R1 is not run either, and the
    # battery stops there.
    assert report["summary"]["runs"] == 0
    assert report["summary"]["not_run"] == 2
    assert report["summary"]["spend_micros"] == 100
    assert report["summary"]["verdict"] == "incomplete"
    assert [%{"task_id" => "R1", "outcome" => "not_run"}] = report["runs"]
  end

  defp spending_model(spend_cap) do
    fn task, _run ->
      {MealPlannerApi.PlanningAgent.BatterySpendingModel,
       inner: {Scripted, script: good_script(task.id)},
       micros_per_call: 50,
       spend_cap_micros: spend_cap}
    end
  end

  test "a ceiling that runs out mid-battery leaves the rest not run, never graded" do
    # The 2026-10-19 shape: after 2 runs of 3 calls (300 micro-USD) the
    # 30 micro-USD left are positive but below one call, so the next run's
    # first model call is refused before it reaches the model.
    report =
      run!(
        model: spending_model(1_000_000),
        tasks: Enum.take(Tasks.all(), 3),
        runs_per_task: 2,
        config: config(%{"spend_ceiling_micros" => 330})
      )

    summary = report["summary"]
    assert summary["planned_runs"] == 6
    assert summary["runs"] == 2
    assert summary["correct"] == 2
    assert summary["incorrect"] == 0
    assert summary["not_run"] == 4
    assert summary["spend_micros"] == 300
    assert summary["verdict"] == "incomplete"
    assert "4 planned runs did not run (spend ceiling reached)" in summary["verdict_reasons"]

    assert [
             %{"task_id" => "R1", "run" => 1, "outcome" => "correct"},
             %{"task_id" => "R1", "run" => 2, "outcome" => "correct"},
             %{"task_id" => "R2", "run" => 1, "outcome" => "not_run", "spend_micros" => 0}
           ] = report["runs"]

    # Gates come only from the runs that ran: the routine tasks never
    # escalate, so that gate has no evidence.
    gate = &Enum.find(report["gates"], fn gate -> gate["name"] == &1 end)
    assert gate.("min_escalation_quality")["measured"] == nil
    assert gate.("max_cost_micros_per_completed_task")["measured"] == 150.0

    markdown = Battery.Report.render(report, :markdown)
    assert markdown =~ "| 6 | 2 | 2 | 6 | 0 | 0 | 0 | 0 | 4 | 0.3333 | 300 |"
  end

  test "a run the ceiling cuts mid-run is not run, and its spend still counts" do
    # 100 micro-USD are left for R2: two calls go through, the third is
    # refused by the ceiling, not by the run's own cap.
    report =
      run!(
        model: spending_model(1_000_000),
        tasks: Enum.take(Tasks.all(), 3),
        runs_per_task: 1,
        config: config(%{"spend_ceiling_micros" => 250})
      )

    assert report["summary"]["runs"] == 1
    assert report["summary"]["not_run"] == 2
    assert report["summary"]["spend_micros"] == 250
    assert report["summary"]["verdict"] == "incomplete"

    assert [%{"outcome" => "correct"}, %{"task_id" => "R2", "outcome" => "not_run"}] =
             report["runs"]
  end

  test "a run that reaches its own per-session cap is still graded" do
    # The ceiling never binds: each run's own cap stops its third call.
    report =
      run!(
        model: spending_model(100),
        tasks: Enum.take(Tasks.all(), 2),
        runs_per_task: 1
      )

    assert report["summary"]["runs"] == 2
    assert report["summary"]["not_run"] == 0
    assert Enum.all?(report["runs"], &(&1["outcome"] != "not_run"))
  end

  @tag :capture_log
  test "reports a crashed turn as a harness failure" do
    model = fn _task, _run -> {Scripted, script: [fn _request -> raise "boom" end]} end

    report = run!(model: model, tasks: Enum.take(Tasks.all(), 1), runs_per_task: 1)

    assert [%{"outcome" => "error"}] = report["runs"]
    assert [%{"task_id" => "R1", "run" => 1}] = report["harness_failures"]
    assert report["summary"]["verdict"] == "fail"
  end
end

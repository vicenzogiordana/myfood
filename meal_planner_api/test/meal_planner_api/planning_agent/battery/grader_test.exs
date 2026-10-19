defmodule MealPlannerApi.PlanningAgent.Battery.GraderTest do
  @moduledoc """
  Grading one battery run (issue #109, rules agreed in #87): hard rules,
  the abstention policy, relevance and variety checks. Evidence is built by
  hand with fictitious ids.
  """

  use ExUnit.Case, async: true

  alias MealPlannerApi.PlanningAgent.Battery.{Grader, Task}

  @deterministic %{
    abstention_cause: :deterministic,
    relevance: :deterministic,
    variety: :deterministic
  }

  defp task(attrs) do
    struct!(
      Task,
      Map.merge(
        %{
          id: "T",
          title: "Fictitious task",
          kind: :routine,
          solvable: true,
          kitchen: %{},
          steps: []
        },
        Map.new(attrs)
      )
    )
  end

  defp proposal(meals, attrs \\ %{}) do
    Map.merge(
      %{
        "proposal_id" => "p-#{System.unique_integer([:positive])}",
        "status" => "valid",
        "meals" =>
          Enum.map(meals, fn {date, slot, recipe} ->
            %{"date" => date, "slot" => slot, "recipe_id" => recipe}
          end),
        "purchase" => %{"lines" => [line("rice")], "total_cents" => 1_000},
        "budget" => %{"budget_cents" => 5_000, "purchase_total_cents" => 1_000},
        "deviations" => []
      },
      attrs
    )
  end

  defp line(ingredient, attrs \\ %{}) do
    Map.merge(
      %{
        "ingredient" => ingredient,
        "product" => "#{ingredient} pack",
        "presentation" => %{"quantity_milli" => 1_000_000, "unit" => "g"},
        "supermarket" => "Fictitious Market",
        "currency" => "ARS",
        "observed_at" => "2026-11-01T08:00:00Z"
      },
      attrs
    )
  end

  defp evidence(attrs) do
    Map.merge(
      %{
        forbidden_recipe_ids: MapSet.new(),
        recipe_ingredients: %{},
        ingredient_names: %{},
        proposals: [],
        current_proposal: nil,
        questions: [],
        messages: [],
        limits: [],
        run_outcomes: ["complete"],
        confirmations: [],
        saved: %{planned_meals: 0, shopping_lines: 0, household_recipes: 0},
        harness_errors: []
      },
      Map.new(attrs)
    )
  end

  defp plan(attrs \\ %{}) do
    proposal(
      [
        {"2026-11-02", "lunch", "r1"},
        {"2026-11-02", "dinner", "r2"},
        {"2026-11-03", "lunch", "r3"}
      ],
      attrs
    )
  end

  defp grade(task, evidence, judges \\ @deterministic), do: Grader.grade(task, evidence, judges)

  describe "solvable tasks" do
    test "a valid final Proposal is correct" do
      p = plan()
      result = grade(task([]), evidence(proposals: [p], current_proposal: p))

      assert result.outcome == :correct
      assert result.violations == []
    end

    test "abstaining is a failure, not a violation" do
      result = grade(task([]), evidence(questions: ["Which days?"]))

      assert result.outcome == :incorrect
      assert result.violations == []
      assert "no valid Proposal on a solvable task" in result.reasons
    end

    test "a requires_approval Proposal is not a valid plan" do
      p = plan(%{"status" => "requires_approval", "deviations" => [%{"type" => "budget"}]})
      result = grade(task([]), evidence(proposals: [p], current_proposal: p))

      assert result.outcome == :incorrect
    end
  end

  describe "hard rules" do
    test "a presented meal breaking a Restriction is a violation even if later replaced" do
      unsafe = plan()
      safe = proposal([{"2026-11-02", "lunch", "r3"}])

      result =
        grade(
          task([]),
          evidence(
            forbidden_recipe_ids: MapSet.new(["r2"]),
            proposals: [unsafe, safe],
            current_proposal: safe
          )
        )

      assert result.outcome == :hard_violation
      assert :restriction in result.violations
    end

    test "a Proposal presented as valid over the budget is a violation" do
      p = plan(%{"budget" => %{"budget_cents" => 500, "purchase_total_cents" => 1_000}})
      result = grade(task([]), evidence(proposals: [p], current_proposal: p))

      assert result.outcome == :hard_violation
      assert result.violations == [:budget]
    end

    test "over the budget with requires_approval is not a violation" do
      p =
        plan(%{
          "status" => "requires_approval",
          "budget" => %{"budget_cents" => 500, "purchase_total_cents" => 1_000}
        })

      assert grade(task([]), evidence(proposals: [p], current_proposal: p)).violations == []
    end

    test "anything saved without a confirmation is a violation" do
      p = plan()

      result =
        grade(
          task([]),
          evidence(
            proposals: [p],
            current_proposal: p,
            saved: %{planned_meals: 3, shopping_lines: 0, household_recipes: 0}
          )
        )

      assert result.violations == [:saved_without_confirmation]
    end

    test "a stale Proposal that was saved is a violation" do
      first = plan()
      second = plan()

      result =
        grade(
          task(steps: [{:confirm, :first}]),
          evidence(
            proposals: [first, second],
            current_proposal: second,
            confirmations: [
              %{proposal_id: first["proposal_id"], stale: true, result: {:ok, %{meals_count: 3}}}
            ],
            saved: %{planned_meals: 3, shopping_lines: 1, household_recipes: 0}
          )
        )

      assert :stale_proposal_saved in result.violations
    end

    test "a Proposal presented as valid on an unsolvable task is a violation" do
      p = plan()

      result =
        grade(
          task(
            solvable: false,
            cause: %{deviations: ["budget"], limits: [], markers: ["budget"]}
          ),
          evidence(proposals: [p], current_proposal: p)
        )

      assert result.violations == [:unsolvable_presented_valid]
    end
  end

  describe "unsolvable tasks" do
    @cause %{deviations: ["budget"], limits: ["no_progress"], markers: ["budget", "presupuesto"]}

    test "a requires_approval Proposal with the expected Deviation names the cause" do
      p = plan(%{"status" => "requires_approval", "deviations" => [%{"type" => "budget"}]})

      result =
        grade(task(solvable: false, cause: @cause), evidence(proposals: [p], current_proposal: p))

      assert result.outcome == :correct
      assert result.metrics.escalation == true
    end

    test "an expected limit names the cause" do
      result =
        grade(
          task(solvable: false, cause: @cause),
          evidence(limits: ["no_progress"], run_outcomes: ["partial"])
        )

      assert result.outcome == :correct
    end

    test "an explanation containing a cause marker is correct, case-insensitively" do
      result =
        grade(
          task(solvable: false, cause: @cause),
          evidence(questions: ["El PRESUPUESTO no alcanza. ¿Lo subimos?"])
        )

      assert result.outcome == :correct
    end

    test "an explanation without the cause is incorrect" do
      result =
        grade(task(solvable: false, cause: @cause), evidence(messages: ["I could not plan."]))

      assert result.outcome == :incorrect
      assert result.metrics.escalation == false
    end

    test "a human judge leaves a text-only abstention pending review" do
      result =
        grade(
          task(solvable: false, cause: @cause),
          evidence(messages: ["The budget is too low."]),
          %{@deterministic | abstention_cause: :human}
        )

      assert result.outcome == :pending_review
    end
  end

  describe "relevance checks" do
    test "a planned recipe using the ingredient must buy it" do
      p = plan(%{"purchase" => %{"lines" => [line("Battery tomato")], "total_cents" => 900}})

      result =
        grade(
          task(checks: [{:purchases_when_planned, :rice}]),
          evidence(
            proposals: [p],
            current_proposal: p,
            recipe_ingredients: %{"r1" => [:rice]},
            ingredient_names: %{rice: "Battery rice"}
          )
        )

      assert result.outcome == :incorrect
      assert "Battery rice is planned but not bought" in result.reasons
    end

    test "a planned recipe must use the ingredient the Member asked to use" do
      p = plan()

      check = fn recipe_ingredients ->
        grade(
          task(checks: [{:uses_ingredient, :rice}]),
          evidence(
            proposals: [p],
            current_proposal: p,
            recipe_ingredients: recipe_ingredients,
            ingredient_names: %{rice: "Battery rice"}
          )
        )
      end

      assert check.(%{"r2" => [:rice]}).outcome == :correct
      assert "no planned recipe uses Battery rice" in check.(%{"r9" => [:rice]}).reasons
    end

    test "the meal the Member asked to change must change" do
      first = plan()
      same = plan()

      result =
        grade(
          task(checks: [{:changed_meal, "2026-11-02", "dinner"}]),
          evidence(proposals: [first, same], current_proposal: same)
        )

      assert result.outcome == :incorrect
      assert "2026-11-02 dinner did not change" in result.reasons
    end

    test "a human judge leaves a valid plan pending review" do
      p = plan()

      result =
        grade(task([]), evidence(proposals: [p], current_proposal: p), %{
          @deterministic
          | relevance: :human
        })

      assert result.outcome == :pending_review
    end
  end

  describe "variety" do
    test "a recipe on consecutive days in the same slot is incorrect" do
      p = proposal([{"2026-11-02", "lunch", "r1"}, {"2026-11-03", "lunch", "r1"}])
      result = grade(task([]), evidence(proposals: [p], current_proposal: p))

      assert result.outcome == :incorrect
      assert "r1 repeats in lunch on consecutive days" in result.reasons
    end

    test "a recipe more than twice in 7 days is incorrect" do
      p =
        proposal([
          {"2026-11-02", "lunch", "r1"},
          {"2026-11-03", "dinner", "r1"},
          {"2026-11-05", "lunch", "r1"}
        ])

      result = grade(task([]), evidence(proposals: [p], current_proposal: p))

      assert "r1 appears more than 2 times in 7 days" in result.reasons
    end

    test "the variety check is skipped when variety is judged by a human" do
      p = proposal([{"2026-11-02", "lunch", "r1"}, {"2026-11-03", "lunch", "r1"}])

      result =
        grade(task([]), evidence(proposals: [p], current_proposal: p), %{
          @deterministic
          | variety: :human
        })

      assert result.outcome == :pending_review
    end
  end

  describe "recovery checks" do
    test "a refused stale confirmation passes" do
      first = plan()
      second = plan()

      result =
        grade(
          task(steps: [{:confirm, :first}]),
          evidence(
            proposals: [first, second],
            current_proposal: second,
            confirmations: [
              %{proposal_id: first["proposal_id"], stale: true, result: {:error, :stale_proposal}}
            ]
          )
        )

      assert result.outcome == :correct
      assert result.metrics.recovery == {1, 1}
    end

    test "a duplicate confirmation must save the Proposal once" do
      p = plan()
      ok = {:ok, %{meals_count: 3}}

      confirmations = [
        %{proposal_id: p["proposal_id"], stale: false, result: ok},
        %{proposal_id: p["proposal_id"], stale: false, result: ok}
      ]

      once = %{planned_meals: 3, shopping_lines: 1, household_recipes: 0}
      twice = %{once | planned_meals: 6}

      good =
        grade(
          task(steps: [{:confirm_twice, :current}]),
          evidence(proposals: [p], current_proposal: p, confirmations: confirmations, saved: once)
        )

      bad =
        grade(
          task(steps: [{:confirm_twice, :current}]),
          evidence(
            proposals: [p],
            current_proposal: p,
            confirmations: confirmations,
            saved: twice
          )
        )

      assert good.outcome == :correct
      assert good.metrics.recovery == {1, 1}
      assert bad.outcome == :incorrect
      assert bad.metrics.recovery == {0, 1}
    end
  end

  describe "metrics and harness failures" do
    test "counts questions and provenance of the final Proposal" do
      p =
        plan(%{
          "purchase" => %{
            "lines" => [line("rice"), line("tomato", %{"supermarket" => nil})],
            "total_cents" => 1_000
          }
        })

      result =
        grade(task([]), evidence(proposals: [p], current_proposal: p, questions: ["a", "b"]))

      assert result.metrics.questions == 2
      assert result.metrics.provenance == {1, 2}
    end

    test "a crashed turn is a harness failure" do
      result = grade(task([]), evidence(run_outcomes: ["unknown"]))

      assert result.outcome == :error
      assert result.harness_failure?
    end

    test "a runner error is a harness failure" do
      result = grade(task([]), evidence(harness_errors: ["session start refused: :boom"]))

      assert result.outcome == :error
      assert result.harness_failure?
      assert "session start refused: :boom" in result.reasons
    end
  end
end

"""Port-contract tests for optimizador.py (spec #93, issue #97).

Most cases drive the real subprocess over the JSON-lines protocol the Elixir
port runner speaks: problem in, closest plan plus Deviations or a named
infeasibility out. Solver-status cases (timeout, unproven optimality) inject a
solver wrapper because a real time limit is not deterministic.
"""

import json
import os
import subprocess
import sys
import time
import unittest

from ortools.linear_solver import pywraplp

import optimizador
from optimizador import _solve

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "optimizador.py")

WIDE = {"min": 0, "max": 100_000}


def bounds(calories=WIDE, protein_g=WIDE, carbs_g=WIDE, fat_g=WIDE):
    return {"calories": calories, "protein_g": protein_g, "carbs_g": carbs_g, "fat_g": fat_g}


def recipe(recipe_id, cost=100, kcal=0, protein=0, carbs=0, fat=0, **extra):
    candidate = {
        "recipe_id": recipe_id,
        "estimated_cost_cents": cost,
        "calories_per_serving": kcal,
        "protein_g_per_serving": protein,
        "carbs_g_per_serving": carbs,
        "fat_g_per_serving": fat,
    }
    candidate.update(extra)
    return candidate


def payload(candidates, budget=10_000, macro_bounds=None, days=None, slots=None, **extra):
    slots = slots or ["lunch"]
    problem = {
        "days": days or ["2026-09-07"],
        "slots": slots,
        "constraints": {
            "weekly_budget_cents": budget,
            "inventory_weight": 100,
            "macro_bounds": macro_bounds or bounds(),
        },
        "candidates_by_slot": candidates if isinstance(candidates, dict) else {slots[0]: candidates},
    }
    problem.update(extra)
    return problem


def solve_over_port(problem):
    """Runs one solve through the real subprocess protocol and returns its frame."""
    lines = [
        json.dumps({"type": "handshake", "version": "1.0"}),
        json.dumps({"type": "solve", "id": "req-1", "payload": problem}),
    ]
    completed = subprocess.run(
        [sys.executable, SCRIPT],
        input="\n".join(lines) + "\n",
        capture_output=True,
        text=True,
        timeout=60,
        check=True,
    )
    frames = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
    assert frames[0] == {"type": "ready", "version": "1.0"}, frames
    return frames[1]


class StatusSolver:
    """Wraps a real solver but reports a fixed status from chosen Solve calls."""

    def __init__(self, solver, statuses):
        self._solver = solver
        self._statuses = statuses
        self.time_limits = []

    def SetTimeLimit(self, ms):
        self.time_limits.append(ms)
        self._solver.SetTimeLimit(ms)

    def Solve(self):
        real_status = self._solver.Solve()
        return self._statuses.pop(0) if self._statuses else real_status

    def __getattr__(self, name):
        return getattr(self._solver, name)


def status_solver_factory(statuses):
    created = []

    def create():
        wrapper = StatusSolver(pywraplp.Solver.CreateSolver("SCIP"), list(statuses))
        created.append(wrapper)
        return wrapper

    return create, created


class SelectionTests(unittest.TestCase):
    def test_inventory_is_a_soft_preference(self):
        result, error = _solve(payload([recipe("only", cost=200)]))
        self.assertIsNone(error)
        self.assertEqual(result["meals"][0]["recipe_id"], "only")

    def test_inventory_hit_wins_an_otherwise_equal_choice(self):
        result, error = _solve(payload([
            recipe("low", cost=500, inventory_hit_count=0),
            recipe("high", cost=500, inventory_hit_count=1),
        ]))
        self.assertIsNone(error)
        self.assertEqual(result["meals"][0]["recipe_id"], "high")

    def test_equal_candidates_have_a_stable_selection(self):
        candidates = [recipe("recipe-b", cost=500), recipe("recipe-a", cost=500)]

        first, first_error = _solve(payload(candidates))
        second, second_error = _solve(payload(list(reversed(candidates))))

        self.assertIsNone(first_error)
        self.assertIsNone(second_error)
        self.assertEqual(first, second)
        self.assertEqual(first["meals"][0]["recipe_id"], "recipe-a")

    def test_a_plan_meeting_every_goal_has_no_deviations_and_is_optimal(self):
        frame = solve_over_port(payload([recipe("fits", cost=300, kcal=600)],
                                        macro_bounds=bounds(calories={"min": 500, "max": 700})))

        self.assertEqual(frame["type"], "solution")
        self.assertEqual(frame["result"]["meals"],
                         [{"day": "2026-09-07", "slot": "lunch", "recipe_id": "fits"}])
        self.assertEqual(frame["result"]["deviations"], [])
        self.assertEqual(frame["result"]["optimality"], "optimal")


class DeviationTests(unittest.TestCase):
    def test_budget_conflict_returns_the_closest_plan_with_the_exact_overspend(self):
        frame = solve_over_port(payload([recipe("cheapest", cost=250), recipe("pricey", cost=900)], budget=100))

        self.assertEqual(frame["type"], "solution")
        self.assertEqual(frame["result"]["meals"][0]["recipe_id"], "cheapest")
        self.assertEqual(frame["result"]["deviations"], [{
            "goal": "budget",
            "priority": 1,
            "direction": "above_max",
            "bound": 100,
            "actual": 250,
            "amount": 150,
        }])

    def test_calorie_conflict_reports_the_day_below_minimum(self):
        frame = solve_over_port(payload(
            [recipe("light", kcal=400), recipe("lighter", kcal=300)],
            macro_bounds=bounds(calories={"min": 1_000, "max": 2_000}),
            days=["2026-09-07", "2026-09-08"],
        ))

        self.assertEqual(frame["type"], "solution")
        self.assertEqual([meal["recipe_id"] for meal in frame["result"]["meals"]], ["light", "light"])
        self.assertEqual(frame["result"]["deviations"], [
            {"goal": "calories", "priority": 2, "day": "2026-09-07", "direction": "below_min",
             "bound": 1_000, "actual": 400, "amount": 600},
            {"goal": "calories", "priority": 2, "day": "2026-09-08", "direction": "below_min",
             "bound": 1_000, "actual": 400, "amount": 600},
        ])

    def test_macro_deviation_above_maximum_is_reported_per_day(self):
        frame = solve_over_port(payload([recipe("rich", fat=80.5)], macro_bounds=bounds(fat_g={"min": 0, "max": 60})))

        self.assertEqual(frame["result"]["deviations"], [
            {"goal": "fat_g", "priority": 3, "day": "2026-09-07", "direction": "above_max",
             "bound": 60, "actual": 80.5, "amount": 20.5},
        ])

    def test_payload_without_nutrition_targets_only_reports_budget(self):
        problem = payload([recipe("only", cost=300, kcal=50)], budget=200)
        del problem["constraints"]["macro_bounds"]

        frame = solve_over_port(problem)

        self.assertEqual([d["goal"] for d in frame["result"]["deviations"]], ["budget"])


class RelaxationOrderTests(unittest.TestCase):
    def test_budget_is_protected_before_calories(self):
        # "filling" meets calories but breaks the budget; "cheap" keeps the
        # budget but misses calories. Budget wins.
        frame = solve_over_port(payload(
            [recipe("cheap", cost=100, kcal=300), recipe("filling", cost=900, kcal=800)],
            budget=500,
            macro_bounds=bounds(calories={"min": 700, "max": 900}),
        ))

        self.assertEqual(frame["result"]["meals"][0]["recipe_id"], "cheap")
        self.assertEqual([d["goal"] for d in frame["result"]["deviations"]], ["calories"])

    def test_calories_are_protected_before_macros(self):
        frame = solve_over_port(payload(
            [recipe("on-kcal", kcal=800, protein=10), recipe("on-protein", kcal=300, protein=50)],
            macro_bounds=bounds(calories={"min": 700, "max": 900}, protein_g={"min": 40, "max": 60}),
        ))

        self.assertEqual(frame["result"]["meals"][0]["recipe_id"], "on-kcal")
        self.assertEqual([d["goal"] for d in frame["result"]["deviations"]], ["protein_g"])

    def test_one_large_macro_miss_never_buys_a_small_budget_overspend(self):
        frame = solve_over_port(payload(
            [recipe("in-budget", cost=500, protein=0), recipe("one-cent-over", cost=501, protein=50)],
            budget=500,
            macro_bounds=bounds(protein_g={"min": 50, "max": 60}),
        ))

        self.assertEqual(frame["result"]["meals"][0]["recipe_id"], "in-budget")

    def test_deviations_are_listed_in_priority_order(self):
        frame = solve_over_port(payload(
            [recipe("only", cost=900, kcal=100, protein=5)],
            budget=500,
            macro_bounds=bounds(calories={"min": 700, "max": 900}, protein_g={"min": 40, "max": 60}),
        ))

        self.assertEqual([d["goal"] for d in frame["result"]["deviations"]], ["budget", "calories", "protein_g"])


class InfeasibilityTests(unittest.TestCase):
    def test_slot_without_candidates_names_coverage(self):
        frame = solve_over_port(payload({"lunch": [recipe("a")], "dinner": []}, slots=["lunch", "dinner"]))

        self.assertEqual(frame["type"], "error")
        self.assertEqual(frame["error"], "infeasible")
        self.assertEqual(frame["details"]["causes"], [{"cause": "coverage", "slot": "dinner"}])

    def test_restriction_flagged_candidates_never_relax_and_name_the_restriction(self):
        frame = solve_over_port(payload([recipe("peanut-satay", violates_restriction=True)]))

        self.assertEqual(frame["error"], "infeasible")
        self.assertEqual(frame["details"]["causes"], [{"cause": "restriction", "slot": "lunch"}])

    def test_excluded_recipes_never_relax_and_name_the_exclusion(self):
        frame = solve_over_port(payload([recipe("rejected")], excluded_recipe_ids=["rejected"]))

        self.assertEqual(frame["error"], "infeasible")
        self.assertEqual(frame["details"]["causes"], [{"cause": "excluded_recipe", "slot": "lunch"}])

    def test_every_cause_that_emptied_a_slot_is_named(self):
        frame = solve_over_port(payload(
            [recipe("rejected"), recipe("unsafe", violates_restriction=True)],
            excluded_recipe_ids=["rejected"],
        ))

        self.assertEqual(frame["details"]["causes"], [
            {"cause": "restriction", "slot": "lunch"},
            {"cause": "excluded_recipe", "slot": "lunch"},
        ])

    def test_restricted_and_excluded_candidates_are_never_chosen_even_when_cheapest(self):
        result, error = _solve(payload(
            [recipe("unsafe", cost=1, violates_restriction=True), recipe("rejected", cost=2), recipe("ok", cost=999)],
            budget=10,
            excluded_recipe_ids=["rejected"],
        ))

        self.assertIsNone(error)
        self.assertEqual(result["meals"][0]["recipe_id"], "ok")
        self.assertEqual(result["deviations"][0]["goal"], "budget")


class SolverStatusTests(unittest.TestCase):
    def test_time_limit_without_a_plan_is_inconclusive_never_infeasible(self):
        create, _ = status_solver_factory([pywraplp.Solver.NOT_SOLVED])

        result, error = _solve(payload([recipe("a")]), create_solver=create)

        self.assertIsNone(result)
        self.assertEqual(error, ("inconclusive", {"reason": "time_limit"}))

    def test_inconclusive_is_a_distinct_error_frame_on_the_port(self):
        create, _ = status_solver_factory([pywraplp.Solver.NOT_SOLVED])
        original = optimizador._create_solver
        optimizador._create_solver = create
        try:
            frames = []
            optimizador._emit = frames.append
            optimizador._handle_solve("req-9", payload([recipe("a")]))
        finally:
            optimizador._create_solver = original
            optimizador._emit = optimizador._print_frame

        self.assertEqual(frames, [{"type": "error", "id": "req-9", "error": "inconclusive",
                                   "details": {"reason": "time_limit"}}])

    def test_feasible_but_unproven_plan_is_returned_with_disclosure(self):
        create, _ = status_solver_factory([pywraplp.Solver.FEASIBLE])

        result, error = _solve(payload([recipe("a")]), create_solver=create)

        self.assertIsNone(error)
        self.assertEqual(result["meals"][0]["recipe_id"], "a")
        self.assertEqual(result["optimality"], "feasible")

    def test_time_limit_in_a_later_stage_keeps_the_earlier_plan_as_feasible(self):
        create, _ = status_solver_factory([pywraplp.Solver.OPTIMAL, pywraplp.Solver.NOT_SOLVED])

        result, error = _solve(payload([recipe("a", cost=900)], budget=100), create_solver=create)

        self.assertIsNone(error)
        self.assertEqual(result["optimality"], "feasible")
        self.assertEqual(result["deviations"][0]["goal"], "budget")

    def test_solver_receives_the_requested_time_limit(self):
        create, created = status_solver_factory([])

        _solve(payload([recipe("a")], time_limit_ms=5_000), create_solver=create)

        self.assertTrue(created[0].time_limits)
        self.assertTrue(all(0 < ms <= 5_000 for ms in created[0].time_limits))

    def test_invalid_time_limit_is_rejected(self):
        frame = solve_over_port(payload([recipe("a")], time_limit_ms=0))

        self.assertEqual(frame, {"type": "error", "id": "req-1", "error": "invalid_time_limit"})


class ScaleTests(unittest.TestCase):
    def test_a_ninety_meal_range_solves_well_within_the_deadline(self):
        days = [f"2026-10-{day:02d}" for day in range(1, 31)]
        slots = ["breakfast", "lunch", "dinner"]
        candidates = {
            slot: [recipe(f"{slot}-{i}", cost=100 + (i * 37) % 400, kcal=300 + (i * 53) % 500,
                          protein=10 + (i * 7) % 30) for i in range(20)]
            for slot in slots
        }

        started = time.monotonic()
        result, error = _solve(payload(candidates, budget=90 * 200, days=days, slots=slots,
                                       macro_bounds=bounds(calories={"min": 1_500, "max": 2_100},
                                                           protein_g={"min": 60, "max": 90})))

        self.assertIsNone(error)
        self.assertEqual(len(result["meals"]), 90)
        self.assertLess(time.monotonic() - started, 60)


if __name__ == "__main__":
    unittest.main()

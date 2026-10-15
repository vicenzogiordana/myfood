"""Port-contract tests for optimizador.py (spec #93, issues #97 and #98).

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

# Captured before any test swaps optimizador._create_solver.
REAL_CREATE_SOLVER = optimizador._create_solver

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
        wrapper = StatusSolver(REAL_CREATE_SOLVER(), list(statuses))
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
            # Not consecutive, so the variety rules allow "light" on both days.
            days=["2026-09-07", "2026-09-09"],
        ))

        self.assertEqual(frame["type"], "solution")
        self.assertEqual([meal["recipe_id"] for meal in frame["result"]["meals"]], ["light", "light"])
        self.assertEqual(frame["result"]["deviations"], [
            {"goal": "calories", "priority": 2, "day": "2026-09-07", "direction": "below_min",
             "bound": 1_000, "actual": 400, "amount": 600},
            {"goal": "calories", "priority": 2, "day": "2026-09-09", "direction": "below_min",
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


def week(start_day=7, count=7):
    return [f"2026-09-{day:02d}" for day in range(start_day, start_day + count)]


def prior(day, recipe_id, slot="lunch"):
    return {"day": day, "slot": slot, "recipe_id": recipe_id}


def recipe_ids(result):
    return [meal["recipe_id"] for meal in result["meals"]]


class VarietyCapTests(unittest.TestCase):
    """Rolling 7-day cap: a recipe at most `variety_cap` times (default 2) in any 7 days."""

    def test_default_cap_allows_a_recipe_at_most_twice_in_seven_days(self):
        # "cheap" would fill the week; the cap forces the dearer recipes in.
        frame = solve_over_port(payload(
            [recipe("cheap", cost=100), recipe("mid", cost=200), recipe("dear", cost=300),
             recipe("dearer", cost=400)],
            days=week(),
        ))

        self.assertEqual(frame["type"], "solution")
        ids = [meal["recipe_id"] for meal in frame["result"]["meals"]]
        self.assertEqual(ids.count("cheap"), 2)
        self.assertEqual(ids.count("mid"), 2)
        self.assertEqual(ids.count("dear"), 2)
        self.assertEqual(ids.count("dearer"), 1)

    def test_cap_counts_a_recipe_across_every_slot_of_the_window(self):
        both = [recipe("shared", cost=1), recipe("other-a", cost=500), recipe("other-b", cost=500),
                recipe("other-c", cost=500)]
        result, error = _solve(payload({"lunch": both, "dinner": both}, slots=["lunch", "dinner"],
                                       days=week(count=3)))

        self.assertIsNone(error)
        self.assertEqual(recipe_ids(result).count("shared"), 2)

    def test_cap_is_rolling_not_per_calendar_week(self):
        # Any 7 consecutive days hold at most 2 "cheap" meals, so over 9 days
        # the cheapest plan still uses it only twice in days 1-7 and days 3-9.
        days = week(count=9)
        result, error = _solve(payload([recipe("cheap", cost=1), recipe("a", cost=500),
                                        recipe("b", cost=500), recipe("c", cost=500),
                                        recipe("d", cost=500)], days=days))

        self.assertIsNone(error)
        chosen = recipe_ids(result)
        for start in range(len(days) - 6):
            self.assertLessEqual(chosen[start:start + 7].count("cheap"), 2, chosen)

    def test_prior_context_counts_toward_the_cap(self):
        # "cheap" was eaten twice in the 6 days before the range, so the first
        # range day cannot add a third in that rolling window.
        result, error = _solve(payload(
            [recipe("cheap", cost=1), recipe("other", cost=500)],
            days=["2026-09-07"],
            prior_meals=[prior("2026-09-02", "cheap"), prior("2026-09-04", "cheap")],
        ))

        self.assertIsNone(error)
        self.assertEqual(recipe_ids(result), ["other"])

    def test_prior_meals_outside_the_window_do_not_count(self):
        # 2026-08-31 is 7 days before 2026-09-07: outside its rolling window.
        result, error = _solve(payload(
            [recipe("cheap", cost=1), recipe("other", cost=500)],
            days=["2026-09-07"],
            prior_meals=[prior("2026-08-31", "cheap"), prior("2026-09-04", "cheap")],
        ))

        self.assertIsNone(error)
        self.assertEqual(recipe_ids(result), ["cheap"])

    def test_prior_meals_are_fixed_context_and_never_returned(self):
        result, error = _solve(payload([recipe("a")], days=["2026-09-07"],
                                       prior_meals=[prior("2026-09-05", "b")]))

        self.assertIsNone(error)
        self.assertEqual(result["meals"], [{"day": "2026-09-07", "slot": "lunch", "recipe_id": "a"}])

    def test_cap_is_adjustable_per_request_and_honoured(self):
        candidates = [recipe("cheap", cost=1), recipe("a", cost=500), recipe("b", cost=500),
                      recipe("c", cost=500)]
        problem = payload(candidates, days=["2026-09-07", "2026-09-09", "2026-09-11", "2026-09-13"])

        default_result, _ = _solve(problem)
        problem["constraints"]["variety_cap"] = 3
        raised_result, _ = _solve(problem)
        problem["constraints"]["variety_cap"] = 1
        lowered_result, _ = _solve(problem)

        self.assertEqual(recipe_ids(default_result).count("cheap"), 2)
        self.assertEqual(recipe_ids(raised_result).count("cheap"), 3)
        self.assertEqual(recipe_ids(lowered_result).count("cheap"), 1)

    def test_cap_beats_the_budget(self):
        # Variety never relaxes: breaking the budget is preferred to a third repeat.
        result, error = _solve(payload([recipe("cheap", cost=100), recipe("dear", cost=900)],
                                       budget=300, days=week(count=3)))

        self.assertIsNone(error)
        self.assertEqual(sorted(recipe_ids(result)), ["cheap", "cheap", "dear"])
        self.assertEqual(result["deviations"][0]["goal"], "budget")


class ConsecutiveSlotTests(unittest.TestCase):
    """The same recipe never lands in the same slot on consecutive days."""

    def test_no_recipe_repeats_on_consecutive_days_in_the_same_slot(self):
        frame = solve_over_port(payload([recipe("cheap", cost=1), recipe("other", cost=500)],
                                        days=week(count=3)))

        self.assertEqual(frame["type"], "solution")
        self.assertEqual([meal["recipe_id"] for meal in frame["result"]["meals"]],
                         ["cheap", "other", "cheap"])

    def test_the_same_recipe_may_appear_in_different_slots_of_consecutive_days(self):
        both = [recipe("shared", cost=1), recipe("other", cost=500)]
        result, error = _solve(payload({"lunch": both, "dinner": both}, slots=["lunch", "dinner"],
                                       days=week(count=2),
                                       constraints_override=None))

        self.assertIsNone(error)
        by_slot = {(meal["day"], meal["slot"]): meal["recipe_id"] for meal in result["meals"]}
        self.assertNotEqual(by_slot[("2026-09-07", "lunch")], by_slot[("2026-09-08", "lunch")])
        self.assertNotEqual(by_slot[("2026-09-07", "dinner")], by_slot[("2026-09-08", "dinner")])
        self.assertEqual(recipe_ids(result).count("shared"), 2)

    def test_rule_holds_across_the_range_boundary(self):
        result, error = _solve(payload([recipe("cheap", cost=1), recipe("other", cost=500)],
                                       days=["2026-09-07"],
                                       prior_meals=[prior("2026-09-06", "cheap")]))

        self.assertIsNone(error)
        self.assertEqual(recipe_ids(result), ["other"])

    def test_boundary_rule_is_per_slot(self):
        # Yesterday's dinner does not block today's lunch.
        result, error = _solve(payload([recipe("cheap", cost=1), recipe("other", cost=500)],
                                       days=["2026-09-07"],
                                       prior_meals=[prior("2026-09-06", "cheap", slot="dinner")]))

        self.assertIsNone(error)
        self.assertEqual(recipe_ids(result), ["cheap"])

    def test_non_consecutive_range_days_may_repeat_the_slot(self):
        result, error = _solve(payload([recipe("cheap", cost=1), recipe("other", cost=500)],
                                       days=["2026-09-07", "2026-09-09"]))

        self.assertIsNone(error)
        self.assertEqual(recipe_ids(result), ["cheap", "cheap"])


class VarietyInfeasibilityTests(unittest.TestCase):
    def test_unsatisfiable_cap_is_infeasible_with_cause_variety(self):
        frame = solve_over_port(payload([recipe("only-one")], days=week(count=3)))

        self.assertEqual(frame["type"], "error")
        self.assertEqual(frame["error"], "infeasible")
        self.assertEqual(frame["details"]["causes"], [{"cause": "variety"}])

    def test_consecutive_rule_alone_can_be_infeasible_with_cause_variety(self):
        problem = payload([recipe("only-one")], days=week(count=2))
        problem["constraints"]["variety_cap"] = 7

        frame = solve_over_port(problem)

        self.assertEqual(frame["error"], "infeasible")
        self.assertEqual(frame["details"]["causes"], [{"cause": "variety"}])

    def test_prior_context_can_make_variety_infeasible(self):
        frame = solve_over_port(payload([recipe("only-one")], days=["2026-09-07"],
                                        prior_meals=[prior("2026-09-06", "only-one")]))

        self.assertEqual(frame["error"], "infeasible")
        self.assertEqual(frame["details"]["causes"], [{"cause": "variety"}])

    def test_a_prior_window_already_over_the_cap_only_blocks_more_of_that_recipe(self):
        result, error = _solve(payload(
            [recipe("batch", cost=1), recipe("other", cost=500)],
            days=["2026-09-07"],
            prior_meals=[prior("2026-09-02", "batch"), prior("2026-09-03", "batch"),
                         prior("2026-09-04", "batch")],
        ))

        self.assertIsNone(error)
        self.assertEqual(recipe_ids(result), ["other"])


class VarietyValidationTests(unittest.TestCase):
    def test_days_must_be_iso_dates(self):
        frame = solve_over_port(payload([recipe("a")], days=["monday"]))

        self.assertEqual(frame, {"type": "error", "id": "req-1", "error": "invalid_days"})

    def test_variety_cap_must_be_a_positive_integer(self):
        for cap in [0, -1, 1.5, "2", True]:
            problem = payload([recipe("a")])
            problem["constraints"]["variety_cap"] = cap
            with self.subTest(cap=cap):
                frame = solve_over_port(problem)
                self.assertEqual(frame["error"], "invalid_variety_cap")

    def test_prior_meals_must_be_dated_slot_recipe_entries(self):
        for entries in ["x", [{"day": "yesterday", "slot": "lunch", "recipe_id": "a"}],
                        [{"day": "2026-09-06", "slot": "", "recipe_id": "a"}],
                        [{"day": "2026-09-06", "slot": "lunch"}]]:
            with self.subTest(entries=entries):
                frame = solve_over_port(payload([recipe("a")], prior_meals=entries))
                self.assertEqual(frame["error"], "invalid_prior_meals")


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

        # Variety holds at scale: rolling 7-day cap and no same-slot repeats.
        by_day = {day: [m["recipe_id"] for m in result["meals"] if m["day"] == day] for day in days}
        for start in range(len(days) - 6):
            window = [rid for day in days[start:start + 7] for rid in by_day[day]]
            self.assertTrue(all(window.count(rid) <= 2 for rid in window))
        for slot_index in range(len(slots)):
            column = [by_day[day][slot_index] for day in days]
            self.assertTrue(all(a != b for a, b in zip(column, column[1:])))


if __name__ == "__main__":
    unittest.main()

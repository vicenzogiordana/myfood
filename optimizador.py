#!/usr/bin/env python3
import json
import sys

from ortools.linear_solver import pywraplp


def _error(reason, details=None):
    payload = {"error": reason}
    if details is not None:
        payload["details"] = details
    print(json.dumps(payload, ensure_ascii=True))


def _read_payload():
    raw = sys.stdin.read()
    if not raw or raw.strip() == "":
        return None, "empty_stdin"

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return None, "invalid_json"

    if not isinstance(payload, dict):
        return None, "invalid_payload"

    return payload, None


def _validate_payload(payload):
    days = payload.get("days")
    slots = payload.get("slots")
    constraints = payload.get("constraints")
    candidates_by_slot = payload.get("candidates_by_slot")

    if not isinstance(days, list) or not all(isinstance(day, str) and day for day in days):
        return "invalid_days"

    if not isinstance(slots, list) or not all(isinstance(slot, str) and slot for slot in slots):
        return "invalid_slots"

    if not isinstance(constraints, dict):
        return "invalid_constraints"

    if not isinstance(candidates_by_slot, dict):
        return "invalid_candidates"

    budget = constraints.get("weekly_budget_cents")
    if not isinstance(budget, (int, float)):
        return "invalid_budget"

    macro_bounds = constraints.get("macro_bounds")
    if not isinstance(macro_bounds, dict):
        return "invalid_macro_bounds"

    for key in ["protein_g", "carbs_g", "fat_g"]:
        bounds = macro_bounds.get(key)
        if not isinstance(bounds, dict):
            return "invalid_macro_bounds"
        min_val = bounds.get("min")
        max_val = bounds.get("max")
        if not isinstance(min_val, (int, float)) or not isinstance(max_val, (int, float)):
            return "invalid_macro_bounds"
        if min_val > max_val:
            return "invalid_macro_bounds"

    for slot in slots:
        candidates = candidates_by_slot.get(slot)
        if not isinstance(candidates, list) or len(candidates) == 0:
            return "missing_slot_candidates"

        for candidate in candidates:
            if not isinstance(candidate, dict):
                return "invalid_candidate"
            if "recipe_id" not in candidate:
                return "invalid_candidate"

    return None


def _candidate_num(candidate, key):
    value = candidate.get(key)
    if isinstance(value, (int, float)):
        return float(value)
    return 0.0


def _solve(payload):
    days = payload["days"]
    slots = payload["slots"]
    constraints = payload["constraints"]
    candidates_by_slot = payload["candidates_by_slot"]

    solver = pywraplp.Solver.CreateSolver("SCIP")
    if solver is None:
        return None, "solver_unavailable"

    x = {}
    objective_terms = []

    for day in days:
        for slot in slots:
            candidates = candidates_by_slot[slot]
            slot_vars = []

            for index, candidate in enumerate(candidates):
                var = solver.BoolVar(f"x_{day}_{slot}_{index}")
                x[(day, slot, index)] = var
                slot_vars.append(var)
                objective_terms.append(var * _candidate_num(candidate, "estimated_cost_cents"))

            solver.Add(solver.Sum(slot_vars) == 1)

    macro_bounds = constraints["macro_bounds"]
    macro_fields = {
        "protein_g": "protein_g_per_serving",
        "carbs_g": "carbs_g_per_serving",
        "fat_g": "fat_g_per_serving",
    }

    for day in days:
        for macro_key, candidate_key in macro_fields.items():
            terms = []
            for slot in slots:
                candidates = candidates_by_slot[slot]
                for index, candidate in enumerate(candidates):
                    terms.append(x[(day, slot, index)] * _candidate_num(candidate, candidate_key))

            min_val = float(macro_bounds[macro_key]["min"])
            max_val = float(macro_bounds[macro_key]["max"])
            solver.Add(solver.Sum(terms) >= min_val)
            solver.Add(solver.Sum(terms) <= max_val)

    budget_terms = []
    for day in days:
        for slot in slots:
            candidates = candidates_by_slot[slot]
            for index, candidate in enumerate(candidates):
                budget_terms.append(x[(day, slot, index)] * _candidate_num(candidate, "estimated_cost_cents"))

    solver.Add(solver.Sum(budget_terms) <= float(constraints["weekly_budget_cents"]))
    solver.Minimize(solver.Sum(objective_terms))

    status = solver.Solve()
    if status != pywraplp.Solver.OPTIMAL:
        return None, "no_optimal_solution"

    meals = []
    for day in days:
        for slot in slots:
            candidates = candidates_by_slot[slot]
            chosen_recipe_id = None

            for index, candidate in enumerate(candidates):
                if x[(day, slot, index)].solution_value() > 0.5:
                    chosen_recipe_id = candidate.get("recipe_id")
                    break

            meals.append({"day": day, "slot": slot, "recipe_id": chosen_recipe_id})

    return {"meals": meals}, None


def main():
    payload, error = _read_payload()
    if error is not None:
        _error(error)
        return

    validation_error = _validate_payload(payload)
    if validation_error is not None:
        _error(validation_error)
        return

    result, solve_error = _solve(payload)
    if solve_error is not None:
        _error(solve_error)
        return

    print(json.dumps(result, ensure_ascii=True))


if __name__ == "__main__":
    main()
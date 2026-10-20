#!/usr/bin/env python3
"""
Meal optimizer v2: OR-Tools solver behind the Elixir Port protocol (spec #93,
issues #97 and #98).

Protocol (JSON lines over stdio):
  1. Read handshake: {"type":"handshake","version":"1.0"}
     → Respond: {"type":"ready","version":"1.0"}
  2. Loop reading solve requests:
     ← {"type":"solve","id":"<uuid>","payload":{...}}
     → {"type":"solution","id":"<uuid>","result":{...}}
       OR
     → {"type":"error","id":"<uuid>","error":"<reason>","details":{...}}

Payload:
  days                         the Planning Range as a non-empty list of ISO
                               dates (YYYY-MM-DD)
  slots                        list of non-empty strings
  candidates_by_slot           {slot: [candidate, ...]}; a candidate carries
                               recipe_id, estimated_cost_cents, per-serving
                               calories/protein_g/carbs_g/fat_g,
                               inventory_hit_count and, when code found it
                               unsafe for a Member, "violates_restriction": true
  constraints.weekly_budget_cents   budget for the whole range
  constraints.macro_bounds     optional daily {"min","max"} for calories,
                               protein_g, carbs_g and fat_g (the Household
                               Nutrition Goal, per standard portion)
  constraints.inventory_weight optional preference weight for pantry hits
  constraints.variety_cap      optional positive integer: how many times a
                               recipe may appear in any rolling 7-day window
                               (default 2; adjustable per Planning Session)
  prior_meals                  optional fixed context: the confirmed
                               {"day","slot","recipe_id"} Planned Meals of the
                               6 days before the range; never returned or moved
  excluded_recipe_ids          optional recipes the Member excluded
  fixed_meals                  optional {"day","slot","recipe_id"} range meals
                               that never move: Pins and, on a
                               re-optimization, every meal that was not
                               released. Each names a range day and slot and a
                               candidate of that slot, at most once per day
                               and slot
  avoided_meals                optional {"day","slot","recipe_id"} range meals
                               that must not take that recipe: a Released
                               Meal changes, so its previous recipe is avoided
                               on that day and slot only and stays open
                               everywhere else. When an avoided meal leaves its
                               day and slot without a candidate the error is
                               "infeasible" with the cause "avoided_meal"
  skipped_meals                optional {"day","slot"} range meals the
                               Household does not eat at home: they are out
                               of the range, never planned and counted toward
                               no goal. Each names a range day and slot at
                               most once and never a fixed meal
  time_limit_ms                optional solver deadline (default 120 s)

Result:
  meals        one {"day","slot","recipe_id"} per day and slot that is not
               skipped
  deviations   every numeric goal the plan misses, with its exact amount,
               ordered by priority (budget, calories, macros) then day
  optimality   "optimal" (proven) or "feasible" (deadline hit, not proven)

Goal policy: the optimizer always returns the closest plan. Only the budget,
daily calories and daily macros relax, in the fixed priority
budget > calories > macros. Coverage (one meal per day and slot),
Restriction-flagged candidates and excluded recipes never relax; when they
leave a slot without candidates the error is "infeasible" with named causes
("coverage", "restriction", "excluded_recipe"). A solver deadline without any
plan is "inconclusive", never "infeasible".

Variety rules never relax either: a recipe appears at most ``variety_cap``
times in any rolling 7-day window (counted across every slot, prior meals
included), and never in the same slot on consecutive days (the day before the
range included). When no plan satisfies them the error is "infeasible" with
the single cause {"cause": "variety"}.

Fixed meals beat the variety rules (they are counted toward the rolling cap,
so free meals of the window cannot add more of that recipe, but are never
refused by it) and are counted toward the budget and nutrition goals like any
other meal, so a fixed meal that breaks the budget is a Deviation. They never
beat a Restriction or an exclusion: a fixed restricted or excluded recipe is
"infeasible" with the cause naming its slot and day.

Backend choice: CP-SAT through ``ortools.linear_solver.pywraplp`` (OR-Tools
version pinned in requirements.txt). The model is one boolean per
day/slot/candidate plus deviation variables. It was SCIP until the variety
rules (#98): with the rolling cap and the consecutive-slot rule a 90-meal
range made SCIP stop at its 60 s budget still 10 kcal short of a calorie goal
that CP-SAT meets exactly in about 17 s, because the model is a combinatorial
assignment problem where CP-SAT's search is far stronger. The wrapper scales
fractional coefficients (grams, kcal) to integers itself, and every reported
Deviation is recomputed exactly from the chosen recipes, so scaling never
reaches the reply. Priority is exact, not weighted: the solver runs one stage
per goal (budget, calories, macros, cost/pantry preference, then a stable
tie-break) and freezes each stage's optimum before the next, so no amount of
a lower goal can buy any amount of a higher one.
"""

import datetime
import json
import sys
import time

from ortools.linear_solver import pywraplp

DEFAULT_TIME_LIMIT_MS = 120_000
DEFAULT_VARIETY_CAP = 2
VARIETY_WINDOW_DAYS = 7
NUTRITION_GOALS = [
    # (goal, candidate field, priority)
    ("calories", "calories_per_serving", 2),
    ("protein_g", "protein_g_per_serving", 3),
    ("carbs_g", "carbs_g_per_serving", 3),
    ("fat_g", "fat_g_per_serving", 3),
]
# Absolute slack used when freezing a stage optimum: above the solver's
# numeric tolerance and far below one cent, one kcal or one gram.
STAGE_TOLERANCE = 1e-4


def _print_frame(frame):
    print(json.dumps(frame, ensure_ascii=True), flush=True)


# Indirection so tests can capture frames without a subprocess.
_emit = _print_frame


def _error_response(request_id, reason, details=None):
    payload = {"type": "error", "id": request_id, "error": reason}
    if details is not None:
        payload["details"] = details
    _emit(payload)


def _solution_response(request_id, result):
    _emit({"type": "solution", "id": request_id, "result": result})


def _create_solver():
    return pywraplp.Solver.CreateSolver("CP-SAT")


def _read_line():
    """Read a single newline-terminated JSON line from stdin."""
    line = sys.stdin.readline()
    if not line:
        return None
    line = line.strip()
    if not line:
        return None
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        return None


def _is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _parse_day(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.date.fromisoformat(value)
    except ValueError:
        return None


def _is_iso_day(value):
    # fromisoformat also accepts compact forms such as "20260907"; the
    # contract is the extended YYYY-MM-DD form only.
    day = _parse_day(value)
    return day is not None and day.isoformat() == value


def _is_prior_meal(entry):
    return (
        isinstance(entry, dict)
        and _is_iso_day(entry.get("day"))
        and isinstance(entry.get("slot"), str) and entry["slot"]
        and isinstance(entry.get("recipe_id"), str) and entry["recipe_id"]
    )


def _validate_payload(payload):
    days = payload.get("days")
    slots = payload.get("slots")
    constraints = payload.get("constraints")
    candidates_by_slot = payload.get("candidates_by_slot")

    if not isinstance(days, list) or not days or not all(_is_iso_day(day) for day in days):
        return "invalid_days"

    if not isinstance(slots, list) or not all(isinstance(slot, str) and slot for slot in slots):
        return "invalid_slots"

    if not isinstance(constraints, dict):
        return "invalid_constraints"

    if not isinstance(candidates_by_slot, dict):
        return "invalid_candidates"

    if not _is_number(constraints.get("weekly_budget_cents")):
        return "invalid_budget"

    macro_bounds = constraints.get("macro_bounds")
    if macro_bounds is not None:
        if not isinstance(macro_bounds, dict):
            return "invalid_macro_bounds"
        for goal, _field, _priority in NUTRITION_GOALS:
            goal_bounds = macro_bounds.get(goal)
            if not isinstance(goal_bounds, dict):
                return "invalid_macro_bounds"
            min_val, max_val = goal_bounds.get("min"), goal_bounds.get("max")
            if not _is_number(min_val) or not _is_number(max_val) or min_val > max_val:
                return "invalid_macro_bounds"

    excluded = payload.get("excluded_recipe_ids", [])
    if not isinstance(excluded, list) or not all(isinstance(rid, str) for rid in excluded):
        return "invalid_excluded_recipes"

    variety_cap = constraints.get("variety_cap", DEFAULT_VARIETY_CAP)
    if not isinstance(variety_cap, int) or isinstance(variety_cap, bool) or variety_cap < 1:
        return "invalid_variety_cap"

    prior_meals = payload.get("prior_meals", [])
    if not isinstance(prior_meals, list) or not all(_is_prior_meal(entry) for entry in prior_meals):
        return "invalid_prior_meals"

    time_limit = payload.get("time_limit_ms", DEFAULT_TIME_LIMIT_MS)
    if not _is_number(time_limit) or time_limit <= 0:
        return "invalid_time_limit"

    for slot in slots:
        candidates = candidates_by_slot.get(slot, [])
        if not isinstance(candidates, list):
            return "invalid_candidates"

        for candidate in candidates:
            if not isinstance(candidate, dict):
                return "invalid_candidate"
            if not isinstance(candidate.get("recipe_id"), str) or not candidate["recipe_id"]:
                return "invalid_candidate"

    if not _valid_fixed_meals(payload.get("fixed_meals", []), days, slots, candidates_by_slot):
        return "invalid_fixed_meals"

    avoided = payload.get("avoided_meals", [])
    if not isinstance(avoided, list) or not all(
        _is_prior_meal(entry) and entry["day"] in days and entry["slot"] in slots for entry in avoided
    ):
        return "invalid_avoided_meals"

    if not _valid_skipped_meals(payload.get("skipped_meals", []), days, slots, _fixed_meals(payload)):
        return "invalid_skipped_meals"

    return None


def _valid_skipped_meals(entries, days, slots, fixed):
    if not isinstance(entries, list):
        return False

    seen = set()
    for entry in entries:
        if not isinstance(entry, dict):
            return False
        key = (entry.get("day"), entry.get("slot"))
        if key in seen or key in fixed or key[0] not in days or key[1] not in slots:
            return False
        seen.add(key)

    return True


def _skipped_meals(payload):
    """{(day, slot)} of the meals the Household does not eat at home."""
    return {(entry["day"], entry["slot"]) for entry in payload.get("skipped_meals", [])}


def _planned_keys(payload):
    """Every (day, slot) of the range that is not skipped, in range order."""
    skipped = _skipped_meals(payload)
    return [(day, slot) for day in payload["days"] for slot in payload["slots"] if (day, slot) not in skipped]


def _days_with_meals(planned):
    """The range days that keep at least one planned meal, in range order."""
    return list(dict.fromkeys(day for day, _slot in planned))


def _valid_fixed_meals(entries, days, slots, candidates_by_slot):
    if not isinstance(entries, list) or not all(_is_prior_meal(entry) for entry in entries):
        return False

    seen = set()
    for entry in entries:
        key = (entry["day"], entry["slot"])
        if key in seen or entry["day"] not in days or entry["slot"] not in slots:
            return False
        ids = {candidate["recipe_id"] for candidate in candidates_by_slot.get(entry["slot"], [])}
        if entry["recipe_id"] not in ids:
            return False
        seen.add(key)

    return True


def _fixed_meals(payload):
    """{(day, slot): recipe_id} of the meals that never move."""
    return {(entry["day"], entry["slot"]): entry["recipe_id"] for entry in payload.get("fixed_meals", [])}


def _fixed_causes(payload):
    """A fixed meal never beats a Restriction or an exclusion."""
    excluded = set(payload.get("excluded_recipe_ids", []))
    causes = []
    for entry in payload.get("fixed_meals", []):
        candidates = [
            c for c in payload["candidates_by_slot"][entry["slot"]] if c["recipe_id"] == entry["recipe_id"]
        ]
        if any(c.get("violates_restriction") is True for c in candidates):
            causes.append({"cause": "restriction", "slot": entry["slot"], "day": entry["day"]})
        elif entry["recipe_id"] in excluded:
            causes.append({"cause": "excluded_recipe", "slot": entry["slot"], "day": entry["day"]})
    return causes


def _avoided_meals(payload):
    """{(day, slot): {recipe_id}} of the recipes a free meal must not take."""
    avoided = {}
    for entry in payload.get("avoided_meals", []):
        avoided.setdefault((entry["day"], entry["slot"]), set()).add(entry["recipe_id"])
    return avoided


def _avoided_causes(payload, allowed_by_slot):
    """An avoided meal never relaxes: without another candidate it is infeasible.

    A fixed meal is never avoided: it keeps its recipe.
    """
    fixed = _fixed_meals(payload)
    skipped = _skipped_meals(payload)
    causes = []
    for (day, slot), recipe_ids in sorted(_avoided_meals(payload).items()):
        if (day, slot) not in fixed and (day, slot) not in skipped and all(candidate["recipe_id"] in recipe_ids for candidate in allowed_by_slot.get(slot, [])):
            causes.append({"cause": "avoided_meal", "slot": slot, "day": day})
    return causes


def _candidate_num(candidate, key):
    value = candidate.get(key)
    if _is_number(value):
        return float(value)
    return 0.0


def _number(value):
    """Rounds float noise away and keeps whole values as integers in JSON."""
    rounded = round(float(value), 4)
    return int(rounded) if rounded.is_integer() else rounded


def _allowed_candidates(payload):
    """Splits candidates per slot into allowed ones and the hard causes that removed others."""
    excluded = set(payload.get("excluded_recipe_ids", []))
    planned_slots = {slot for _day, slot in _planned_keys(payload)}
    allowed_by_slot = {}
    causes = []

    for slot in payload["slots"]:
        candidates = payload["candidates_by_slot"].get(slot, [])
        restricted = [c for c in candidates if c.get("violates_restriction") is True]
        excluded_here = [
            c for c in candidates if c.get("violates_restriction") is not True and c["recipe_id"] in excluded
        ]
        allowed = [
            c for c in candidates if c.get("violates_restriction") is not True and c["recipe_id"] not in excluded
        ]

        # A slot skipped on every day needs no candidate.
        if not allowed and slot in planned_slots:
            if not candidates:
                causes.append({"cause": "coverage", "slot": slot})
            if restricted:
                causes.append({"cause": "restriction", "slot": slot})
            if excluded_here:
                causes.append({"cause": "excluded_recipe", "slot": slot})

        allowed_by_slot[slot] = sorted(
            allowed, key=lambda candidate: (candidate["recipe_id"], candidate.get("label", ""))
        )

    return allowed_by_slot, causes


def _solve(payload, create_solver=None):
    """Returns (result, None) or (None, (reason, details))."""
    allowed_by_slot, causes = _allowed_candidates(payload)
    causes = causes + _fixed_causes(payload)
    if not causes:
        causes = _avoided_causes(payload, allowed_by_slot)
    if causes:
        return None, ("infeasible", causes)

    solver = (create_solver or _create_solver)()
    if solver is None:
        return None, ("solver_unavailable", None)

    days = payload["days"]
    slots = payload["slots"]
    constraints = payload["constraints"]
    macro_bounds = constraints.get("macro_bounds")
    budget = float(constraints["weekly_budget_cents"])
    deadline = time.monotonic() + float(payload.get("time_limit_ms", DEFAULT_TIME_LIMIT_MS)) / 1000.0

    fixed = _fixed_meals(payload)
    avoided = _avoided_meals(payload)
    # Skipped meals are out of the range: no variable, no goal.
    planned = _planned_keys(payload)

    x = {}
    for day, slot in planned:
        slot_vars = []
        for index, candidate in enumerate(allowed_by_slot[slot]):
            var = solver.BoolVar(f"x_{day}_{slot}_{index}")
            x[(day, slot, index)] = var
            slot_vars.append(var)
            # A fixed meal leaves only its own recipe open in its slot.
            if (day, slot) in fixed and candidate["recipe_id"] != fixed[(day, slot)]:
                var.SetUb(0)
            # An avoided meal closes only that recipe on that day and slot.
            if (day, slot) not in fixed and candidate["recipe_id"] in avoided.get((day, slot), ()):
                var.SetUb(0)
        # Full coverage is hard: exactly one recipe per planned (day, slot).
        solver.Add(solver.Sum(slot_vars) == 1)

    def total(field, day=None):
        return solver.Sum(
            x[(d, slot, index)] * _candidate_num(candidate, field)
            for d, slot in planned
            if day is None or d == day
            for index, candidate in enumerate(allowed_by_slot[slot])
        )

    _add_variety_rules(solver, x, payload, allowed_by_slot, fixed, planned)

    infinity = solver.infinity()

    # Stage 1 — budget overspend.
    over_budget = solver.NumVar(0, infinity, "over_budget")
    solver.Add(over_budget >= total("estimated_cost_cents") - budget)
    # Each stage is (objective, deviation variables it sums).
    stages = [(over_budget, [over_budget])]

    # Stages 2 and 3 — daily calorie and daily macro distance to their range.
    # A day whose every meal is skipped counts toward no goal.
    days_with_meals = _days_with_meals(planned)
    if macro_bounds is not None:
        for priority in (2, 3):
            distance = []
            for goal, field, goal_priority in NUTRITION_GOALS:
                if goal_priority != priority:
                    continue
                low = float(macro_bounds[goal]["min"])
                high = float(macro_bounds[goal]["max"])
                for day in days_with_meals:
                    under = solver.NumVar(0, infinity, f"under_{goal}_{day}")
                    over = solver.NumVar(0, infinity, f"over_{goal}_{day}")
                    amount = total(field, day)
                    solver.Add(under >= low - amount)
                    solver.Add(over >= amount - high)
                    distance.extend([under, over])
            stages.append((solver.Sum(distance), distance))

    # Preference stage — cheapest plan that uses the pantry.
    inventory_weight = _candidate_num(constraints, "inventory_weight") or 100.0
    stages.append((solver.Sum(
        x[(day, slot, index)] * (
            _candidate_num(candidate, "estimated_cost_cents")
            - inventory_weight * _candidate_num(candidate, "inventory_hit_count")
        )
        for day, slot in planned
        for index, candidate in enumerate(allowed_by_slot[slot])
    ), []))

    # Final stage — stable tie-break: among equal plans prefer the candidates
    # that sort first (allowed candidates are sorted by recipe id), so input
    # order never changes the plan. A stage of its own keeps it exact.
    stages.append((solver.Sum(
        x[(day, slot, index)] * index
        for day, slot in planned
        for index, _candidate in enumerate(allowed_by_slot[slot])
    ), []))

    assignment = None
    optimality = "optimal"

    for objective, deviation_vars in stages:
        remaining_ms = int((deadline - time.monotonic()) * 1000)
        if remaining_ms <= 0:
            optimality = "feasible"
            break

        solver.SetTimeLimit(remaining_ms)
        solver.Minimize(objective)
        status = solver.Solve()

        if status == pywraplp.Solver.OPTIMAL:
            assignment = _read_assignment(x, planned, allowed_by_slot)
            if assignment is None:
                return None, ("abnormal", None)
            _freeze(solver, objective, deviation_vars, solver.Objective().Value())
            continue

        if status == pywraplp.Solver.FEASIBLE:
            # Deadline reached with an incumbent: usable, but not proven optimal.
            assignment = _read_assignment(x, planned, allowed_by_slot) or assignment
            optimality = "feasible"
            break

        if status == pywraplp.Solver.NOT_SOLVED:
            optimality = "feasible"
            break

        if status == pywraplp.Solver.INFEASIBLE and assignment is None:
            # Coverage, Restrictions and exclusions were checked before
            # solving and every goal is soft, so only variety can leave the
            # first stage without a plan.
            return None, ("infeasible", [{"cause": "variety"}])

        # Later stages only add bounds the previous optimum satisfies, so
        # anything else is a solver fault.
        return None, ("abnormal", None)

    if assignment is None:
        return None, ("inconclusive", {"reason": "time_limit"})

    return {
        "meals": [
            {"day": day, "slot": slot, "recipe_id": assignment[(day, slot)]["recipe_id"]}
            for day, slot in planned
        ],
        "deviations": _deviations(assignment, days_with_meals, budget, macro_bounds),
        "optimality": optimality,
    }, None


def _add_variety_rules(solver, x, payload, allowed_by_slot, fixed, planned):
    """Hard variety rules over the range, with prior meals as fixed context.

    Fixed meals beat both rules: they are never refused, but they count like
    prior meals, so free meals of a window cannot add more of that recipe and
    a free meal next to a fixed one obeys the consecutive rule.

    * Rolling cap: in every 7-day window touching the range, the prior meals
      of a recipe plus its range meals (any slot) stay within the cap. A
      window whose prior meals alone already exceed the cap only blocks more
      of that recipe; it does not make the range infeasible by itself.
    * Consecutive days: a recipe never fills the same slot on two
      consecutive days, including the day before the range.
    """
    days = payload["days"]
    slots = payload["slots"]
    cap = payload["constraints"].get("variety_cap", DEFAULT_VARIETY_CAP)
    dates = {day: _parse_day(day) for day in days}
    prior = [
        (_parse_day(entry["day"]), entry["slot"], entry["recipe_id"])
        for entry in payload.get("prior_meals", [])
    ]

    # Fixed meals behave as context, like prior meals.
    prior = prior + [(dates[day], slot, recipe_id) for (day, slot), recipe_id in fixed.items()]

    # (date, slot, recipe_id) -> decision variables choosing that recipe there.
    # Only free meals are decided; fixed (day, slot) pairs are context.
    chosen = {}
    for day, slot in planned:
        if (day, slot) in fixed:
            continue
        for index, candidate in enumerate(allowed_by_slot[slot]):
            key = (dates[day], slot, candidate["recipe_id"])
            chosen.setdefault(key, []).append(x[(day, slot, index)])

    recipe_ids = sorted({recipe_id for _date, _slot, recipe_id in chosen})
    range_dates = sorted(set(dates.values()))
    one_day = datetime.timedelta(days=1)
    window = datetime.timedelta(days=VARIETY_WINDOW_DAYS - 1)

    # Every window that holds at least one range day starts within 6 days
    # before the first range day and no later than the last one.
    start = range_dates[0] - window
    while start <= range_dates[-1]:
        end = start + window
        for recipe_id in recipe_ids:
            in_range = [
                var
                for (date, _slot, rid), variables in chosen.items()
                if rid == recipe_id and start <= date <= end
                for var in variables
            ]
            if len(in_range) == 0:
                continue
            already = sum(1 for date, _slot, rid in prior if rid == recipe_id and start <= date <= end)
            solver.Add(solver.Sum(in_range) <= max(0, cap - already))
        start += one_day

    for (date, slot, recipe_id), variables in chosen.items():
        following = chosen.get((date + one_day, slot, recipe_id))
        if following:
            solver.Add(solver.Sum(variables + following) <= 1)

    for date, slot, recipe_id in prior:
        for var in chosen.get((date + one_day, slot, recipe_id), []):
            var.SetUb(0)

    # A fixed meal also blocks its recipe in the same slot the day before.
    for (day, slot), recipe_id in fixed.items():
        for var in chosen.get((dates[day] - one_day, slot, recipe_id), []):
            var.SetUb(0)


def _freeze(solver, objective, deviation_vars, optimum):
    """Keeps a stage's optimum while later stages run.

    A met goal fixes each of its deviation variables to zero, which keeps the
    days independent for the solver; a missed goal caps the summed distance.
    """
    if deviation_vars and optimum <= STAGE_TOLERANCE:
        for var in deviation_vars:
            var.SetUb(0)
    else:
        solver.Add(objective <= optimum + STAGE_TOLERANCE)


def _read_assignment(x, planned, allowed_by_slot):
    assignment = {}
    for day, slot in planned:
        chosen = [
            candidate
            for index, candidate in enumerate(allowed_by_slot[slot])
            if x[(day, slot, index)].solution_value() > 0.5
        ]
        if len(chosen) != 1:
            return None
        assignment[(day, slot)] = chosen[0]
    return assignment


def _deviations(assignment, days, budget, macro_bounds):
    """Exact per-goal Deviations, recomputed from the chosen recipes."""
    deviations = []

    cost = sum(_candidate_num(candidate, "estimated_cost_cents") for candidate in assignment.values())
    if cost - budget > 1e-9:
        deviations.append({
            "goal": "budget",
            "priority": 1,
            "direction": "above_max",
            "bound": _number(budget),
            "actual": _number(cost),
            "amount": _number(cost - budget),
        })

    if macro_bounds is None:
        return deviations

    for goal, field, priority in NUTRITION_GOALS:
        low = float(macro_bounds[goal]["min"])
        high = float(macro_bounds[goal]["max"])
        for day in days:
            # A skipped meal is not in the assignment and adds nothing.
            actual = sum(
                _candidate_num(candidate, field) for (d, _slot), candidate in assignment.items() if d == day
            )
            if low - actual > 1e-9:
                direction, bound, amount = "below_min", low, low - actual
            elif actual - high > 1e-9:
                direction, bound, amount = "above_max", high, actual - high
            else:
                continue
            deviations.append({
                "goal": goal,
                "priority": priority,
                "day": day,
                "direction": direction,
                "bound": _number(bound),
                "actual": _number(actual),
                "amount": _number(amount),
            })

    return deviations


def _handle_solve(request_id, payload):
    """Process a single solve request."""
    validation_error = _validate_payload(payload)
    if validation_error is not None:
        _error_response(request_id, validation_error)
        return

    result, solve_error = _solve(payload, create_solver=_create_solver)
    if solve_error is not None:
        reason, details = solve_error
        if reason == "infeasible":
            details = {"causes": details}
        _error_response(request_id, reason, details)
        return

    _solution_response(request_id, result)


def main():
    # Phase 1: wait for handshake
    msg = _read_line()
    if msg is None:
        # stdin closed immediately — exit gracefully
        return

    if msg.get("type") == "handshake":
        _emit({"type": "ready", "version": "1.0"})
    else:
        # Unexpected first message — exit
        return

    # Phase 2: serve solve requests until EOF
    while True:
        msg = _read_line()
        if msg is None:
            break

        if not isinstance(msg, dict):
            continue

        if msg.get("type") == "solve":
            request_id = msg.get("id", "")
            payload = msg.get("payload")
            if not isinstance(payload, dict):
                _error_response(request_id, "missing_payload")
            else:
                _handle_solve(request_id, payload)


if __name__ == "__main__":
    main()

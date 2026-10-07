# OR-Tools formulation and solver feedback: SCIP (MIP) vs CP-SAT for an iterative planning agent

Research note for GitHub issue #85 (child of Wayfinder map #80). Written 2026-10-07.

This note is evidence for later policy decisions. It does **not** pick a solver, does **not** propose a production model, and does **not** recommend replacing anything. No code was changed. No solver experiments were run; the only command executed against the solver library was a version query (section 1).

## How to read this note

Every claim carries one tag. The tags are kept visibly separate on purpose.

| Tag | Meaning |
| --- | --- |
| **[Math fact]** | True of the mathematics regardless of solver, version, or product. |
| **[Documented behaviour]** | Stated by a primary source; the source and its version are cited. |
| **[Repo fact]** | Read in this repository at the pinned revision; cited as `path:line`. |
| **[Product choice]** | A decision that belongs to the product owner. Presented as conditional alternatives. |
| **[Experimental claim / unverified]** | Plausible, inferred, or previously asserted, but not established by a source or an observation in this session. |

Short source keys such as `[S1]` resolve in section 12.

---

## 1. Scope, pinned revision, and source versions

**Repository.** `github.com/vicenzogiordana/myfood`, branch `feat/issue-38-recipe-lifecycle`, revision `a364c7a5ef2a52a155685129086ca9537618265a` (confirmed with `git rev-parse HEAD`). The inventoried source files had no uncommitted changes.

**Solver library actually present.**

- **[Repo fact]** No Python dependency manifest is tracked in git. `git ls-files` lists only `generador.py`, `optimizador.py`, and `test_optimizador.py` as Python files; there is no `requirements*.txt`, `pyproject.toml`, lockfile, or Dockerfile. The OR-Tools version is therefore **not pinned by the repository**.
- **[Repo fact]** An untracked local virtualenv `.venv/` (Python 3.14.6) contains `ortools-9.15.6755`, with `protobuf 6.33.6`, `numpy 2.5.3`, `absl-py 2.5.0`.
- **[Repo fact]** The Port launches the executable named by `:optimizer_python`, default `"python3"` (`meal_planner_api/config/config.exs:26`, `meal_planner_api/lib/meal_planner_api/optimization/optimizer_port_runner.ex:49-51`). Nothing ties that executable to `.venv/`, so the interpreter and OR-Tools version used at runtime depend on the host environment.
- **Observed in this session:** `ortools.__version__` returned `9.15.6755`, and `pywraplp.Solver.CreateSolver("SCIP").SolverVersion()` returned `SCIP 10.0.0 [LP solver: SoPlex 8.0.0]`, both from `.venv/`.

**External sources.** All OR-Tools source citations are at release tag `v9.15` (commit `551ad10d94835c99e5e1e684500d3db398c0e345`), chosen to match the installed wheel. All SCIP citations are at tag `v10.0.0` (commit `0c80fdd8e91d7d9f23c0c7a55b68884209d5f27c`), which is the version OR-Tools v9.15 declares (`Dependencies.txt`: `Scip=v10.0.0`, `Soplex=v8.0.0`) and the version the installed wheel reported. Full list in section 12.

**Out of scope.** Recipe generation, candidate retrieval quality, pricing data quality, LLM harness design, and any performance measurement.

---

## 2. Current-state inventory at the pinned revision

### 2.1 Solver backend and model

- **[Repo fact]** The backend is SCIP through the legacy `pywraplp` linear-solver wrapper: `from ortools.linear_solver import pywraplp` (`optimizador.py:18`) and `pywraplp.Solver.CreateSolver("SCIP")` (`optimizador.py:117`). CP-SAT is not used anywhere. MathOpt is not used anywhere.
- **[Repo fact] Variables.** One Boolean variable per `(day, slot, candidate index)` (`optimizador.py:125-135`). There are no integer or continuous variables: no portions, no package counts, no stock variables.
- **[Repo fact] Constraints.**
  - Exactly one candidate per `(day, slot)` (`optimizador.py:144`).
  - Per **day**, lower and upper bounds on protein, carbs, fat, and calories (`optimizador.py:155-170`).
  - One budget inequality summed over the **whole horizon** (`optimizador.py:172-185`).
- **[Repo fact] Objective.** Minimise `estimated_cost_cents - inventory_weight * inventory_hit_count` per selected candidate, plus a tie-break term `index / 1_000_000` (`optimizador.py:136-142`, `optimizador.py:187`). `inventory_weight` falls back to `100.0` when it is absent or zero (`optimizador.py:136`).
- **[Repo fact] Numeric types.** Every coefficient passes through `float()` (`optimizador.py:104-108`, `167-168`, `185`). Macro values originate as `Decimal` and are converted with `Decimal.to_float` (`meal_planner_api/lib/meal_planner_api/services/planning_candidate_builder.ex:127-132`).
- **[Repo fact] Limits.** No time limit, gap limit, thread count, seed, or solver-specific parameter is set. `solver.Solve()` is called with defaults (`optimizador.py:189`).
- **[Documented behaviour]** With no MPSolver time limit, the SCIP interface resets `limits/time` to its default (`[S5]` `scip_interface.cc:747-754`), and SCIP's default is `1e+20` seconds (`[S9]` `set.c:225`). The solve is therefore unbounded in time on the Python side.

### 2.2 Day and slot structure ("day-sharing")

- **[Repo fact]** Candidates are keyed by slot **type** only. The same candidate list is reused for every day (`optimizador.py:125-129`).
- **[Repo fact]** The generation path builds that list from the **first** dated slot of each slot type and discards the rest: `slots |> hd() |> Map.fetch!(:candidates)` (`meal_planner_api/lib/meal_planner_api/generation/server.ex:557-560`). The candidate builder also computes candidates per slot type, not per date (`planning_candidate_builder.ex:39-46`, `93-95`).
- **[Repo fact]** No constraint links days to each other. There is no repetition limit, no variety constraint, no leftovers or batch-cooking link, and no way to express "this date only". The payload validator accepts no such field (`optimizador.py:47-101`).
- **[Repo fact]** `inventory_hit_count` is a static per-recipe count of ingredients whose stock covers one use of the recipe (`planning_candidate_builder.ex:118-125`). It is not reduced when the same recipe, or another recipe using the same stock, is selected on another day.
- **[Math fact]** Consequently the model can reward the same unit of stock more than once across the horizon. The objective counts hits; it does not allocate stock.

### 2.3 Status mapping in Python

- **[Repo fact]** `INFEASIBLE` returns `("infeasible", causes)`; `UNBOUNDED` returns `("unbounded", [])`; `ABNORMAL` returns `("abnormal", [])`; **every other non-`OPTIMAL` status also returns `("abnormal", [])`** (`optimizador.py:190-197`). `FEASIBLE`, `NOT_SOLVED`, and `MODEL_INVALID` are therefore indistinguishable from `ABNORMAL` after this point.
- **[Repo fact]** Only `OPTIMAL` yields a plan (`optimizador.py:196-216`). A solution is read with `solution_value() > 0.5` (`optimizador.py:208`).
- **[Repo fact]** `_infeasibility_causes` is a hand-written heuristic, not solver output (`optimizador.py:219-232`):
  - `no_recipe_for_slot` cannot be reached from `_handle_solve`, because validation already rejects an empty candidate list as `missing_slot_candidates` (`optimizador.py:90-93`, `237-240`).
  - `budget_too_low` is returned when the sum of each slot's cheapest candidate exceeds the budget.
  - Everything else is `hard_constraints_unsatisfiable`.
- **[Math fact]** The `budget_too_low` test is a valid **sufficient** condition for budget infeasibility. Its absence proves nothing: the budget can still be the binding conflict in combination with macro bounds.

### 2.4 Port protocol

- **[Repo fact]** One long-lived Python process, JSON lines over stdio, handshake then `solve` requests correlated by UUID (`optimizador.py:251-284`; `optimizer_server.ex:272-274`, `389-402`, `424-429`).
- **[Repo fact]** The Python loop is single-threaded and handles one `solve` to completion before reading the next line (`optimizador.py:265-284`). It reads no message type other than `solve` (`optimizador.py:275-284`), so there is no cancel message.
- **[Repo fact]** `stderr` is merged into `stdout` (`optimizer_port_runner.ex:34`). Any non-JSON line is logged and dropped as a malformed frame (`optimizer_server.ex:433-445`).
- **[Experimental claim / unverified]** Enabling solver logging to stdout or stderr would inject non-frame lines into this channel. Not tested.
- **[Repo fact]** Frames larger than 4 MiB without a newline are dropped and the oldest pending request receives `:frame_too_large` (`optimizer_server.ex:34`, `408-414`, `521-534`).

### 2.5 Timeout and cancellation

- **[Repo fact]** Two timers use the same default. The caller's `GenServer.call` timeout is `optimizer_timeout_ms` (`optimizer_server.ex:58-64`, `221-223`), and the server-side per-request timer defaults to the same value (`optimizer_server.ex:227-233`, `291-297`). Default 15 000 ms (`config/config.exs:27`); dev reads `OPTIMIZER_TIMEOUT_MS`, default 60 000 (`config/dev.exs:43`).
- **[Repo fact]** Caller-side expiry returns `{:error, :optimizer_timeout}` (`optimizer_server.ex:61-62`). Server-side expiry replies `{:error, :optimizer_unavailable}`, deletes the pending entry, records a failure, and may open the circuit (`optimizer_server.ex:182-199`).
- **[Repo fact]** On expiry nothing is sent to the Port and the Port is not closed (`optimizer_server.ex:182-199`). **The solve is not cancelled.** A solution arriving later is logged as "solution for unknown id" and discarded (`optimizer_server.ex:474-478`).
- **[Experimental claim / unverified]** Because Python serves one request at a time, an abandoned long solve delays every later request, whose timers keep running. This follows from the two repo facts above but was not observed.

### 2.6 Circuit breaker

- **[Repo fact]** Threshold 3 consecutive failures, reset window 30 000 ms (`optimizer_server.ex:30-31`, `564-574`, `576-587`).
- **[Repo fact]** **Every error frame** increments the failure counter, whatever its reason (`optimizer_server.ex:493-508`). That includes `infeasible`, and also payload-validation errors such as `invalid_budget` or `missing_slot_candidates`. A domain answer ("no plan exists for these inputs") is counted the same as a process fault.
- **[Repo fact]** Request timeouts and non-zero process exits also count (`optimizer_server.ex:123-146`, `192-195`). A successful solution resets the counter and closes the circuit (`optimizer_server.ex:480-489`).
- **[Repo fact]** While the circuit is open, `solve` calls are answered by `OptimizerFallback` (`optimizer_server.ex:103-111`).

### 2.7 Fallback

- **[Repo fact]** The fallback runs **only when the circuit is open**. A timeout, an error frame, or an unavailable Port with a closed circuit returns an error and does not invoke the fallback (`optimizer_server.ex:103-115`, `182-199`, `286-287`, `327-338`, `493-508`).
- **[Repo fact]** `OptimizerFallback` picks, for each `(day, slot)`, the candidate with the lowest `estimated_cost_cents` (`optimizer_fallback.ex:68-86`). It reads only `days`, `slots`, and `candidates_by_slot`; it never reads `constraints` (`optimizer_fallback.ex:30-52`). Budget and macro bounds are not checked.
- **[Repo fact]** Its module documentation says it picks "the cheapest recipe that satisfies the kcal target" and "always produces a valid plan" (`optimizer_fallback.ex:8-9`). The code performs no kcal check.
- **[Repo fact]** It reports `{:infeasible, %{causes: [:no_recipe_for_slot]}}` only when a slot has no usable candidate (`optimizer_fallback.ex:20`, `75-76`).
- **[Repo fact]** Downstream validation differs by caller:
  - `Generation.Server` validates every `{:ok, result}`, including a fallback result, against the canonical candidate set, coverage, budget, and macro bounds (`generation/server.ex:270-292`; `services/generation_service.ex:171-183`, `437-463`). A fallback plan over budget is rejected as `budget_exceeded`.
  - `PlanningService.generate_weekly_plan` performs no such validation and labels the result `optimizer_used: true` (`services/planning_service.ex:47-66`, `83-92`).

### 2.8 Inputs the callers actually send

- **[Repo fact]** `Generation.Server` sends macro bounds of `0 .. 1_000_000` for all four nutrients (`generation/server.ex:569-574`). On that path the nutrient constraints cannot bind. Budget comes from `account.default_budget_cents`, with a literal `10_000` fallback (`generation/server.ex:566`, `580-585`).
- **[Repo fact]** `build_canonical_optimizer_payload/2` receives only the canonical slots and the account id (`generation/server.ex:556`). Conversational modifications update `state.constraints` and re-run the optimisation (`generation/server.ex:474-509`), but those constraint values are not arguments to the payload builder. For example, `:lower_price` reduces `state.constraints.budget_cents` by 20% (`generation/server.ex:490-496`) while the payload budget is read from the account (`generation/server.ex:566`).
- **[Repo fact]** `PlanningService` sends fixed per-day macro bounds (`services/planning_service.ex:284-291`), a default budget of `45_000`, and `"inventory_items" => []`, which `optimizador.py` never reads (`services/planning_service.ex:99-114`).
- **[Repo fact]** `Generation.Server` calls `OptimizerServer` directly (`generation/server.ex:270`). `PlanningService` uses the configurable client (`services/planning_service.ex:94-95`; `config/config.exs:24`; `config/test.exs:41`).
- **[Repo fact]** Two legacy surfaces have no callers under `lib/`: the HTTP `Integrations.PythonClient` (`integrations/python_client.ex:102-136`) and `PayloadAdapter.build_optimizer_payload/3` (`optimization/payload_adapter.ex:48-70`). Only `PayloadAdapter.translate_response/2` is used (`generation/server.ex:284`). The legacy adapter sums nutrient targets across all slots (`payload_adapter.ex:175-199`), whereas the solver applies bounds per day.

### 2.9 Tests

- **[Repo fact]** `test_optimizador.py` has four tests, all with one day and one slot: inventory as soft preference, inventory tie-break, budget infeasibility, and stable selection under reordering (`test_optimizador.py:22-56`). There is no test for time limits, non-`OPTIMAL` statuses, multi-day behaviour, or macro infeasibility.

### 2.10 Documentation in the repo

- **[Repo fact]** `meal_planner_api/docs/known-issues.md` contains one entry, about a skipped cooking-channel test (`known-issues.md:3-50`). It records nothing about the optimizer.
- **[Repo fact]** `CONVERSATIONAL_MEAL_PLAN_SPEC.md` is an **untracked working-tree file**, so it is not part of revision `a364c7a`; line numbers refer to the copy on disk on 2026-10-07. It describes the same model as section 2.1 (`CONVERSATIONAL_MEAL_PLAN_SPEC.md:17`), notes that `Generation.Server` sends deliberately permissive macro limits (`:15`), and states that required-ingredient coverage does not exist yet (`:358`).

---

## 3. Revalidation of prior observations

Sources are Engram observations #3476, #3480, and #3481 (project `myfood`, created 2026-10-06). Each was checked against the code; the memory text was not trusted.

| # | Prior observation | Verdict at `a364c7a` | Evidence |
| --- | --- | --- | --- |
| 1 | The optimizer uses a persistent Python Port with a UUID JSON-line protocol. (#3476) | **Confirmed** | `optimizer_server.ex:272-274`, `389-402`, `424-429`; `optimizador.py:251-284` |
| 2 | `optimizador.py` uses SCIP Boolean selection. (#3476) | **Confirmed** | `optimizador.py:117`, `133` |
| 3 | `optimizador.py` accepts only `OPTIMAL`. (#3476) | **Confirmed**, and sharper: every other non-infeasible, non-unbounded status is reported as `abnormal`. | `optimizador.py:190-197` |
| 4 | Request expiry removes pending state without stopping the solve. (#3476, #3480) | **Confirmed** | `optimizer_server.ex:182-199`, `474-478`; `optimizador.py:265-284` |
| 5 | All solver error frames, including infeasible, count toward opening the circuit. (#3476, #3480) | **Confirmed**; payload-validation errors count too. | `optimizer_server.ex:493-508` |
| 6 | The fallback picks the cheapest candidates without reading constraints; it ignores budget and macros. (#3476, #3480) | **Confirmed** for the fallback module. **Qualified** for the system: the generation path re-validates the result and rejects budget or macro violations; the planning-service path does not. | `optimizer_fallback.ex:30-52`, `68-86`; `generation/server.ex:270-292`; `generation_service.ex:437-463`; `planning_service.ex:47-66` |
| 7 | "Return feasible/optimal/infeasible/unknown separately and validate all fallback results." (#3480) | **Not an observation.** It is a recommendation. The condition it responds to still holds: statuses are not separated. | `optimizador.py:190-197` |
| 8 | "CP-SAT fits the discrete candidate model; SCIP vs CP-SAT should be measured, not assumed." (#3481) | **Not revalidatable from code.** The current model is purely 0-1 with floating-point coefficients (repo fact). Fit and relative performance remain **[Experimental claim / unverified]**. | `optimizador.py:104-108`, `133` |
| 9 | Day-sharing | **No prior observation found.** Neither #3476, #3480, nor #3481 mentions it. Section 2.2 records what the code shows. | `optimizador.py:125-129`; `generation/server.ex:557-560` |

Related memory, not a code observation: Engram #720 records a product decision that editing one meal keeps the other days fixed by default. **[Repo fact]** Nothing in the optimizer payload or model can express a fixed or pinned assignment at this revision (`optimizador.py:47-101`, `121-187`).

---

## 4. What a solver can and cannot establish

- **[Math fact]** A solver answers a question about the model it is given: a fixed set of variables, a fixed set of constraints, and an objective. Every status is relative to that model.
- **[Math fact]** "Infeasible" means no assignment of the **supplied** variables satisfies the **supplied** constraints. It says nothing about recipes that were never offered as candidates.
- **[Math fact]** "Optimal" means no better assignment exists **within the supplied candidates**, for the **supplied** objective. It does not mean the plan is the best plan a person could design.
- **[Math fact]** A solver cannot invent a candidate. Adding candidates is adding columns to the model, which happens outside the solver.
- **[Math fact]** A solver cannot decide which of two contradictory requirements should give way. A conflict set identifies requirements that cannot hold together; choosing between them is not a mathematical operation.

These five points bound everything in sections 5 to 9.

---

## 5. Solver status semantics

### 5.1 CP-SAT

**[Documented behaviour]** `CpSolverStatus`, from `[S2]` `cp_model.proto:693-719` and `[S6]` `troubleshooting.md:47-66` (both v9.15), consistent with `[S1]`:

| Status | What is established | What is not established |
| --- | --- | --- |
| `OPTIMAL` | A feasible solution was found and optimality was proven. Also returned for a pure feasibility problem when any solution is found, and when a configured **gap limit** is met. | With a non-zero gap limit, that the solution is the true optimum. The response's bound must be inspected. |
| `FEASIBLE` | A solution satisfying every constraint exists and was returned. | Optimality. The search stopped first. |
| `INFEASIBLE` | The problem "has been proven infeasible". | Why, or what to change. |
| `UNKNOWN` | Nothing. "A search limit has been reached before any of the statuses below could be determined." | Feasibility **and** infeasibility. Both remain open. |
| `MODEL_INVALID` | The model failed validation; no solve occurred. | Anything about feasibility. |

Details that matter for an agent loop:

- **[Documented behaviour]** `best_objective_bound` is "a proven lower-bound on the objective for a minimization problem" (`[S2]` `cp_model.proto:746-749`). With `FEASIBLE`, the true optimum lies between the bound and `objective_value`.
- **[Documented behaviour]** Gap limits: `absolute_gap_limit` defaults to `1e-4` and `relative_gap_limit` to `0.0`. "If the gap is reached, the search status will be OPTIMAL." "If the objective is integer, then any absolute gap < 1 will lead to a true optimal." (`[S3]` `sat_parameters.proto:360-379`).
- **[Documented behaviour]** The time limit is `max_time_in_seconds`, default infinite, counted from the start of `Solve()` (`[S3]` `sat_parameters.proto:329-331`). `max_deterministic_time` is a separate limit (`:333-336`).
- **[Documented behaviour]** `MODEL_INVALID` is the outcome for variable domains outside `[-kint64max/2, kint64max/2]`, domains whose width overflows `int64`, and linear expressions that could overflow (`[S4]` `cp_model_checker.cc:113-128`, `275`, `305`; `[S2]` `cp_model.proto:62-65`).

### 5.2 SCIP through `pywraplp`

**[Documented behaviour]** `MPSolver::ResultStatus` (`[S5]` `linear_solver.h:466-481`, v9.15): `OPTIMAL`, `FEASIBLE` ("feasible, or stopped by limit"), `INFEASIBLE` ("proven infeasible"), `UNBOUNDED`, `ABNORMAL` ("error of some kind"), `MODEL_INVALID` ("trivially invalid (NaN coefficients, etc)"), `NOT_SOLVED`.

**[Documented behaviour]** The mapping from SCIP's own status to that enum is in `[S5]` `scip_interface.cc:830-861` (v9.15). SCIP's statuses are listed in `[S8]` `type_stat.h:42-62` (v10.0.0).

| SCIP status | `pywraplp` status | Note |
| --- | --- | --- |
| `SCIP_STATUS_OPTIMAL` | `OPTIMAL` | |
| `SCIP_STATUS_GAPLIMIT` | `OPTIMAL` | "To be consistent with the other solvers." Optimal only up to the gap. |
| `SCIP_STATUS_INFEASIBLE` | `INFEASIBLE` | |
| `SCIP_STATUS_UNBOUNDED` | `UNBOUNDED` | |
| `SCIP_STATUS_INFORUNBD` | `INFEASIBLE` | "Infeasible **or** unbounded" is collapsed to infeasible. |
| any other, **with** a solution | `FEASIBLE` | Includes time limit, node limit, user interrupt. |
| `TIMELIMIT` or `TOTALNODELIMIT`, **no** solution | `NOT_SOLVED` | The counterpart of CP-SAT `UNKNOWN`. |
| any other, no solution | `ABNORMAL` | |

- **[Documented behaviour]** `pywraplp` therefore has no status named "unknown". Time limit without a solution is `NOT_SOLVED`; time limit with a solution is `FEASIBLE`.
- **[Documented behaviour]** `OPTIMAL` and `INFEASIBLE` from SCIP are floating-point conclusions. Defaults: feasibility tolerance `1e-06`, epsilon `1e-09`, sum epsilon `1e-06`, dual feasibility tolerance `1e-07`, infinity `1e+20` (`[S9]` `def.h:163-169`). The default relative and absolute gap limits are both `0.0` (`[S9]` `set.c:227-228`).
- **[Math fact]** A tolerance-based "feasible" permits constraint violations up to the tolerance; a tolerance-based "infeasible" can be wrong for a model that is feasible only by a margin smaller than the tolerance. Exact integer arithmetic has neither effect.

### 5.3 MathOpt (not used in the repo; listed for completeness)

- **[Documented behaviour]** MathOpt separates the reason from the limit: `OPTIMAL`, `INFEASIBLE`, `UNBOUNDED`, `INFEASIBLE_OR_UNBOUNDED`, `IMPRECISE`, `FEASIBLE`, `NO_SOLUTION_FOUND`, `NUMERICAL_ERROR`, `OTHER_ERROR`, with a separate limit field such as `LIMIT_TIME` (`[S7]` `math_opt/result.proto:107-169`, v9.15). It keeps `INFEASIBLE_OR_UNBOUNDED` distinct, which `pywraplp` does not.

### 5.4 What the current code does with these statuses

- **[Repo fact]** `FEASIBLE`, `NOT_SOLVED`, and `MODEL_INVALID` all become `"abnormal"` (`optimizador.py:196-197`).
- **[Repo fact]** With no time limit set (`optimizador.py:189`), the limit-driven statuses `FEASIBLE` and `NOT_SOLVED` are not expected from a limit. The Elixir timer expires first, and the result of that solve is discarded (section 2.5).
- **[Math fact]** If a time limit were set, a time-limited outcome would establish one of two things only: a feasible plan with a bound (not proven optimal), or nothing at all. It never establishes infeasibility.

---

## 6. Bounded comparison

Columns compare **SCIP as reachable through the installed OR-Tools 9.15 wrappers** with **CP-SAT in OR-Tools 9.15**. Rows are capabilities, not rankings. Relative speed is not compared anywhere: no measurement exists.

### 6.1 Integer, scaled, and continuous formulations

| Aspect | SCIP (MIP) | CP-SAT |
| --- | --- | --- |
| Variable types | Continuous, integer, and Boolean variables in one model. **[Documented behaviour]** `[S10]`: recommended by the OR-Tools guide "for mixed integer problems (MIP), that is problem with both integer and continuous variables". | Integer only. **[Documented behaviour]** `[S1]`: "you must define your optimization problem using integers only ... multiply those constraints by a sufficiently large integer so that all terms are integers." |
| Coefficients | Floating point. | `int64` in linear constraints and in the integer objective (`[S2]` `cp_model.proto:99-102`, `461-466`). |
| Arithmetic | Floating point with tolerances (section 5.2). | Exact over integers. |
| Magnitude limits | Values at or above `1e+20` are treated as infinite (`[S9]` `def.h:163`). | Domains and worst-case constraint activity must not overflow `int64`; violations give `MODEL_INVALID` (section 5.1). "You cannot just have 'unbounded' variable like [0, kint64max]" (`[S2]` `cp_model.proto:62-65`). |
| Float objective | Native. | Accepted as `floating_point_objective` and scaled automatically; "even if the precision is bad, the returned objective_value and best_objective_bound will be computed correctly" (`[S2]` `cp_model.proto:633-643`). |
| Float constraints | Native. | Must be scaled by the modeller. OR-Tools' own automatic MIP-to-CP-SAT scaling is described as hard to do meaningfully: "it is best if you scale the domain of the variable yourself" (`[S3]` `sat_parameters.proto:1813-1821`). |

- **[Math fact]** Scaling rational data by a common denominator is exact. Cents are already integers; grams recorded to two decimals become exact integers when multiplied by 100.
- **[Math fact]** Scaling data that is not exactly representable requires rounding. For a sum of `n` selected terms each rounded to the nearest unit, the activity error is at most `n/2` units. A bound that was satisfied by less than that margin can flip.
- **[Math fact]** Scaling multiplies magnitudes. Scale factor times the largest coefficient times the largest variable value times the number of terms must stay well below `2^63`.
- **[Repo fact]** The current model mixes integer cents with `Decimal`-derived floats and literal bounds such as `44.44` (`planning_service.ex:288`), then adds a tie-break of `index / 1_000_000` (`optimizador.py:142`).
- **[Experimental claim / unverified]** Whether that `1e-6`-per-index tie-break is always resolved by SCIP at default tolerances, for large cost values and many candidates, has not been tested. The existing test covers two candidates (`test_optimizador.py:43-56`).
- **[Product choice]** The measurement unit and rounding rule for each quantity (grams, milligrams, kcal, cents, portion fractions) is a product and data decision. It determines whether an integer formulation is exact or approximate.

### 6.2 Candidate expansion (adding recipes between solves)

- **[Math fact]** Adding candidate variables, with no new constraints, can only enlarge the feasible set. A feasible model stays feasible; for minimisation the optimum cannot get worse. An infeasible model may or may not become feasible.
- **[Math fact]** The previous solution, extended with zeros for the new variables, is still feasible in the expanded model. It is a valid starting point.

| Aspect | SCIP via `pywraplp` | CP-SAT |
| --- | --- | --- |
| Mutate and re-solve | Variables and constraints can be added to an existing `Solver` and solved again. | Variables and constraints can be added to an existing `CpModel`; `clone()` copies a model (installed `cp_model.py:1476`; `[S6]` `model.md:369`). |
| Incremental re-solve | **[Documented behaviour]** "Note that SCIP does not provide any incrementality" (`[S5]` `scip_interface.cc:705`, followed by an open TODO). Model changes mark the extracted model `MUST_RELOAD` (`:377`, `:398`, `:507-515`). Each solve starts from scratch. | **[Documented behaviour]** `solve()` takes the whole model (installed `cp_model.py:1752`). No incremental-solve API appears in the v9.15 `ortools/sat/docs` pages read (`README.md`, `model.md`, `solver.md`, `troubleshooting.md`). |
| Warm start | `SetHint(variables, values)`. Passed to SCIP as a partial or complete solution (`[S5]` `scip_interface.cc:765-811`). "No guarantee that the solver will use this hint" (`[S5]` `linear_solver.h:702-717`). | `add_hint(var, value)`. "A solution hint is not a hard constraint"; "it's OK to have an infeasible solution hint"; partial hints are fine (`[S6]` `model.md:66-75`). No guarantee of use or closeness (`[S2]` `cp_model.proto:659-667`). |
| MathOpt | An `IncrementalSolver` class exists (installed `math_opt/python/solve.py:162-184`). Which model updates the SCIP backend applies incrementally was **not verified** (section 10). | Same class; same gap. |

- **[Experimental claim / unverified]** Whether hints reduce time-to-first-feasible on this problem shape, for either solver, is unmeasured.

### 6.3 Day- and slot-specific constraints, dated pins

- **[Math fact]** With one Boolean `x[d,s,c]` per (date, slot, candidate), the following are all linear and expressible identically in both solvers:
  - Pin: `x[d,s,c] = 1`.
  - Ban on a date: `x[d,s,c] = 0`, or simply omit the variable.
  - Date-specific candidate lists: create variables only for allowed triples.
  - Repetition limit: `sum over d,s of x[d,s,c] <= k`.
  - No repeat on consecutive days: `x[d,s,c] + x[d+1,s,c] <= 1`.
  - Weekly coverage: `sum over d,s and c in group of x[d,s,c] >= 1`.
- **[Math fact]** A pin is a restriction. It can make a feasible model infeasible, and two pins on one slot are infeasible by construction.
- **[Documented behaviour]** CP-SAT additionally offers conditional constraints through enforcement literals (`[S2]` `cp_model.proto:320-328`) and Boolean-specific constraints such as exactly-one, at-most-one, and implication (installed `cp_model.py:927-973`). In MIP the same conditions are written as linear inequalities, typically with big-M constants.
- **[Math fact]** A big-M constant must be large enough to be valid and small enough to stay numerically meaningful relative to the solver's tolerance. Exact integer reasoning has no such trade-off.
- **[Repo fact]** None of these exist today; candidates are shared across days (section 2.2).

### 6.4 Portion scaling

- **[Math fact]** "Choose recipe `c` **and** choose its portion multiplier `p`" makes nutrient and cost contributions a product of two decisions. That is bilinear, not linear.
- **[Math fact]** Three standard linear treatments:
  1. **Discrete portion variants.** Each (recipe, portion) pair becomes its own candidate. Linear in both solvers. Multiplies the candidate count.
  2. **Semi-continuous portion.** A portion variable `p[c]` with `lo * x[c] <= p[c] <= hi * x[c]`. Linear. Continuous `p` is native in MIP; in CP-SAT `p` must be an integer count of a fixed step.
  3. **Fixed per-participant portion.** The multiplier is data, not a decision. No model change.
- **[Documented behaviour]** CP-SAT also has an integer product constraint, `add_multiplication_equality` (installed `cp_model.py:1085`), so a product of integer variables can be stated directly.
- **[Experimental claim / unverified]** How any of these scale with the number of recipes and step sizes is unmeasured.
- **[Product choice]** Whether portions are a solver decision at all, their allowed range and step, and whether they differ per participant. The spec lists multi-participant numeric targets as an open decision (`CONVERSATIONAL_MEAL_PLAN_SPEC.md:374`).

### 6.5 Package and basket coupling, budget

- **[Math fact]** Purchased cost is not the sum of per-recipe costs. If ingredient `i` is sold in packages of size `q[i]` at price `r[i]`, then with demand `D[i] = sum of a[i,c] * x[...]` and stock use `u[i]`:
  - `q[i] * n[i] + u[i] >= D[i]`, with `n[i]` a non-negative **integer** package count;
  - `0 <= u[i] <= stock[i]`;
  - basket cost `= sum of r[i] * n[i]`, and the budget constrains that sum.
- **[Math fact]** Two recipes sharing an ingredient can share a package. The budget constraint then couples all days, and the per-recipe `estimated_cost_cents` used today is no longer the quantity being bounded.
- **[Math fact]** Leftover `q[i] * n[i] + u[i] - D[i]` is a linear expression and can be penalised or bounded.

| Aspect | SCIP (MIP) | CP-SAT |
| --- | --- | --- |
| Integer `n[i]` | Native integer variable. | Native integer variable. |
| Demand `D[i]`, stock `u[i]` | Continuous, native. | Integer in a chosen unit (for example milli-units). |
| Overflow exposure | None from integrality; tolerance exposure instead. | Quantity scale times price scale times term count must stay inside `int64` (section 5.1). |

- **[Repo fact]** Inventory quantities are already stored as integer milli-units and compared per unit (`planning_candidate_builder.ex:120-123`), and recipe cost is an integer `estimated_cost_cents` (`planning_candidate_builder.ex:108`).
- **[Repo fact]** The current budget constraint sums `estimated_cost_cents` per selected recipe (`optimizador.py:172-185`). It does not model packages, sharing, or stock.
- **[Experimental claim / unverified]** Whether package sizes and prices exist in the data model with enough coverage to state these constraints was not investigated in this ticket.
- **[Product choice]** Whether the budget bounds the **basket to buy** or the **consumed value** of the plan; how missing prices are treated; whether leftovers count.

### 6.6 Stock and inventory allocation

- **[Math fact]** Allocation needs a variable for stock **used**, bounded by stock **available**, shared by every meal that draws on it (the `u[i]` above). A per-recipe hit count cannot represent that.
- **[Math fact]** Dated stock (expiry) adds an index: use of lot `l` on or before its date. Still linear.
- **[Math fact]** Unit mismatch (stock in grams, recipe in "units") is a data conversion, not something either solver resolves.
- **[Repo fact]** Today inventory is "represented only as an objective signal" (`planning_candidate_builder.ex:7`), matching on identical `unit` (`:121`), and never as a constraint (`optimizador.py:219-220`).
- **[Product choice]** Whether using stock is a preference or a requirement, and whether "use what expires first" is an objective or a rule.

### 6.7 Preferences and objectives

- **[Math fact]** A soft constraint is a hard constraint plus a slack variable penalised in the objective. Both solvers express it the same way.
- **[Math fact]** A weighted sum emulates a strict priority order only when each higher-priority weight exceeds the entire possible range of all lower-priority terms. In floating point, large weight ratios collide with tolerances; in `int64`, they collide with overflow limits.
- **[Math fact]** A strict (lexicographic) order can also be obtained by sequential solves: optimise objective 1, add `objective1 <= z1` as a constraint, optimise objective 2, and so on. Each stage needs a **proven** optimum, or an explicit acceptance of the stage's gap, for the order to be strict.
- **[Documented behaviour]** MathOpt models carry objective priorities (installed `math_opt/python/objectives.py:115-123`). Which backends honour them was **not verified**.
- **[Documented behaviour]** CP-SAT's default absolute gap is `1e-4`, which for an all-integer objective means a reported `OPTIMAL` is a true optimum (`[S3]` `sat_parameters.proto:373-378`).
- **[Repo fact]** The current objective is a single weighted sum with one weight, `inventory_weight` (`optimizador.py:136-142`; `config/config.exs:28`).
- **[Product choice]** The priority order among cost, stock use, variety, preference match, and stability; and whether any of them is strict.

### 6.8 Constraint-preserving refinement

"Refinement" here means producing a new plan from an accepted plan after one change, **without weakening any hard constraint**.

| Technique | Guarantee | SCIP via `pywraplp` | CP-SAT |
| --- | --- | --- | --- |
| Fix variables to the previous values | **[Math fact]** Hard. Unchanged days stay unchanged or the model is infeasible. | Set bounds or add equalities. | Add equalities, or hint and set `fix_variables_to_their_hinted_value` (`[S3]` `sat_parameters.proto:1205-1207`). |
| Add a constraint | **[Math fact]** Hard. All earlier constraints still apply. | Supported; re-solve from scratch. | Supported; re-solve. |
| Hint the previous plan | **[Documented behaviour]** None. A hint is not a constraint and closeness is not guaranteed (section 6.2). | `SetHint`. | `add_hint`; `repair_hint` changes how the hint is exploited (`[S3]` `sat_parameters.proto:1199-1203`). |
| Minimise distance to the previous plan | **[Math fact]** Soft but optimised. For 0-1 variables, the count of changed slots is linear: `sum over previously chosen (d,s,c) of (1 - x[d,s,c])`. | Linear objective term. | Linear objective term. |
| Bound the distance | **[Math fact]** Hard. "Change at most `k` slots" is one linear inequality. | Supported. | Supported. |

- **[Math fact]** Hinting alone cannot implement "keep the other days fixed". Only fixing or a distance bound gives that guarantee.
- **[Math fact]** Fixing other days can make a requested change infeasible. That outcome is information for the user, not a solver defect.
- **[Repo fact]** Today every modification triggers a full re-optimisation with no carried-over assignment (`generation/server.ex:474-509`).

---

## 7. Conflict diagnosis: what is actually available

None of the techniques below finds a recipe or settles a contradiction. Each returns a **set of named requirements** that cannot hold together for the supplied candidates.

### 7.1 CP-SAT assumptions

- **[Documented behaviour]** Constraints are guarded by enforcement literals, the literals are passed as assumptions, and on `INFEASIBLE` the response lists a subset of them in `sufficient_assumptions_for_infeasibility` (`[S2]` `cp_model.proto:669-682`, `777-796`; `[S6]` `troubleshooting.md:83-138`; installed `cp_model.py:1668-1679`, `1948-1952`).
- **[Documented behaviour]** Limits, stated by the source:
  - The subset is **sufficient**, not guaranteed minimal: "no guarantee that we return an irreducible (aka minimal subset)" (`cp_model.proto:782-785`); "this set is minimized but not guaranteed to be minimal" (`troubleshooting.md:89`).
  - It covers **only the assumptions supplied**. Constraints without an assumption literal are treated as fixed background.
  - "Currently, this is minimized only in single-thread and if the problem is not an optimization problem, otherwise, it will always include all the assumptions" (`cp_model.proto:791-793`).
  - "Solving with assumptions is not compatible with parallelism. Therefore, the number of workers must be set to 1" (`troubleshooting.md:93-94`).
  - Only one core is returned; multiple cores are an open TODO (`cp_model.proto:795`).
  - It is populated only when the status is `INFEASIBLE` (`cp_model.proto:777-778`). `UNKNOWN` yields no explanation.
- **[Documented behaviour]** A truly minimal set requires a different model: minimise the weighted number of assumption literals set to false, "likely a harder problem to solve" (`cp_model.proto:787-789`; `troubleshooting.md:90-91`).
- **[Math fact]** One enforcement literal may guard a group of constraints. Grouping by user-meaningful requirement (for example "budget", "Tuesday dinner pin", "protein floor") makes the returned set readable. The grouping is a modelling decision that determines what the explanation can say.

### 7.2 Irreducible infeasible subsystems in SCIP

- **[Documented behaviour]** SCIP 10.0.0 added IIS search: "added the possibility to search for irreducible infeasible subsystems (IIS)", a new `iisfinder` plugin type with a "greedy" finder, the API `SCIPgenerateIIS()` and `SCIPgetIIS()`, and shell commands `iis`, `write/iis`, `display/iis` (`[S9]` `CHANGELOG:1-3`, `73-75`, `257-259`, `328-330`).
- **[Documented behaviour]** Parameters include `iis/irreducible` ("should the resultant infeasible set be irreducible, i.e., an IIS not an IS"), `iis/time`, and `iis/nodes` (`[S9]` `set.c:1749-1784`). The result can therefore be a non-irreducible infeasible set, or be cut short by a limit.
- **[Documented behaviour]** **Not reachable through the installed OR-Tools wrappers.**
  - The installed `pywraplp.py` exposes no IIS method.
  - `SetSolverSpecificParametersAsString` sets parameters; it does not invoke `SCIPgenerateIIS()`.
  - MathOpt's `compute_infeasible_subsystem` states: "As of August 2023, the only supported solver is Gurobi" (installed `math_opt/python/solve.py:122-123`, OR-Tools 9.15).
- **[Experimental claim / unverified]** Using SCIP's IIS finder would need a different binding (for example SCIP's own Python interface) or the SCIP shell. Neither is installed here, and neither was checked.

### 7.3 Solver-independent techniques

- **[Math fact] Deletion filtering.** Remove one requirement group; re-solve; if still infeasible, leave it out, otherwise restore it. One pass over `m` groups yields an irreducible infeasible set using `m` solves. Each solve must **terminate with a proof**; a time-limited `UNKNOWN` or `NOT_SOLVED` breaks the procedure. `[S6]` `troubleshooting.md:73-81` lists the manual form of this.
- **[Math fact] Elastic (slack) relaxation.** Add a non-negative slack to each requirement group and minimise total weighted slack. A non-zero slack names a requirement that must give way and by how much. The resulting assignment **violates** the original constraints. It is a diagnostic, not a plan.
- **[Math fact] Necessary-condition pre-checks.** Cheap arithmetic tests that prove infeasibility without a solver: empty candidate list for a slot; sum of per-slot minimum costs above budget; per-day maximum achievable nutrient below its floor. Each is sufficient for infeasibility and silent otherwise.
- **[Repo fact]** The code has exactly this third kind, for budget only (`optimizador.py:225-231`), and returns the generic `hard_constraints_unsatisfiable` otherwise.
- **[Math fact]** Several distinct conflict sets may coexist. Resolving one may expose the next. No single returned set is "the" reason.

---

## 8. Agent-loop implications (conditional alternatives, not decisions)

### 8.1 Which signals could justify candidate expansion

Each row states a signal, what it does and does not establish, and the alternatives. None is a recommendation.

| Signal | Establishes | Does not establish | Alternatives |
| --- | --- | --- | --- |
| A slot has zero eligible candidates before solving. **[Repo fact]** `planning_candidate_builder.ex:64-77` | **[Math fact]** The model is infeasible for a reason that more candidates of the right kind can remove. | Which recipes would be acceptable. | Expand candidates for that slot; or ask the user. |
| `INFEASIBLE`, and the conflict set contains only **aggregate** requirements (budget, nutrient bounds) and no pin, exclusion, or user rule. | **[Math fact]** No combination of the current candidates meets those aggregates. | That any real recipe would. Expansion may fail indefinitely. | Expand toward the binding dimension (cheaper, higher-protein, and so on); or report and ask. |
| `INFEASIBLE`, and the conflict set is entirely user rules, pins, or policy. | **[Math fact]** The requirements contradict each other given the candidates. | Which one the user would give up. | Clarification. Expansion cannot help if the rules conflict regardless of candidates (for example a pin on an excluded recipe). |
| `FEASIBLE` or `OPTIMAL`, but a soft objective is poor (for example low variety, no stock used). | **[Math fact]** Within current candidates this is the best found (or proven best). | That better candidates exist. | Expand as an optional quality step; or accept. This is a **[Product choice]** about effort versus quality. |
| `UNKNOWN` / `NOT_SOLVED` / timeout. | Nothing. | Feasibility or infeasibility. | Retry with a longer limit, a smaller horizon, or a simpler model. Expansion makes the model larger, so it is not supported by this signal. |

- **[Math fact]** Expansion is justified by a signal only when added candidates **could** remove the stated cause. That is true for candidate scarcity and for aggregate bounds. It is false for contradictions among rules that do not depend on candidates.
- **[Product choice]** An expansion budget (how many rounds, how many candidates, what cost) and what happens when it is exhausted.

### 8.2 Using solver feedback without relaxing hard constraints

- **[Math fact]** The following never weaken a hard constraint: adding candidates; adding hints; changing the objective or its weights; changing time limits, seeds, or worker counts; reading bounds, gaps, and conflict sets.
- **[Math fact]** The following **do** weaken a hard constraint and are therefore relaxations: widening a bound; removing a pin or exclusion; converting a hard requirement to a penalised slack; returning the assignment from an elastic diagnostic model as a plan.
- **[Math fact]** A diagnostic solve and a planning solve can be kept strictly apart. The diagnostic may use assumptions, deletion, or slack to **name** conflicts. The plan is only ever produced by the unrelaxed model.
- **[Math fact]** An independent check of any returned assignment against the original constraints holds regardless of which solver, status, or fallback produced it. **[Repo fact]** One caller already does this (`generation_service.ex:171-183`); one does not (`planning_service.ex:47-66`).
- **[Product choice]** Which requirements are hard. The spec already declares some (exclusions win over requirements, `CONVERSATIONAL_MEAL_PLAN_SPEC.md:148`); the status of others, such as stock use, is open.

### 8.3 Outcomes that require user clarification

Stated as conditions under which the mathematics has nothing further to offer:

- **[Math fact]** A conflict set made of the user's own requirements. Choosing which to drop is a preference.
- **[Math fact]** Infeasibility that persists after candidate expansion is exhausted. The remaining options all relax something.
- **[Math fact]** A requested edit that is infeasible while other days are held fixed. Either the edit or the fixing must give way.
- **[Math fact]** Several materially different plans with equal objective value. The objective does not rank them.
- **[Math fact]** Missing data that a constraint depends on (price, nutrient values, package size, unit conversion). The solver cannot supply it, and treating missing as zero silently changes the problem. **[Repo fact]** Missing numeric fields become `0.0` today (`optimizador.py:104-108`).
- **[Product choice]** Whether a proven-feasible but not-proven-optimal plan may be shown, and how it is labelled.
- **[Product choice]** Whether the agent may ask before or after spending expansion effort.

---

## 9. Illustrative formulations

**Illustrative only. Untested. Not run in this session. Not a proposed production model.** The snippets show how the same small problem is stated in each API so the formulation differences are concrete. Names are invented for the example.

Common pseudo-math, for dates `d`, slots `s`, candidates `c`, ingredients `i`:

```text
x[d,s,c] in {0,1}                          choose candidate c for (d,s)
n[i]     in {0,1,2,...}                    packages of ingredient i to buy
u[i]     in [0, stock[i]]                  stock of ingredient i consumed

sum_c x[d,s,c] = 1                         for every (d,s)
x[d0,s0,c0] = 1                            dated pin
sum_{d,s} x[d,s,c] <= 2                    repetition limit per recipe
lo[m] <= sum_{s,c} macro[m,c]*x[d,s,c] <= hi[m]      per day d, nutrient m
q[i]*n[i] + u[i] >= sum_{d,s,c} need[i,c]*x[d,s,c]   per ingredient i
sum_i price[i]*n[i] <= budget
minimise  sum_i price[i]*n[i]  -  w * sum_i u[i]
```

### 9.1 MIP with `pywraplp` and SCIP (illustrative, untested)

```python
from ortools.linear_solver import pywraplp

solver = pywraplp.Solver.CreateSolver("SCIP")
solver.SetTimeLimit(10_000)  # milliseconds

x = {(d, s, c): solver.BoolVar(f"x_{d}_{s}_{c}") for d in days for s in slots for c in cands[d, s]}
n = {i: solver.IntVar(0, max_packs[i], f"n_{i}") for i in ingredients}
u = {i: solver.NumVar(0.0, stock[i], f"u_{i}") for i in ingredients}   # continuous

for d in days:
    for s in slots:
        solver.Add(sum(x[d, s, c] for c in cands[d, s]) == 1)
solver.Add(x[pin_day, pin_slot, pin_cand] == 1)                          # dated pin
for d in days:
    for m in macros:
        day_total = sum(macro[m][c] * x[d, s, c] for s in slots for c in cands[d, s])
        solver.Add(day_total >= lo[m])
        solver.Add(day_total <= hi[m])
for i in ingredients:
    demand = sum(need[i].get(k[2], 0.0) * x[k] for k in x)
    solver.Add(pack_size[i] * n[i] + u[i] >= demand)
solver.Add(sum(price[i] * n[i] for i in ingredients) <= budget)
solver.Minimize(sum(price[i] * n[i] for i in ingredients) - w * sum(u.values()))

status = solver.Solve()
# OPTIMAL: proven (up to tolerance / gap).   FEASIBLE: a plan, not proven optimal.
# INFEASIBLE: proven for these candidates (may also mean "infeasible or unbounded").
# NOT_SOLVED: limit hit with no plan; nothing established.
```

### 9.2 CP-SAT (illustrative, untested)

All quantities are integers in a chosen unit: cents, milligrams, milli-units of stock.

```python
from ortools.sat.python import cp_model

model = cp_model.CpModel()
x = {(d, s, c): model.new_bool_var(f"x_{d}_{s}_{c}") for d in days for s in slots for c in cands[d, s]}
n = {i: model.new_int_var(0, max_packs[i], f"n_{i}") for i in ingredients}
u = {i: model.new_int_var(0, stock_milli[i], f"u_{i}") for i in ingredients}  # integer milli-units

for d in days:
    for s in slots:
        model.add_exactly_one(x[d, s, c] for c in cands[d, s])

# One enforcement literal per user-meaningful requirement group.
pin_ok    = model.new_bool_var("req_pin_tuesday_dinner")
budget_ok = model.new_bool_var("req_budget")
macro_ok  = {m: model.new_bool_var(f"req_{m}") for m in macros}

model.add(x[pin_day, pin_slot, pin_cand] == 1).only_enforce_if(pin_ok)
for d in days:
    for m in macros:
        day_total = sum(macro_mg[m][c] * x[d, s, c] for s in slots for c in cands[d, s])
        model.add(day_total >= lo_mg[m]).only_enforce_if(macro_ok[m])
        model.add(day_total <= hi_mg[m]).only_enforce_if(macro_ok[m])
for i in ingredients:
    demand = sum(need_milli[i].get(k[2], 0) * x[k] for k in x)
    model.add(pack_milli[i] * n[i] + u[i] >= demand)
model.add(sum(price_cents[i] * n[i] for i in ingredients) <= budget_cents).only_enforce_if(budget_ok)

solver = cp_model.CpSolver()
solver.parameters.max_time_in_seconds = 10.0
```

Planning solve and diagnostic solve kept apart (illustrative, untested):

```python
# (a) Planning solve: every requirement literal fixed true, objective present.
for lit in [pin_ok, budget_ok, *macro_ok.values()]:
    model.add(lit == 1)
model.minimize(sum(price_cents[i] * n[i] for i in ingredients) - w * sum(u.values()))
status = solver.solve(model)
# OPTIMAL / FEASIBLE: a plan satisfying every hard requirement.
# INFEASIBLE: proven for these candidates.   UNKNOWN: nothing established.

# (b) Diagnostic solve, on a separate copy WITHOUT the fixings and WITHOUT an objective,
#     single worker, requirement literals as assumptions.
diag = base_model.clone()                 # the model before step (a)
diag.add_assumptions([pin_ok, budget_ok, *macro_ok.values()])
dsolver = cp_model.CpSolver()
dsolver.parameters.num_workers = 1
if dsolver.solve(diag) == cp_model.INFEASIBLE:
    core = dsolver.sufficient_assumptions_for_infeasibility()
    # 'core' is a sufficient set of requirement literals, not guaranteed minimal.
    # It names requirements in conflict. It is never used to build a plan.
```

Notes on the example:

- **[Documented behaviour]** The diagnostic copy has no objective and one worker because the source says core minimisation applies only then, and that assumptions are incompatible with parallelism (section 7.1).
- **[Experimental claim / unverified]** Whether literals carried through `clone()` can be reused as written above was not executed; treat the snippet as a sketch of intent.

### 9.3 Refinement (illustrative, untested, either solver)

```text
Given accepted plan x_prev and one edited slot (d*, s*):

  hard:  x[d,s,c] = x_prev[d,s,c]      for every (d,s) other than (d*,s*)     # keep other days
  or
  hard:  sum_{(d,s,c): x_prev=1} (1 - x[d,s,c]) <= k                          # change at most k slots
  or
  soft:  add  lambda * sum_{(d,s,c): x_prev=1} (1 - x[d,s,c])  to the objective

A hint alone gives none of these guarantees.
```

---

## 10. Evidence gaps

1. **No measurements exist.** Nothing in this note supports a statement about relative speed, time to first feasible solution, or scaling for either solver on this problem.
2. **Runtime OR-Tools version is unpinned.** The 9.15.6755 / SCIP 10.0.0 finding describes the local `.venv/`. The version used by a deployed `python3` is unknown.
3. **MathOpt incremental-solve documentation was unreachable.** `https://developers.google.com/optimization/math_opt/incremental_solve` returned HTTP 404 on 2026-10-07. Which model updates the SCIP and CP-SAT backends apply incrementally is unverified. The `IncrementalSolver` class was confirmed to exist in the installed package only.
4. **MathOpt multi-objective backend support** was not verified; only the presence of objective priorities in the Python model API.
5. **SCIP IIS through Python** was not verified. The feature exists in SCIP 10.0.0 and is absent from the two OR-Tools wrappers checked. No SCIP-native Python binding is installed.
6. **SCIP's integrality tolerance rule** was not re-read in source. Only the default tolerance values were confirmed.
7. **CP-SAT through the `pywraplp` wrapper** (a third route) was not examined beyond one note in `sat_parameters.proto:703-706` that the worker count is overridden to 8 on that route unless set explicitly.
8. **The developers.google.com pages are undated relative to releases.** `[S1]` and `[S10]` show "Last updated 2024-08-28 UTC" and do not name an OR-Tools version. Where they and the v9.15 source could differ, the source was used.
9. **`https://developers.google.com/optimization/cp`** was fetched and, as summarised by the fetch tool, did not contain integer-scaling guidance; the quotation used comes from `[S1]`. Web pages were read through a summarising fetch tool, so quotations from `[S1]` and `[S10]` are less certain than quotations from downloaded source files.
10. **Data availability** for package sizes, package prices, unit conversions, and nutrient precision was not investigated. Section 6.5 and 6.6 are formulation facts only.
11. **Operating-system behaviour on Port close** (whether the Python process and an in-flight solve are terminated) was not verified.
12. **Thread-safety of interrupting SCIP.** `InterruptSolve` is implemented for SCIP (`[S5]` `scip_interface.cc:138-145`), while a comment elsewhere says "InterruptSolve is not thread safe for SCIP" as of 2021 (`[S5]` `linear_solver.h:610-612`). Not reconciled.
13. **The tie-break robustness** of `index / 1_000_000` under SCIP tolerances is untested beyond two candidates.

---

## 11. Falsifiable prototype questions

Each question names what would be measured and what result would falsify the stated hypothesis. Hypotheses are phrased to be testable, not as expectations.

| # | Hypothesis | Measure | Falsified if |
| --- | --- | --- | --- |
| P1 | For the current model shape (0-1 selection, per-day nutrient bounds, one budget), both solvers reach a **proven** terminal status within the 15 s Elixir timeout at realistic size. | Status and wall time per solver over fixtures of 7 days x 3 slots x {10, 50, 200} candidates, fixed seeds, repeated runs. | Either solver returns a limit status, or exceeds 15 s, on any realistic fixture. |
| P2 | Scaling nutrient data to integers changes no feasibility verdict relative to the floating-point model. | Feasible/infeasible verdict of both formulations on fixtures including bounds placed within one rounding unit of an achievable total. | Any fixture yields different verdicts. |
| P3 | With a time limit set in Python below the Elixir timeout, no solve outlives its request. | Count of "solution for unknown id" log lines and Python CPU time after request expiry, under forced-hard instances. | Any late solution arrives, or the process is still solving after the reply. |
| P4 | `sufficient_assumptions_for_infeasibility` returns a set that is irreducible on grouped requirements. | For constructed infeasible fixtures with a known minimal conflict, compare the returned set with the known one; then verify by deletion. | The returned set contains a requirement whose removal leaves the rest infeasible. |
| P5 | Deletion filtering over requirement groups completes within an interactive budget. | Total wall time and number of proof-terminated solves for `m` in {5, 10, 20} groups. | Any sub-solve ends in a limit status, or total time exceeds the chosen budget. |
| P6 | Hinting the previous plan after candidate expansion reduces time to first feasible solution. | Time to first solution with and without hints, same seeds, per solver. | No reduction, or an increase, across the fixture set. |
| P7 | A hinted re-solve stays close to the previous plan without a distance term. | Number of changed slots between consecutive plans, with hint only. | The count is not lower than for an unhinted solve. (Section 6.8 says no guarantee exists.) |
| P8 | Adding package-count and stock-use variables keeps both solvers within the timeout. | Status and wall time with 50 to 300 ingredients and integer package counts. | A limit status or timeout at realistic size. |
| P9 | The integer formulation stays inside `int64` at the chosen units. | Model validation result at maximum plausible horizon, quantities, and prices. | `MODEL_INVALID` with an overflow message. |
| P10 | Counting only process faults toward the circuit breaker changes how often the fallback is used. | Fallback invocation count under a replayed mix of infeasible and feasible requests, with and without infeasible counted. | No difference in fallback frequency. |
| P11 | The fallback's cheapest-per-slot plan passes independent validation at a useful rate. | Share of fallback outputs accepted by `validate_optimizer_response` over recorded payloads. | Acceptance is near zero under realistic budgets and nutrient bounds, meaning the fallback rarely yields a usable plan. |
| P12 | The `1e-6` tie-break yields identical plans under candidate reordering at scale. | Plan equality across shuffled inputs for large candidate lists and large costs. | Any pair of shuffles yields different plans. |

---

## 12. Sources

Access date for every source: **2026-10-07**.

| Key | Source | Version / commit | URL |
| --- | --- | --- | --- |
| S1 | OR-Tools guide, "CP-SAT Solver" | Page "Last updated 2024-08-28 UTC"; no release stated | https://developers.google.com/optimization/cp/cp_solver |
| S2 | `ortools/sat/cp_model.proto` | OR-Tools `v9.15`, `551ad10d` | https://github.com/google/or-tools/blob/v9.15/ortools/sat/cp_model.proto |
| S3 | `ortools/sat/sat_parameters.proto` | OR-Tools `v9.15`, `551ad10d` | https://github.com/google/or-tools/blob/v9.15/ortools/sat/sat_parameters.proto |
| S4 | `ortools/sat/cp_model_checker.cc` | OR-Tools `v9.15`, `551ad10d` | https://github.com/google/or-tools/blob/v9.15/ortools/sat/cp_model_checker.cc |
| S5 | `ortools/linear_solver/linear_solver.h`, `scip_interface.cc` | OR-Tools `v9.15`, `551ad10d` | https://github.com/google/or-tools/tree/v9.15/ortools/linear_solver |
| S6 | `ortools/sat/docs/` (`README.md`, `model.md`, `solver.md`, `troubleshooting.md`) | OR-Tools `v9.15`, `551ad10d` | https://github.com/google/or-tools/tree/v9.15/ortools/sat/docs |
| S7 | `ortools/math_opt/result.proto`, `infeasible_subsystem.proto` | OR-Tools `v9.15`, `551ad10d` | https://github.com/google/or-tools/tree/v9.15/ortools/math_opt |
| S8 | `src/scip/type_stat.h` | SCIP `v10.0.0`, `0c80fdd8` | https://github.com/scipopt/scip/blob/v10.0.0/src/scip/type_stat.h |
| S9 | `src/scip/def.h`, `src/scip/set.c`, `src/scip/iisfinder.c`, `CHANGELOG`, `doc/xternal.c` | SCIP `v10.0.0`, `0c80fdd8` | https://github.com/scipopt/scip/tree/v10.0.0 |
| S10 | OR-Tools guide, "Solving a MIP Problem" | Page "Last updated 2024-08-28 UTC"; no release stated | https://developers.google.com/optimization/mip/mip_example |
| S11 | OR-Tools dependency manifest (`Dependencies.txt`, `cmake/dependencies/CMakeLists.txt`) | OR-Tools `v9.15`, `551ad10d` | https://github.com/google/or-tools/blob/v9.15/Dependencies.txt |
| S12 | Installed package files: `ortools/sat/python/cp_model.py`, `ortools/linear_solver/pywraplp.py`, `ortools/math_opt/python/{solve,objectives,parameters}.py` | `ortools 9.15.6755` wheel in local `.venv/` (Python 3.14.6) | local, untracked |

Sources attempted and not used:

- `https://developers.google.com/optimization/math_opt/incremental_solve`: HTTP 404.
- `https://developers.google.com/optimization/cp`: reachable ("Last updated 2026-03-18 UTC"); contained nothing used here.

No secondary sources (blogs, forum answers) were used.

Repository files read at `a364c7a`: `optimizador.py`, `test_optimizador.py`, `generador.py` (confirmed unrelated: a recipe generator with no solver import), and under `meal_planner_api/`: `lib/meal_planner_api/optimization/{optimizer_server,optimizer_port,optimizer_port_runner,optimizer_fallback,optimizer_mock,payload_adapter}.ex`, `lib/meal_planner_api/integrations/python_client.ex`, `lib/meal_planner_api/services/{generation_service,planning_service,planning_candidate_builder}.ex`, `lib/meal_planner_api/generation/server.ex`, `config/{config,dev,test}.exs`, `docs/known-issues.md`, `docs/CONVERSATIONAL_MEAL_PLAN_SPEC.md`, and `test/meal_planner_api/optimization/optimizer_server_test.exs` (circuit-breaker tests only).

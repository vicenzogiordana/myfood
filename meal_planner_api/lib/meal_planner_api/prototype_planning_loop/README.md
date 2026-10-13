# Prototype 88: bounded planning loop

**Throwaway.** This folder and `lib/mix/tasks/prototype.planning_loop.ex` exist
only on the `prototype/88-planning-loop` branch to answer one question for
issue #88. Nothing here is production code and none of it is merged to `main`.

## The question

Can a small Elixir-native loop (model call, tool call, result, repeat, with a
step bound) drive recipe and price lookup, the OR-Tools optimizer and conflict
escalation, while a check outside the model keeps every hard constraint?

Two cases to try by hand:

1. A simple weekly plan for a household without restrictions (Casa Aurora).
2. Pin a recipe that contains an allergen of a member (Casa Boreal, Bruno is
   allergic to peanut; ask for the peanut pad thai): the agent must flag the
   conflict and ask, never include it silently.

## Run it

From `meal_planner_api/`:

```sh
mix prototype.planning_loop
```

Pick a household, then chat line by line (`/salir` quits). After every step the
chat prints the tool called with its arguments, the optimizer outcome, the
validation verdict, and tokens and spend. The line `[estado según el código]`
under each reply comes from the validator, not from the model.

No network, no spend (scripted model, real solver and validator):

```sh
mix prototype.planning_loop --scripted simple
mix prototype.planning_loop --scripted allergen
mix prototype.planning_loop --scripted invalid
```

All three exit 0 on the expected outcome and non-zero otherwise. `invalid`
proves the check outside the model: the scripted model skips the optimizer,
submits three bad plans for Casa Boreal (a member's allergen, over budget, an
unfilled slot plus a malformed entry) and then claims the plan is valid. Each
must be rejected by the validator with the right cause, and the status line
must contradict the claim.

## Setting the key

The live chat reads the key only from the `OPENAI_API_KEY` environment variable
and stops with a message when it is missing. Set it in your own shell for the
session, for example:

```sh
read -s OPENAI_API_KEY && export OPENAI_API_KEY
```

Do not put it in a tracked file. Optional overrides:

- `PROTOTYPE_OPENAI_MODEL` (default `gpt-6.1-sol`)
- `PROTOTYPE_SPEND_CAP_USD` (can only lower the USD 5 ceiling)
- `OPTIMIZER_PYTHON` (interpreter with `ortools`; default is the repository
  `.venv/bin/python`)

## Spend ceiling

Spend is accumulated across all runs in `PROTOTYPE_WIPE_ME_spend_ledger.json`
in this folder (git-ignored). The ledger may over-count but never under-count:

- Before each live call, the worst-case cost of that call is written to the
  file as a reservation. The call is refused when spend is at the ceiling or
  when the reservation would cross it.
- After a complete response, the reservation is replaced by the cost of the
  usage the API reported. A 4xx rejection drops the reservation.
- A call that times out, is killed, fails in transit, returns 5xx or dies with
  the process keeps its reservation, which counts as spent from then on, also
  in later runs. The spend line shows it as `reservas sin conciliar`.

Deleting the file resets the counter, so only delete it when the prototype is
over.

## What is real and what is fake

Real: the OR-Tools solver (`optimizador.py`, launched through the backend's
`OptimizerPortRunner`), the OpenAI Responses API in live mode, the validator.

Fake: households, members, allergies, budgets, inventories, the 13-recipe
catalogue and all prices (`fixtures.ex`). No database, no internet lookups.

Known shortcuts:

- The solver has no variety constraint, so plans repeat the same day seven times.
- The solver cannot pin a meal to one day. Pins are applied by overwriting the
  solved cell, with budget reserved up front; daily macro bounds are not
  re-checked for pinned days.
- Macro bounds are enforced by the solver only. The validator checks allergens,
  budget and full coverage.
- One Python process per solve.

## Layout

- `loop.ex`: the bounded loop (12 model turns, 5 minutes per request, 60 s per
  model call). No terminal I/O; this is the part worth lifting out.
- `tools.ex`, `validator.ex`, `optimizer.ex`, `fixtures.ex`: tool set, hard
  constraints, solver bridge, fake data.
- `model.ex`, `openai_model.ex`, `scripted_model.ex`: model interface and its
  two implementations.
- `spend_ledger.ex`: spend counter and ceiling.

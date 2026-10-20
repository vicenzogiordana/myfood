# Planning chat

`mix planning_agent.chat` is a terminal chat with the production planning
agent. It runs a real Planning Session (`PlanningAgent.Session`) over a
fictitious Household, so you can try the finished agent live: the agent
loop, the validator, the limits and the per-session spend cap are the ones
the app uses.

## The Household

Seeded on the first run into the chat's own database
(`PlanningAgent.Chat.Household`, built with the quality battery's fixture
builder):

- 3 Members; the third is allergic to peanuts (two peanut recipes exist and
  must never be planned)
- weekly grocery budget ARS 45,000
- Planning Range Monday 2 to Sunday 8 November 2026, lunch and dinner
- 18 recipes over 16 priced Ingredients, with two pasta brands
  (Don Trigo, La Molienda)
- Pantry: rice, onion and eggs

Prices are observed on the battery clock (1 November 2026), so they are
fresh. Live price lookups never reach the internet: they answer no offers.

## Run it

Once, create and migrate the chat database:

```sh
cd meal_planner_api
set -a; source .envrc; source .envrc.local; set +a
MIX_ENV=test MYFOOD_TEST_DATABASE=meal_planner_api_chat mix do ecto.create, ecto.migrate
```

Then chat (paid model calls, Claude when `PLANNING_AGENT_MODEL_PROVIDER=claude`):

```sh
export OPTIMIZER_PYTHON=/path/to/.venv-ortools/bin/python
MIX_ENV=test MYFOOD_TEST_DATABASE=meal_planner_api_chat mix planning_agent.chat
```

It reads the same provider environment as `mix planning_agent.battery`
(see [QUALITY_BATTERY.md](QUALITY_BATTERY.md)); without the spend and token
caps the session refuses to start. It runs with `MIX_ENV=test` because the
test environment holds the offline price scraper, but it keeps its data, so
it refuses the shared `meal_planner_api_test` database.

Options:

- `--reset` empties the chat database and seeds again. Needed after a
  `/confirm`, which plans the whole range.
- `--scripted` replaces the model with a scripted one and the optimizer
  with a greedy one: no key, no spend, no Python. The first message gets a
  plan; later ones get a fixed reply.

## Commands

| Command     | Effect                                                         |
| ----------- | -------------------------------------------------------------- |
| `/approve`  | Deviation Approval of the shown Proposal                       |
| `/confirm`  | confirm the shown Proposal: saves the plan and shopping list   |
| `/continue` | authorize one more stretch after a limit was reached           |
| `/stop`     | halt the running turn; the session and its Proposal survive    |
| `/spend`    | paid spend of this session so far                              |
| `/help`     | the command list                                               |
| `/quit`     | cancel the session and exit (end of input does the same)       |

Anything else goes to the agent. `/stop` and `/spend` act while the agent
works; other lines wait until its run ends.

After every run the chat prints a status line built by code, never by the
model: the shown Proposal's status (`valid`, `requires_approval`), its
budget check, the run's outcome (`complete`, `partial`, `failure`, ...) and
the spend so far. The session spend is printed again at exit.

## Piped, non-interactive

```sh
printf 'armame el plan de la semana\n/spend\n/quit\n' | \
  MIX_ENV=test MYFOOD_TEST_DATABASE=meal_planner_api_chat mix planning_agent.chat
```

A Ctrl-C leaves the session's slot held; the next start releases it.

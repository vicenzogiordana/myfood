# Prototype 88: bounded planning loop (Elixir-native)

Disposable prototype for [#88](https://github.com/vicenzogiordana/myfood/issues/88), child of map [#80](https://github.com/vicenzogiordana/myfood/issues/80).
Branch `prototype/88-planning-loop`. Never merged into `main`.

## Objective

Give the human a terminal chat where a bounded autonomous agent plans a week of meals for a fictitious household, so they can try it by hand and react to it.

## Problem and why

The map needs empirical evidence about the harness before choosing an architecture. In #87 the human stopped the measurement interview and asked for something working to try first.

## Question the prototype answers

Can a small Elixir-native loop (model call, tool call, result, repeat, with a step bound) drive recipe and price lookup, the OR-Tools optimizer and conflict escalation while a check outside the model keeps every hard constraint?

## Agreements with the human (2026-10-13)

| Topic | Agreement |
|---|---|
| Candidate set | Elixir-native only. Pi adapted in a Node sidecar is plan B, tried only if Elixir fails on something concrete. Pi fork and hybrid-as-separate-candidate eliminated before running. No side-by-side comparison. |
| Provider and model | OpenAI only, `gpt-6.1-sol`. A cheaper model is deferred to a second round. |
| Spend | Hard ceiling of USD 5 total across the whole prototype. On reaching it, stop and notify before any further spend. |
| Data | Fictitious households, profiles, budgets and inventories only. Recipe and price lookups return prepared responses; no internet. No production writes. |
| Trial interface | Terminal chat. Mobile app integration is out. |
| Artifact location | This branch, prototype code in its own folder inside the backend. Findings summary posted on #88 on resolution; code discarded. |
| Stopping conditions | Hand over when the chat resolves the two cases below. Stop earlier on the spend ceiling or on a concrete Elixir blocker. |

## Scope

In scope for the first delivery:

1. Simple weekly plan for a household without restrictions, ending in a valid plan.
2. A pinned recipe containing a household member's allergen: the agent flags it and asks instead of including it.

Deferred to a second round after the human's reaction: cancellation, retries, crash and restart, stale state, no-progress detection, the remaining thirteen tasks from #87, and a cheaper model.

## Constraints

- Tool calling for `gpt-6.1-sol` exists only on the Responses API (`v1/responses`), not on Chat Completions.
- Prices used by the spend counter: USD 2 per 1M input tokens, USD 0.10 per 1M cached input tokens, USD 10 per 1M output tokens (OpenAI pricing page, fetched 2026-10-13).
- The API key is supplied by the human through their local environment. It is never read, printed, logged or committed by the agent.
- Hard constraints (allergens, budget) are checked by code outside the model before a proposal is shown as valid.
- No new dependencies: `Req` and `Jason` are already in `mix.exs`.
- The loop is hand-written rather than backed by LangChain. This is a prototype convenience and does not supersede the historical #29 LangChain rule, which stays a human decision.
- The default `python3` on this machine has no `ortools` module; the optimizer must be launched the way the backend already launches it.

## Test-first exception

The prototype skill forbids tests for throwaway code and there is no pre-existing runnable test for this behavior. Checks are structural: compilation without warnings, formatting, and two scripted dry runs that exercise the loop without network or spend.

## Delivery strategy

`exception-ok`. The branch is disposable and no pull request is opened, so the 400-line delivery budget does not slice it. Forecast: about 600 authored lines. Actual after T1 and T2: 1586 added lines across 13 files.

## Tasks

- [x] **T1 Engine.** Fictitious fixtures, tool set (recipe lookup, price lookup, optimizer call, proposal validation, ask-the-human), OpenAI Responses client, bounded loop, persistent spend ledger with the USD 5 ceiling, scripted-model dry run.
  - Route: delegated direct (writer trigger: more than two non-trivial files; preparation trigger: reading the optimizer seam).
  - Checks: `mix compile --warnings-as-errors`; `mix format --check-formatted` on prototype files; scripted dry runs for both cases exit 0 and print a validated plan (case 1) and a conflict question (case 2).
- [x] **T2 Terminal chat.** One mix task that starts the chat, lets the human pick a household, shows each step live (tool called, optimizer result, validation verdict, spend so far) and a README with the run command and the question being answered.
  - Route: delegated direct, same writer as T1.
  - Checks: the mix task starts in scripted mode without a key; without a key in live mode it exits with a clear message and no network call.
- [x] **T3 Live trial.** The human sets the key and runs both cases against `gpt-6.1-sol`. Record observations, spend, and the human's reaction.
  - Route: inline, human-driven.
  - Checks: observed transcripts for both cases; spend below the ceiling.
- [ ] **T4 Resolution.** With explicit authorization, post findings on #88 with a link to this branch and update map #80.

## Progress

- T1 done in commit `004ad08`, T2 done in commit `1be7eb6`, both by one delegated writer.
- Observed checks (writer report, 2026-10-13): `mix compile --warnings-as-errors` exit 0; `mix format --check-formatted` on prototype files exit 0; `mix prototype.planning_loop --scripted simple` exit 0 with a valid 21-meal plan at $151.90 of $160.00; `mix prototype.planning_loop --scripted allergen` exit 0 with the pinned `d_pad_thai` refused, a question to the human, then a valid plan at $137.20 of $170.00; live mode without a key exits 1 with a clear message and no network call.
- Parent spot check: `mix prototype.planning_loop --scripted allergen` re-run, exit 0, same outcome.
- Review assessment for `main..1be7eb6`: risk `medium`, `review_due` true (`slice_budget_reached`).
- Native review of `main..f9a7ede` (lineage `review-fb7bf45cf39e7b99`): consent granted by the human, approved, acknowledged. Five advisory findings, none blocking.
- Two advisory findings fixed at the human's request by the same writer: `f3edc18` reserves the worst-case cost in the ledger before each model call and settles it afterwards, so the ceiling can only over-count; `241ac71` adds `--scripted invalid` and makes the validator report malformed entries instead of raising.
- Observed checks after the fixes (writer report): compile and format exit 0; `--scripted simple`, `--scripted allergen` and `--scripted invalid` exit 0; live mode without a key exits 1. `--scripted invalid` shows three rejected proposals (allergen, over budget, unfilled slot with a malformed entry) and the status line stays rejected after the model's false claim. Parent spot check: `--scripted invalid` re-run, exit 0, same outcome.
- Offline demonstration of the reservation: an unsettled reservation is counted as spent by the next ceiling check, including from a second OS process.
- Advisory findings left open: a raise inside the model call kills the chat instead of returning a stopped outcome; the optimizer bridge raises on unexpected protocol replies.
- Writer decisions to keep in mind: a 4xx response releases its reservation because it is not billed; `PROTOTYPE_SPEND_LEDGER_PATH` can point the ledger at another file, which would bypass accumulated spend and is not documented in the README.
- Second native review, required by the stop hook over the whole branch against `main` (lineage `review-e3e92599d43b5bab`): consent granted by the human, approved, acknowledged. Seven advisory findings, none blocking: unlocked non-atomic ledger writes can under-count with two concurrent runs; a raise inside the model call kills the chat; the optimizer bridge raises on unexpected protocol replies; turn bound, deadline, timeout and ledger refusals have no repeatable check; a response truncated at the output limit shows as an empty reply; wrong-typed tool arguments can raise in recipe search and price lookup; an unparsable or negative spend cap falls back to USD 5 silently.
- T3 live trial run by the human on 2026-10-13 against `gpt-6.1-sol`. Total spend USD 0.0331 of 5. The key was exported in the shell (`read -s OPENAI_API_KEY && export OPENAI_API_KEY`), because `direnv` is not installed and `.envrc.local` is only read by it.

## Live trial observations

| Case | Household | Observed |
|---|---|---|
| Simple weekly plan | Casa Aurora | Three model turns: optimizer, proposal, reply. Validator VALID, $151.90 of $160.00, USD 0.0101. The agent went straight to the optimizer and accepted seven identical days without comment. |
| "I want variety" | Casa Aurora | Four turns: recipe search, optimizer with three exclusions (infeasible), retry with one exclusion (solved, $159.75), then the agent judged the result still repetitive, did not present it, and asked the human with concrete options. |
| "Alternate all those options" | Casa Aurora | The agent pinned all 21 cells; the optimizer tool answered infeasible. The agent reported that the optimizer does not say which constraint fails and proposed a relaxation. The infeasible verdict was false, see findings. |
| Pinned allergen recipe | Casa Boreal | Two turns: recipe search, then a question stating the pad thai contains peanut and Bruno is allergic. No proposal made. |
| Human insists on the allergen | Casa Boreal | One turn: the agent refused again and asked to replace the dish. It never attempted the pin. |

The four unconfirmed Responses API assumptions held in practice: no HTTP 400, usage and cached tokens reported on every call. The ledger carried spend across runs.

## Human reaction (2026-10-13)

"Very good." The human wants the production agent to use the product scraper: asking "I like Luchetti pasta, how much is it?", getting real prices, and then setting it as a preferred brand, so that every plan recipe needing pasta uses that product and its price. This is a requirement for production, not for this prototype, which keeps fictitious data and no internet. The scraper is the sibling project `ratoneando-go`; the backend client is `integrations/go_scraper_client.ex`, used today only by `mix price_sync.run`. Open for a later decision: whether a brand preference is private to a member or shared by the household.

## Findings so far

- The solver interpreter is the repository-root `.venv/bin/python` (ortools 9.15); the backend default `python3` has no ortools.
- `OptimizerPortRunner.open_port/1` runs the solver from a mix task without the Repo. `OptimizerServer` was not reused: it is a named singleton that falls back silently to a non-solver when its circuit opens.
- `optimizador.py` has no variety constraint and cannot pin a meal to a day, so every day of a plan is identical and pins are applied after solving.
- A scripted model reply claimed a plan was validated right after a rejection, so the chat shows a code-owned status line under every reply.
- Allergen recipes are removed from candidates and allergen pins are refused inside `run_optimizer`, so the model may learn of the conflict from the tool rather than detect it itself.
- In the live trial the model detected the allergen conflict from recipe data on its own and held it under pressure, so the code-level refusal was exercised only in the scripted invalid run.
- The Elixir-native loop was sufficient for every case tried. Nothing observed called for plan B (Pi adapted).
- The agent's planning quality is capped by the solver, not the loop: no variety constraint, no per-day pinning, and an opaque infeasibility cause.
- The prototype's pin shortcut (`tools.ex`, `solve/3`) returns a false infeasible for heavily pinned plans: it subtracts each pin's extra cost from the weekly budget and still asks the solver to fill every cell with the reduced budget. Not fixed. A tool that reports a false "no solution" misleads an otherwise well-behaved agent.
- Initiative depends on the prompt: the agent evaluated and refined only after the human complained.
- The approved-absence exception agreed in #84 is not implemented; the agent only offers to replace the dish.
- The code-owned status line can read as stale: after a refused attempt it still reports the earlier proposal as valid.

## Next step

T4: post the findings on #88 with a link to this branch, close #88, and add the decision line to map #80. Authorized by the human on 2026-10-13.

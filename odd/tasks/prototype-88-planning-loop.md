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
- [ ] **T3 Live trial.** The human sets the key and runs both cases against `gpt-6.1-sol`. Record observations, spend, and the human's reaction.
  - Route: inline, human-driven.
  - Checks: observed transcripts for both cases; spend below the ceiling.
- [ ] **T4 Resolution.** With explicit authorization, post findings on #88 with a link to this branch and update map #80.

## Progress

- T1 done in commit `004ad08`, T2 done in commit `1be7eb6`, both by one delegated writer.
- Observed checks (writer report, 2026-10-13): `mix compile --warnings-as-errors` exit 0; `mix format --check-formatted` on prototype files exit 0; `mix prototype.planning_loop --scripted simple` exit 0 with a valid 21-meal plan at $151.90 of $160.00; `mix prototype.planning_loop --scripted allergen` exit 0 with the pinned `d_pad_thai` refused, a question to the human, then a valid plan at $137.20 of $170.00; live mode without a key exits 1 with a clear message and no network call.
- Parent spot check: `mix prototype.planning_loop --scripted allergen` re-run, exit 0, same outcome.
- Review assessment for `main..1be7eb6`: risk `medium`, `review_due` true (`slice_budget_reached`).
- Not exercised: the live OpenAI path. No key was available and no spend was made.

## Findings so far

- The solver interpreter is the repository-root `.venv/bin/python` (ortools 9.15); the backend default `python3` has no ortools.
- `OptimizerPortRunner.open_port/1` runs the solver from a mix task without the Repo. `OptimizerServer` was not reused: it is a named singleton that falls back silently to a non-solver when its circuit opens.
- `optimizador.py` has no variety constraint and cannot pin a meal to a day, so every day of a plan is identical and pins are applied after solving.
- A scripted model reply claimed a plan was validated right after a rejection, so the chat shows a code-owned status line under every reply.
- Allergen recipes are removed from candidates and allergen pins are refused inside `run_optimizer`, so the model may learn of the conflict from the tool rather than detect it itself.

## Unconfirmed assumptions in the live path

The shape of the Responses API `usage` object, `max_output_tokens` as a request field, the top-level response `status`, and `strict: true` schemas with nullable enums for `gpt-6.1-sol`. A wrong assumption shows as an HTTP 400 on the first live call or as zero tokens in the ledger.

## Next step

T3: the human sets `OPENAI_API_KEY` locally and runs `mix prototype.planning_loop` from `meal_planner_api/`.

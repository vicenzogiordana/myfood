# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT-MAP.md`** at the repo root — it points at one context per sub-area
  (root, api, mobile). Read each context relevant to the topic.
- Each context's `CONTEXT.md` (or its equivalent — see the table in
  `CONTEXT-MAP.md`). The current `root` context file is `context.md`
  (lowercase) for historical reasons; treat it as the project `CONTEXT.md`.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in. In
  multi-context repos, also check `<context>/docs/adr/` for context-scoped
  decisions. The `api` context already has `meal_planner_api/docs/` which
  contains PRD history, channel specs, frontend integration guide, and known
  issues — treat those as the api context's ADRs/design notes.

If any of these files don't exist for a context, **proceed silently**. Don't
flag their absence; don't suggest creating them upfront. The producer skill
(`/grill-with-docs`) creates them lazily when terms or decisions actually get
resolved.

## File structure

Multi-context repo (presence of `CONTEXT-MAP.md` at the root):

```
/
├── CONTEXT-MAP.md
├── context.md                       ← root context (whole project)
├── docs/adr/                        ← system-wide decisions
└── meal_planner_api/
    ├── ARCHITECTURE.md              ← api context (Phoenix API)
    └── docs/                        ← api context's ADRs/design notes
        ├── CHANNELS.md
        ├── FRONTEND_INTEGRATION.md
        ├── AUTH_COMPATIBILITY_PRD.md
        └── known-issues.md
```

A future `mobile/` directory will hold the React Native app context.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal,
a hypothesis, a test name, a code identifier, a UI string), use the term as
defined in the relevant `CONTEXT.md`. Don't drift to synonyms the glossary
explicitly avoids.

Core MyFood vocabulary (from `context.md`):

- `Account` (not "household", "family", "tenant" — those are reserved for
  other concepts).
- `User` vs `Account`: a `User` is a credential; an `Account` is the
  multi-tenant boundary that owns `MealPlan`, `Budget`, `ShoppingItem`,
  `Message`.
- `MealPlan` and `Meal` are distinct: a `MealPlan` is the weekly plan, a
  `Meal` is a single dish in a slot.
- `Inventory` is the canonical "what's in the house" (used by the AI for
  zero-waste prioritization). Not "pantry" or "stock".
- `PlanningSession` is the conversational state with the AI that produces a
  `MealPlan`. The check button transitions it to `confirmed`.

If the concept you need isn't in the glossary yet, that's a signal — either
you're inventing language the project doesn't use (reconsider) or there's a
real gap (note it for `/grill-with-docs`).

## Flag ADR conflicts

If your output contradicts an existing ADR or design note, surface it
explicitly rather than silently overriding:

> _Contradicts `meal_planner_api/ARCHITECTURE.md` (Clean Architecture boundary between Application and Persistence) — but worth reopening because…_

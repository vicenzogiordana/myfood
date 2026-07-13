# MyFood — Domain Context Map

MyFood is a monorepo with multiple domain contexts. Engineering skills should
read the contexts relevant to the area they are about to touch.

## Contexts

| Context   | Path                          | File                                              | Notes                                                                                       |
| --------- | ----------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `root`    | `./`                          | [`context.md`](./context.md)                      | Whole-project context: business model, domain entities, AI persona, monetization, founders. |
| `api`     | `./meal_planner_api/`         | [`meal_planner_api/ARCHITECTURE.md`](./meal_planner_api/ARCHITECTURE.md) | Phoenix API context: Clean Architecture layers, auth flow, integrations (Gemini, OR-Tools, RevenueCat). Own `docs/` with channels, frontend integration, PRD history. |
| `mobile`  | (not yet present)             | _pending_                                          | React Native app. Will live under a top-level directory (e.g. `mobile/`) once the app is scaffolded. |

## Reading order for sub-agents

1. Read this file first.
2. Pick the contexts relevant to the task. The `root` context is always relevant
   (it defines the ubiquitous language). Add `api` and/or `mobile` if the work
   touches those sub-projects.
3. Read the context's `CONTEXT.md` (or its equivalent — see table above). Use
   the vocabulary defined there in any output (issue titles, PR descriptions,
   test names, code identifiers).

## ADRs

- System-wide ADRs (when they exist) live under `docs/adr/` at the repo root.
- Context-scoped ADRs live under `<context>/docs/adr/`. The `api` context
  already has `meal_planner_api/docs/` (channels, frontend integration, auth
  compatibility PRD, known issues) which plays a similar role.

## Renaming note

The root context file is currently `context.md` (lowercase) for historical
reasons. Engineering skills should treat it as the project `CONTEXT.md`. A
rename to `CONTEXT.md` is safe to do in a follow-up cleanup change.

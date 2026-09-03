# AI Intent Boundary Specification

## Purpose
Defines the typed-intent boundary the AI must cross to influence a planning session. AI outputs MUST be a closed set of intent maps; any intent carrying a recipe/proposal/meal id or any DB-mutating key MUST be rejected. AI may only enter the planning flow through `AIChannel.handle_in("new_message", ...)`, where its response is validated by `validate_ai_intent/1` before any planner state mutation.

## Requirements

### Requirement: Closed set of accepted intent kinds
`validate_ai_intent/1` MUST accept only `kind ∈ {:change_constraints, :request_slot_swap, :request_recipe_suggestion}`, returning `{:ok, intent}`.

| Scenario | Given | When | Then |
|---|---|---|---|
| change_constraints accepted | `%{kind: :change_constraints, payload: %{max_budget: 100}}` | `validate_ai_intent/1` runs | `{:ok, intent}` |
| request_slot_swap accepted | `%{kind: :request_slot_swap, payload: %{day: "2026-03-04", from: :lunch, to: :dinner}}` | `validate_ai_intent/1` runs | `{:ok, intent}` |
| request_recipe_suggestion accepted | `%{kind: :request_recipe_suggestion, payload: %{tags: ["quick"]}}` | `validate_ai_intent/1` runs | `{:ok, intent}` |

### Requirement: Forbidden keys are rejected
`validate_ai_intent/1` MUST return `{:error, :forbidden_intent}` when the intent (top level or nested under `payload`) carries `:recipe_id`, `:proposal_id`, `:scheduled_meal_id`, or any DB-mutating key (`:insert`/`:update`/`:delete`/`:upsert`/`:destroy`/`:changeset`).

| Scenario | Given | When | Then |
|---|---|---|---|
| recipe_id rejected | `%{kind: :request_recipe_suggestion, payload: %{recipe_id: 42}}` | `validate_ai_intent/1` runs | `{:error, :forbidden_intent}` |
| proposal_id rejected | `%{kind: :change_constraints, payload: %{proposal_id: "abc"}}` | `validate_ai_intent/1` runs | `{:error, :forbidden_intent}` |
| scheduled_meal_id rejected | `%{kind: :request_slot_swap, payload: %{scheduled_meal_id: 7}}` | `validate_ai_intent/1` runs | `{:error, :forbidden_intent}` |
| DB-mutating key rejected | `%{kind: :change_constraints, payload: %{insert: %{}}}` | `validate_ai_intent/1` runs | `{:error, :forbidden_intent}` |

### Requirement: Unknown kind rejected
`validate_ai_intent/1` MUST return `{:error, :unknown_intent}` when `kind` is absent or not in the closed set.

| Scenario | Given | When | Then |
|---|---|---|---|
| Unknown kind rejected | `%{kind: :delete_everything, payload: %{}}` | `validate_ai_intent/1` runs | `{:error, :unknown_intent}` |

### Requirement: AI enters planning only via AIChannel seam
The AI's response MUST flow through `AIChannel.handle_in("new_message", ...)`, where `validate_ai_intent/1` runs before any planner state mutation. `PlanningChannel.handle_in` MUST NOT expose an AI-intent surface.

| Scenario | Given | When | Then |
|---|---|---|---|
| PlanningChannel has no AI-intent surface | `PlanningChannel.handle_in/3` event list | clauses inspected | none accepts an `intent` key validated by `validate_ai_intent/1` |

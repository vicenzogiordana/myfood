# Plan Narration

## Purpose

Defines the read-only LLM turn that runs after the solver produces
`proposal_json`, presenting the plan conversationally and stating any
assumptions the system made to resolve ambiguity — without ever mutating a
recipe ID, quantity, price, or any solver decision.

**Owner decisions referenced**: solve-and-narrate ambiguity handling (system
narrates assumptions instead of asking blocking clarifying questions);
soft, tunable iteration-count notice (no hard cap).

## Requirements

### Requirement: Narration is strictly read-only over solved output

After `proposal_json` is persisted, the system MUST generate narration text
from a second LLM call that receives only already-solved, deterministic
data (slots, recipes, prices, macros) plus the accumulated constraint
context. The narration turn MUST NOT alter, and MUST have no code path
capable of altering, any recipe ID, quantity, price, or macro value in the
persisted plan.

#### Scenario: Narration describes an existing plan without side effects

- GIVEN a solved `proposal_json` for the week
- WHEN the narration turn runs
- THEN the returned text references the plan's actual recipes/prices, and
  `proposal_json` is byte-identical before and after narration

#### Scenario: Narration failure never blocks the proposal

- GIVEN the narration LLM call errors or times out
- WHEN the solver has already produced a valid `proposal_json`
- THEN the `proposal_ready`/`proposal_update` event is still broadcast with
  `narration: nil` (or a default fallback string), and the plan remains
  usable

### Requirement: Narration states assumptions made to resolve ambiguity

When constraint extraction accepted an ambiguous or partially-specified
request (e.g., an unspecified guest count, or a budget/macro conflict that
required a tradeoff), the narration MUST explicitly state the assumption
used to solve it, in the user's language.

#### Scenario: Unspecified servings assumption is narrated

- GIVEN no chat turn specified a guest count for Saturday or Sunday
- WHEN the solver defaults those slots to the account's active-membership
  count (see `variable-servings`)
- THEN the narration explicitly states the assumption, e.g. "asumí sábado y
  domingo, 4 personas"

#### Scenario: Budget/macro conflict tradeoff is narrated

- GIVEN a requested budget cannot satisfy a requested macro floor
- WHEN the solver relaxes one constraint to produce a feasible plan
- THEN the narration states which constraint was relaxed and why, instead
  of silently presenting the plan or blocking on a clarifying question

### Requirement: Soft iteration-count notice

The system MUST track the number of solver re-runs within a single
generation session and, once a configurable threshold `N` is reached
(default: 5, tunable per environment/config), MUST include a gentle notice
in the next narration nudging the user toward accepting the plan. This
notice MUST NOT block further iteration.

#### Scenario: Threshold reached mid-negotiation

- GIVEN the session has already triggered 5 solver re-runs
- WHEN the user sends a 6th modification
- THEN the solver re-runs normally and the narration appends a soft nudge
  (e.g., "looks like you're still adjusting — want me to lock in the
  closest match?") without preventing a 7th iteration

#### Scenario: Threshold not yet reached

- GIVEN the session has triggered 2 solver re-runs
- WHEN the user sends another modification
- THEN the narration contains no iteration notice

### Requirement: Narration streams to the planning channel

Narration text MUST stream to the client over the existing
`AIChannel`/`GeminiClient` SSE plumbing, delivered as an additive
`narration` field on `PlanningChannel`'s `proposal_ready`/`proposal_update`
payloads, without changing the existing wire shape of those events for
clients that ignore the field.

#### Scenario: Client ignoring narration is unaffected

- GIVEN a client that does not read the `narration` field
- WHEN a `proposal_update` event is broadcast with narration streaming
- THEN the client's existing handling of recipe/price/macro fields is
  unaffected

## Cross-References

`conversational-constraint-extraction` (source of the assumptions being
narrated and of rejection events needing clarification narration),
`variable-servings` (default-servings assumption text).

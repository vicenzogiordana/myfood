# Planning Chat History

## Purpose

Defines the persisted `planning_chat_messages` table that durably stores
planning negotiation turns, scoped per the existing multi-familia tenancy
model, and how it feeds the LLM's multi-turn context window.

**Owner decision referenced**: chat history is persisted in DB (not
ephemeral-only), because "iterate until you like it" implies the user may
background the app mid-negotiation and reconnect.

## Requirements

### Requirement: planning_chat_messages schema

The system MUST persist a `planning_chat_messages` row per chat turn with:
`generation_run_id` (FK to the owning `planning_generation_runs` row),
`account_id` (tenant scope, per `account-membership`), `role`
(`:user | :assistant`), `content` (text), `content_type`
(`:text | :speech_transcript`), and standard timestamps. Rows MUST be
immutable after insert (no update path — only insert and read).

#### Scenario: A chat turn is persisted with tenant scope

- GIVEN an in-flight `planning_generation_runs` row for `Account_A`
- WHEN the user sends a chat message during negotiation
- THEN a `planning_chat_messages` row is inserted with
  `account_id: Account_A.id`, the correct `role`, and `content_type`
  matching the input (text or speech transcript)

#### Scenario: Assistant narration turns are persisted alongside user turns

- GIVEN a solver re-run produces a narration (see `plan-narration`)
- WHEN the narration is broadcast to the client
- THEN a `planning_chat_messages` row is inserted with `role: :assistant`
  and the narration text as `content`

### Requirement: Account-scoped access only

All reads and writes to `planning_chat_messages` MUST be scoped to
`account_id` and MUST follow the same `EnforceAccountScope` conventions as
every other tenant-scoped table. A request whose JWT `account_id` does not
match the row's `account_id` MUST be rejected before any row is returned.

#### Scenario: Cross-account read is rejected

- GIVEN `User_U` is scoped to `Account_A` via JWT
- WHEN a query attempts to read `planning_chat_messages` rows belonging to
  `Account_B`
- THEN the pipeline rejects the request before the query executes, per
  `auth-pipeline-and-current-resource` conventions

#### Scenario: No admin/analytics read path exists

- GIVEN the persisted chat content may include sensitive household
  negotiation details
- WHEN any non-account-scoped actor (admin tooling, analytics) attempts to
  read `planning_chat_messages`
- THEN no such read path exists in this change (explicitly out of scope)

### Requirement: LLM context window assembled from persisted history

When extraction or narration needs conversational context beyond the
current turn, the system MUST assemble the LLM's context window by
querying `planning_chat_messages` for the current `generation_run_id`,
ordered chronologically, rather than relying solely on in-memory
`Generation.Server` state.

#### Scenario: Context survives a reconnect mid-negotiation

- GIVEN the user has sent 3 chat turns in a session and then disconnects
  (app backgrounded)
- WHEN the user reconnects and sends a 4th turn
- THEN the LLM's context window includes all 3 prior turns retrieved from
  `planning_chat_messages`, not just the 4th turn in isolation

#### Scenario: Session state and persisted history stay consistent

- GIVEN `Generation.Server`'s in-memory constraint set is the merge result
  of all validated deltas
- WHEN the persisted `planning_chat_messages` history is replayed
- THEN replaying the persisted turns' extracted deltas in order reproduces
  the same merged constraint set held in `Generation.Server` state

## Cross-References

`account-membership` and `auth-pipeline-and-current-resource` (tenancy
scoping conventions reused here — see `phase-a-tenancy-refactor`),
`conversational-constraint-extraction` (multi-turn accumulation consuming
this history), `plan-narration` (assistant-role turns persisted here).

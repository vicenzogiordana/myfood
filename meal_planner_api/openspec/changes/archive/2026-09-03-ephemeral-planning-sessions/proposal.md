# Proposal: Ephemeral Planning Sessions and Range Locks

## Intent

Planning is proposal-centric (`Generation.Server` per account; no session lifecycle, range lock, typed-intent boundary, or chat retention). Each attempt must be bounded: ineligible Accounts refused at `start_planning`; overlapping ranges rejected by DB; AI cannot persist or select recipes.

## Scope

### In Scope
- 3 tables + Postgres EXCLUDE; `PlanningSessionServer` + `Sweeper`.
- `validate_ai_intent/1` typed-intent boundary; AI via `AIChannel` only.
- `PlanningChannel` events `start_planning`, `send_message`, `cancel_planning`; capability re-check.
- Hard-delete `planning_messages` + `planning_exceptions` on terminal status.

### Out of Scope
- `Generation.Server` Registry replacement, `recipe_versions`, soft-delete, new AI.

## Capabilities

### New Capabilities
- `planning-sessions`: ephemeral lifecycle, exclusive range lock per account, typed-intent boundary, hard-delete retention.
- `ai-intent-boundary`: `validate_ai_intent/1` rejects `:recipe_id`, `:proposal_id`, `:scheduled_meal_id`, DB keys.

### Modified Capabilities
- None — `channels` covers join-time entitlement.

## Approach

`planning_sessions` first-class with `(account_id, range_from, range_to, status, lock_owner_user_id, lock_owner_membership_id, lease_expires_at)` + partial `EXCLUDE USING gist (account_id WITH =, daterange(range_from, range_to, '[]') WITH &&) WHERE (status = 'active')` — DB refuses overlap. `PlanningSessionServer` owns lifecycle, broadcasts on `planning:<account_id>`; `validate_ai_intent/1` rejects recipe/DB keys.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `priv/repo/migrations/` (new) | New | 3 tables + EXCLUDE. |
| `lib/meal_planner_api/persistence/planning/planning_session.ex` | New | Schema. |
| `lib/meal_planner_api/persistence/planning/planning_message.ex` | New | Chat row. |
| `lib/meal_planner_api/persistence/planning/planning_exception.ex` | New | Exception row. |
| `lib/meal_planner_api/data/planning_repo.ex` | Modified | CRUD + hard-delete. |
| `lib/meal_planner_api/services/generation_service.ex` | Modified | Add `validate_ai_intent/1`. |
| `lib/meal_planner_api/generation/planning_session_server.ex` | New | Lifecycle + broadcasts. |
| `test/meal_planner_api/{data,generation,channels}/` | New/Modified | All three. |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| EXCLUDE fails — `btree_gist` | Med | `CREATE EXTENSION IF NOT EXISTS`. |
| Entitlement expiry mid-session | Med | Reply `:subscription_required`. |
| Peer cancel conflict | Low | Aligned with `AccountsMembership.remove_member/3`. |

## Rollback Plan

Revert migration; remove `PlanningSessionServer` + Sweeper; revert handlers; retire `validate_ai_intent/1`.

## Dependencies

Postgres range types + `btree_gist`. Issues #30–#32 merged. Parent #29. To satisfy #33.

## Success Criteria

- [x] Overlap `start_planning` → `{:error, :overlapping_range}`.
- [x] Cancel hard-deletes `planning_messages` + `planning_exceptions`; broadcasts `session_cancelled`.
- [x] AI `:recipe_id` / `:proposal_id` → `:forbidden_intent`; ineligible Account `start_planning` → `:subscription_required`.
- [x] `mix test --max-failures 10` passes; `mix precommit` no new warnings.

## Work Units

| Unit | Goal | Lines |
|------|------|-------|
| (a) | migrations + schemas + EXCLUDE | ~120 |
| (b) | `PlanningRepo` + `validate_ai_intent/1` | ~150 |
| (c) | `PlanningSessionServer` + Sweeper | ~250 |
| (d) | channel events + re-check | ~120 |
| (e) | integration tests + `mix precommit` | ~150 |

`delivery_strategy: auto-chain`, `chain_strategy: stacked-to-main`.
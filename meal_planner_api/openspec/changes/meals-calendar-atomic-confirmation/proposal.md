# Proposal: Meals Calendar and Atomic Menu Confirmation

## Change Summary

Issue #35 closes the calendar range-write and confirmation gaps without rebuilding shipped primitives: selected ranges replace safely, PlanningSession governs confirmation, and all callers use the atomic confirmation path.

## Intent

Deliver account-safe calendar replacement and confirmation. AC #1 reuses `:enforce_capability` and `ChannelCapability.authorize`; AC #4 reuses the channel's `Repo.transaction/1`. This change only closes their uncovered paths.

## Scope

### In Scope
- **PR1 — AC #3, <=200 lines:** add `replace_scheduled_meals_for_range/3` in `persistence/calendar.ex`, a `data/planning_repo.ex` helper, `PUT /api/calendar/meals/range` in `calendar_controller.ex`/`router.ex`, and persistence/controller tests.
- **PR2 — AC #2 + AC #1 test, <=250 lines:** route `generation/server.ex:do_confirm/2` through `PlanningSession` (`:acquired` → `:committed`); reject missing, lost, foreign, and terminal locks. Add session tests. Enable `:revenuecat_access_enforcement` only inside a runtime test; its default stays off.
- **PR3 — AC #4 closure, <=100 lines:** retire `services/planning_chat_service.ex:confirm_proposal/2`. Run `grep -r "confirm_proposal" meal_planner_api/assets meal_planner_api/lib meal_planner_api/test`; delete an unused HTTP route or bridge callers to the channel transaction.

### Out of Scope
- React Native UI, RevenueCat provider/default rollout, recipe catalogue, optimizer, and shopping extraction.

## Capabilities

### New Capabilities
- `calendar`: account-scoped range replacement and capability-gated calendar access.

### Modified Capabilities
- `planning-sessions`: confirmation validates its existing lock and records `:committed` after atomic persistence.

## Approach

Use approved **Approach A**: reuse `PlanningSession`, add transactional range replacement, and retire the legacy HTTP path. Deliver stacked-to-main as `feat/issue-35-meals-calendar-atomic-confirmation-pr1`, `-pr2`, and `-pr3`; each targets `main` within its budget.

## Cross-references

| Spec | Reused contract |
|---|---|
| `meal_planner_api/openspec/specs/planning-sessions/spec.md` | Lock, `:lost_lock`, ownership, commit lifecycle. |
| `meal_planner_api/openspec/changes/planning-shopping-extraction/specs/planning-shopping-cart.md` | Atomic cart/meal transaction. |
| `meal_planner_api/openspec/specs/accounts/spec.md` | Account lifecycle. |
| `meal_planner_api/openspec/specs/channels/spec.md` | Channel authorization helpers. |

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| Calendar persistence/HTTP, confirmation, tests | Modified | Range replacement, lock validation, atomic-path retirement. |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Default-off flag leaves AC #1 inactive by default. | Med | PR2 flag-enabled test documents this posture. |
| HTTP callers break on retirement. | Med | Search consumers; delete or bridge atomically. |
| Lock wiring regresses the 530-test suite. | Med | Strict TDD and `mix precommit` before merge. |
| Replacement duplicates slots. | Low | Preserve `(account_id, date, slot)` uniqueness; test partial range. |

## Rollback Plan

Revert each stacked PR independently; no database-shape change is required. Restore the HTTP route only for an emergency consumer rollback.

## Dependencies

- #30, #33, and #34 are merged; #36 is downstream.

## Acceptance Traceability

| Issue AC | Source / delivery |
|---|---|
| Expired Account refused | Reused gates; PR2 flag-enabled proof. |
| Invalid/lost/foreign lock rejected | PR2; `planning-sessions`. |
| Outside dates preserved | PR1; `calendar`. |
| Menu and effects are atomic | Reused shopping-cart spec; PR3 removes HTTP bypass. |

## Success Criteria

- [ ] PR1 replaces only the selected range without duplicate slots.
- [ ] PR2 rejects invalid locks and commits a valid session.
- [ ] Flag-enabled enforcement and confirmation pass `mix precommit`.

## Open Questions for the Orchestrator to Relay

None. HTTP retirement and the default-off flag posture are confirmed.

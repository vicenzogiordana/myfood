# Delta for Planning Sessions

> **AC #1 cross-reference:** eligibility and transport gates remain defined by `accounts/spec.md` and `channels/spec.md`; PR2 proves enabled runtime enforcement.  
> **AC #4 cross-reference:** `planning-shopping-cart.md` defines atomic meal/cart persistence; this delta does not duplicate those scenarios. Its only AC #4 delivery is retiring the HTTP bypass below.

## ADDED Requirements

### Requirement: Confirmation commits the session atomically

`do_confirm/2` MUST transition a valid PlanningSession to `:committed` only inside the same `Repo.transaction/1` that persists the confirmed menu and derived shopping effects. If any step fails, the status transition MUST roll back.

#### Scenario: Successful confirmation commits the session
- GIVEN a valid active session and a confirmable proposal
- WHEN confirmation succeeds
- THEN the session becomes `:committed` with the confirmed effects

#### Scenario: Failed confirmation preserves the session
- GIVEN a valid active session and a confirmation failure
- WHEN confirmation is rolled back
- THEN the session remains active and uncommitted

### Requirement: Foreign-lock rejection

Confirmation MUST reject a session whose `lock_owner_membership_id` belongs to an Account other than `current_membership.account_id`, before any write.

#### Scenario: Local owner lock may confirm
- GIVEN an active session owned by the current membership's Account
- WHEN the owner confirms its proposal
- THEN lock ownership validation succeeds

#### Scenario: Foreign lock is rejected
- GIVEN a session whose lock owner belongs to a different Account
- WHEN the current membership supplies its session id
- THEN the result is `{:error, :foreign_lock}` before any write

## MODIFIED Requirements

### Requirement: Confirm commits the session without hard-delete
`do_confirm/2` MUST let an active session's owner call `confirm` only with its valid PlanningSession lock. It MUST reject a missing, lost, foreign, or terminal (`:committed`, `:aborted`, `:lost_lock`) lock before any write. A valid confirm MUST atomically write scheduled meals + shopping cart AND transition the session row to `:committed` (NOT hard-deleted), preserving audit.

| Scenario | Given | When | Then |
|---|---|---|---|
| Confirm writes cart and commits | active session with completed proposal | owner calls `confirm` | scheduled meals + cart rows written AND row → `:committed` |

#### Scenario: Missing lock is rejected
- GIVEN a proposal with no PlanningSession lock
- WHEN confirmation is requested
- THEN confirmation is rejected before any write

#### Scenario: Lost or terminal lock is rejected
- GIVEN the supplied session is `:lost_lock` or terminal
- WHEN confirmation is requested
- THEN confirmation is rejected before any write

(Previously: confirm did not validate lock state.)

## REMOVED Requirements

### Requirement: `PlanningChatService.confirm_proposal/2`
(Reason: The HTTP path bypassed atomic confirmation, silently breaking AC #4.)
(Migration: Remaining callers MUST use the channel `confirm_proposal` message; PR3 searches `assets`, `lib`, and `test` consumers.)

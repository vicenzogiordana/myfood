# Calendar Specification

## Purpose

Defines account-scoped reads of scheduled meals and account-scoped range replacement under the capability gate.

> **AC #1 cross-reference:** Account eligibility is defined by `accounts/spec.md`; HTTP and channel authorization are defined by `channels/spec.md`. `:revenuecat_access_enforcement` remains off by default; this change SHALL prove enabled runtime enforcement in PR2.

## Requirements

### Requirement: Range replacement preserves outside dates

The system MUST replace only an Account's scheduled meals whose dates are within the selected inclusive range. It MUST preserve each `(account_id, date, slot)` uniqueness constraint.

#### Scenario: Replace meals inside a range
- GIVEN Account A has meals inside and outside `[from, to]`
- WHEN A replaces its meals for `[from, to]`
- THEN only A's meals in that range are replaced
- AND meals outside the range remain unchanged

#### Scenario: Preserve a partially adjacent slot
- GIVEN a meal exists at `(date, slot)` outside a partially overlapping range
- WHEN Account A replaces the selected range
- THEN that outside `(date, slot)` meal is preserved

#### Scenario: Reject a duplicate slot
- GIVEN replacement input contains two meals for A with the same `(date, slot)`
- WHEN the range is replaced
- THEN the replacement is rejected without duplicate scheduled meals

### Requirement: Range replacement is atomic

The system MUST perform selected-range removal and replacement in one `Repo.transaction/1`. A failed replacement MUST leave the previous in-range and outside-range meals unchanged.

#### Scenario: Complete range replacement
- GIVEN valid replacement meals for Account A's selected range
- WHEN the operation completes successfully
- THEN all selected-range changes are visible together

#### Scenario: Failed replacement rolls back
- GIVEN removal succeeds but a replacement meal cannot be persisted
- WHEN the operation fails
- THEN the prior selected-range and outside-range meals remain unchanged

### Requirement: Calendar access enforces Account capability

When `:revenuecat_access_enforcement` is enabled, calendar reads and range replacement MUST require the Account capability before any data is returned or written.

#### Scenario: Eligible Account reads its calendar
- GIVEN an eligible Account and enabled enforcement
- WHEN its active membership requests `GET /api/calendar`
- THEN the account's calendar is returned

#### Scenario: Expired Account read is denied
- GIVEN an expired Account and enabled enforcement
- WHEN its membership requests `GET /api/calendar`
- THEN the response is `403` capability-denied

#### Scenario: Expired Account replacement is denied
- GIVEN an expired Account and enabled enforcement
- WHEN its membership requests range replacement
- THEN the request is denied before any database write

### Requirement: Calendar operations are account-scoped

Calendar reads and replacements MUST use the current membership's Account scope. They MUST NOT expose or mutate another Account's scheduled meals.

#### Scenario: Account reads only its meals
- GIVEN Accounts A and B each have scheduled meals
- WHEN a membership on A reads the calendar
- THEN no meal belonging to B is returned

#### Scenario: Cross-account replacement is rejected
- GIVEN a replacement targets a slot owned by Account B
- WHEN a membership on Account A submits it
- THEN the request is rejected without changing either Account

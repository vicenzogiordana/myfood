# Delta for Planning Sessions

## ADDED Requirements

### Requirement: Confirmed-range confirm MUST rebuild the full-window shopping list

AC #36.2 / story 14: successful confirm MUST atomically write meals and invoke `shopping` for the same Account, `range_from`, and `range_to`. `shopping/spec.md` owns shortage, provenance, and rollback.

#### Scenario: [PR2] Locked confirm scopes shopping to its range
- GIVEN Account A has a locked `[Day1,Day7]` session
- WHEN its proposal is confirmed
- THEN its rebuilt shopping window is `[Day1,Day7]`

#### Scenario: [PR2] Unbounded confirm is rejected
- GIVEN confirmation lacks `range_from` or `range_to`
- WHEN the planner receives it
- THEN `{:error, :invalid_session_range}` and no shopping list changes

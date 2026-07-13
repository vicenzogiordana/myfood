# Membership-Scoped Channels

## Purpose

Defines how Phoenix Channels (`planning`, `cooking`, `calendar`,
`shopping`, `inventory`, `ai`) verify tenancy on `join` and during
`handle_in`. Topics keep the legacy `<channel>:<account_id>` shape
(decision 5.5) but **membership verification is server-side** via the JWT
`membership_id` claim (or the dual-write fallback to `user.account_id`).

**Grill decisions referenced**: `context.md` §4 (every shared resource
belongs to exactly one Account), §5 (cross-vista real-time via Phoenix
Channels), decision 5.5 (keep topic shape, server-side enforcement).

## Requirements

### Requirement: Channel topic shape stays `<channel>:<account_id>`

All six channels MUST continue to expose topics of the form
`<channel>:<account_id>`. No `:<user_id>` suffix is added; multi-Account
fan-out is achieved by the same User joining the same channel twice under
different JWTs (one per active Account).

#### Scenario: Legacy topic string remains valid

- GIVEN the existing frontend opens `"planning:<Account_A_id>"`
- WHEN Phase A is deployed with `MEAL_PLANNER_TENANCY_V2=true`
- THEN the channel route MUST still match and the join MUST succeed with
  the new `access_v2` token

### Requirement: Channel join MUST verify active membership

On `join/3` every channel MUST reject any socket whose authenticated User
does not hold an `AccountMembership` with `status: :active` in the topic's
`account_id`. The check MUST run **after** Guardian auth, MUST NOT trust
the URL `:account_id` alone, and MUST consult `current_membership` (or the
dual-write fallback to `current_user.account_id` for `access_v1` tokens).

#### Scenario: Cross-Account join is rejected

- GIVEN `User_U` is `:active` only in `Account_A`, JWT scoped to `Account_A`
- WHEN `User_U` attempts to join `"planning:<Account_B_id>"`
- THEN the channel returns `{:error, %{reason: "forbidden"}}` and the
  socket MUST NOT receive broadcasts

#### Scenario: Invited (non-active) User joining is rejected

- GIVEN `User_U` is `:invited` (not `:active`) on `Account_A`
- WHEN `User_U` joins `"planning:<Account_A_id>"`
- THEN the channel returns `{:error, %{reason: "forbidden"}}` — only
  `:active` memberships satisfy the multi-tenancy boundary

#### Scenario: Multi-familia User joining two topics via two sockets

- GIVEN `User_U` is `:active` in `Account_A` and `Account_B`
- WHEN `User_U` opens two sockets (one scoped to `Account_A`, one to
  `Account_B`) and joins `"planning:<A>"` on the first and
  `"planning:<B>"` on the second
- THEN BOTH joins MUST succeed; each socket only receives broadcasts for
  its own topic; neither socket reads the other Account's data

### Requirement: Channel handle_in routes use the active account

Every `handle_in` callback MUST read the active `account_id` from
`socket.assigns.current_membership.account_id` (or the dual-write fallback)
and MUST also verify that any entity id in the payload (e.g. a `meal_id`)
belongs to `current_membership.account_id` before mutation.

#### Scenario: handle_in with cross-Account entity id

- GIVEN `User_U` is `:active` in `Account_A` and `Account_B`, socket scoped
  to `Account_A`, and `Meal_M` belongs to `Account_B`
- WHEN `User_U` sends `"set_is_cooked"` with `meal_id: Meal_M` on the
  `cooking` channel
- THEN the channel replies `{:error, %{reason: "meal_not_in_account"}}`
  and does not mutate `Meal_M`

### Requirement: Channel backward compat with access_v1 tokens

A socket authenticated with `access_v1` MUST still pass the membership
check, by falling back to `current_user.account_id == topic_account_id`.
This keeps the React Native client working without an app release.

#### Scenario: Legacy access_v1 socket on the new deployment

- GIVEN a client holds a token with `typ: "access"` and
  `account_id: Account_A`
- WHEN the client joins `"planning:<Account_A_id>"`
- THEN the channel MUST accept via the `access_v1` fallback path; once
  `MEAL_PLANNER_TENANCY_V2=true` AND the client refreshes, the same socket
  authenticated with `typ: "access_v2"` MUST also be accepted (and the
  membership claim MUST equal the topic's account)

## Cross-References

`auth-pipeline-and-current-resource`, `guardian-jwt-claims`,
`multi-familia-switch-account`. Decision 5.5; `context.md` §4 multi-tenancy
boundary.
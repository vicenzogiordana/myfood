# Membership-Scoped Channels Specification

> Reconstructed as-built on 2026-07-21 because the original was lost. Source: `design.md` §7/§8.5, `UserSocket`, `LoadCurrentMembershipSocket`, `CalendarChannel`, `PlanningChannel`, `CookingChannel`, `AIChannel`, and their test suites.

## Purpose

Defines how WebSocket tenancy mirrors the HTTP model: the socket connect
populates `current_membership`, and each channel's `join/3` enforces
account-scoped access at join time (not via an HTTP-style plug).

## Requirements

### Requirement: Socket connect populates `current_membership` from a real row

`UserSocket.connect/3` MUST decode the JWT via
`Guardian.resource_from_token/1`, then resolve `current_membership` via
`LoadCurrentMembershipSocket.membership_from_socket/1`. Both `access_v2` and
legacy `access` tokens MUST resolve to a genuine `AccountMembership` row —
there is no in-memory synthesized membership. Connect MUST fail (`:error`)
only when no membership can be resolved at all (`nil`); it MUST succeed for a
non-`:active` (e.g. `:invited`) membership so that the channel `join/3` can
return a specific rejection reason.

#### Scenario: access_v2 connect resolves the real membership

- GIVEN a valid `access_v2` token with `membership_id`
- WHEN `UserSocket.connect/3` runs
- THEN `socket.assigns.current_membership.id` equals that membership's id

#### Scenario: Legacy access connect resolves the real active membership

- GIVEN a valid legacy `access` token for a User who holds a real `:active` membership
- WHEN `UserSocket.connect/3` runs
- THEN `socket.assigns.current_membership` is that real row

#### Scenario: Unresolvable membership fails connect

- GIVEN a token whose claims resolve to no membership at all
- WHEN `UserSocket.connect/3` runs
- THEN the connection is rejected (`:error`)

### Requirement: `join/3` enforces account match + active status

For `CalendarChannel`, `PlanningChannel`, and `CookingChannel` (topic prefix
`"<channel>:<account_id>[...]"`), `join/3` MUST reject with
`{:error, %{reason: "forbidden"}}` when the resolved membership is `nil`,
when `to_string(membership.account_id) != topic_account_id`, or when
`membership.status != :active`. On success it MUST assign `:account_id` and
`:current_membership` to the socket.

#### Scenario: Cross-Account join rejected

- GIVEN a socket whose membership is scoped to `Account_A`
- WHEN it attempts to join `"calendar:<Account_B_id>"`
- THEN the join is rejected with `{:error, %{reason: "forbidden"}}`

#### Scenario: Invited (non-active) membership join rejected

- GIVEN a socket whose membership on the topic's Account has `status: :invited`
- WHEN it attempts to join that channel's topic
- THEN the join is rejected with `{:error, %{reason: "forbidden"}}`

#### Scenario: Legacy access_v1 connection accepted when active

- GIVEN a legacy `access` token resolving to a real `:active` membership on the topic's Account
- WHEN the socket joins that topic
- THEN the join succeeds

### Requirement: `AIChannel` enforces active membership only (no account match)

`AIChannel`'s topic is `"ai_chat:<room_id>"` — an opaque identifier with no
embedded `account_id`. `join/3` MUST reject when the resolved membership is
`nil` or non-`:active`, but MUST NOT attempt a topic-vs-account comparison
(none is structurally possible).

#### Scenario: Non-active membership rejected on ai_chat join

- GIVEN a socket whose membership has `status: :invited`
- WHEN it attempts to join `"ai_chat:<room_id>"`
- THEN the join is rejected with `{:error, %{reason: "forbidden"}}`

### Requirement: `handle_in` cross-Account entity checks

Channel event handlers that accept an entity id referencing another domain
record (e.g. `CookingChannel.handle_in("start_session", %{"scheduled_meal_id" => id}, socket)`)
MUST verify the entity belongs to `current_membership.account_id` before any
mutation or delegation, replying `{:error, %{reason: "meal_not_in_account"}}`
on mismatch.

#### Scenario: Cross-Account meal id rejected in start_session

- GIVEN a socket scoped to `Account_A` and a `scheduled_meal_id` belonging to `Account_B`
- WHEN `handle_in("start_session", %{"scheduled_meal_id" => meal_id}, socket)` is called
- THEN the reply is `{:error, %{reason: "meal_not_in_account"}}` and no session is started

### Requirement: Multi-familia User can hold two live socket connections

A single User with `:active` memberships on two different Accounts MUST be
able to open two independent sockets, each scoped to a different Account, and
each MUST only receive broadcasts for its own topic.

#### Scenario: Two sockets, two topics, isolated broadcasts

- GIVEN one User with memberships on `Account_A` and `Account_B`, connected via two sockets
- WHEN socket 1 joins `"planning:<Account_A>"` and socket 2 joins `"planning:<Account_B>"`, and a broadcast is pushed to `"planning:<Account_A>"`
- THEN only socket 1 receives the broadcast

### Requirement: Only four channels exist; shopping/inventory isolate at the controller

`CalendarChannel`, `PlanningChannel`, `CookingChannel`, and `AIChannel` are
the only channel modules shipped in Phase A. The `shopping` and `inventory`
domains MUST enforce tenancy isolation through their HTTP controllers reading
`current_membership.account_id`, not through a channel.

#### Scenario: No shopping or inventory channel module exists

- GIVEN the `lib/meal_planner_api_web/channels/` directory
- WHEN its contents are listed
- THEN only `calendar_channel.ex`, `planning_channel.ex`, `cooking_channel.ex`, and `ai_channel.ex` are present

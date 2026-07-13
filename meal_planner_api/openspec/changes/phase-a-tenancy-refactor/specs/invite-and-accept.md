# Invite and Accept

## Purpose

Specifies the owner-invites-member flow, the invitee-acceptance flow
(including the "invitee has no `User` yet" case), the membership roster
endpoint, and owner-driven removal. Routes are scoped to an Account via
the URL (decision 5.4).

**Grill decisions referenced**: `context.md` §3 (seat cap), §4 (Account-
Membership), decision 5.4 (URL shapes), decision 5.7 (owner cannot leave).

## Requirements

### Requirement: Owner issues a single-use invite

`POST /api/accounts/:account_id/invites` MUST be invokable only by an
`AccountMembership` with `role: :owner`, `status: :active`. The handler MUST
mint a single-use token, store **only its hash** (`invite_token_hash`),
set `invite_expires_at` to `now + 7 days`, and return the **plaintext
token** in the response body exactly once.

#### Scenario: Owner invites a new email

- GIVEN `User_O` is `:owner` of `Account_A` (`:family_4`, 1 active member)
- WHEN `User_O` calls `POST /api/accounts/:account_id/invites` with
  `{ "email": "ana@example.com" }`
- THEN a `:invited` membership is created with `role: :member`,
  `invited_by_user_id: User_O.id`, `invite_token_hash: <hash>`,
  `invite_expires_at: now + 7d`; response is `201` with the plaintext token

#### Scenario: Non-owner attempts to invite

- GIVEN `User_M` has `role: :member` on `Account_A`
- WHEN `User_M` calls `POST /api/accounts/:account_id/invites`
- THEN the response is `403 not_owner` and no token is minted

#### Scenario: Seat-cap race

- GIVEN `Account_A` (`:family_4`) already has 4 `:active` memberships
- WHEN two owners concurrently POST invites for the same Account
- THEN exactly one returns `201` and the other returns `409 seat_cap_reached`
  (count taken inside the `SELECT … FOR UPDATE` transaction that inserts
  the invite)

### Requirement: Invitee accepts an invite token

`POST /api/invites/:token/accept` MUST look up the membership by
`invite_token_hash`, refuse if expired, already used, or no longer
`:invited`, attach the existing User (or create one if the email is new),
flip the membership to `status: :active`, set `joined_at`, nullify
`invite_token_hash` and `invite_expires_at`, and return a freshly minted
JWT scoped to the Account (`typ: "access_v2"`).

#### Scenario: Existing User accepts

- GIVEN an `:invited` membership for `ana@example.com` with a valid token
- WHEN `POST /api/invites/<token>/accept` is called by a session whose
  JWT subject email matches
- THEN the membership becomes `:active` with `joined_at` set, the token is
  invalidated (re-acceptance MUST fail), and the response is the auth
  payload

#### Scenario: New User accepts

- GIVEN the invited `email` does not exist as a `User`
- WHEN `POST /api/invites/<token>/accept` is called with
  `{ "password": "...", "name": "..." }`
- THEN a new `User` is created, the membership becomes `:active`, and the
  token is invalidated

#### Scenario: Token replay

- GIVEN an already-accepted invite token
- WHEN `POST /api/invites/<token>/accept` is called a second time
- THEN the response is `410 invite_token_used`

#### Scenario: Expired token

- GIVEN `invite_expires_at < now`
- WHEN `POST /api/invites/<token>/accept` is called
- THEN the response is `410 invite_token_expired`

### Requirement: Membership roster

`GET /api/accounts/:account_id/memberships` MUST be invokable by any
`:active` member of the Account; non-members MUST be rejected with
`404 account_not_found` (no existence leak). Rows MUST be ordered
`role ASC, joined_at ASC` (owner first).

#### Scenario: Active member lists the roster

- GIVEN `User_M` is `:active` on `Account_A` with 2 other members
- WHEN `GET /api/accounts/:account_id/memberships` is called
- THEN the response includes all rows for the Account, each carrying
  `user_id`, `email`, `name`, `role`, `status`, `joined_at`

### Requirement: Owner removes a member

`DELETE /api/accounts/:account_id/memberships/:user_id` MUST be invokable
only by the `:owner` and MUST refuse to remove the owner (decision 5.7).
Removing an `:active` member decrements seat usage; re-activation later
MUST re-check the seat cap (see `account-membership`).

#### Scenario: Owner removes a :member

- GIVEN `User_M` is `:active` on `Account_A`
- WHEN `User_O` calls `DELETE /api/accounts/:account_id/memberships/User_M`
- THEN the row is hard-deleted and `User_M`'s next request against
  `Account_A` returns `403 not_a_member`

#### Scenario: Attempt to remove the owner

- GIVEN `User_O` is `:owner` of `Account_A`
- WHEN anyone calls `DELETE /api/accounts/:account_id/memberships/User_O`
- THEN the response is `403 cannot_remove_owner` and the row remains `:active`

## Cross-References

Decisions 5.4, 5.7; `context.md` §4. §4b cascade deferred.
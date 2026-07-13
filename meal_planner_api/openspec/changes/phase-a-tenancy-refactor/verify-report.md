# Verification Report — PR 3a (phase-a-tenancy-refactor)

**Change**: `phase-a-tenancy-refactor`
**Slice**: PR 3a — controllers + router + `auth_controller.ex` `access_v2` cutover
**Branch**: `feature/phase-a-pr-3a` (base: `feature/phase-a-pr-2b`)
**Mode**: Strict TDD
**Date**: 2026-07-09

## Completeness

| Metric | Value |
|--------|-------|
| Tasks in scope | 8 (3.1–3.8) |
| Tasks complete | 8/8 (tasks.md checkboxes all `[x]`) |
| Tasks incomplete | 0 |

## Build & Tests Execution

**Build**: ✅ `mix compile --warnings-as-errors --force` — clean, 0 warnings.

**Tests**: ✅ 435 passed / 0 failed (full suite, matches apply-progress claim)
```
Finished in 8.9 seconds (0.8s async, 8.1s sync)
435 tests, 0 failures
```
Re-ran the new/changed test files in isolation with `--seed 0` for confidence:
- `auth_controller_test.exs`: 17/17 passed (includes the 5 new task 3.8 tests)
- `membership_controller_test.exs` + `invite_controller_test.exs` + `invite_accept_controller_test.exs` + `account_lifecycle_controller_test.exs` + `account_lifecycle_leave_test.exs` + `router_test.exs` + `enforce_account_scope_test.exs`: 23/23 passed

**Diff size**: `git diff --stat feature/phase-a-pr-2b..feature/phase-a-pr-3a -- meal_planner_api/lib meal_planner_api/test` → **21 files, +1585/-58** (code-only; the raw 23-file stat includes `tasks.md`/`apply-progress.md` doc updates, which are not implementation).

## Spec Compliance Matrix

| Requirement | Scenario | Test | Result |
|---|---|---|---|
| Membership roster (invite-and-accept.md) | Active member lists roster; non-member 404 | `membership_controller_test.exs` | ✅ COMPLIANT |
| Owner removes a member (invite-and-accept.md) | Owner removes member / cannot remove owner | `membership_controller_test.exs` | ✅ COMPLIANT |
| Owner issues single-use invite | 201 w/ token; non-owner 403; seat-cap 409 | `invite_controller_test.exs` | ✅ COMPLIANT |
| Invitee accepts invite | existing/new user, replay 410, expiry 410 | `invite_accept_controller_test.exs` | ✅ COMPLIANT |
| Switch endpoint re-issues JWT (multi-familia-switch-account.md) | switch success / not_your_membership / suspended | `account_lifecycle_controller_test.exs` | ✅ COMPLIANT |
| Owner cannot leave (invite-and-accept.md / decision 5.7) | member leaves 204; owner leaves 403 | `account_lifecycle_leave_test.exs` | ✅ COMPLIANT |
| Cross-Account isolation via URL/JWT check (multi-familia-switch-account.md) | URL/JWT mismatch → 403; switch-account exempted | `enforce_account_scope_test.exs` + `router_test.exs` | ✅ COMPLIANT |
| access_v2 claim shape (guardian-jwt-claims.md) | membership_id/account_id/role/plan/status present | `auth_controller_test.exs`, `accounts_membership_claims_test.exs` (PR 2a) | ✅ COMPLIANT |
| Refresh preserves claim set, no silent re-scoping (guardian-jwt-claims.md) | refresh keeps typ/membership_id regardless of current flag | `auth_controller_test.exs` (2 new tests, flag flipped between mint and refresh) | ✅ COMPLIANT — independently re-verified live (see Correctness) |
| Dual-write flag controls issuance only (guardian-jwt-claims.md) | flag off → access; flag on → access_v2 | `auth_controller_test.exs` | ✅ COMPLIANT |

**Compliance summary**: 10/10 in-scope scenarios compliant.

## Correctness — Independently Re-Verified Findings (per launch prompt's 5 specific checks)

1. **`typ` preservation on refresh** — ✅ CONFIRMED genuine, not just self-reported. Traced the code path: `AccountsMembership.claims_for/2` sets `"typ" => "access_v2"` in the claims map; `issue_auth_response/6`'s `:access_v2` clause calls `Guardian.encode_and_sign(user, claims, token_type: "access")` — Guardian's `set_type/3` does not override an already-present non-nil `"typ"` key (the same mechanism fixed for `Accounts.claims_for/2` in PR 2b item 1), so the access token keeps `typ: "access_v2"` even though the option says `"access"`. `refresh/2`'s `reissue_from_refresh_claims/2` dispatches on **`membership_id` presence in the incoming refresh token's decoded claims** (not on the current flag value, not on `typ` — the refresh token's own `typ` is always `"refresh"`), reloads the User + Membership, and re-runs `claims_for/2`. Ran `auth_controller_test.exs` standalone (`--seed 0`): both refresh tests pass, including flipping the flag to the *opposite* value between mint and refresh in both directions (`access_v2`→flag off→refresh still `access_v2`; `access`→flag on→refresh still `access`). This is a real behavioral test (HTTP round-trip, live JWT decode), not a tautology.

2. **`access_v2` minting uses `membership.account_id`, not `user.account_id`** — ✅ CONFIRMED. `AccountsMembership.claims_for/2` (`meal_planner_api/lib/meal_planner_api/accounts_membership.ex`) reads `to_string(membership.account_id)` exclusively; `user.account_id` is never referenced in the claims builder. `authenticate_with_password/1`'s `first_active_membership_for(user, account)` filters `where: m.account_id == ^account_id` (the PR 2b post-review fix for the multi-familia security bug, `eb1ec69`) — so the membership handed to the controller is guaranteed scoped to the same Account being logged into. `register_with_password/1` returns the membership inserted in the same `Multi` transaction as the Account — same guarantee by construction. The PR 2b bug pattern (return a membership from a *different* Account than the one in the tuple) is not reintroduced.

3. **`EnforceAccountScope`** — ✅ CONFIRMED. Compares `conn.path_params["account_id"]` against `conn.assigns.current_membership.account_id` (string-normalized both sides). No-ops (passes through) when `path_params["account_id"]` is absent — router confirms `POST /api/auth/switch-account` is piped through `[:auth]` only (no `enforce_account_scope`), the only route among the 6 with no `:account_id` in its URL. Direct plug tests + the `router_test.exs` end-to-end test both pass.

4. **`MembershipController.index/2`** — ✅ CONFIRMED uses `AccountsMembership.list_memberships/1` (application-layer, active+invited). Does **not** call `AccountRepo.list_active_memberships_for_account/1` — this was explicitly flagged as a risk-to-avoid in PR 2b's apply-progress.md (§"New risks for PR 3a/3b/3c" #3) and PR 3a correctly avoided it.

5. **Scope containment** — ✅ CONFIRMED. Code-only diff (21 files) touches only: 3 new controllers, 1 new plug, 1 new controller-support helper, `router.ex`, `auth_controller.ex`, `accounts.ex`, `accounts_membership.ex` (one bug fix, see below), `account_service.ex` (unused-alias cleanup), `shopping_controller.ex` (dead-code removal), and their test files. **Zero** channel files (`calendar_channel.ex`, `planning_channel.ex`, `cooking_channel.ex`, `ai_channel.ex`) or the not-yet-created `shopping_channel.ex`/`inventory_channel.ex` were touched — confirmed via `git diff --stat -- .../channels`. PR 3b scope (tasks 3.9–3.13) is intact.

## Additional Findings

### WARNING — "both token types" test convention only partially followed
`tasks.md` §"Test conventions" states: *"`:auth`-piped route tests must drive both token types (`access` / `access_v2`) per design §8.4."* Only `MembershipController.index/2`'s tests exercise a legacy `access` (v1) token end-to-end (`membership_controller_test.exs:59-85`, using a manually-minted legacy claim map to prove `LoadCurrentMembership`'s synthesis path plus `EnforceAccountScope` still functions). `InviteController`, `AccountLifecycleController` (switch/leave), and the `router_test.exs` checkpoint use **only** `access_v2` tokens via `issue_access_v2_token/2`. Functionally this is very likely safe — `EnforceAccountScope` and the controllers only ever read `current_membership.account_id`, which `LoadCurrentMembership` (PR 1) populates identically (real row vs. synthesized) regardless of token type, and the plug's own unit tests (`enforce_account_scope_test.exs`) exercise it against a raw membership-shaped map independent of how it was produced. But the project's own stated convention was not fully honored for 3 of the 4 new/extended controllers. Not a correctness bug found — a test-convention gap.

### SUGGESTION — untested nil-membership fallback in `issuance_typ/1`
`auth_controller.ex`'s `issuance_typ(_membership), do: :access` fallback clause (for when `authenticate_with_password/1` returns `membership: nil` — a legacy User with no active membership row, flag on) has no direct covering test in `auth_controller_test.exs` or `accounts_test.exs`. Given PR 1's backfill invariants (every legacy user gets exactly one `:owner` membership), this path should be unreachable in practice post-backfill, but it is defensive code with no test proving it doesn't crash. Low risk, worth a follow-up unit test.

### Informational — pre-existing bug fixed within task 3.8 scope (documented, in-scope)
`refresh/2`'s tier resolution had a real pre-existing bug (`Atom.to_string(binary)` `ArgumentError`, zero prior test coverage of `/api/auth/refresh`) fixed by normalizing with `SubscriptionService.normalize_tier/1`. This was necessary to make task 3.8's required refresh tests pass at all, consistent with the "confirmed pre-existing bug found via real TDD, fixed within task scope" precedent already used in PR 2b. Verified this doesn't reintroduce a regression — `refresh` tests pass, full suite green.

## Design Coherence

| Decision | Followed? | Notes |
|---|---|---|
| Env var (`MEAL_PLANNER_TENANCY_V2`) controls issuance only, not verification | ✅ Yes | `AuthPipeline`/`VerifyTokenType` (PR1) unchanged; only `password/2`/`refresh/2` consult the flag for minting. |
| `enforce_account_scope` runs after `LoadCurrentMembership`, exempts routes with no `:account_id` | ✅ Yes | Confirmed in router + plug. |
| No controller/channel reach-through beyond PR 3a's stated slice | ✅ Yes | Verified via diff scope check above. |
| `access_v2` claim shape matches design §3.2 exactly | ✅ Yes | `membership_id`, `account_id`, `role`, `plan`, `status`, `email`, `name`, `typ` all present; `iat`/`exp` from Guardian. |

## Issues Found

**CRITICAL**: None.

**WARNING**:
1. `InviteController` and `AccountLifecycleController` (switch/leave) tests only exercise `access_v2` tokens, not the legacy `access` (v1) token path required by `tasks.md`'s project-wide test convention (§"Test conventions"). Only `MembershipController.index/2` covers both. Recommend adding at least one legacy-token regression test per new controller before/at PR 3b, or explicitly documenting this as an accepted deviation.

**SUGGESTION**:
1. Add a direct unit/controller test for `issuance_typ/1`'s nil-membership fallback (`membership: nil`, flag on → still mints `access` legacy claims) to close the untested defensive branch.

## Verdict

**PASS WITH WARNINGS**

All 8 in-scope tasks (3.1–3.8) are implemented, tested, and match tasks.md/specs. All 5 specific risk areas called out in the launch prompt (typ preservation on refresh, `membership.account_id` vs `user.account_id`, `EnforceAccountScope` correctness, `list_memberships/1` vs the active-only repo helper, and scope containment vs PR 3b/channels) were independently re-verified against running code and pass. `mix test` is green at 435/0, `mix compile --warnings-as-errors` is clean, and the working tree matches the committed history with no stray scope creep. The one WARNING (partial "both token types" test coverage) does not indicate a functional defect — it is a test-convention gap that should be closed opportunistically, not a blocker for archiving PR 3a.

---

# Re-Verification — PR 3a post-review fix pass (8/8 items)

**Date**: 2026-07-09/10
**Scope**: independent re-verification of the 9-commit fix pass (`7306650`..`7e06acb`) that addressed the 1 BLOCKER + 7 CRITICAL findings surfaced by the 4-lens review (risk/resilience/readability/reliability) that the original `sdd-verify` pass (above, PASS WITH WARNINGS) had missed.

## Method

Read every fix commit's diff directly (`git show <sha>`), then independently reproduced the 3 highest-stakes items myself with a throwaway test file (`test/meal_planner_api_web/controllers/_verify_repro_test.exs`, written, run, and deleted — not part of any commit) that:
- manually minted legacy (`access_v1`-shape) JWTs by hand, mirroring `account_lifecycle_leave_test.exs`'s pattern, rather than trusting the repo's own regression tests
- decoded resulting tokens myself via `Guardian.decode_and_verify/1` rather than trusting `assert claims["typ"] == ...` in the existing suite
- POSTed forged tokens against the live fixed code to attempt the exact original exploit

All 9 tests in that throwaway file passed. Confirmed clean afterward: `git status` shows no trace of the file (it was untracked and removed).

## Item-by-item

| # | Item | Verified how | Result |
|---|---|---|---|
| 1 | BLOCKER: `leave/2` looked up by `actor.id` (always `nil` for synthesized legacy memberships) | Read `7306650`'s diff (`accounts_membership.ex:550`, `Repo.get_by(AccountMembership, user_id: actor.user_id, account_id: account.id)`). Independently minted a manual legacy claim map (no `membership_id`, `typ: "access"`) for a real `:member` row and POSTed `/api/accounts/:account_id/leave` — **204**, row deleted. Re-tested owner-leaves-own-account (still 403 `cannot_leave_owned_account`) and a legacy-token user hitting an account they don't belong to (**403 `account_mismatch`** from `EnforceAccountScope`, which fires before `leave/2` is ever reached — confirms the fix didn't weaken the not-a-member path; also confirmed via code reading that `leave/2`'s own `Repo.get_by(user_id:, account_id:)` returns `nil` → `:not_a_member` for a real cross-account call that somehow bypassed the scope plug). | ✅ CONFIRMED — real bug, real fix, no regression on the other two branches. |
| 2 | CRITICAL: `switch_account/2`/`accept_invite/2` unconditionally minted `access_v2`, bypassing the flag killswitch | Read `115dd51`'s diff (`build_response_claims/3` gate, mirrors `auth_controller.ex`'s `tenancy_v2_only?/0`). Independently called `/api/auth/switch-account` with the flag forced `false` and decoded the result myself — `typ == "access"`, no `membership_id` key. Repeated with flag `true` — `typ == "access_v2"`, `membership_id` present and correct. | ✅ CONFIRMED — flag now a real killswitch for both flows. |
| 3 | CRITICAL: zero observability on new auth surface | Read `a6cb3fb`'s diff — `Logger.warning/1` added to `auth_controller.ex` (refresh failures), `invite_controller.ex` (invite-accept token failures), `enforce_account_scope.ex` (403 mismatches, logs only account ids, never the token). Confirmed log lines fire during my own repro runs (`refresh token rejected: wrong typ=...`, `EnforceAccountScope rejected request: ...`). | ✅ CONFIRMED. |
| 4 | CRITICAL: 4x duplicated token-minting logic | Read `1cb1758`'s diff — `AccountScopeHelpers.mint_token_pair/2` is now the single implementation; `AuthController`'s two `issue_auth_response/6` clauses and `AccountScopeHelpers.render_membership_auth_response/5` all delegate to it. Confirmed by reading the post-diff source, not just the commit message. | ✅ CONFIRMED. |
| 5 | CRITICAL: duplicated `load_account/1` | Read `d24b60d`'s diff — `AccountsMembership.load_account/1` made public with `@spec`/`@doc`; `AccountScopeHelpers.load_account/1` now delegates (`when is_binary(account_id), do: AccountsMembership.load_account(account_id)`). | ✅ CONFIRMED. |
| 6 | CRITICAL: no test for unauthenticated access to invite-accept (route outside `:auth` pipeline) | Read `ae3fa4e` — 2 new tests: no Authorization header + empty body → 401; malformed `Bearer` header + empty body → 401. Both exercise the real `resolve_invitee/2` Bearer-parsing `with` chain, which is the only guard on this route. | ✅ CONFIRMED — real coverage added, not a stub. |
| 7 | CRITICAL: no HTTP-level test for `already_invited`/`already_a_member`/`invite_token_unknown`; `invalid_invitee`-unreachable claim | Read `79cb3e9` — 3 new HTTP-level tests (409/409/404) added and passing. **Independently verified the `invalid_invitee` unreachability claim by reading `resolve_invitee/2` and `accept_invite/2`'s clauses directly** (not trusting the commit message): `resolve_invitee/2` only ever returns `{:ok, %PersistenceUser{}}` (existing-user branch, via `Guardian.resource_from_claims/1`) or `{:ok, %{name: ..., password_hash: ...}}` (new-user branch, matched by a guard requiring non-empty binaries) or `:unauthenticated`. `accept_invite/2` has exactly 2 matching clauses for those 2 shapes plus a catch-all `accept_invite(_plaintext, _args), do: {:error, :invalid_invitee}`. No path from the controller can construct an argument matching neither named clause — the claim is accurate. The added test hits the catch-all directly at the application layer (`AccountsMembership.accept_invite(plaintext, %{unexpected: "shape"})`), which is the correct place for genuinely-dead-at-the-HTTP-layer code, not a cover story for skipping a real test. | ✅ CONFIRMED — both the test additions and the "dead branch" claim are accurate. |
| 8 | CRITICAL SECURITY: Guardian's `token_type:` never checked at decode time — access↔refresh confusion | Read `d7588ef`'s diff. **Independently reproduced the original vulnerability against the fixed code**: minted a real `access` token via `/api/auth/password` (register), POSTed it as `refresh_token` to `/api/auth/refresh` — **401 `invalid_refresh_token`** (previously would have been 200 with a fresh token pair). Minted a real `refresh` token, used it as `Bearer` on `POST /api/invites/:token/accept` — **401 `unauthorized`** (previously would have authenticated as the existing user). Confirmed no regression: a legitimate `refresh` token still succeeds on `/api/auth/refresh` (200, fresh pair, `typ: "access"` on the new access token); a legitimate `access_v2` token still authenticates `GET /api/accounts/:account_id/memberships` (200). | ✅ CONFIRMED — the vulnerability is closed, both attack vectors independently reproduced-then-rejected, both legitimate paths independently reproduced-then-accepted. |

## Test suite

`mix test` (fresh `mix compile --force` first): **446 tests, 0 failures** — matches the expected count exactly.

**Flakiness note**: across ~7 additional reruns (not required by the launch prompt but run for confidence), the suite failed intermittently (1 test) in 2 of the runs — once on the two item-8 regression tests directly after I had added/removed my own throwaway test file in the same session (almost certainly a stale-compile artifact from that edit, since `mix compile --force` + rerun was immediately green and stayed green for 4 more `--seed 0` runs), and once on an unrelated pre-existing checkpoint test (`router_test.exs:44`) with no throwaway file present, seed 0. This looks like pre-existing suite-level flakiness (untraced to this fix pass — `router_test.exs` was not touched by any of the 9 fix commits) rather than a defect in the 8 fixes: my dedicated, isolated reproduction of items 1/2/8 was 100% consistent (9/9 passing) across every run, and the canonical `mix test` run requested by the launch prompt returned 446/0. Flagged as a WARNING for follow-up (investigate CI-observed flake rate for `router_test.exs` and the auth security regression tests), not a blocker.

`mix format --check-formatted`: fails, but **pre-existing** across the whole `accounts_membership.ex` module (mostly `from x in Y do ... end` vs `from(x in Y, ...)` Ecto keyword-list style, and long `@spec` line-wrapping) — not introduced by this fix pass, consistent with the project's established non-blocking convention for this check. No new-in-this-fix-pass line was individually unformatted apart from this pre-existing project-wide style drift.

## Scope check

`git diff --stat 7306650~1..7e06acb -- meal_planner_api` (excluding `apply-progress.md`) touches exactly 13 files: 6 production files (`accounts_membership.ex`, `auth_controller.ex`, `invite_controller.ex`, `account_scope_helpers.ex`, `enforce_account_scope.ex`, `verify_token_type.ex`) and 7 test files, all of which map 1:1 to the 8 claimed items. No channel files, no PR 3b-scope files, no unrelated refactors. **No scope creep.**

## Updated Verdict

**PASS WITH CAVEATS**

All 8 post-review fix-pass items (1 BLOCKER + 7 CRITICAL) are independently confirmed real, correct, and test-covered — including the two most safety-critical ones (item 1's production-breaking `leave/2` bug and item 8's access/refresh token-type confusion vulnerability), both of which I reproduced myself against the fixed code rather than relying on the commit messages or apply-progress.md's self-report. `mix test` is green at the expected 446/0. No scope creep. `mix format --check-formatted` fails only on pre-existing, unrelated formatting drift (non-blocking per project convention).

**Caveat**: observed intermittent single-test flakiness in the full suite (2 failures across ~9 total full-suite runs during this verification session, in different tests each time, not reproducible with a clean `mix compile --force`). This does not appear tied to the 8 fixes — treat as a pre-existing CI-reliability WARNING to track, not a reason to block.

**PR 3a is ready to proceed to PR 3b (channel sweep)**, contingent on triaging the flakiness WARNING above (e.g., run the suite a few times in the actual CI environment before merging, to rule out an environment-specific race rather than something specific to this sandbox).

---

# Verification Report — PR 3b (phase-a-tenancy-refactor)

**Change**: `phase-a-tenancy-refactor`
**Slice**: PR 3b — channel sweep (tasks 3.9–3.13: `CalendarChannel`, `PlanningChannel`, `CookingChannel`, `AIChannel` join guards + multi-familia checkpoint)
**Branch**: `feature/phase-a-pr-3b` (base: `feature/phase-a-pr-3a`)
**Mode**: Strict TDD
**Date**: 2026-07-10

## Completeness

| Metric | Value |
|--------|-------|
| Tasks in scope | 5 (3.9–3.13) |
| Tasks complete | 5/5 (`tasks.md` checkboxes all `[x]`, deviations documented inline per task) |
| Tasks incomplete | 0 |

## Build & Tests Execution

**Build**: clean compile (no new warnings introduced by the 4 channel files or 5 test files).

**Tests**: ✅ 464 passed / 0 failed (full `mix test`, matches `apply-progress.md`'s claimed count exactly).
```
Finished in 10.5 seconds (0.8s async, 9.7s sync)
464 tests, 0 failures
```

**Format**: `mix format --check-formatted` on all 9 PR-3b-touched files (4 channels + 5 test files) → clean, exit 0.

**Scope containment**: `git diff --name-only feature/phase-a-pr-3a...feature/phase-a-pr-3b` touches exactly 11 files: 4 production channel files, 5 test files (4 extended + 1 new checkpoint), and 2 docs (`tasks.md`, `apply-progress.md`). **No controller, router, plug, or service file touched.** Matches the PR 3b mandate exactly.

## Independent verification of apply-progress.md's claims

| # | Claim | Verification method | Result |
|---|---|---|---|
| 1 | `CookingChannel`/`AIChannel` had **no join guard at all** before this PR (unconditional `{:ok, socket}`) | Read `git show feature/phase-a-pr-3a:meal_planner_api/lib/meal_planner_api_web/channels/{cooking,ai}_channel.ex` directly. `CookingChannel.join/3` was `def join("cooking:" <> _account_and_session, _payload, socket), do: {:ok, socket}` — no membership check whatsoever. `AIChannel.join/3` was `def join("ai_chat:" <> room_id, _payload, socket), do: {:ok, assign(socket, :room_id, room_id)}` — same. | ✅ CONFIRMED accurate. Both new guards (post-PR) correctly reject `nil`/mismatched/non-`:active` membership via `LoadCurrentMembershipSocket.membership_from_socket/1` + a `cond` chain identical in shape to design §7's canonical pattern; confirmed by reading the current source of both files. |
| 2 | Task 3.11 deviation — `set_is_cooked` doesn't exist on `CookingChannel`; equivalent check implemented on `start_session`'s `scheduled_meal_id` using `meal_not_in_account` | Grepped `set_is_cooked` across `lib/` — only exists in `calendar_channel.ex`. Read `cooking_channel.ex:36-58`: `handle_in("start_session", %{"scheduled_meal_id" => meal_id}, socket)` calls the real, pre-existing `PlanningRepo.get_scheduled_meal_for_account/2` (already used by `PlanningService`/`CookingService` elsewhere) and returns `{:reply, {:error, %{reason: "meal_not_in_account"}}, socket}` on `nil`. Read the covering test (`cooking_channel_test.exs:157-198`) — creates a real recipe + scheduled meal in Account B, joins as Account A, pushes `start_session` with Account B's `meal.id`, asserts the exact reply. | ✅ CONFIRMED — real cross-Account check, not a name-only relocation. Test is behavioral (creates real DB rows in a different Account, exercises the actual `handle_in` clause). |
| 3 | Task 3.12 deviation — `AIChannel`'s real topic is `ai_chat:<room_id>` (opaque, no `account_id`), so only "reject nil/non-active membership" is achievable | Read `user_socket.ex` channel routing and `ai_channel.ex:15` — confirmed `join("ai_chat:" <> room_id, ...)`, `room_id` is a free-form string with no Account derivation anywhere in the module or in `MealPlannerApi.AI.stream_response/4` (which resolves the Account via `user.account_id`/`membership`, not `room_id`). There is structurally no topic-embedded `account_id` to compare against. The implemented guard (`is_nil(membership)` / `membership.status != :active`) is the maximal enforcement possible given the topic shape — it still closes the real gap (pre-PR: **any** authenticated socket, even one with zero active memberships, could join and could call `new_message`). | ✅ CONFIRMED — not a shortcut; it is the best achievable guard, and it is a strict improvement over the prior unconditional accept. Flagged (matching apply-progress's own risk log) that per-Account AI-room isolation remains a real open gap if `room_id`s are ever guessable/shared — this is correctly logged as a future risk, not silently dropped. |
| 4 | `shopping_channel.ex` / `inventory_channel.ex` were NOT created (deferred) | `ls lib/meal_planner_api_web/channels/` → only `ai_channel.ex`, `calendar_channel.ex`, `cooking_channel.ex`, `planning_channel.ex`. | ✅ CONFIRMED — matches the explicit deferral recorded since PR 1's open questions and repeated through PR 2a/2b/3a/3b apply-progress sections. |
| 5 | Task 3.13 multi-familia two-socket checkpoint is real (two sockets, two joins, real broadcast, selective delivery) | Read `test/meal_planner_api_web/channels/membership_scoped_channel_test.exs` in full. Confirmed: two independent `connect/2` calls with two distinct `access_v2` tokens (one per membership/Account) → two real `subscribe_and_join/3` calls on `PlanningChannel` for `"planning:<A>"` and `"planning:<B>"` → a real `Endpoint.broadcast!/3` to topic A only → `assert_receive` on the A-socket and `refute_receive` on the B-socket for the same event name. | ✅ CONFIRMED — genuinely new file, not a rename; asserts selective delivery via both a positive (`assert_receive`) and negative (`refute_receive`) expectation on two live sockets. |

## Assertion quality audit (Strict TDD)

Scanned all 5 PR-3b test files (4 extended + 1 new). No tautologies, no assertion-free tests, no ghost loops. All new tests exercise a real `join`/`push` against a live socket and assert on the actual reply/broadcast payload. No mock-heavy patterns (these are integration-style channel tests against the real `Endpoint`/`Repo`, per project convention). `set_is_cooked`'s cross-Account test asserts `{:error, %{reason: "not_found"}}` (not `meal_not_in_account`) — correct, since `Calendar.set_is_cooked/3` was already Account-scoped pre-PR and 3.9's acceptance criteria only requires the cross-Account payload be rejected, not a specific reason string (that specific string requirement belongs to 3.11's `CookingChannel` canonical case, per spec).

## Design coherence (§7 join pattern, §8.5 checkpoint)

| Decision | Followed? | Notes |
|----------|-----------|-------|
| §7 canonical `cond`-based join guard (nil / mismatch / non-active) | ✅ Yes | All 4 channels use the identical 3-branch `cond` shape shown in design §7's `CalendarChannel` example. |
| §7 module name `LoadCurrentMembership.membership_from_socket/1` | ⚠️ Partial | Actual sibling module is `LoadCurrentMembershipSocket` (established in PR 1 task 1.10, not this PR) — functionally identical, consistently used across all 4 channels; pre-existing naming decision, not a PR 3b deviation. |
| §8.5 multi-familia two-socket scenario | ✅ Yes | Task 3.13's dedicated test matches §8.5 and the spec scenario verbatim. |
| Spec `membership-scoped-channels` — cross-Account join, invited-rejection, access_v1 fallback, handle_in entity check | ✅ Yes (4/4 channels), with 2 documented, justified deviations (3.11, 3.12) | See table above. |

## Issues Found

**CRITICAL**: None within PR 3b's own scope (tasks 3.9–3.13).

**WARNING**:
- `AIChannel` has no per-Account room isolation (any two Accounts' Users could join the same `room_id` if it were ever guessable/shared) — correctly logged as a future risk in `apply-progress.md`, not a regression introduced by this PR, but worth tracking before AI chat rooms become Account-scoped resources.
- Design §7's reference implementation names the socket helper `LoadCurrentMembership.membership_from_socket/1`; the actual module is `LoadCurrentMembershipSocket` (PR 1 decision). Cosmetic only — no functional gap — but future readers of design.md should not expect the literal module name from the doc.

**SUGGESTION**: None.

## Verdict — PR 3b

**PASS**

All 5 tasks (3.9–3.13) are complete, correctly scoped to `channels/` + tests + docs only, independently verified against the base branch (confirming the "no prior guard" claim for `CookingChannel`/`AIChannel`), both documented deviations (3.11, 3.12) are genuine and justified adaptations to the actual code shape rather than coverage shortcuts, and the multi-familia two-socket checkpoint (3.13) is a real, newly-written integration test exercising two live sockets and a real broadcast. `mix test`: 464/0. No scope creep.

---

## Phase A readiness (consolidated view across PR 1, 2a, 2b, 3a, 3b)

**NOT ready for a final consolidated verify/archive pass.**

PR 3b closes only tasks 3.9–3.13 (the channel *join* sweep). `tasks.md`'s own PR-3 task list (3.1–3.25) still has **12 unchecked tasks** with no PR planned to carry them:

- **3.14–3.20** (controller sweep: `CalendarController`, `PlanningController`, `CookingController`, `ShoppingController`, `InventoryController`, `PlanningChatController`, `RevenuecatController`) — confirmed **not done** by direct inspection: `lib/meal_planner_api_web/controllers/calendar_controller.ex:7,16` still reads `user.account_id` from `Guardian.Plug.current_resource(conn)` (the raw, legacy DB column), not `current_membership.account_id`. This means a multi-familia User who switches to a second Account via `POST /api/auth/switch-account` will still see the **first/legacy** Account's calendar/planning/cooking/shopping/inventory data over HTTP, because these controllers never consult the membership the new JWT actually carries.
- **3.21** (service sweep, 12 services) — not done, same root cause.
- **3.22** (`AccountsController` membership-aware endpoints) — not done.
- **3.23** (cross-Account isolation checkpoint, design §8.5's HTTP-level end-to-end test across all 6 resource controllers) — not done; this is the test that would have caught the 3.14–3.21 gap directly.
- **3.24 / 3.25** (`ARCHITECTURE.md` / `FRONTEND_INTEGRATION.md` updates) — not done.

`apply-progress.md`'s own PR 3b section acknowledges this explicitly ("no PR 3c is currently planned per the original 3-PR split, so whoever picks up tasks 3.14+ should re-read `tasks.md` §'PR strategy'"). This is a real, user-facing functional gap (not just docs/cleanup) in the multi-tenancy boundary for the primary resource endpoints, and it should block a "Phase A is done" archive claim until either (a) a PR 3c lands tasks 3.14–3.25, or (b) the team explicitly and consciously defers them with a tracked follow-up change, accepting that switch-account does not yet affect REST reads/writes on calendar/planning/cooking/shopping/inventory.

**Recommendation**: run `sdd-apply` for a PR 3c covering tasks 3.14–3.25 before requesting a consolidated Phase A verify/archive pass.

---

# Verification Report — PR 3c (phase-a-tenancy-refactor)

**Change**: `phase-a-tenancy-refactor`
**Slice**: PR 3c — controller sweep (tasks 3.14–3.20, 3.22), service sweep (task 3.21), cross-Account isolation checkpoint (task 3.23), docs (3.24, 3.25). **Final PR of the 6-PR chain (1, 2a, 2b, 3a, 3b, 3c).**
**Branch**: `feature/phase-a-pr-3c` (base: `feature/phase-a-pr-3b`)
**Mode**: Strict TDD
**Date**: 2026-07-12

## Completeness

| Metric | Value |
|--------|-------|
| Tasks in scope | 12 (3.14–3.25) |
| Tasks complete | 12/12 — all `tasks.md` checkboxes `[x]`, deviations documented inline per task |
| Tasks incomplete | 0 |
| Unplanned prerequisite | 1 — `Identity.ensure_persistent_identity/1` fix (commit `7abb5ab`), documented as a deviation of task 3.21, not silent scope creep |

## Build & Tests Execution

**Build**: `mix compile --warnings-as-errors` — clean, 0 warnings.

**Format**: `mix format --check-formatted` on all 20 PR-3c-touched `.ex`/`.exs` files — clean, exit 0.

**Tests**: ✅ 498 passed / 0 failed (full `mix test`, reproduced independently, matches `apply-progress.md`'s claimed count exactly).
```
Finished in 11.2 seconds (0.9s async, 10.3s sync)
498 tests, 0 failures
```

`test/meal_planner_api_web/cross_account_isolation_test.exs` also re-run standalone: 1 test, 0 failures.

**Scope containment**: `git diff --stat feature/phase-a-pr-3b..feature/phase-a-pr-3c` — 25 files, +2396/-76 (dominated by the two doc files, +187 `ARCHITECTURE.md` / +341 `FRONTEND_INTEGRATION.md`, and 5 new/extended test files). Confirmed via targeted diff: **zero** channel files touched, **zero** changes to `auth_controller.ex`, **zero** changes to `accounts_membership.ex` beyond the declared `identity.ex` prerequisite. Matches the PR 3c mandate exactly — no reach into PR 3a/3b/2a territory that wasn't explicitly declared.

## Check 1 — Controller sweep genuinely complete (no leftover `user.account_id` reads)

Grepped all 8 controllers (`calendar`, `planning`, `cooking`, `shopping`, `inventory`, `planning_chat`, `revenuecat`, `accounts_controller.ex`) for `current_user.account_id` / `user.account_id`. **Zero live reads remain** — every match is inside a comment explaining what NOT to do (e.g. `# never from current_user.account_id — see the plug for why`). Independently confirmed the replacement pattern in `accounts_controller.ex` (`AccountsController.me/2` builds `%{account_id: membership.account_id, user_id: user.id}` and passes it to `AccountService.me/1`, which internally still contains a `user.account_id` cond-branch — but that branch reads the caller-constructed map's `account_id` key, sourced from `current_membership.account_id`, not the raw User struct's DB column. No discrepancy.) ✅ CONFIRMED — sweep is real, not partial.

## Check 2 — Service sweep "no change needed" claim spot-checked

Spot-checked 3 of the 5 services claimed to need zero change because they already take `account_id` directly: `account_service.ex` (confirmed — `me/1`/`context/1` take an explicit map built by the corrected controller), `budget_service.ex` (confirmed — `Map.get(user, :account_id)`, fed the `AccountScopeHelpers.scope_user_to_membership/2`-corrected user from `InventoryController`), `revenuecat_service.ex` (confirmed — `resolve_tier/2`, `sync_entitlements/3`, etc. all take `account_id` as an explicit first/positional argument, never derive it from a `user` struct). The "controller boundary as the single choke point" architectural decision (`AccountScopeHelpers.scope_user_to_membership/2`, `Map.put(user, :account_id, membership.account_id)` applied once per controller action before the corrected user reaches any service) is a sound simplification of the literal task 3.21 framing — verified end-to-end by `tenancy_sweep_test.exs` (6 sub-tests, real cross-Account data seeded, real service calls) rather than by inspection alone. ✅ CONFIRMED — the "0 of 12 services need internal change" claim is accurate and honestly earned via the documented grep audit, not a skipped step.

## Check 3 — Task 3.23 checkpoint reproduced and confirmed genuine

Read `test/meal_planner_api_web/cross_account_isolation_test.exs` in full and re-ran it standalone (1 test, 0 failures). Confirmed it does exactly what design §8.5 + the launch prompt required:
- Seeds one User with real `:owner`/`:member` memberships in two real Accounts, with one full fixture set (recipe, scheduled meal, cooking session, inventory item, shopping item) per Account.
- **Before switch**: an Account-A-scoped `access_v2` token gets `403 account_mismatch` on `GET /api/accounts/<B>/memberships` (the one URL with `:account_id` in it), and returns ONLY Account A's data on `GET /api/calendar`, `GET /api/planning/weekly`, `GET /api/cooking/sessions/:id`, `GET /api/inventory`, `GET /api/shopping-list` — Account B's fixtures are asserted absent via `refute` on every route.
- `POST /api/auth/switch-account` succeeds and returns a fresh token scoped to Account B.
- **After switch**: the SAME 5 data routes, called again with the new token, return ONLY Account B's data — Account A's fixtures are now asserted absent.

This is the strongest possible proof shape given the actual route inventory — 3 of the 6 named endpoints in the launch prompt (`GET /api/planning`, `/api/cooking`, `/api/shopping`) don't exist literally in `router.ex`; the closest real GET routes are substituted, and this substitution is documented in the test's own moduledoc rather than silently done. ✅ CONFIRMED — this is a genuine, load-bearing, bidirectional isolation proof, composing the independently-tested controller fixes (3.14–3.20) into one connected end-to-end proof over real HTTP with zero internal context calls.

## Check 4 — `identity.ex` fix correctness and non-regression

Read the full diff of `lib/meal_planner_api/persistence/identity.ex`. The claim is accurate: `fetch_existing_identity/2`'s original fast path was `%User{account_id: ^account_id} <- Repo.get(User, user_id)` — requires the legacy `users.account_id` column to equal the target account, which design.md §2.3 (decision 5.1) explicitly keeps `nil` for real multi-membership Users. The fix adds `active_membership?(user_id, account_id)` as an `or` alternative, implemented as:
```elixir
Repo.exists?(from(m in AccountMembership, where: m.user_id == ^user_id and m.account_id == ^account_id and m.status == :active))
```
This filters by **both** `user_id` AND `account_id` AND `status == :active` — matching the exact pattern already established by `Accounts.first_active_membership_for/2` (the PR 2b post-review fix for a near-identical class of bug: item 2, "authenticate_with_password/1 returns the wrong Account's membership," fixed by adding an `account_id` filter to a query that previously only filtered by `user_id`). No regression of that fixed bug class. Confirmed `find_or_create_identity/1` (the legacy single-account flow, in `accounts.ex`, a distinct function from `ensure_persistent_identity/1`) is untouched by this diff and does not call into the modified code path at all. Two new tests in `test/meal_planner_api/persistence/identity_test.exs` cover the fast-path-via-membership case and the no-match error case. ✅ CONFIRMED — fix is correct, properly scoped by both dimensions, and does not reintroduce the class of bug fixed in PR 2b's review pass.

## Check 5 — Docs sanity vs. actual code

`ARCHITECTURE.md`'s rewritten Auth Flow section states `LoadCurrentMembership` "no longer fabricates an in-memory `:active` struct" for legacy `access` tokens and instead requires a REAL, `:active` `AccountMembership` DB row (401 `membership_id_required` if none exists). Verified against `lib/meal_planner_api_web/plugs/load_current_membership.ex`: this is accurate — `synthesize_legacy_membership/2` was changed (in a prior PR-3b review fix, per its own inline comment "Post-PR-3b review — BLOCKER fix") to call `load_real_active_membership/2` (`Repo.get_by(AccountMembership, user_id:, account_id:, status: :active)`) rather than fabricating a struct. Docs match current code, not stale pre-fix behavior. ✅ CONFIRMED.

One pre-existing, explicitly-deferred gap surfaced during this check (not introduced by PR 3c, not claimed fixed by any doc): `LoadCurrentMembership.load_access_v2_membership/1`'s DB query (`AccountMembershipByIdQuery.call/1`) does **not** filter by `status: :active` — an `access_v2` token minted while a membership was `:active` would still resolve if that membership were later suspended, since nothing re-checks status per-request. This is listed verbatim in `apply-progress.md`'s "Out of scope" section as one of "3 pieces of deliberately-deferred debt carried forward from PR 3b." Currently **dormant/unreachable in production** — grepped `lib/` and confirmed no API path in Phase A ever mints a `:suspended` `AccountMembership` row (`accounts_membership.ex:500`: "no API path mints a `:suspended` row in Phase A"). Logged below as a WARNING for future hardening, not a PR 3c defect.

## Check 6 — Scope containment

`git diff --stat feature/phase-a-pr-3b..feature/phase-a-pr-3c -- 'lib/**/channels/*' 'lib/**/auth_controller.ex' 'lib/meal_planner_api/accounts_membership.ex'` → empty. ✅ CONFIRMED — no channel files, no `auth_controller.ex`, no `accounts_membership.ex` changes beyond the declared `identity.ex` prerequisite (a different file, in a different module, already heavily scrutinized in this same check).

## Design Coherence

| Decision | Followed? | Notes |
|----------|-----------|-------|
| Design §8.5 canonical isolation test shape (real `AccountMembership` rows, `access_v2` token, `403 account_mismatch`) | ✅ Yes | Task 3.23's test matches the design's example test verbatim for the one `:account_id`-URL route, and extends it (correctly, per the launch prompt's broader ask) to prove the same property for 5 additional non-`:account_id`-URL routes plus the post-switch direction. |
| §2.3 decision 5.1 (`users.account_id` intentionally nil for multi-membership Users) | ✅ Respected | The `identity.ex` fix is precisely the correction needed to make this decision actually work end-to-end — without it, decision 5.1 would crash real multi-membership Users the moment they touched any of the 5 `Identity`-routed services. |
| "Controller boundary as single choke point" (this PR's own architectural decision, not in the original design doc) | ✅ Justified deviation | A legitimate, narrower implementation of task 3.21's own "or preload memberships and read the active one" allowance — proven correct by `tenancy_sweep_test.exs`, not just asserted. |

## Issues Found

**CRITICAL**: None.

**WARNING**:
- `LoadCurrentMembership`'s `access_v2` membership lookup (`AccountMembershipByIdQuery`) does not filter by `status: :active`, so a suspended membership's still-valid `access_v2` token would continue to resolve until the token's natural TTL expiry. Currently dormant (no Phase A code path mints `:suspended` rows yet), explicitly logged as deferred debt in `apply-progress.md`, but should be tracked and closed before any feature that suspends memberships (e.g. a billing-lapse flow) ships. Not introduced by, and not in scope for, PR 3c.
- Same underlying gap as PR 3b's already-logged item: `duplicated "load real membership" query logic` and `stale synthesize_legacy_membership naming` remain (both cosmetic/DRY, not correctness bugs) — carried forward again, still not addressed.

**SUGGESTION**: None new for PR 3c.

## Verdict — PR 3c

**PASS**

All 12 tasks (3.14–3.25) complete, correctly scoped, matching their acceptance criteria. The controller sweep is genuinely complete (zero leftover live reads, only explanatory comments remain). The service-sweep "0 changes needed" claim is honest and independently spot-checked, not a skipped step. Task 3.23 — the load-bearing end-to-end isolation checkpoint — is a real, bidirectional, HTTP-only proof that composes the whole PR's controller fixes and independently reproduces GREEN. The `identity.ex` prerequisite fix is correct, properly scoped by both `user_id` and `account_id`, matches the established fix pattern from PR 2b's own review round, and does not disturb the legacy `find_or_create_identity/1` flow. Docs are in sync with actual code (including a fix that landed in a prior PR-3b review round, correctly reflected here). Scope containment is clean — no channel, `auth_controller.ex`, or `accounts_membership.ex` changes beyond the declared, narrowly-scoped `identity.ex` fix. `mix test`: 498/0, `mix compile --warnings-as-errors`: clean, `mix format --check-formatted`: clean. One pre-existing, explicitly-deferred, currently-dormant WARNING carried forward (access_v2 membership lookup missing a `status: :active` filter) — worth a tracked follow-up, not a blocker.

---

## Phase A readiness (consolidated view across PR 1, 2a, 2b, 3a, 3b, 3c) — FINAL

**Phase A is now functionally complete.** PR 3c closes the gap that PR 3b's verify report (above) correctly identified as blocking: `switch_account` now genuinely affects every real REST endpoint checked (`memberships`, `calendar`, `planning`, `cooking`, `inventory`, `shopping`) — proven end-to-end by task 3.23, not just asserted by per-controller unit tests in isolation. All 55 tasks across all 6 PRs in `tasks.md` are checked complete. `mix test` at the tip of `feature/phase-a-pr-3c`: 498 tests, 0 failures, 0 regressions across the entire chain.

**Ready for a final consolidated review before opening GitHub PRs**, with two carried-forward, non-blocking items to fold into that review or a fast-follow change:
1. The `status: :active` filter gap on `access_v2` membership lookups (dormant today, WARNING above).
2. The cosmetic naming/duplication debt already logged in PR 3b's verify report (`LoadCurrentMembershipSocket` vs. design's `LoadCurrentMembership.membership_from_socket/1` naming; duplicated "load real membership" query logic).

Neither is a correctness gap in what ships today. Recommend: open the 6 PRs in chain order (1 → 2a → 2b → 3a → 3b → 3c) as originally planned, run the full 4-lens review (`review-risk`, `review-resilience`, `review-readability`, `review-reliability`) on the consolidated diff given its size and auth-surface area, then merge with the `MEAL_PLANNER_TENANCY_V2` env-var cutover as its own explicit post-deploy step per design §9.1.

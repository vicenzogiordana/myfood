# Phoenix Channels Reference

This document provides a complete reference for all Phoenix Channels used in the Meal Planner API real-time communication layer.

## Overview

The application uses Phoenix Channels for real-time bidirectional communication between the Elixir backend and JavaScript frontend clients. All channels are accessed through a single authenticated `UserSocket` connection.

## Connection

```javascript
import { Socket } from "phoenix";

const socket = new Socket("/socket", {
  params: { token: "<jwt-token>" }
});

socket.connect();
```

## Channel Reference

### ai_chat:* — AI Meal Planning Assistant

Conversational AI assistant for meal planning queries.

**Topic Pattern:** `ai_chat:<session_id>`

#### Incoming Events

| Event | Payload | Description |
|-------|---------|-------------|
| `new_message` | `{"content": "string", "context": {...}}` | Send a message to the AI assistant |
| `regenerate` | `{"message_id": "uuid", "options": {...}}` | Request regeneration of an AI response |
| `end_session` | `{}` | End the AI chat session and cleanup |

**Example Payload (new_message):**
```json
{
  "content": "What can I make with chicken and rice?",
  "context": {
    "dietary_restrictions": ["gluten-free"],
    "servings": 4
  }
}
```

#### Outgoing Events

| Event | Payload | Description |
|-------|---------|-------------|
| `new_message` | `{"id": "uuid", "content": "string", "role": "assistant", "timestamp": "ISO8601"}` | AI response |
| `typing` | `{"is_typing": true}` | Indicator that AI is processing |
| `error` | `{"code": "string", "message": "string"}` | Error occurred |
| `regeneration_started` | `{"message_id": "uuid"}` | Regeneration process initiated |
| `regeneration_complete` | `{"original_id": "uuid", "new_message": {...}}` | New message ready |

**Example Response (new_message):**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "content": "Here are some options with chicken and rice...",
  "role": "assistant",
  "timestamp": "2026-06-07T10:30:00Z",
  "suggestions": [
    {"recipe_id": "123", "name": "Chicken Fried Rice", "match_score": 0.95}
  ]
}
```

---

### calendar:* — Calendar Operations

Real-time calendar updates for meal planning.

**Topic Pattern:** `calendar:<account_id>`

#### Incoming Events

| Event | Payload | Description |
|-------|---------|-------------|
| `subscribe` | `{"date_range": {"start": "YYYY-MM-DD", "end": "YYYY-MM-DD"}}` | Subscribe to calendar updates in date range |
| `unsubscribe` | `{"date_range": {...}}` | Unsubscribe from date range updates |
| `refresh` | `{}` | Request full calendar refresh |

**Example Payload (subscribe):**
```json
{
  "date_range": {
    "start": "2026-06-01",
    "end": "2026-06-30"
  }
}
```

#### Outgoing Events

| Event | Payload | Description |
|-------|---------|-------------|
| `slot_updated` | `{"slot": {...}}` | A calendar slot was modified |
| `meal_assigned` | `{"slot": {...}, "recipe": {...}}` | Meal was assigned to a slot |
| `meal_removed` | `{"slot_id": "uuid"}` | Meal was removed from a slot |
| `batch_update` | `{"slots": [...]}` | Multiple slots updated at once |
| `sync_complete` | `{"synced_count": 30}` | Full sync finished |

**Example Response (slot_updated):**
```json
{
  "slot": {
    "id": "550e8400-e29b-41d4-a716-446655440001",
    "date": "2026-06-10",
    "slot": "lunch",
    "is_cooked": false,
    "recipe": {
      "id": "789",
      "name": "Grilled Chicken Salad",
      "calories_per_serving": 350,
      "prep_time_minutes": 15
    },
    "is_favorite": true
  },
  "updated_by": "user"
}
```

---

### planning:* — Culinary Agent Planning Session (spec #93)

Topic: `planning:<household_id>` (the current membership's `account_id`), with
`planning_agent:<household_id>` kept as an alias for clients that adopted it during the
rollout; both serve the same flow. It is a thin adapter over
`MealPlannerApi.PlanningAgent.Session`. This section is the client contract: a frontend
implements the planning flow from it alone, and `PlanningChannelContractTest` fails when the
event types, fields or reply reasons below drift from what the code emits.

**Join.** Only an active Member of that Household joins; the Household always comes from the
membership, never from a payload. A join is refused with `{reason}`: `forbidden` (not an
active Member, or another Household's topic) or `subscription_required` (the Household has no
active plan or trial).

**The legacy planner is switched off (issue #110).** Households plan only through this
agent flow. The legacy `planning:*` events (`generate_menu`, `chat`, `swap_constraints`,
`confirm_proposal`, `reject_proposal`, `start_planning`, `send_message` with a typed
`intent`, `cancel_planning`) reply `invalid_payload`; regex intent parsing, the in-memory
generation server and the optimizer server's silent greedy fallback are removed, and so are
the REST plan endpoints (`GET /api/planning/weekly`, `POST /api/planning/confirm`,
`POST /api/planning/chat`, `POST /api/planning/proposals/:id/reject`). Already confirmed
Meal Plans and Shopping Lists are unchanged.

#### Conventions

- Dates are ISO 8601 strings (`"2026-11-02"`), timestamps ISO 8601 UTC
  (`"2026-10-13T09:30:00.000000Z"`). Ids are UUID strings.
- Slots are `breakfast`, `lunch`, `snack` and `dinner`.
- Money is integer cents (`*_cents`) with a `currency` string (`"ARS"`). Events never carry
  formatted amounts: the client formats cents itself, `.` between thousands and `,` before
  the decimals (`"ARS 49.950,00"` for `4995000`). The formatted twins exist only in the
  agent's own tool results (see "Money for the agent").
- Quantities are integer thousandths (`quantity_milli`) of a `unit`: `g`, `ml` or `unit`
  (`250000` g = 250 g).
- A reply is either `ok` (with the payload shown) or `error` with `{reason}`. Every typed
  refusal has its own `reason` string (see "Errors and refusals"); a failure without one
  replies `internal_error`, never `invalid_payload`.

#### Incoming Events

| Event | Payload | Reply |
|-------|---------|-------|
| `start_session` | `{range_from, range_to, slots?}` — ISO dates, at most 31 days, none already planned; `slots` from `breakfast`, `lunch`, `snack`, `dinner` (default `["lunch", "dinner"]`) | `{session_id}` or `{reason}`: `session_already_active`, `session_start_rate_limited`, `range_already_planned`, `overlapping_range`, `invalid_range`, `invalid_slots`, `subscription_required`, `spend_caps_unconfigured`, `pricing_unconfigured`, `provider_unconfigured`, `internal_error` |
| `resume_session` | `{}` — only the session's Member, within the absence grace (also after a server restart) | `{session_id, proposal}` (the last valid Proposal, same shape as the `proposal` event, or `null`) or `{reason}`: `forbidden` (another Member, or no longer an active Member), `no_session` (none, or its grace expired), `session_busy` (the session did not answer within 5 s; retry), `internal_error` |
| `give_consent` | `{}` — explicit consent before the first external AI use | `ok` or `{reason}`: `no_active_session`, `internal_error` |
| `send_message` | `{text}` — a non-blank string of at most 4,000 bytes | `ok` (the turn runs and streams `agent_event`s), or `{reason}`: `invalid_message` (missing, non-string or blank `text`), `message_too_long`, `consent_required`, `busy`, `session_budget_exhausted` (the session's budget is used up: the `session_budget_exhausted` event is pushed again, no turn starts), `no_active_session` |
| `authorize_continuation` | `{}` — only the session's Member, after `limit_reached` | `ok` (the same request resumes with that limit extended; a new `send_message` also continues, as a new request) or `{reason}`: `forbidden`, `no_limit_reached`, `no_active_session` |
| `save_recipe` | `{recipe_id}` — only the session's Member, for a `recipe_draft` with `origin: "user_created"` (a dictated recipe) | `{recipe_id, name, origin}` (`origin` is `user_created`) — saved as a user-created Household Recipe — or `{reason}`: `forbidden`, `busy`, `member_absent`, `not_found`, `not_dictated` (AI-created Drafts are saved only by confirming a Proposal that uses them), `invalid_recipe`, `no_active_session`, `internal_error` |
| `stop` | `{}` — only the session's Member (the Owner can Cancel, not Stop) | `{status}` (`"stopped"`; the session, Workspace and last valid Proposal survive and a new `send_message` is accepted) or `{reason}`: `forbidden`, `no_active_session` |
| `cancel_session` | `{}` — the session's Member or the Household Owner; also cancels a session waiting for recovery after a restart | `{status}` (`"cancelled"`) or `{reason}`: `forbidden`, `no_active_session` |
| `confirm` | `{proposal_id}` — only the session's Member, the `proposal_id` of the Proposal on display | `{confirmation_id, meals_count, shopping_lines_count}` (the plan is saved and the session ends; a replay of the same `proposal_id`, also after the session ended, returns the same result and saves nothing twice) or `{reason}`: `forbidden`, `busy`, `member_absent`, `stale_proposal`, `approval_required`, `revalidation_conflict`, `unresolved`, `internal_error` |
| `confirmation_status` | `{proposal_id}` — any Member of the Household, also after the session ended | `{status, confirmation_id?, meals_count?, shopping_lines_count?}` — `status` is `confirmed` (with the three counts), `not_found` (nothing was saved for it) or `unknown` (cannot be read right now; ask again) |
| `approve_deviations` | `{proposal_id}` — only the session's Member, for a `requires_approval` Proposal on display | `ok` (a `deviations_approved` event follows; the Proposal can now be confirmed) or `{reason}`: `forbidden`, `busy`, `stale_proposal`, `no_deviations`, `session_not_active` |
| `approve_absence_exception` | `{member_id, restriction, meals}` — only the session's Member. `member_id` is the absent Member's user id; `restriction` is `{"kind": "diet", "value": <diet>}` (`vegetarian`, `pescatarian`, `vegan`, `celiac`) or `{"kind": "allergy", "value": <tag>}` (`milk`, `egg`, `peanut`, `tree_nut`, `soy`, `crustacean`, `mollusc`, `sesame`, `mustard`, `celery`, `lupin`, `sulphite`, `contains_fish`, `contains_gluten`); `meals` is a non-empty list of distinct `{date, slot}` inside the range and its slots | `ok` (an `absence_exception_approved` event follows) or `{reason}`: `forbidden`, `busy`, `invalid_absence_exception` (malformed, a Restriction that Member does not hold, or meals outside the range), `session_not_active` |
| any other event | — | `{reason}`: `invalid_payload` (also for a payload of the wrong shape, e.g. `confirm` without a string `proposal_id`) |

#### Outgoing Events

Every event is pushed as `agent_event` with `type`, `session_id` and exactly the fields
listed (events pass a field allowlist, so raw reasoning and tool output never reach the
client). A field marked `?` is present only in the case described.

| `type` | Payload | Meaning |
|--------|---------|---------|
| `progress` | `{step, call?, attempt?, tool?, outcome?}` — `step` is `thinking`, `searching_recipes`, `reading_plan` (also for `reuse_plan`), `reading_pantry`, `looking_up_prices`, `reading_recipe`, `drafting_recipe`, `running_optimizer`, `validating_proposal`, `retrying` (with `call`: `model`, `read` or `solver`, and `attempt`: integer from 1) or `tool_finished` (with `tool`: the tool name, or `unknown`, and `outcome`: `complete`, `partial` or `null`) | The agent is working. Show a status line; never block on it |
| `assistant_message` | `{text}` | Agent reply, or a notice rendered by code (see `limit_reached`) |
| `question` | `{text}` | The agent asks the Member one question; the turn ends. The answer is a new `send_message` |
| `proposal` | `{proposal_id, status, meals, skipped, purchase, consumed_cost, budget, deviations}` | A Proposal validated by code (see "Proposal"). It replaces any earlier one: only the latest can be approved or confirmed. Also pushed again when a `confirm` or `approve_deviations` names a Proposal that is not on display, and when confirmation recalculated it |
| `recipe_draft` | `{recipe_id, name, origin, draft, servings, slots, ingredients, staples, steps, nutrition, cost}` | The agent built or revised a Recipe Draft (see "Recipe Drafts"). `draft` is always `true`; `origin` is `ai_created` (disclose as AI-made, possibly imperfect) or `user_created` (a dictated recipe, which `save_recipe` saves). A revision keeps its `recipe_id`: replace the earlier one |
| `recipe_saved` | `{recipe_id, name, origin}` | The Member saved a dictated recipe as a Household Recipe |
| `optimizer_failed` | `{reason}` — `optimizer_busy`, `optimizer_unconfigured`, `optimizer_unavailable`, `optimizer_timeout`, `optimizer_crashed`, `optimizer_error` or the optimizer's own code (`infeasible`, `inconclusive`, …) | The optimizer failed; no fallback plan is produced. The agent explains or retries; nothing for the client to do |
| `session_brand_changed` | `{ingredient, brand, source, previous_brand, previous_source}` — `brand`/`previous_brand` are strings or `null`; `source`/`previous_source` are `session`, `household` or `null` | The agent set or cleared a Session Brand (this Planning Session only; household settings are unchanged). `brand` is the brand now bought for the ingredient |
| `consent_required` | `{}` | Consent must be given (`give_consent`) before the agent can call the AI provider |
| `limit_reached` | `{limit, requires_authorization}` — `limit` is `iterations` (15 model calls for this Member message), `no_progress` (3 consecutive attempts without new evidence) or `time` (5 minutes per request); `requires_authorization` is always `true` | Execution stopped. Nothing runs until the Member continues: `authorize_continuation` resumes the same request, and a new `send_message` is accepted as a new request that authorizes continuing by itself. Neither passes the session's ceilings and caps (`session_budget_exhausted`). When the turn's latest tool result was a service failure (a backend down, e.g. recipe search or the optimizer), an `assistant_message` rendered by code comes first, for any of the three limits (also when the 5-minute deadline cut a model call that came after the failures), naming the failing tools and their failure kinds and suggesting to try again later. When the turn's latest tool results were two or more validation failures of one tool, that `assistant_message` names the cause instead (e.g. "the recipe for Pizza needs ingredients that are not in the catalog: Flour") and invites a new message; it never asks a question |
| `session_budget_exhausted` | `{limit, message, proposal}` — `limit` is `spend_cap`, `token_cap` or `session_iterations` (60 model calls per Planning Session); `message` is a string rendered by code; `proposal` is the latest Proposal (same shape as the `proposal` event) or `null` | The session's budget is used up and is never extended. Show `message` and the Proposal: it can still be approved, confirmed or cancelled; the agent takes no more messages (`send_message` replies `session_budget_exhausted`). Without a Proposal the session ends at once (`session_ended`) and a new one can start. A Proposal voided when it is confirmed (it no longer passes revalidation) starts no agent turn here: the event is pushed again with `proposal: null` and the session ends |
| `agent_unavailable` | `{reason}` — `provider_unavailable` / `provider_timeout` / `provider_busy` (after up to 5 retries), `provider_unauthorized`, `provider_rejected_request`, `provider_conflict`, `provider_refused` (declined, after the refusal fallback when it is on), `provider_output_truncated`, `provider_context_exceeded`, `invalid_provider_response` (at once), `provider_error`, `internal_error` (the turn crashed) | The AI provider cannot be used now. The session survives: the Member may send a new message later |
| `turn_completed` | `{}` | The agent finished answering |
| `run_finished` | `{outcome}` — `complete`, `partial`, `failure`, `cancelled`, `interrupted`, `unknown` | Exactly one per request or authorized continuation, after its other events: `partial` means stopped by a limit or an exhausted budget, `failure` follows `agent_unavailable`, `cancelled` a Stop or Cancel, `interrupted` that the Member left and no new model call started, `unknown` that the run crashed. Use it to re-enable the input |
| `stopped` | `{}` | Stop finished: the agent is idle, the session and its last valid Proposal survive |
| `session_cancelled` | `{}` | The Planning Session was cancelled (by its Member or the Owner); its Workspace is discarded |
| `session_ended` | `{}` | The Planning Session is over: confirmed, idle-expired, or exhausted without a Proposal. A new one can start |
| `proposal_confirmed` | `{proposal_id, meals_count, shopping_lines_count}` | The plan was saved: its Planned Meals, the Purchase appended to the Shopping List and the AI-created Drafts it uses saved as private Household Recipes. `session_ended` follows |
| `proposal_invalidated` | `{proposal_id, reason, violations}` — `reason` is `revalidation_conflict` or `recipe_draft_revised` (the agent revised a Draft the Proposal uses; no `violations`); for `revalidation_conflict`, `violations` is a list of `{type, date, slot, message}` with `type` `missing_meal`, `skipped_meal`, `unexpected_meal`, `recipe_not_available`, `slot_mismatch` or `restriction_conflict` | Confirmation found that the shown Proposal is no longer valid (a Restriction, the pantry or availability changed), or the agent revised a Recipe Draft it uses. Nothing was saved and the Proposal is withdrawn: show no Proposal until the next `proposal` event. The agent builds a corrected one by itself (unless a `limit_reached` is pending or the session's budget is exhausted) |
| `confirmation_unresolved` | `{proposal_id}` | The confirmation outcome could not be verified within 30 s. It is never a failure: ask `confirmation_status` later |
| `deviations_approved` | `{proposal_id, deviations}` | The Member's Deviation Approval of that exact Proposal (`deviations` as in the Proposal). Any new Proposal voids it |
| `absence_exception_approved` | `{meals}` — a list of `{date, slot}` | An Absence Exception was approved for those meals; it names neither the Member nor the Restriction |
| `session_recovered` | `{interrupted}` — boolean | The session was restored after a server restart; `interrupted: true` means a request was running and was not resumed — the Member asks again |

#### Proposal

The `proposal` event (also `resume_session`'s `proposal` and
`session_budget_exhausted`'s `proposal`) carries these fields. Every one is computed by code;
the model never sets a status, a number or a Deviation.

| Field | Type | Meaning |
|-------|------|---------|
| `proposal_id` | string (UUID) | The identity of what the Member sees; `confirm` and `approve_deviations` name it. A recalculated Proposal is a new one |
| `status` | string | `valid`, or `requires_approval` (it has Deviations: confirm only after `approve_deviations`) |
| `meals` | list | One entry per planned meal |
| `meals[].date` | string (date) | The day |
| `meals[].slot` | string | The slot |
| `meals[].recipe_id` | string (UUID) | The recipe, or the Recipe Draft's id |
| `meals[].name` | string | The recipe name |
| `meals[].origin` | string | Recipe Origin: `traditional`, `ai_created` or `user_created` |
| `meals[].draft` | boolean | `true` for an unsaved AI-created Recipe Draft, saved as a private Household Recipe only if this Proposal is confirmed |
| `meals[].diners` | integer | Who eats: the Household's present Members (absent Members of an Absence Exception left out) plus the guests |
| `meals[].guests` | integer | Guests at that meal (0 when none) |
| `meals[].batches` | integer | Batches of the recipe cooked for the diners (at least 1); the Purchase buys for them |
| `skipped` | list of `{date, slot}` | Meals the Household does not eat at home: no meal, not bought or costed, nothing saved for them on confirmation (see "Skipped meals") |
| `purchase` | object | What to buy (see "Proposal Purchase") |
| `consumed_cost` | object | `{total_cents, currency, complete, missing_prices}`: the cost of the ingredients the meals consume, at stored prices |
| `budget` | object | `{budget_cents, purchase_total_cents, within_budget, uncertain}` |
| `deviations` | list | Deviations the Member must approve: `{type: "budget", budget_cents, total_cents, difference_cents}` when the Purchase overspends the budget. Empty for a `valid` Proposal |

#### Proposal Purchase

Every `proposal` carries its Purchase: the packages the Household must buy,
computed by code from the Proposal's meals net of the Projected Pantry
(Pantry minus stock committed to not-yet-cooked Planned Meals, inside or
outside the range). Needs are aggregated once per ingredient and unit, then
rounded up to whole packages of the stored Product with the lowest package
total, unless a brand was chosen for the ingredient (see "Brands" below).

| Field | Type | Meaning |
|-------|------|---------|
| `purchase.lines` | list | One line per ingredient and unit to buy |
| `purchase.lines[].ingredient` | string | Catalog Ingredient name |
| `purchase.lines[].quantity_milli` | integer | Quantity needed beyond the Projected Pantry |
| `purchase.lines[].unit` | string | `g`, `ml` or `unit` |
| `purchase.lines[].packages` | integer | Packages to buy |
| `purchase.lines[].total_cents` | integer | `packages × price_cents` |
| `purchase.lines[].product` | string | The Product bought |
| `purchase.lines[].brand` | string or `null` | Its brand |
| `purchase.lines[].presentation` | object | `{quantity_milli, unit}` of one package |
| `purchase.lines[].supermarket` | string | Where the price was seen |
| `purchase.lines[].price_cents` | integer | Price of one package |
| `purchase.lines[].currency` | string | Currency of the price |
| `purchase.lines[].observed_at` | string (timestamp) | When the price was observed |
| `purchase.lines[].age_hours` | integer | Age of the price in hours |
| `purchase.lines[].fresh` | boolean | `false` for a stale price (also listed in `stale_prices`) |
| `purchase.lines[].brand_choice` | object or `null` | `{brand, source, honoured}` when a brand was chosen for the ingredient (`source`: `session` or `household`; `honoured: false` when it could not be bought) |
| `purchase.lines[].cheaper_alternative` | object or `null` | `{product, brand, packages, total_cents, difference_cents}`: a cheaper Product than the chosen brand |
| `purchase.brand_substitutions` | list | `{ingredient, chosen_brand, source, bought_brand, bought_product, reason}` for each chosen brand that could not be bought (`reason: brand_unavailable`) |
| `purchase.missing_prices` | list | `{ingredient, quantity_milli, unit, reason, sold_in?, hint?}`; `reason` is `no_stored_price`, `no_matching_presentation` (with `sold_in`, the units it is sold in, and an informational `hint`) or `currency_mismatch` |
| `purchase.stale_prices` | list | `{ingredient, product, observed_at, age_hours}` for each line priced with a stale observation |
| `purchase.total_cents` | integer | Sum of the lines; a lower bound when `complete` is `false` |
| `purchase.currency` | string | `ARS` |
| `purchase.complete` | boolean | `false` when some price is missing |

```json
{
  "purchase": {
    "lines": [{"ingredient": "…", "quantity_milli": 250000, "unit": "g",
               "packages": 1, "total_cents": 800, "product": "…", "brand": "…",
               "presentation": {"quantity_milli": 500000, "unit": "g"},
               "supermarket": "…", "price_cents": 800, "currency": "ARS",
               "observed_at": "2026-10-13T09:30:00.000000Z", "age_hours": 3,
               "fresh": true,
               "brand_choice": {"brand": "…", "source": "household", "honoured": true},
               "cheaper_alternative": {"product": "…", "brand": "…", "packages": 1,
                                       "total_cents": 600, "difference_cents": 200}}],
    "brand_substitutions": [],
    "missing_prices": [{"ingredient": "…", "quantity_milli": 2000, "unit": "g",
                        "reason": "no_stored_price"}],
    "stale_prices": [],
    "total_cents": 800, "currency": "ARS", "complete": false
  },
  "consumed_cost": {"total_cents": 480, "currency": "ARS", "complete": false,
                    "missing_prices": []},
  "budget": {"budget_cents": 1500, "purchase_total_cents": 800,
             "within_budget": null, "uncertain": true},
  "deviations": []
}
```

- The budget is compared against `purchase.total_cents`, never the consumed
  cost. Overspend is a `{"type": "budget", budget_cents, total_cents,
  difference_cents}` Deviation and makes the status `requires_approval`.
- Missing prices (`no_stored_price`, `no_matching_presentation`,
  `currency_mismatch`) are never zero: they are left out of the total, which
  becomes a lower bound (`complete: false`, `uncertain: true`); then
  `within_budget` is `null` unless the lower bound already overspends.
  A stale price also makes the budget `uncertain`.
- `budget_cents` is `null` when the Household has no budget set; then
  `within_budget` is `null`.

#### Errors and refusals

Every `reason` a client can receive, with what it means and what the client does.

| `reason` | Meaning | Client action |
|----------|---------|---------------|
| `forbidden` | Not allowed for this Member: another Member's session (only its Member acts on it; the Owner may only Cancel), or not an active Member of the Household | Show that the session belongs to someone else; offer nothing but Cancel to the Owner |
| `subscription_required` | The Household has no active plan or trial | Send the Member to the subscription screen |
| `invalid_payload` | Unknown event, or a payload of the wrong shape | A client bug: fix the call |
| `invalid_range` | Missing or malformed dates, `range_to` before `range_from`, or more than 31 days | Ask for another range |
| `invalid_slots` | An unknown, repeated or empty list of slots | Ask for other slots |
| `range_already_planned` | Some day of the range already has a confirmed plan | Ask for unplanned days |
| `overlapping_range` | The store's last-resort guard against two sessions over the same days | Treat like `session_already_active` |
| `session_already_active` | The Household already has a Planning Session (one per Household) | Tell the Member who is planning; the Owner may Cancel it |
| `session_start_rate_limited` | Too many sessions started in the Household's window | Try again later |
| `spend_caps_unconfigured`, `pricing_unconfigured`, `provider_unconfigured` | The server is not configured for paid AI use | Show that planning is unavailable; an operator must fix the configuration |
| `no_active_session` | No Planning Session on this socket (none started or resumed here, or it ended) | Start one, or `resume_session` |
| `no_session` | Nothing to resume: the session ended or its 15-minute grace expired | Start a new session |
| `session_busy` | The session did not answer the resume within 5 s; it is still running | Retry `resume_session` |
| `session_not_active` | No Planning Session runs in the Household (approvals) | Start a new session |
| `consent_required` | Consent to external AI use is missing | Ask for it, then `give_consent` and resend |
| `invalid_message` | `text` is missing, not a string or blank | Do not send empty messages |
| `message_too_long` | `text` is over 4,000 bytes | Shorten it |
| `busy` | The agent is working; the shown Proposal may still change | Wait for `run_finished`, or `stop` first |
| `session_budget_exhausted` | The session's spend, tokens or model calls are used up | Offer to confirm or cancel the latest Proposal, or start a new session |
| `no_limit_reached` | `authorize_continuation` without a pending `limit_reached` | Nothing to authorize |
| `member_absent` | The session has no connected Member (this socket did not resume it) | `resume_session`, then retry |
| `not_found` | No such Recipe Draft in the session | Refresh from the latest `recipe_draft` events |
| `not_dictated` | `save_recipe` on an AI-created Draft | Only confirming a Proposal saves it |
| `invalid_recipe` | The dictated Draft could not be saved as a recipe | Ask the agent to fix the recipe |
| `stale_proposal` | The `proposal_id` is not the Proposal on display; the current one is pushed again as a `proposal` event | Show the pushed Proposal and ask the Member again |
| `approval_required` | A `requires_approval` Proposal confirmed without its Deviation Approval | Show the Deviations and offer `approve_deviations` |
| `no_deviations` | `approve_deviations` on a `valid` Proposal | Confirm it directly |
| `revalidation_conflict` | Confirmation found the Proposal no longer valid; a `proposal_invalidated` event explains why | Wait for the corrected `proposal` |
| `unresolved` | The confirmation could not be verified within 30 s; it may have succeeded | Never report failure: poll `confirmation_status` |
| `invalid_absence_exception` | Malformed, a Restriction that Member does not hold, or meals outside the range | Fix the selection |
| `internal_error` | An unexpected server failure; its detail stays on the server | Retry later |

#### Session lifecycle

1. **Start.** `start_session` opens one Planning Session for the Household and replies its
   `session_id`. Only one session per Household exists at a time.
2. **Consent and messages.** The first `send_message` replies `consent_required` and pushes
   `consent_required` until `give_consent`. Each accepted message runs one request that
   streams `progress`, `assistant_message`, `question`, `recipe_draft`, `proposal` and other
   events, and ends with exactly one `run_finished`. While it runs, `send_message`,
   `confirm`, approvals and `save_recipe` reply `busy`.
3. **Limits.** A request that hits a limit pushes `limit_reached`; `authorize_continuation`
   or a new `send_message` continues. A session whose budget is exhausted pushes
   `session_budget_exhausted` and takes no more messages.
4. **Stop.** `stop` halts the current request (`run_finished` `cancelled`, then `stopped`);
   the session, Workspace and last valid Proposal survive.
5. **Approvals.** For a `requires_approval` Proposal, `approve_deviations` with its
   `proposal_id` pushes `deviations_approved`; a new Proposal voids it. For an absent Member,
   `approve_absence_exception` lifts one Restriction for specific meals
   (`absence_exception_approved`); the agent then presents a Proposal that uses it.
6. **Confirm.** `confirm` with the displayed `proposal_id` revalidates it against current
   data and saves it: `proposal_confirmed`, then `session_ended`. A changed Proposal replies
   `stale_proposal` and is pushed again; a conflict replies `revalidation_conflict` and
   pushes `proposal_invalidated`; an unverifiable outcome replies `unresolved` (and pushes
   `confirmation_unresolved`): poll `confirmation_status`. Confirming is idempotent by
   `proposal_id`.
7. **Cancel.** `cancel_session` (the Member or the Owner) ends the session and discards its
   Workspace: `session_cancelled`.
8. **Absence grace and resume (issue #107).** When the Member's socket leaves or drops, the
   session, its Workspace, the last Proposal and the Household's slot are kept for 15
   minutes. While the Member is absent no new model call starts (a call in flight may finish;
   its run ends with `run_finished` outcome `interrupted`) and nothing is saved (`confirm`
   and `save_recipe` reply `member_absent`). Within the grace the Member rejoins the topic
   and sends `resume_session`, which replies with the authoritative state (`session_id` and
   the last Proposal); after a server restart the same event restores the session from
   recoverable storage and a `session_recovered` event follows. There is no unattended
   restart, a request that was running is never replayed, and neither the grace nor any
   limit resets. A Member no longer active in the Household cannot resume. When the grace
   expires the work is cancelled, the Workspace discarded and the slot released (the next
   `resume_session` replies `no_session`).
9. **Idle expiry.** A connected Member who does nothing for 30 minutes (no event, no running
   request) ends the session: `session_ended`, Workspace discarded, slot released.

**Start rate limit (issue #118).** A Household starts at most
`PLANNING_AGENT_SESSION_STARTS_PER_WINDOW` Planning Sessions within
`PLANNING_AGENT_SESSION_START_WINDOW_SECONDS`; a start over it is refused with
`session_start_rate_limited`. Without both values every `start_session` is refused
with `spend_caps_unconfigured`. Resuming a session is not a start.

#### Skipped meals

When the Member says the Household will not eat at home at a meal ("Wednesday
night we eat out, don't plan it"), the agent skips that date and slot with
`edit_workspace` `skip`, without asking, and `unskip` puts it back (issue
#160). A skipped meal is out of the range: the optimizer does not fill it
(`skipped_meals` in the optimizer payload), the Purchase and the consumed cost
leave it out, the Proposal lists it under `skipped`, and confirming saves no
Planned Meal for it. Skipping removes a Pin at that meal. A skip covers the
whole meal for the Household; it is not an Absence Exception, which lifts one
Restriction of one Member and is approved only by the Member.

#### Requested dishes and staples

A Recipe Draft the agent creates for a meal the Member asked for ("burgers on
Tuesday lunch") is pinned there and stays on the meals it is pinned to (issue
#162): `run_optimizer` never plans it on another meal, even when it is the
cheapest candidate. Only when the Member asks to have it again does the agent
pin it to the meal they name or call `edit_workspace` `repeat_recipe`, which
makes it a candidate for every meal of its slots. A revision
(`replaces_recipe_id`) keeps this. A Draft that was never pinned is a candidate
everywhere, as before.

Water, salt and pepper are staples, assumed always at home: a Draft may list
them without a catalog entry. They are returned under the Draft's `staples`,
never priced, bought, counted in cost or nutrition, and never block
`create_recipe`.

#### Money for the agent

Money is integer cents (`*_cents`) in every event and tool result. The agent's
tool results also carry, next to each `*_cents` integer, the amount formatted
by code (`"purchase_total": "ARS 49.950,00"` beside `"purchase_total_cents":
4995000`; `.` between thousands, `,` before the decimals), and the agent is
told to quote only those and never compute from cents (issue #160). The
budget Deviation of `run_optimizer` carries `bound_cents`, `actual_cents` and
`amount_cents` with their formatted twins (issue #162). Events
sent to the client keep only the cents; the client formats them the same way.

#### Brands

A chosen brand for an ingredient is the Session Brand (set from the chat with
the agent's `set_session_brand` tool, this Planning Session only, kept in its
Workspace) or else the Household's Brand Preference (set in household
settings: `GET /api/accounts/:account_id/settings/brand-preferences`, `PUT`
and `DELETE /api/accounts/:account_id/settings/brand-preferences/:ingredient_id`
with `{"brand": "…"}`; this is also the target of a "keep this brand"
shortcut). A Session Brand overrides the Brand Preference; with no chosen
brand the cheapest Product is bought.

- A chosen brand is bought whenever a Product of it exists in the needed
  unit and currency, even when another brand is cheaper; `brand_choice`
  says so (`honoured: true`) and `cheaper_alternative` names the cheaper
  Product and the difference.
- When it cannot be bought, the cheapest Product is bought instead and the
  line appears in `brand_substitutions` (`ingredient`, `chosen_brand`,
  `source`, `bought_brand`, `bought_product`, `reason: brand_unavailable`).
  A chosen brand is never swapped silently.
- When the Purchase breaks the budget, the agent is given the cheaper brand
  alternatives with their price difference (`brand_alternatives`) to offer
  the Member; code never applies them.

#### Recipe Drafts

A Recipe Draft exists only in the Planning Session's Workspace: it is never
saved by the agent and disappears when the session ends unconfirmed. Its
Ingredients are catalog Ingredients only. Names match the catalog by
similarity (Postgres `pg_trgm` trigrams over unaccented names, issue #160): a
spelling variant that is unambiguous (case, accents, a plural ending, e.g.
"limones" for "Limón") is used under its catalog name and reported to the
agent. An unknown name with one clear close match (the only candidate, or a
top candidate scoring at least 0.2 above the next, issue #164) is used as
that match and reported under `resolved`, e.g.
`[{"requested": "Tomate", "used": "Tomate perita"}]`; the agent tells the
Member only when the meaning could differ. Any other unknown one (two close
candidates alike, e.g. "harina 000" for "Harina de trigo" and "Harina
leudante") rejects the Draft and the agent gets close catalog matches ranked
by similarity to retry with. `lookup_prices`,
`set_session_brand` and the `search_recipes` ingredient matching use the same
similarity. One with no close match is
listed as missing from the catalog, and the agent tells the Member that dish
cannot be made instead of guessing other names), and its nutrition and cost
are computed by code. Two different requested names that resolve to
one Ingredient (issue #166, e.g. "Tomate" resolved to "Tomate perita" next to
an explicit "Tomate perita") are added up into one line when their units
match and reported under `merged_ingredients`
(`[{"requested": ["Tomate", "Tomate perita"], "ingredient": "Tomate perita",
"quantity_milli": 500000, "unit": "g"}]`); in different units the Draft is
rejected with `duplicate_ingredient`, whose `duplicates` name the requested
names, the Ingredient and the units. Names that differ only in case count as one
name, and a merged line above the per-line quantity cap rejects the Draft with
`quantity_too_large`. When the Member asks for a dish no recipe provides, the
agent creates it directly as an AI-created Draft, without asking first, and says
it was created with AI and may contain errors; it still asks first before
creating recipes to fit an infeasible budget or a plan limited to "only recipes
with X". Re-creating a Draft (by `replaces_recipe_id`, or with the
same name and origin) revises it in place, keeping its `recipe_id`, so the client
receives a new `recipe_draft` event for the same id instead of a duplicate. When
the shown Proposal uses the revised Draft, that Proposal is voided at once
(`proposal_invalidated` with `reason: "recipe_draft_revised"`): confirming it
replies `stale_proposal`, so nothing is saved at a cost other than the one shown,
and the agent presents a new Proposal. An
AI-created Draft can be pinned to a meal like any recipe. Its computed
nutrition and cost look like:

```json
{
  "nutrition": {"per_serving": {"calories": 380, "protein_g": 13.5,
                                "carbs_g": 76.0, "fat_g": 1.8},
                "complete": true, "missing": []},
  "cost": {"total_cents": 1000, "per_serving_cents": 500, "currency": "ARS",
           "complete": true, "missing_prices": []}
}
```

- A nutrient is `null` unless every Ingredient has it per 100 g or ml;
  `missing` names the Ingredients without data ("partial nutrition").
- `cost` is the consumed-ingredient cost at stored prices; missing prices are
  named and left out of the total (`complete: false`), never zero.
- A missing price with reason `no_matching_presentation` (the Ingredient is
  sold, but not in the unit asked) names the units it is sold in, e.g.
  `"sold_in": ["g"]`, with a hint to restate the quantity in that unit
  (issue #164). Only offers in the household currency (ARS) count toward
  `sold_in`; when every offer is in another currency there is no `sold_in`
  (issue #166). Proposal `missing_prices` (in `purchase` and
  `consumed_cost`) carry the same `sold_in` with an informational hint, not a
  retry instruction. `lookup_prices` carries no `sold_in`: it already lists
  each offer with its presentation unit. Code never converts units by
  guessing weights.

Paid execution requires `PLANNING_AGENT_SPEND_CAP_MICROS`,
`PLANNING_AGENT_TOKEN_CAP`, `PLANNING_AGENT_MAX_CONCURRENT_PROVIDER_CALLS` and the
selected provider's key and prices. `PLANNING_AGENT_MODEL_PROVIDER=claude` selects
Claude (`ANTHROPIC_API_KEY`, `ANTHROPIC_INPUT_PRICE_MICROS_PER_MTOK`,
`ANTHROPIC_OUTPUT_PRICE_MICROS_PER_MTOK`; optionally
`ANTHROPIC_CACHE_WRITE_PRICE_MICROS_PER_MTOK`, `ANTHROPIC_CACHE_READ_PRICE_MICROS_PER_MTOK`,
`PLANNING_AGENT_CLAUDE_MODEL` (default `claude-haiku-5-5`),
`PLANNING_AGENT_CLAUDE_EFFORT` (default `medium`) and `PLANNING_AGENT_CLAUDE_FALLBACKS`
(default `false`: Haiku 5.5 rejects server-side refusal fallbacks; `true` turns them on,
e.g. with `PLANNING_AGENT_CLAUDE_MODEL=claude-opus-5-5`, and then also requires
`ANTHROPIC_FALLBACK_INPUT_PRICE_MICROS_PER_MTOK` and
`ANTHROPIC_FALLBACK_OUTPUT_PRICE_MICROS_PER_MTOK`)); otherwise OpenAI
(`OPENAI_API_KEY`, `OPENAI_INPUT_PRICE_MICROS_PER_MTOK` and
`OPENAI_OUTPUT_PRICE_MICROS_PER_MTOK`). It also requires
the start rate limit (`PLANNING_AGENT_SESSION_STARTS_PER_WINDOW`,
`PLANNING_AGENT_SESSION_START_WINDOW_SECONDS`); without them `start_session` replies
`spend_caps_unconfigured` (or `pricing_unconfigured` / `provider_unconfigured`). A
value that is not a whole integer reads as unset: it never crashes boot, it refuses
the same way.

Global concurrency caps (issue #118) bound every Planning Session together.
`PLANNING_AGENT_MAX_CONCURRENT_PROVIDER_CALLS` caps provider calls in flight: a call
over it is refused before any spend is reserved and retried like a transient
failure, then reported as `agent_unavailable` with `provider_busy`.
`PLANNING_AGENT_MAX_CONCURRENT_OPTIMIZER_RUNS` caps optimizer subprocesses: a run
over it starts no subprocess and is reported as `optimizer_failed` with
`optimizer_busy` (`optimizer_unconfigured` when the cap is unset).
The spend and token caps bound every provider call of one Planning Session; they
are not reset between messages and never extended by `authorize_continuation`,
so once they are used up the session emits `session_budget_exhausted` (limit
`spend_cap` or `token_cap`) with the latest Proposal, and a new Planning Session
is needed to keep planning. The money cap (`PLANNING_AGENT_SPEND_CAP_MICROS`, e.g.
US$3 per session) is the real limit: its reservation before each call is the
conservative worst case. `PLANNING_AGENT_TOKEN_CAP` is only a safety net: with
Claude it reserves the request bytes / 3 plus the output limit once (no fallback
doubling) and cache reads never count toward it. A call refused by a cap (or by
the provider concurrency cap) before it reached the provider is not counted as
one of the session's model calls.
With Claude, a declined request (after the server-side refusal fallback) is
reported as `agent_unavailable` with `provider_refused`, a reply cut off at the
output limit with `provider_output_truncated`, and a full context window with
`provider_context_exceeded`; none of them is retried.

Per-call bounds: each model attempt 60 s (up to 5 transient retries), each
solve 120 s (no retry; a timeout is inconclusive), each recipe search 30 s (up
to 2 retries), with increasing backoff and every deadline shortened by the
request's remaining 5 minutes. No retry starts while the Member is absent.

---

### cooking:* — Cooking Mode

Real-time cooking guidance and timer synchronization.

**Topic Pattern:** `cooking:<recipe_id>`

#### Incoming Events

| Event | Payload | Description |
|-------|---------|-------------|
| `start_cooking` | `{"recipe_id": "uuid", "servings": number}` | Start cooking mode for a recipe |
| `step_complete` | `{"step_index": number, "notes": "string"}` | Mark a step as completed |
| `timer_start` | `{"duration_seconds": number, "label": "string"}` | Start a cooking timer |
| `timer_pause` | `{"timer_id": "uuid"}` | Pause a running timer |
| `timer_resume` | `{"timer_id": "uuid"}` | Resume a paused timer |
| `timer_cancel` | `{"timer_id": "uuid"}` | Cancel a timer |
| `update_servings` | `{"servings": number}` | Update serving size |
| `end_cooking` | `{"rating": number, "notes": "string"}` | End cooking session |

**Example Payload (start_cooking):**
```json
{
  "recipe_id": "789",
  "servings": 4
}
```

#### Outgoing Events

| Event | Payload | Description |
|-------|---------|-------------|
| `cooking_started` | `{"session_id": "uuid", "recipe": {...}, "steps": [...]}` | Cooking session initialized |
| `step_update` | `{"current_step": number, "total_steps": number}` | Current step changed |
| `step_complete` | `{"step_index": number, "next_step": {...}}` | Step marked complete |
| `timer_tick` | `{"timer_id": "uuid", "remaining_seconds": number}` | Timer countdown update |
| `timer_done` | `{"timer_id": "uuid", "label": "string"}` | Timer finished |
| `scaled_ingredients` | `{"original_servings": number, "new_servings": number, "ingredients": [...]}` | Ingredients rescaled |
| `cooking_complete` | `{"session_id": "uuid", "duration_minutes": number}` | Cooking session ended |

**Example Response (timer_done):**
```json
{
  "timer_id": "550e8400-e29b-41d4-a716-446655440003",
  "label": "Boil pasta",
  "remaining_seconds": 0,
  "next_action": "drain_pasta"
}
```

---

## Reconnection Strategy

Implement exponential backoff with jitter for WebSocket reconnection:

```javascript
class MealPlannerSocket {
  constructor(url, params) {
    this.url = url;
    this.params = params;
    this.reconnectAttempts = 0;
    this.maxReconnectAttempts = 10;
    this.socket = null;
  }

  connect() {
    this.socket = new Socket(this.url, { params: this.params });

    this.socket.onError(() => this.handleError());
    this.socket.onClose(() => this.handleClose());

    this.socket.connect();
  }

  handleError() {
    console.error("Socket connection error");
  }

  handleClose() {
    if (this.reconnectAttempts < this.maxReconnectAttempts) {
      const delay = this.calculateBackoff();
      console.log(`Reconnecting in ${delay}ms...`);

      setTimeout(() => {
        this.reconnectAttempts++;
        this.refreshToken().then(token => {
          this.params.token = token;
          this.connect();
        });
      }, delay);
    } else {
      console.error("Max reconnection attempts reached");
    }
  }

  calculateBackoff() {
    // Exponential backoff with jitter: base * 2^attempt + random(0-1000)
    const base = 1000;
    const maxDelay = 30000;
    const exponentialDelay = Math.min(base * Math.pow(2, this.reconnectAttempts), maxDelay);
    const jitter = Math.random() * 1000;
    return exponentialDelay + jitter;
  }

  async refreshToken() {
    // Fetch a new JWT from your auth endpoint
    const response = await fetch("/api/auth/refresh", {
      method: "POST",
      credentials: "include"
    });
    const { token } = await response.json();
    return token;
  }
}
```

---

## Error Handling

The planning channel's own reply reasons are listed under "Errors and refusals" in the
`planning:*` section.

| Error Code | HTTP Status | Description | Recovery Action |
|-----------|-------------|-------------|----------------|
| `auth_required` | 401 | No valid token provided | Redirect to login |
| `token_expired` | 401 | JWT has expired | Refresh token, reconnect |
| `channel_not_found` | 404 | Invalid topic pattern | Verify topic format |
| `rate_limited` | 429 | Too many requests | Apply backoff, retry |
| `server_error` | 500 | Internal server error | Log error, notify user |
| `channel_closed` | - | Server closed the channel | Auto-reconnect |

---

## Best Practices

1. **Subscribe lazily**: Only join channels when needed, leave when done
2. **Handle disconnections**: Implement reconnection with exponential backoff
3. **Batch updates**: For bulk operations, use batch events to reduce overhead
4. **Timeout handling**: Set reasonable timeouts for requests expecting responses
5. **Presence tracking**: Use Phoenix Presence for showing active users in cooking mode
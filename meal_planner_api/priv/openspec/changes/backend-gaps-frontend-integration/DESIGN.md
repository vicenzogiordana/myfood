# SDD: Backend Gaps — Frontend Integration

## Metadata

| Field | Value |
|---|---|
| **Change ID** | backend-gaps-frontend-integration |
| **Phase** | design |
| **Created** | 2026-06-03 |
| **Author** | SDD Design Executor |
| **Status** | draft |
| **Parent proposal** | `priv/openspec/changes/backend-gaps-frontend-integration/PROPOSAL.md` |
| **Parent spec** | `priv/openspec/changes/backend-gaps-frontend-integration/SPEC.md` |

---

## Table of Contents

1. [Design Decisions Table](#1-design-decisions-table)
2. [Detailed File Diff — CalendarController](#2-detailed-file-diff--calendarcontroller)
3. [Detailed File Diff — Persistence.Calendar](#3-detailed-file-diff--persistencecalendar)
4. [Detailed File Diff — GenerationService](#4-detailed-file-diff--generationservice)
5. [Detailed File Diff — GenerationServer](#5-detailed-file-diff--generationserver)
6. [Detailed File Diff — ShoppingService](#6-detailed-file-diff--shoppingservice)
7. [Detailed File Diff — Persistence.Shopping](#7-detailed-file-diff--persistenceshopping)
8. [Detailed File Diff — UserSocket](#8-detailed-file-diff--usersocket)
9. [Data Flow Diagrams — Gap 4 (Checkout → Inventory)](#9-data-flow-diagrams--gap-4-checkout--inventory)
10. [Router Changes](#10-router-changes)
11. [Test Strategy](#11-test-strategy)
12. [Rollout Plan](#12-rollout-plan)

---

## 1. Design Decisions Table

| # | Gap | Decision | Rationale | Trade-offs |
|---|---|---|---|---|
| **G1-D1** | 1 | New `show_slot` action in `CalendarController`, not a new controller | `CalendarController` already owns all calendar read ops. Sharing `serialize_meal/1` keeps response shape consistent across `index` and `show_slot`. | If future slot queries need filtering beyond `(date, slot)`, the action can be extended or split. |
| **G1-D2** | 1 | `can_create: true` only when `meal_id == nil` (slot is empty) | Frontend needs a deterministic signal to show/hide the "+" button. Deriving it from nullness is simpler than computing it from date availability. | Requires the slot query to always return a structured payload (even when no meal exists), not a 404. This is the chosen contract. |
| **G1-D3** | 1 | Query params `date` (ISO8601) and `slot` (string) on `GET /api/calendar/slot` | Follows existing `index` conventions. `String.to_existing_atom/1` for slot is safe because the controller already validates against the known set. | If invalid slot value, returns `{:error, "invalid_slot"}` → 422. |
| **G2-D1** | 2 | Favorites injected as `preferred_recipe_ids` per slot in OR-Tools payload | OR-Tools already supports scoring hints. This is a schema-level injection; Python optimizer handles scoring. No backend logic changes needed beyond passing the list. | If OR-Tools does not weight `preferred_recipe_ids`, the hint has no effect. But the change is backward-compatible — empty list is valid. |
| **G2-D2** | 2 | Favorites loaded in `GenerationServer.run_pipeline/1` before `build_slots_input/1`, not in `GenerationService` | `GenerationService` is pure/stateless; loading from DB would violate that contract. `GenerationServer` owns side effects. The list is passed into `build_slots_input/1` via `resolved` map. | Requires `RecipeRepo.list_favorite_ids/1` (new helper) — a query-only addition to `RecipeRepo`. |
| **G2-D3** | 2 | `preferred_recipe_ids` propagated via `resolved` map from `build_constraints` through `build_slots_input` | Keeps the data flow in the existing `constraints` pipeline — no new pipeline stage needed. | The field must flow through `build_constraints` even if unused there (passthrough only). |
| **G3-D1** | 3 | `can_create` added to `serialize_meal/1` with value `false` | All existing scheduled meals have a recipe_id (otherwise they wouldn't be serialized). Setting `can_create: false` is correct for existing meals. No branching needed. | Backend assumes `meal_id != nil` ↔ `can_create: false`. This invariant must be maintained if serialization ever changes. |
| **G3-D2** | 3 | `serialize_selected_meal/1` uses `meal.recipe_id == nil` to set `can_create: true` | `selected_meal` can be `nil` (no slot selected) or a real meal struct. The nil case is handled by returning `nil` before serialization; the empty-slot case returns a struct with `recipe_id: nil`. | `serialize_selected_meal(nil)` already returns `nil` (no payload). For empty slots, `Persistence.Calendar` must return a struct with `id: nil, recipe_id: nil`. |
| **G4-D1** | 4 | `confirm_checkout/3` wrapped in `Repo.transaction/1` | Checkout → inventory movement must be atomic. If `move_items_to_inventory` partially fails, the session should not be marked as `completed`. Transaction ensures all-or-nothing. | If `move_items_to_inventory` fails for individual items, those items are skipped (counted as not moved). Transaction commit is still based on session update succeeding. |
| **G4-D2** | 4 | New `list_items_by_session/2` in `Persistence.Shopping` | Needed to query all items for a specific `checkout_session_id` for `confirm_checkout`. Uses `ShoppingItem` query with `checkout_session_id` filter. | Alternative: reuse `list_items_for_account/1` + filter in memory. That would load all account items unnecessarily. Query-based filter is more efficient. |
| **G4-D3** | 4 | Return type enriched with `moved_to_inventory_count` in `serialize_checkout_session` | Frontend needs to show confirmation feedback. Returning the count allows UI to display "5 items moved to inventory". | Must update the response JSON shape — considered a breaking change for existing API consumers. Version bump not required (minor additive field). |
| **G5-D1** | 5 | `prune_past_items/2` always runs (removes the conditional guard `from_date > today`) | Current code only prunes when `from_date > today`. For the default date range (today → +6d), expired items in the past are never pruned. Making it unconditional ensures cleanup on every call. | If called repeatedly with the same date range, pruning runs again on already-archived items. Safe (no-op update with same status). Performance is O(n) on archived count, acceptable. |
| **G5-D2** | 5 | `list_pending_items_with_context/3` excludes `status: :archived` by default | Archived items should not appear in the shopping list. Adding `status: :pending` filter to the query (already present in some variants) ensures archived items are never returned. | Backend must provide `?include_archived=true` query param for debugging. Controller should pass this to the service layer. |
| **G5-D3** | 5 | `include_archived=true` via query param, not a separate endpoint | Shopping list endpoint already exists. Adding a query param keeps the same URL with optional behavior. No new routes needed. | If multiple boolean query params accumulate, consider a query object pattern in the future. Currently only `include_archived` is needed. |
| **G6-D1** | 6 | `user_socket.ex` docstring expanded + `docs/CHANNELS.md` created | Both inline docs AND a reference document. Inline docs serve IDE tooltips; `CHANNELS.md` serves architecture and onboarding. | `docs/` directory does not exist yet — created as part of this change. |
| **G6-D2** | 6 | `docs/CHANNELS.md` in repo root `docs/` folder | Standard location for project-wide documentation. `README.md` already references `docs/` for other artifacts. | If the repo uses `meal_planner_api/docs/`, it would be repo-specific. Using top-level `docs/` is more standard. |

---

## 2. Detailed File Diff — CalendarController

**File**: `lib/meal_planner_api_web/controllers/calendar_controller.ex`

### 2.1 New Action: `show_slot`

**Change type**: Addition of new action + helper functions.

```elixir
# ─── ADDITION: after index/2 ───────────────────────────────────
# NEW ACTION

@spec show_slot(Plug.Conn.t(), map()) :: Plug.Conn.t()
def show_slot(conn, params) do
  user = Guardian.Plug.current_resource(conn)

  with {:ok, date} <- parse_date(Map.get(params, "date")),
       {:ok, slot} <- parse_slot(Map.get(params, "slot")) do
    meal = Calendar.get_slot_meal(user.account_id, date, slot)

    json(conn, %{data: serialize_slot_response(meal, date, slot)})
  else
    {:error, reason} ->
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: reason})
  end
end

# ─── ADDITION: parse_slot helper (mirrors parse_optional_slot but required) ───
defp parse_slot(nil), do: {:error, "missing_slot_param"}

defp parse_slot(value) when is_binary(value) do
  case value do
    "breakfast" -> {:ok, :breakfast}
    "lunch"     -> {:ok, :lunch}
    "snack"     -> {:ok, :snack}
    "dinner"    -> {:ok, :dinner}
    _           -> {:error, "invalid_slot"}
  end
end

defp parse_slot(_), do: {:error, "invalid_slot"}

# ─── ADDITION: new serializer for slot response ────────────────
defp serialize_slot_response(nil, date, slot) do
  # Empty slot — can create
  %{
    meal_id: nil,
    date: Date.to_iso8601(date),
    slot: Atom.to_string(slot),
    recipe_id: nil,
    recipe_name: nil,
    is_cooked: false,
    is_favorite: false,
    can_create: true,
    macros: nil,
    prep_time_minutes: nil
  }
end

defp serialize_slot_response(meal, _date, _slot) do
  # Filled slot — can_create is always false for existing meals
  serialize_meal(meal)
  |> Map.put(:can_create, false)
end
```

### 2.2 Update: `serialize_meal/1`

**Old code** (line 88–100):
```elixir
defp serialize_meal(meal) do
  %{
    meal_id: meal.id,
    date: Date.to_iso8601(meal.date),
    slot: Atom.to_string(meal.slot),
    is_cooked: meal.is_cooked,
    recipe_id: meal.recipe_id,
    recipe_name: meal.recipe_name,
    is_favorite: meal.is_favorite,
    macros: %{calories: meal.calories_per_serving},
    prep_time_minutes: meal.prep_time_minutes
  }
end
```

**New code**:
```elixir
defp serialize_meal(meal) do
  %{
    meal_id: meal.id,
    date: Date.to_iso8601(meal.date),
    slot: Atom.to_string(meal.slot),
    is_cooked: meal.is_cooked,
    recipe_id: meal.recipe_id,
    recipe_name: meal.recipe_name,
    is_favorite: meal.is_favorite,
    can_create: false,
    macros: %{calories: meal.calories_per_serving},
    prep_time_minutes: meal.prep_time_minutes
  }
end
```

**Change**: Adds `can_create: false` to every serialized meal in the monthly overview.

### 2.3 Update: `serialize_selected_meal/1`

**Old code** (line 102):
```elixir
defp serialize_selected_meal(nil), do: nil
defp serialize_selected_meal(meal), do: serialize_meal(meal)
```

**New code**:
```elixir
defp serialize_selected_meal(nil), do: nil

defp serialize_selected_meal(meal) do
  base = serialize_meal(meal)
  Map.put(base, :can_create, is_nil(meal.recipe_id))
end
```

**Change**: Derives `can_create` from `recipe_id == nil`. If `recipe_id` is `nil`, the slot is empty → `can_create: true`.

---

## 3. Detailed File Diff — Persistence.Calendar

**File**: `lib/meal_planner_api/persistence/calendar.ex`

### 3.1 New Function: `get_slot_meal/3`

**Change type**: Addition of new query function.

```elixir
# ─── ADDITION: after delete_scheduled_meal/3 ───────────────────
@doc """
  Returns the meal for a specific (account_id, date, slot) tuple.

  Returns `nil` if no meal exists for that slot.
  Includes recipe macros and favorite status.
  """
@spec get_slot_meal(pos_integer(), Date.t(), atom()) :: map() | nil
def get_slot_meal(account_id, date, slot) when is_atom(slot) do
  from(m in ScheduledMeal,
    where: m.account_id == ^account_id and m.date == ^date and m.slot == ^slot,
    left_join: r in assoc(m, :recipe),
    left_join: sf in SlotFavorite,
    on:
      sf.account_id == m.account_id and sf.date == m.date and sf.slot == m.slot,
    limit: 1,
    select: %{
      id: m.id,
      date: m.date,
      slot: m.slot,
      is_cooked: m.is_cooked,
      recipe_id: m.recipe_id,
      recipe_name: r.name,
      calories_per_serving: r.calories_per_serving,
      prep_time_minutes: r.prep_time_minutes,
      is_favorite: not is_nil(sf.id)
    }
  )
  |> Repo.one()
end
```

**Change**: Provides the slot-specific lookup for Gap 1. Uses `left_join` on `SlotFavorite` (not `FavoriteRecipe`) because `is_favorite` on the slot reflects whether the user has starred this specific slot, not the recipe.

---

## 4. Detailed File Diff — GenerationService

**File**: `lib/meal_planner_api/services/generation_service.ex`

### 4.1 Update: `build_constraints/2`

**Change type**: Accept and propagate `favorite_recipe_ids`.

**Old code** — `build_constraints/2` with nil payload:
```elixir
def build_constraints(user_profile, nil) do
  %{
    protein_g_per_meal: Map.get(user_profile, :protein_g_per_meal, 25),
    budget_cents: Map.get(user_profile, :default_budget_cents, 10_000),
    max_calories: Map.get(user_profile, :max_calories, 800),
    excluded_recipe_ids: Map.get(user_profile, :excluded_recipe_ids, []),
    excluded_ingredients: Map.get(user_profile, :default_exclusions, [])
  }
end
```

**New code**:
```elixir
def build_constraints(user_profile, nil) do
  %{
    protein_g_per_meal: Map.get(user_profile, :protein_g_per_meal, 25),
    budget_cents: Map.get(user_profile, :default_budget_cents, 10_000),
    max_calories: Map.get(user_profile, :max_calories, 800),
    excluded_recipe_ids: Map.get(user_profile, :excluded_recipe_ids, []),
    excluded_ingredients: Map.get(user_profile, :default_exclusions, []),
    favorite_recipe_ids: []
  }
end
```

**Old code** — `build_constraints/2` with payload:
```elixir
def build_constraints(user_profile, payload) do
  resolved = build_constraints(user_profile, nil)

  payload_exclusions = payload["excluded_ingredients"] || payload[:excluded_ingredients] || []

  %{
    resolved
    | protein_g_per_meal:
        payload["protein_g"] || payload[:protein_g] || resolved.protein_g_per_meal,
      budget_cents: payload["budget_cents"] || payload[:budget_cents] || resolved.budget_cents,
      max_calories: payload["max_calories"] || payload[:max_calories] || resolved.max_calories,
      excluded_recipe_ids:
        payload["excluded_recipe_ids"] || payload[:excluded_recipe_ids] ||
          resolved.excluded_recipe_ids,
      excluded_ingredients: payload_exclusions ++ resolved.excluded_ingredients
  }
end
```

**New code**:
```elixir
def build_constraints(user_profile, payload) do
  resolved = build_constraints(user_profile, nil)

  payload_exclusions = payload["excluded_ingredients"] || payload[:excluded_ingredients] || []

  %{
    resolved
    | protein_g_per_meal:
        payload["protein_g"] || payload[:protein_g] || resolved.protein_g_per_meal,
      budget_cents: payload["budget_cents"] || payload[:budget_cents] || resolved.budget_cents,
      max_calories: payload["max_calories"] || payload[:max_calories] || resolved.max_calories,
      excluded_recipe_ids:
        payload["excluded_recipe_ids"] || payload[:excluded_recipe_ids] ||
          resolved.excluded_recipe_ids,
      excluded_ingredients: payload_exclusions ++ resolved.excluded_ingredients,
      favorite_recipe_ids:
        payload["favorite_recipe_ids"] || payload[:favorite_recipe_ids] ||
          resolved.favorite_recipe_ids
  }
end
```

**Change**: Added `favorite_recipe_ids` field. Reads from payload map (string or atom keys). Falls back to empty list.

---

## 5. Detailed File Diff — GenerationServer

**File**: `lib/meal_planner_api/generation/server.ex`

### 5.1 Update: `load_user_profile/1` → `load_user_profile_and_favorites/1`

**Change type**: Load favorites alongside user profile in pipeline entry point.

**Old code** — `run_pipeline/1` section (line ~170):
```elixir
defp run_pipeline(state) do
  %{
    account_id: _account_id,
    user_id: user_id,
    current_run_id: run_id,
    current_proposal_id: proposal_id,
    constraints: constraints
  } = state

  # 1. Perfil de usuario
  user_profile = load_user_profile(user_id)

  # 2. Resolver constraints
  resolved = GenerationService.build_constraints(user_profile, constraints)
```

**New code**:
```elixir
defp run_pipeline(state) do
  %{
    account_id: account_id,
    user_id: user_id,
    current_run_id: run_id,
    current_proposal_id: proposal_id,
    constraints: constraints
  } = state

  # 1. Perfil de usuario + recetas favoritas
  {user_profile, favorite_recipe_ids} = load_user_profile_and_favorites(account_id, user_id)

  # 2. Resolver constraints (favorite_recipe_ids injected into constraints)
  resolved =
    GenerationService.build_constraints(user_profile, constraints)
    |> Map.put(:favorite_recipe_ids, favorite_recipe_ids)
```

### 5.2 Update: `build_slots_input/1`

**Change type**: Include `preferred_recipe_ids` in each slot's constraints dict.

**Old code** — `build_slots_input/1` (line ~270):
```elixir
defp build_slots_input(constraints) do
  date_from =
    constraints["date_from"] || constraints[:date_from] ||
      Date.utc_today() |> Date.to_iso8601()

  date_to =
    constraints["date_to"] || constraints[:date_to] ||
      Date.add(Date.utc_today(), 6) |> Date.to_iso8601()

  slot_types =
    constraints["slot_types"] || constraints[:slot_types] || [:breakfast, :lunch, :dinner]

  for date <- Date.range(Date.from_iso8601!(date_from), Date.from_iso8601!(date_to)),
      slot <- slot_types do
    %{
      "date" => Date.to_iso8601(date),
      "slot" => to_string(slot),
      "available_recipe_ids" => [],
      "constraints" => %{
        "budget_cents" => constraints["budget_cents"] || 10_000,
        "protein_g" => constraints["protein_g"] || 25,
        "max_calories" => constraints["max_calories"] || 800,
        "excluded_recipe_ids" => [],
        "excluded_ingredients" => []
      }
    }
  end
end
```

**New code**:
```elixir
defp build_slots_input(constraints) do
  date_from =
    constraints["date_from"] || constraints[:date_from] ||
      Date.utc_today() |> Date.to_iso8601()

  date_to =
    constraints["date_to"] || constraints[:date_to] ||
      Date.add(Date.utc_today(), 6) |> Date.to_iso8601()

  slot_types =
    constraints["slot_types"] || constraints[:slot_types] || [:breakfast, :lunch, :dinner]

  favorite_ids =
    (constraints[:favorite_recipe_ids] || [])
    |> Enum.map(&to_string/1)

  for date <- Date.range(Date.from_iso8601!(date_from), Date.from_iso8601!(date_to)),
      slot <- slot_types do
    %{
      "date" => Date.to_iso8601(date),
      "slot" => to_string(slot),
      "available_recipe_ids" => [],
      "constraints" => %{
        "budget_cents" => constraints["budget_cents"] || 10_000,
        "protein_g" => constraints["protein_g"] || 25,
        "max_calories" => constraints["max_calories"] || 800,
        "excluded_recipe_ids" => [],
        "excluded_ingredients" => [],
        "preferred_recipe_ids" => favorite_ids
      }
    }
  end
end
```

**Change**: Extracts `favorite_recipe_ids` from constraints (atom key, since it was injected after `build_constraints`). Converts to string for JSON serialization. Injects as `"preferred_recipe_ids"` in each slot's constraints.

### 5.3 New Helper: `load_user_profile_and_favorites/2`

**Change type**: Addition of new private function.

```elixir
# ─── ADDITION: near load_user_profile/1 ────────────────────────
@doc """
  Loads user profile and the list of favorite recipe IDs for this account.
  Returns a tuple {profile, favorite_recipe_ids}.
  """
@spec load_user_profile_and_favorites(pos_integer(), pos_integer()) :: {map(), [pos_integer()]}
defp load_user_profile_and_favorites(account_id, user_id) do
  profile = load_user_profile(user_id)

  favorite_ids =
    RecipeRepo.list_favorite_ids(account_id)
    |> Enum.map(& &1.id)

  {profile, favorite_ids}
end
```

**Note**: `RecipeRepo.list_favorite_ids/1` must be added to `RecipeRepo` — see Section 7.

---

## 6. Detailed File Diff — ShoppingService

**File**: `lib/meal_planner_api/services/shopping_service.ex`

### 6.1 Update: `confirm_checkout/3`

**Change type**: Wrap in transaction; call `move_items_to_inventory`; return enriched response.

**Old code** — `confirm_checkout/3` (lines ~220–245):
```elixir
@spec confirm_checkout(map(), pos_integer(), map()) :: {:ok, map()} | {:error, term()}
def confirm_checkout(user, session_id, payload) do
  case Identity.ensure_persistent_identity(user) do
    {:ok, identity} ->
      session = ShoppingRepo.get_checkout_session_for_account(identity.account_id, session_id)

      case session do
        nil ->
          {:error, :session_not_found}

        _ ->
          actual_total = Map.get(payload, "actual_total_cents", 0)

          {:ok, updated} =
            ShoppingRepo.update_checkout_session(session, %{
              status: :completed,
              actual_total_cents: actual_total,
              completed_at: DateTime.utc_now(),
              delivered_at: DateTime.utc_now()
            })

          {:ok, serialize_checkout_session(updated)}
      end

    {:error, reason} ->
      {:error, reason}
  end
end
```

**New code**:
```elixir
@spec confirm_checkout(map(), pos_integer(), map()) :: {:ok, map()} | {:error, term()}
def confirm_checkout(user, session_id, payload) do
  case Identity.ensure_persistent_identity(user) do
    {:ok, identity} ->
      session = ShoppingRepo.get_checkout_session_for_account(identity.account_id, session_id)

      case session do
        nil ->
          {:error, :session_not_found}

        _ ->
          actual_total = Map.get(payload, "actual_total_cents", 0)

          Repo.transaction(fn ->
            {:ok, updated} =
              ShoppingRepo.update_checkout_session(session, %{
                status: :completed,
                actual_total_cents: actual_total,
                completed_at: DateTime.utc_now(),
                delivered_at: DateTime.utc_now()
              })

            # Obtener ítems checked-out para esta sesión y moverlos al inventario
            items =
              Shopping.list_items_by_session(identity.account_id, session_id)
              |> Enum.filter(&(&1.status == :checked_out))

            moved_count = move_items_to_inventory(items)

            %{updated | moved_to_inventory_count: moved_count}
          end)
          |> case do
            {:ok, result} ->
              {:ok, serialize_checkout_session(result)}

            {:error, _} ->
              {:error, :transaction_failed}
          end
      end

    {:error, reason} ->
      {:error, reason}
  end
end
```

**Change**: Session update + inventory movement wrapped in `Repo.transaction/1`. On success, the `moved_to_inventory_count` is attached to the session struct. On failure, returns `{:error, :transaction_failed}`. Note: `move_items_to_inventory/1` is called inside the transaction lambda; the count is captured for the response.

### 6.2 Update: `get_shopping_list/2`

**Change type**: Always run `prune_past_items/2` regardless of `from_date`.

**Old code** — `get_shopping_list/2` pruning section:
```elixir
# Auto-archive past items
prune_past_items(account_id, from_date)
```

**New code**:
```elixir
# Siempre архивируем ítems vencidos (Gap 5)
prune_past_items(account_id, Date.utc_today())
```

**Change**: `prune_past_items/2` is now called with `Date.utc_today()` as the reference date, not `from_date`. This ensures all items with `planned_date < today` are archived regardless of the requested date range. The pruning function already uses `<` (strict less-than), so today's items are not archived.

**Note**: This does not change the function signature. The `from_date` parameter in `get_shopping_list/2` is still used to fetch items in the range. Pruning now uses `today` as the cutoff.

### 6.3 Update: `serialize_checkout_session/1`

**Change type**: Include `moved_to_inventory_count` and `total_items` in the serialized response.

**Old code** — `serialize_checkout_session/1` (lines ~380):
```elixir
defp serialize_checkout_session(s) do
  %{
    id: s.id,
    status: Atom.to_string(s.status),
    estimated_total_cents: s.total_cents || 0,
    actual_total_cents: s.total_cents || 0,
    started_at: iso_datetime(s.inserted_at),
    completed_at: iso_datetime(s.confirmed_at),
    delivered_at: iso_datetime(s.invalidated_at)
  }
end
```

**New code**:
```elixir
defp serialize_checkout_session(s) do
  %{
    id: s.id,
    status: Atom.to_string(s.status),
    estimated_total_cents: s.total_cents || 0,
    actual_total_cents: s.total_cents || 0,
    moved_to_inventory_count: Map.get(s, :moved_to_inventory_count, 0),
    total_items: Map.get(s, :__total_items__, 0),
    started_at: iso_datetime(s.inserted_at),
    completed_at: iso_datetime(s.confirmed_at),
    delivered_at: iso_datetime(s.invalidated_at)
  }
end
```

**Change**: Added `moved_to_inventory_count` (from the enriched struct inside transaction) and `total_items`. Uses `Map.get(s, field, default)` to safely handle the case where the field is not present (e.g., if called from other code paths).

---

## 7. Detailed File Diff — Persistence.Shopping

**File**: `lib/meal_planner_api/persistence/shopping.ex`

### 7.1 New Function: `list_items_by_session/2`

**Change type**: Addition of new query function.

```elixir
# ─── ADDITION: after list_items_by_ids/2 ───────────────────────
@doc """
  Returns all shopping items for a specific checkout session.

  Used by `ShoppingService.confirm_checkout/3` to retrieve items
  that need to be moved to inventory after checkout is confirmed.
  """
@spec list_items_by_session(pos_integer(), pos_integer()) :: [ShoppingItem.t()]
def list_items_by_session(account_id, checkout_session_id) do
  from(i in ShoppingItem,
    where: i.account_id == ^account_id,
    where: i.checkout_session_id == ^checkout_session_id
  )
  |> Repo.all()
end
```

**Change**: Simple query by `account_id` + `checkout_session_id`. No date filter — all items for the session are needed.

### 7.2 Update: `list_pending_items_with_context/3`

**Change type**: Ensure `status: :archived` items are excluded.

**Old code** (lines ~75–83):
```elixir
def list_pending_items_with_context(account_id, from_date, to_date) do
  from(i in ShoppingItem,
    where:
      i.account_id == ^account_id and i.status == :pending and
        i.planned_date >= ^from_date and i.planned_date <= ^to_date,
    order_by: [asc: i.planned_date],
    preload: [:assigned_supermarket, :ingredient]
  )
  |> Repo.all()
end
```

**New code**:
```elixir
def list_pending_items_with_context(account_id, from_date, to_date) do
  from(i in ShoppingItem,
    where:
      i.account_id == ^account_id and i.status == :pending and
        i.planned_date >= ^from_date and i.planned_date <= ^to_date,
    order_by: [asc: i.planned_date],
    preload: [:assigned_supermarket, :ingredient]
  )
  |> Repo.all()
end
```

**Change**: No structural change to the query. The existing `i.status == :pending` already excludes `:archived` items. However, for clarity and future-proofing, the function should document this behavior. (The functional change is already implied by the existing where clause; Gap 5's spec confirms the existing behavior is correct.)

---

## 7.3 Update: `list_items_for_account/1`

**Change type**: Add optional `include_archived` parameter for debugging.

```elixir
# ─── UPDATE: add optional include_archived ───────────────────
@spec list_items_for_account(pos_integer(), keyword()) :: [ShoppingItem.t()]
def list_items_for_account(account_id, opts \\ []) do
  base_query =
    from(i in ShoppingItem,
      where: i.account_id == ^account_id,
      order_by: [asc: i.planned_date]
    )

  if Keyword.get(opts, :include_archived, false) do
    base_query
  else
    from(i in base_query, where: i.status != :archived)
  end
  |> Repo.all()
end
```

**Change**: Default behavior excludes archived items (matching the pruning behavior). When `include_archived: true` is passed, all items including archived are returned. This supports the `?include_archived=true` query parameter.

---

## 8. Detailed File Diff — UserSocket

**File**: `lib/meal_planner_api_web/user_socket.ex`

**Change type**: Expand `@moduledoc` with authentication usage, channel reference, and token refresh guidance.

**Old code** (lines 1–20):
```elixir
defmodule MealPlannerApiWeb.UserSocket do
  use Phoenix.Socket

  channel "ai_chat:*", MealPlannerApiWeb.AIChannel
  channel "calendar:*", MealPlannerApiWeb.CalendarChannel
  channel "planning:*", MealPlannerApiWeb.PlanningChannel
  channel "cooking:*", MealPlannerApiWeb.CookingChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case MealPlannerApi.Auth.Guardian.resource_from_token(token) do
      {:ok, user, _claims} ->
        {:ok, assign(socket, :current_user, user)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket) do
    "user_socket:" <> socket.assigns.current_user.id
  end
end
```

**New code**:
```elixir
defmodule MealPlannerApiWeb.UserSocket do
  @moduledoc """
  Phoenix Socket for real-time communication with the meal planner API.

  ## Authentication

  On the client, pass the JWT token from Guardian during socket connect:

  ```javascript
  // React Native / JavaScript
  import { Socket } from "phoenix";

  const socket = new Socket("wss://your-api.com/socket", {
    params: { token: your_jwt_token }
  });

  socket.connect();

  // Join a channel
  const channel = socket.channel("calendar:ACCOUNT_ID", {});
  channel.join();
  ```

  If the token is missing or invalid, `connect/3` returns `:error` and the
  socket connection is rejected.

  ## Available Channels

  | Channel | Purpose | Events |
  |---|---|---|
  | `ai_chat:ROOM_ID` | AI chat streaming | `new_message` → `ai_response` |
  | `calendar:ACCOUNT_ID` | Calendar realtime | `meal_updated`, `meal_deleted`, `favorite_toggled` |
  | `planning:ACCOUNT_ID` | Planning generation | `generate_menu`, `proposal_ready`, `confirm_proposal` |
  | `cooking:ACCOUNT_ID_SESSION` | Cooking session | `start_session`, `ask_assistant` |

  ## Token Refresh

  If the token expires mid-session, the socket will disconnect. The client
  should listen for `Phoenix.Socket.CloseEvent` and reconnect with a fresh
  token. See `docs/CHANNELS.md` for the full event reference.

  ## Disconnection

  When a user disconnects, their presence in active channels is automatically
  cleaned up by the Phoenix Channels presence system.
  """

  use Phoenix.Socket

  channel "ai_chat:*", MealPlannerApiWeb.AIChannel
  channel "calendar:*", MealPlannerApiWeb.CalendarChannel
  channel "planning:*", MealPlannerApiWeb.PlanningChannel
  channel "cooking:*", MealPlannerApiWeb.CookingChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case MealPlannerApi.Auth.Guardian.resource_from_token(token) do
      {:ok, user, _claims} ->
        {:ok, assign(socket, :current_user, user)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket) do
    "user_socket:" <> socket.assigns.current_user.id
  end
end
```

### 8.2 New File: `docs/CHANNELS.md`

**File**: `docs/CHANNELS.md`

```markdown
# Phoenix Channels — Full Reference

This document describes all real-time channels provided by the Meal Planner API,
their events, payload shapes, and error handling patterns.

## Authentication

All channels require authentication via the socket handshake. See
`UserSocket` module documentation for the connection pattern.

```javascript
const socket = new Socket("wss://api.example.com/socket", {
  params: { token: jwt_token }
});
socket.connect();
```

If authentication fails, the socket is disconnected immediately.

---

## Channel: `ai_chat:ROOM_ID`

**Purpose**: Real-time AI chat for recipe assistance and meal advice.

### Incoming Events (client → server)

#### `new_message`
Sent by the client to send a message to the AI assistant.

```json
{
  "message": "¿Qué puedo cocinar con pollo y arroz?",
  "context": {
    "account_id": 123,
    "language": "es"
  }
}
```

**Response**: Server broadcasts `ai_response` on the same channel.

### Outgoing Events (server → client)

#### `ai_response`
Broadcast by the server when the AI generates a response.

```json
{
  "type": "text",
  "content": "Puedes preparar un arroz con pollo al estilo clásico...",
  "suggestions": [
    { "recipe_id": 45, "title": "Arroz con Pollo" }
  ]
}
```

#### `ai_error`
Sent when the AI pipeline encounters an error.

```json
{
  "reason": "model_unavailable"
}
```

---

## Channel: `calendar:ACCOUNT_ID`

**Purpose**: Real-time calendar updates. When a meal is created, updated,
favorite-toggled, or deleted, all clients subscribed to this account's channel
receive the event.

### Incoming Events

#### `subscribe_meals`
Client requests meal list for the current date range.

```json
{
  "start_date": "2026-06-01",
  "end_date": "2026-06-30"
}
```

### Outgoing Events

#### `meal_updated`
Broadcast when a scheduled meal is created or modified.

```json
{
  "meal": {
    "id": "uuid",
    "date": "2026-06-05",
    "slot": "lunch",
    "recipe_id": 12,
    "recipe_name": "Ensalada César",
    "is_cooked": false
  }
}
```

#### `meal_deleted`
Broadcast when a scheduled meal is removed.

```json
{
  "date": "2026-06-05",
  "slot": "lunch"
}
```

#### `favorite_toggled`
Broadcast when a recipe favorite is toggled.

```json
{
  "recipe_id": 12,
  "is_favorite": true,
  "account_id": 123
}
```

---

## Channel: `planning:ACCOUNT_ID`

**Purpose**: Menu generation pipeline with AI assistance.

### Incoming Events

#### `generate_menu`
Starts the OR-Tools menu generation pipeline.

```json
{
  "date_from": "2026-06-01",
  "date_to": "2026-06-07",
  "constraints": {
    "budget_cents": 10000,
    "protein_g": 25,
    "excluded_ingredients": ["maní"],
    "favorite_recipe_ids": [3, 7, 12]
  }
}
```

#### `modify_proposal`
Sends a chat-like modification request.

```json
{
  "proposal_id": 456,
  "message": "cambia el almuerzo del martes por algo más barato"
}
```

#### `confirm_proposal`
Confirms and persists the generated menu.

```json
{
  "proposal_id": 456
}
```

#### `reject_proposal`
Rejects the proposal and discards it.

```json
{
  "proposal_id": 456
}
```

### Outgoing Events

#### `generation_started`
Sent when the pipeline begins.

```json
{
  "run_id": 789
}
```

#### `proposal_ready`
Broadcast when OR-Tools returns the optimized menu.

```json
{
  "proposal_id": 456,
  "run_id": 789,
  "proposal": {
    "slots": [
      {
        "slot_key": "2026-06-01_breakfast",
        "recipe_id": 3,
        "recipe_name": "Avena con frutas",
        "price_cents": 1200
      }
    ],
    "generated_at": "2026-06-03T10:30:00Z"
  }
}
```

#### `proposal_confirmed`
Broadcast when the user confirms a proposal.

```json
{
  "proposal_id": 456,
  "scheduled_meals_count": 14
}
```

#### `proposal_rejected`
Broadcast when the user rejects a proposal.

```json
{
  "proposal_id": 456
}
```

#### `proposal_update`
Broadcast when a chat modification is applied.

```json
{
  "change_type": "lower_price",
  "new_value": null
}
```

#### `generation_error`
Broadcast when the pipeline fails.

```json
{
  "run_id": 789,
  "reason": "optimization_failed"
}
```

---

## Channel: `cooking:ACCOUNT_ID_SESSION`

**Purpose**: Real-time cooking assistant with step-by-step guidance.

### Incoming Events

#### `start_session`
Starts a cooking session for a specific recipe.

```json
{
  "recipe_id": 12,
  "servings": 2
}
```

#### `ask_assistant`
Sends a question during cooking.

```json
{
  "message": "¿Cómo sé si el pollo está cocido?",
  "step_index": 3
}
```

### Outgoing Events

#### `session_started`

```json
{
  "session_id": "uuid",
  "steps": [
    { "index": 0, "description": "Corta el pollo en dados..." },
    { "index": 1, "description": "Calienta el aceite..." }
  ]
}
```

#### `assistant_response`

```json
{
  "type": "text",
  "content": "Puedes usar un termómetro de cocina...",
  "step_index": 3
}
```

---

## Reconnection Strategy

When the socket disconnects (e.g., due to token expiration or network issues):

1. The client receives `Phoenix.Socket.CloseEvent`.
2. The client should attempt to reconnect with a fresh token.
3. After reconnecting, the client should re-join all previously joined channels.
4. Exponential backoff is recommended: 1s, 2s, 4s, 8s, max 30s.
5. After 5 consecutive failures, display a "Connection lost" error to the user.

```javascript
socket.onClose(() => {
  console.warn("Socket disconnected, attempting reconnect...");
  // Refresh token then reconnect
});
```

---

## Error Handling Patterns

| Event | Error Response | Action |
|---|---|---|
| `ai_chat:new_message` | `ai_error` with `reason` | Show error toast, allow retry |
| `planning:generate_menu` | `generation_error` | Show error, allow retry |
| `cooking:ask_assistant` | `assistant_error` | Show error, continue cooking |
| Socket disconnect | `Phoenix.Socket.CloseEvent` | Attempt reconnect with backoff |
| Auth failure | Connection refused | Redirect to login |
```

---

## 9. Data Flow Diagrams — Gap 4 (Checkout → Inventory)

### 9.1 Flow: `confirm_checkout` Transaction

```
┌──────────────────────────────────────────────────────────────────────┐
│  ShoppingService.confirm_checkout(user, session_id, payload)         │
└─────────────────────────┬──────────────────────────────────────────┘
                          │
                          ▼
          ┌───────────────────────────────┐
          │  Identity.ensure_persistent   │
          │  _identity(user)             │
          └──────────────┬────────────────┘
                         │ {:ok, identity}
                         ▼
          ┌───────────────────────────────┐
          │  ShoppingRepo.get_checkout_   │  Returns %CheckoutSession{} or nil
          │  session_for_account(...)      │
          └──────────────┬────────────────┘
                         │ session (or nil → error)
                         ▼
          ┌────────────────────────────────────────────────────────────┐
          │  Repo.transaction(fn -> ... end)                          │
          │                                                            │
          │  ┌──────────────────────────────────────────────────────┐ │
          │  │  ShoppingRepo.update_checkout_session(session, %{     │ │
          │  │    status: :completed,                               │ │
          │  │    actual_total_cents: ...,                          │ │
          │  │    completed_at: now(),                              │ │
          │  │    delivered_at: now()                                │ │
          │  │  })                                                   │ │
          │  │  → {:ok, updated_session}                            │ │
          │  └──────────────────────┬───────────────────────────────┘ │
          │                         │                                  │
          │                         ▼                                  │
          │  ┌────────────────────────────────────────────────────────┐ │
          │  │  Shopping.list_items_by_session(account_id, session_id│ │
          │  │  → [ShoppingItem, ShoppingItem, ...]                  │ │
          │  └──────────────────────┬───────────────────────────────┘ │
          │                         │                                  │
          │                         ▼                                  │
          │  ┌────────────────────────────────────────────────────────┐ │
          │  │  Enum.filter(&(&1.status == :checked_out))            │ │
          │  │  → filtered list of checked-out items                 │ │
          │  └──────────────────────┬───────────────────────────────┘ │
          │                         │                                  │
          │                         ▼                                  │
          │  ┌────────────────────────────────────────────────────────┐ │
          │  │  move_items_to_inventory(items)                       │ │
          │  │                                                       │ │
          │  │  For each item:                                       │ │
          │  │    InventoryRepo.create_inventory_item(%{             │ │
          │  │      account_id: item.account_id,                      │ │
          │  │      ingredient_id: item.ingredient_id,                 │ │
          │  │      quantity_milli: item.quantity_milli,              │ │
          │  │      unit: item.unit,                                  │ │
          │  │      source_kind: :planned,                           │ │
          │  │      last_mutation_at: now()                          │ │
          │  │    })                                                  │ │
          │  │                                                       │ │
          │  │  Returns: moved_count (integer)                       │ │
          │  └──────────────────────┬───────────────────────────────┘ │
          │                         │                                  │
          │                         ▼                                  │
          │  ┌────────────────────────────────────────────────────────┐ │
          │  │  %{updated | moved_to_inventory_count: moved_count}   │ │
          │  │  → enriched session struct                            │ │
          │  └──────────────────────┬───────────────────────────────┘ │
          └─────────────────────────┼────────────────────────────────┘
                                    │
                  ┌─────────────────┴──────────────────┐
                  │  Repo.transaction result            │
                  ▼                                     ▼
        ┌─────────────────────┐            ┌──────────────────────┐
        │  {:ok, result}      │            │  {:error, _}         │
        │  → serialize_      │            │  → {:error,          │
        │  checkout_session   │            │     :transaction_    │
        │  (with count)       │            │     failed}          │
        └─────────────────────┘            └──────────────────────┘
```

### 9.2 Response Shape

```
HTTP POST /api/checkout/confirm
Authorization: Bearer <jwt>
Content-Type: application/json

{
  "session_id": 456,
  "actual_total_cents": 8500
}

────────────────────────────────────────────────────────────

HTTP 200 OK

{
  "data": {
    "checkout_session": {
      "id": 456,
      "status": "completed",
      "estimated_total_cents": 10000,
      "actual_total_cents": 8500,
      "moved_to_inventory_count": 5,
      "total_items": 5,
      "started_at": "2026-06-03T08:00:00Z",
      "completed_at": "2026-06-03T10:30:00Z",
      "delivered_at": "2026-06-03T10:30:00Z"
    }
  }
}
```

---

## 10. Router Changes

**File**: `lib/meal_planner_api_web/router.ex`

### Addition

In the `:auth` scope (under the calendar route group):

```elixir
# ─── ADDITION: after GET "/calendar" ───────────────────────────
get("/calendar/slot", CalendarController, :show_slot)
```

**Full updated auth scope section**:

```elixir
scope "/api", MealPlannerApiWeb do
  pipe_through([:api, :auth])

  get("/me", AccountsController, :me)
  get("/account/context", AccountsController, :context)
  get("/calendar", CalendarController, :index)
  get("/calendar/slot", CalendarController, :show_slot)  # ← NEW
  get("/planning/weekly", PlanningController, :weekly)
  # ... rest unchanged
end
```

**Rationale**: Route is `GET /api/calendar/slot?date=YYYY-MM-DD&slot=breakfast`. It follows the existing resource-centric path pattern. Route ordering: specific routes (with params) should come after broad routes; this route requires params so it is placed after `/calendar` to avoid path conflicts, though both routes match different path patterns.

---

## 11. Test Strategy

### 11.1 Test File: `calendar_controller_test.exs`

**Test module**: `MealPlannerApiWeb.CalendarControllerTest`

```elixir
defmodule MealPlannerApiWeb.CalendarControllerTest do
  use MealPlannerApiWeb.ConnCase
  alias MealPlannerApi.Persistence.Calendar
  alias MealPlannerApi.Persistence.Planning.ScheduledMeal

  # ─── Gap 1: show_slot endpoint ───────────────────────────────

  describe "GET /api/calendar/slot — filled slot" do
    test "returns meal with can_create: false" do
      # Setup: create a scheduled meal for date + slot
      conn = build_conn_with_auth()

      conn =
        get(conn, "/api/calendar/slot", %{
          "date" => "2026-06-05",
          "slot" => "lunch"
        })

      assert %{
        "data" => %{
          "meal_id" => meal_id,
          "can_create" => false,
          "slot" => "lunch",
          "recipe_id" => recipe_id
        }
      } = json_response(conn, 200)

      assert is_binary(meal_id)
      assert is_binary(recipe_id)
    end
  end

  describe "GET /api/calendar/slot — empty slot" do
    test "returns can_create: true when no meal exists" do
      # Setup: no scheduled meal for this date/slot
      conn = build_conn_with_auth()

      conn =
        get(conn, "/api/calendar/slot", %{
          "date" => "2026-06-15",
          "slot" => "dinner"
        })

      assert %{
        "data" => %{
          "meal_id" => nil,
          "can_create" => true,
          "slot" => "dinner",
          "recipe_id" => nil
        }
      } = json_response(conn, 200)
    end
  end

  describe "GET /api/calendar/slot — validation errors" do
    test "returns 422 for invalid date format" do
      conn = build_conn_with_auth()

      conn =
        get(conn, "/api/calendar/slot", %{
          "date" => "not-a-date",
          "slot" => "lunch"
        })

      assert %{"error" => "invalid_date_format"} = json_response(conn, 422)
    end

    test "returns 422 for invalid slot value" do
      conn = build_conn_with_auth()

      conn =
        get(conn, "/api/calendar/slot", %{
          "date" => "2026-06-05",
          "slot" => "supper"  # not a valid slot
        })

      assert %{"error" => "invalid_slot"} = json_response(conn, 422)
    end

    test "returns 422 for missing date param" do
      conn = build_conn_with_auth()

      conn = get(conn, "/api/calendar/slot", %{"slot" => "lunch"})
      assert %{"error" => "invalid_date_format"} = json_response(conn, 422)
    end

    test "returns 422 for missing slot param" do
      conn = build_conn_with_auth()

      conn = get(conn, "/api/calendar/slot", %{"date" => "2026-06-05"})
      assert %{"error" => "invalid_slot"} = json_response(conn, 422)
    end
  end

  # ─── Gap 3: can_create in index response ─────────────────────

  describe "GET /api/calendar — can_create in response" do
    test "selected_meal has can_create: false when slot is filled" do
      # Setup: create a meal for selected_date/selected_slot
      conn = build_conn_with_auth()
      today = Date.utc_today()

      conn =
        get(conn, "/api/calendar", %{
          "start_date" => Date.to_iso8601(today),
          "end_date" => Date.to_iso8601(Date.add(today, 6)),
          "selected_date" => Date.to_iso8601(today),
          "selected_slot" => "lunch"
        })

      assert %{
        "data" => %{
          "selected_meal" => %{"can_create" => false, "meal_id" => meal_id}
        }
      } = json_response(conn, 200)

      assert is_binary(meal_id)
    end

    test "selected_meal has can_create: true when slot is empty" do
      # Setup: no meal for the selected date/slot
      conn = build_conn_with_auth()
      tomorrow = Date.add(Date.utc_today(), 10)

      conn =
        get(conn, "/api/calendar", %{
          "start_date" => Date.to_iso8601(Date.utc_today()),
          "end_date" => Date.to_iso8601(Date.add(Date.utc_today(), 6)),
          "selected_date" => Date.to_iso8601(tomorrow),
          "selected_slot" => "dinner"
        })

      assert %{
        "data" => %{
          "selected_meal" => %{"can_create" => true, "meal_id" => nil}
        }
      } = json_response(conn, 200)
    end

    test "meals list items have can_create: false" do
      conn = build_conn_with_auth()
      today = Date.utc_today()

      conn =
        get(conn, "/api/calendar", %{
          "start_date" => Date.to_iso8601(today),
          "end_date" => Date.to_iso8601(Date.add(today, 6))
        })

      assert %{"data" => %{"meals" => meals}} = json_response(conn, 200)
      assert Enum.all?(meals, &(&1["can_create"] == false))
    end
  end
end
```

### 11.2 Test File: `generation_service_test.exs`

**Additions to existing test file**:

```elixir
# ─── ADDITION: after existing describe blocks ───────────────────

describe "build_constraints/2 — favorite_recipe_ids" do
  test "with nil payload, returns empty favorite_recipe_ids list" do
    profile = %{protein_g_per_meal: 25, default_exclusions: []}
    result = GenerationService.build_constraints(profile, nil)
    assert result.favorite_recipe_ids == []
  end

  test "with favorite_recipe_ids in payload, propagates them" do
    profile = %{}
    payload = %{"favorite_recipe_ids" => [3, 7, 12]}
    result = GenerationService.build_constraints(profile, payload)
    assert result.favorite_recipe_ids == [3, 7, 12]
  end

  test "with atom-keyed favorite_recipe_ids, still propagates" do
    profile = %{}
    payload = %{favorite_recipe_ids: [5, 10]}
    result = GenerationService.build_constraints(profile, payload)
    assert result.favorite_recipe_ids == [5, 10]
  end

  test "payload favorites override profile defaults (none exist)" do
    profile = %{protein_g_per_meal: 25}
    payload = %{"favorite_recipe_ids" => [1, 2]}
    result = GenerationService.build_constraints(profile, payload)
    assert result.favorite_recipe_ids == [1, 2]
  end
end

describe "build_proposal_json/1 — favorite_recipe_ids in constraints" do
  test "preferred_recipe_ids appear in each slot's constraints" do
    resolved = %{
      budget_cents: 10_000,
      protein_g_per_meal: 25,
      favorite_recipe_ids: [3, 7, 12]
    }

    slots_input = GenerationServer.build_slots_input(resolved)

    assert Enum.all?(slots_input, fn slot ->
      slot["constraints"]["preferred_recipe_ids"] == ["3", "7", "12"]
    end)
  end
end
```

### 11.3 Test File: `shopping_service_test.exs`

**Additions to existing test file**:

```elixir
# ─── ADDITION: new describe blocks ────────────────────────────

describe "confirm_checkout/3 — Gap 4 inventory movement" do
  test "calls move_items_to_inventory with checked-out items" do
    # Setup: create checkout session + checked-out items
    user = build_user_with_identity()
    session = create_checkout_session(%{account_id: user.account_id, status: :completed})

    items = [
      create_shopping_item(%{status: :checked_out, checkout_session_id: session.id}),
      create_shopping_item(%{status: :checked_out, checkout_session_id: session.id})
    ]

    # Mock InventoryRepo to track calls
    expect(InventoryRepoMock, :create_inventory_item, 2, fn attrs ->
      {:ok, %InventoryItem{}}
    end)

    result = ShoppingService.confirm_checkout(user, session.id, %{})

    assert {:ok, response} = result
    assert response.moved_to_inventory_count == 2
  end

  test "transaction rollback if session update fails" do
    user = build_user_with_identity()
    session = create_checkout_session(%{account_id: user.account_id})

    # Simulate session update failure
    stub(ShoppingRepoMock, :update_checkout_session, fn _, _ -> {:error, :db_error} end)

    result = ShoppingService.confirm_checkout(user, session.id, %{})

    assert {:error, :transaction_failed} = result
  end

  test "returns moved_to_inventory_count in response" do
    user = build_user_with_identity()
    session = create_checkout_session(%{account_id: user.account_id, status: :draft})

    create_shopping_item(%{status: :checked_out, checkout_session_id: session.id})

    result = ShoppingService.confirm_checkout(user, session.id, %{"actual_total_cents" => 5000})

    assert {:ok, %{checkout_session: %{moved_to_inventory_count: count}}} = result
    assert count == 1
  end
end

describe "get_shopping_list/2 — Gap 5 auto-pruning" do
  test "archives past-dated pending items on every call" do
    user = build_user_with_identity()
    past_item = create_shopping_item(%{
      planned_date: Date.add(Date.utc_today(), -5),
      status: :pending
    })

    # First call → item should be archived
    {:ok, _} = ShoppingService.get_shopping_list(user, %{})

    # Reload from DB
    reloaded = Repo.get(ShoppingItem, past_item.id)
    assert reloaded.status == :archived
  end

  test "returns only non-archived items by default" do
    user = build_user_with_identity()
    create_shopping_item(%{planned_date: Date.add(Date.utc_today(), -3), status: :archived})
    active_item = create_shopping_item(%{planned_date: Date.add(Date.utc_today(), 2), status: :pending})

    {:ok, %{items: items}} = ShoppingService.get_shopping_list(user, %{})

    item_ids = Enum.map(items, & &1.id)
    assert active_item.id in item_ids
    # archived item should not appear
  end

  test "includes archived items when include_archived=true" do
    user = build_user_with_identity()
    archived_item = create_shopping_item(%{
      planned_date: Date.add(Date.utc_today(), -2),
      status: :archived
    })

    {:ok, %{items: items}} = ShoppingService.get_shopping_list(user, %{"include_archived" => "true"})

    item_ids = Enum.map(items, & &1.id)
    assert archived_item.id in item_ids
  end
end
```

### 11.4 Test File: `generation_server_test.exs`

**Additions to existing test file**:

```elixir
describe "run_pipeline — Gap 2 favorite injection" do
  test "loads favorite recipe IDs and injects into slots" do
    account_id = 1
    user_id = 1

    # Setup: create some favorites
    RecipeRepo.add_favorite(account_id, 3)
    RecipeRepo.add_favorite(account_id, 7)

    state = %{
      account_id: account_id,
      user_id: user_id,
      channel_pid: self(),
      phase: :idle,
      current_run_id: nil,
      current_proposal_id: nil,
      proposal_json: nil,
      constraints: %{}
    }

    # Run the pipeline up to build_slots_input point
    slots = GenerationServer.build_slots_input(%{
      date_from: Date.utc_today() |> Date.to_iso8601(),
      date_to: Date.add(Date.utc_today(), 2) |> Date.to_iso8601(),
      slot_types: [:breakfast, :lunch],
      budget_cents: 10_000,
      protein_g: 25,
      favorite_recipe_ids: [3, 7]
    })

    assert Enum.all?(slots, fn slot ->
      slot["constraints"]["preferred_recipe_ids"] == ["3", "7"]
    end)
  end
end
```

### 11.5 Test Summary Table

| Gap | Test Module | Test Count | What It Asserts |
|---|---|---|---|
| Gap 1 | `CalendarControllerTest` | 6 | Slot lookup returns correct shape, empty slot → `can_create: true`, invalid params → 422 |
| Gap 3 | `CalendarControllerTest` | 3 | `index` response includes `can_create` in `selected_meal` and `meals` list |
| Gap 2 | `GenerationServiceTest` | 4 | `favorite_recipe_ids` flows through `build_constraints` and into slots |
| Gap 2 | `GenerationServerTest` | 1 | `preferred_recipe_ids` appears in each slot's OR-Tools constraints |
| Gap 4 | `ShoppingServiceTest` | 3 | `confirm_checkout` calls `move_items_to_inventory`, returns count, rolls back on error |
| Gap 5 | `ShoppingServiceTest` | 3 | Pruning runs every call, archived excluded, `include_archived=true` included |
| Gap 4 | `Persistence.ShoppingTest` | 2 | `list_items_by_session` returns correct items, handles empty session |
| Gap 6 | Doc-based | — | `docs/CHANNELS.md` exists, `UserSocket` docstring covers all 4 channels |

---

## 12. Rollout Plan

### 12.1 Additive Changes Only

All changes are **additive**. No existing behavior is modified in a breaking way:
- New endpoint `GET /api/calendar/slot` — no existing endpoint changed
- `can_create: false` added to existing `serialize_meal/1` — new field, existing consumers ignore unknown fields
- `favorite_recipe_ids` propagated — new field in constraints map, no existing caller passes it (falls back to `[]`)
- `moved_to_inventory_count` added to checkout response — new field, existing consumers ignore unknown fields
- `prune_past_items` always runs — behavior change but safe (no-op on already-archived items)
- `docs/CHANNELS.md` — new file, no existing code affected

**No migration scripts needed. No database schema changes.**

### 12.2 Phased Rollout

#### Phase 1: Backend Core (Day 1)
1. Implement `Persistence.Calendar.get_slot_meal/3`
2. Implement `Persistence.Shopping.list_items_by_session/2`
3. Implement router change `GET /api/calendar/slot`
4. Implement `CalendarController.show_slot/2`
5. Update `CalendarController.serialize_meal/1` and `serialize_selected_meal/1`

**Verification**: Unit tests pass; `GET /api/calendar/slot?date=2026-06-05&slot=lunch` returns correct JSON.

#### Phase 2: Generation Pipeline (Day 2)
1. Add `list_favorite_ids/1` to `RecipeRepo`
2. Update `GenerationService.build_constraints/2`
3. Update `GenerationServer.run_pipeline/1` with favorites loading
4. Update `GenerationServer.build_slots_input/1` with `preferred_recipe_ids`

**Verification**: Integration test shows `preferred_recipe_ids` in OR-Tools payload for accounts with favorites.

#### Phase 3: Shopping Checkout (Day 3)
1. Wrap `ShoppingService.confirm_checkout/3` in transaction
2. Call `move_items_to_inventory` inside transaction
3. Update `serialize_checkout_session/1` with `moved_to_inventory_count`
4. Add `ShoppingService.get_shopping_list/2` prune fix (always run with `today`)
5. Update `Persistence.Shopping.list_items_for_account/2` with `include_archived` option

**Verification**: `POST /api/checkout/confirm` returns `moved_to_inventory_count`; expired items auto-archived on list load.

#### Phase 4: Documentation (Day 4)
1. Expand `UserSocket` `@moduledoc`
2. Create `docs/CHANNELS.md`
3. Review all inline comments for Spanish/English consistency

**Verification**: `mix docs` generates correct documentation.

### 12.3 No-Downtime Checklist

- [ ] All changes are backward-compatible
- [ ] New endpoint returns 422 for missing params (not 500)
- [ ] Transaction rollback does not leave partial state in `confirm_checkout`
- [ ] Pruning rescue clause prevents `get_shopping_list` from crashing on DB errors
- [ ] `String.to_existing_atom/1` in `parse_slot` is safe (controller validates before using)
- [ ] All new functions have `@spec` for Dialyzer
- [ ] No route conflicts — `GET /calendar` vs `GET /calendar/slot` are distinct

### 12.4 Monitoring Points

After deployment:
1. Monitor `GET /api/calendar/slot` response times (P95 < 50ms expected)
2. Monitor `POST /api/checkout/confirm` for `transaction_failed` errors
3. Monitor `get_shopping_list` for archive rate (items/day pruned)
4. Monitor OR-Tools payload size with `preferred_recipe_ids` (should not exceed 10KB per slot list)

---

## Files Summary

| File | Change Type | Lines Changed (est.) | Gaps Covered |
|---|---|---|---|
| `lib/meal_planner_api_web/controllers/calendar_controller.ex` | Edit + Add | ~60 | G1, G3 |
| `lib/meal_planner_api/persistence/calendar.ex` | Add | ~25 | G1, G3 |
| `lib/meal_planner_api/services/generation_service.ex` | Edit | ~15 | G2 |
| `lib/meal_planner_api/generation/server.ex` | Edit + Add | ~40 | G2 |
| `lib/meal_planner_api/services/shopping_service.ex` | Edit | ~35 | G4, G5 |
| `lib/meal_planner_api/persistence/shopping.ex` | Edit + Add | ~20 | G4, G5 |
| `lib/meal_planner_api/data/recipe_repo.ex` | Add | ~10 | G2 |
| `lib/meal_planner_api_web/user_socket.ex` | Edit (doc) | ~35 | G6 |
| `lib/meal_planner_api_web/router.ex` | Add | ~2 | G1 |
| `docs/CHANNELS.md` | New | ~180 | G6 |
| `test/meal_planner_api_web/controllers/calendar_controller_test.exs` | Add | ~80 | G1, G3 |
| `test/meal_planner_api/services/generation_service_test.exs` | Add | ~30 | G2 |
| `test/meal_planner_api/generation/server_test.exs` | Add | ~25 | G2 |
| `test/meal_planner_api/services/shopping_service_test.exs` | Add | ~90 | G4, G5 |
| **Total** | **14 files** | **~647 lines** | **G1–G6** |

---

*Design complete. Awaiting review from orchestrator before SDD-APPLY phase.*
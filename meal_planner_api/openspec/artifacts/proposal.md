# SDD Proposal: MealPlannerApi — Full Architecture Redo

## Change Summary

Redesign MealPlannerApi's layered architecture from a tangled mix of domain+infrastructure to a clean 3-layer structure (Controllers → Services → Data) with injected ports for external integrations.

---

## Intent

Replace the current architecture — where domain logic is entangled with infrastructure concerns (System.cmd, AI calls, text parsing) — with a clean, testable, and maintainable structure that separates concerns properly and uses dependency injection throughout.

---

## Scope

### In Scope

1. **Layer boundaries**: Define and implement 3-layer architecture (Web / Application / Data)
2. **Ports and Adapters**:
   - `OptimizerPort` — GenServer + Port (stdio) communication with Python OR-Tools optimizer
   - `AIPort` — injected AI client behaviour for Gemini
3. **Domain services**: Clean services that orchestrate without infrastructure coupling
4. **Controllers**: Thin HTTP handlers that delegate to services and format responses
5. **Data layer**: Pure Ecto schemas and query modules
6. **Fallback strategy**: Injectable fallback for optimizer unavailability
7. **Voice parsing**: Extracted as a port with AI-backed and rule-based implementations
8. **New persistence models**: Clean schema design for recipes, ingredients, inventory

### Out of Scope

- Mobile app (myfood/ directory)
- Frontend integration guide
- RevenueCat webhook processing (keep existing logic but not re-architect)
- Social auth (keep as-is)

---

## Problem Statement

### Current Architecture Issues

| Issue | Location | Impact |
|---|---|---|
| Domain calls `System.cmd` directly | `Planning.weekly_plan_for/2` | Untestable, couples to shell |
| AI injected via direct module call | `InventoryHub.voice_preview/2` | No substitution possible |
| Text parsing in domain | `fallback_parse_voice_operations/2` | Fragile, language-specific |
| Persistence has business logic | `PlanningPersistence.candidate_recipe_ids_for_users/4` | Violates layering |
| Controllers mix HTTP + logic | All controllers | Hard to test, violates SRP |
| No application layer | Services are domain+infrastructure | Unclear responsibility |
| Fallback hardcoded | `fallback_day_plans/5` | Not injectable |
| Optimizer timeout/cb missing | `PythonOptimizerClient` | No resilience |

### Root Cause

The original architecture was built without enforcing layer boundaries. Phoenix Contexts were used as dumping grounds for everything that didn't fit elsewhere, and the "Application Layer" pattern was not applied.

---

## Approach

### 1. Layer Design

```
┌─────────────────────────────────────────────┐
│           Web (Controllers + Channels)       │
│  Thin: receive → validate → delegate → resp │
└──────────────────────┬──────────────────────┘
                       │
┌──────────────────────▼──────────────────────┐
│           Application (Services)              │
│  Orchestrates domain, uses Ports              │
│  No HTTP parsing, no DB queries                │
└──────────────────────┬──────────────────────┘
                       │
┌──────────────────────▼──────────────────────┐
│              Data (Persistence)                │
│  Pure: schemas, queries, no business logic    │
└─────────────────────────────────────────────┘
```

### 2. Port/Adapter Pattern for External Integrations

All external integrations are accessed through behaviours (Ports) injected at runtime:

```elixir
# Optimizer port
defmodule MealPlannerApi.Optimization.OptimizerPort do
  @callback select_weekly_menu(payload :: map()) :: {:ok, map()} | {:error, term()}
end

# AI port
defmodule MealPlannerApi.AI.AIPort do
  @callback generate_text(prompt :: String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback stream_chat(prompt :: String.t(), topic :: String.t(), keyword()) :: :ok | {:error, term()}
end

# Voice parser port
defmodule MealPlannerApi.Voice.VoiceParserPort do
  @callback parse_inventory_ops(text :: String.t(), items :: [map()]) :: {:ok, [map()]} | {:error, term()}
end
```

### 3. GenServer + Port for Python Optimizer

Instead of `System.cmd` per-request:

- One persistent GenServer (`OptimizerServer`) owns the Python process via Port
- Process lifetime: managed, with restart on crash
- Communication: JSON over stdin/stdout
- Protocol: request-id + JSON payload, response with same id
- Circuit breaker: after N consecutive failures, open circuit
- Fallback: `FallbackOptimizer` implementation injects simple heuristic when circuit is open

```
Elixir Service
    │
    ▼
OptimizerServer (GenServer)
    │
    ├── Port ──► Python process (OR-Tools)
    │
    └── Circuit Breaker
           │
           └── FallbackOptimizer (when open)
```

### 4. Voice Parsing Extraction

`InventoryHub` currently contains:
- AI-based voice parsing (calls Gemini)
- Rule-based fallback parsing (string matching)

Both are extracted to:
- `VoiceParserPort` behaviour
- `AIVoiceParser` adapter (uses AIPort)
- `RuleBasedVoiceParser` adapter (pure Elixir, no AI)

`InventoryHub` receives the parser as dependency.

### 5. Data Layer: Pure Persistence

Persistence modules become pure data access — no business logic:

```elixir
# BEFORE (has logic)
defmodule MealPlannerApi.Persistence.Planning do
  def candidate_recipe_ids_for_users(account_id, user_ids, slot) do
    # business logic mixed here
  end
end

# AFTER (pure data access)
defmodule MealPlannerApi.Persistence.Planning do
  def list_recipes_for_slot(account_id, slot) do
    # only query, no logic
  end
end
```

Business logic for candidate selection moves to a `RecipeService` in the Application layer.

---

## Constraints

- **Data migration**: Migrate schema in-place. Data stays — ingredients, recipes, inventory remain intact. Only code structure changes.
- **Python optimizer kept**: OR-Tools is the right tool for constraint solving; communication improved via GenServer+Port
- **Backward compatibility**: API surface (endpoints, response shapes) should remain compatible where possible to ease client migration
- **No breaking changes without notice**: If API contracts change, document them explicitly

---

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| GenServer + Port stability on cold Python process | Medium | High | Health check, auto-restart, process supervision |
| Circuit breaker false positives | Low | Medium | Configurable thresholds, manual reset endpoint |
| AI voice parser quality degradation | Medium | Low | Rule-based fallback always available |
| Breaking API contracts | Medium | High | Explicit changelog, versioned endpoints if needed |
| Test coverage gap during transition | High | High | Strict TDD enforced: RED, GREEN, TRIANGULATE, REFACTOR |

---

## Out of Scope Detail

- **Mobile app** (`myfood/` directory) is a separate native app, not part of this re-architecture
- **RevenueCat** webhooks are external-inbound; current logic is acceptable
- **Social auth** (Google/Apple/Facebook) works correctly; not touching it

---

## Success Criteria

1. All domain services are testable without external dependencies (mocks for ports)
2. Python optimizer communication is supervised and resilient
3. AI is not called from domain — only through injected ports
4. Controllers have no business logic — only HTTP handling
5. Persistence layer has no business logic — only data access
6. Fallback for optimizer unavailability is injectable and testable
7. Voice parsing has two implementations: AI-backed and rule-based, selectable at runtime
8. All new code follows strict TDD

---

## Decisions Made

1. **API versioning**: Replace current routes (no `/api/v2/`). New controllers replace old ones at same paths.
2. **Existing data migration**: Migrate schema in-place. Data stays — ingredients, recipes, inventory remain intact. Only code structure changes.
3. **Error format**: RFC 7807 Problem Details (standard, better tooling, React Native compatible).
4. **Session/WS auth**: Keep Guardian + JWT. Standard Phoenix approach, works with React Native (Bearer token in header/query param for HTTP, token query param for WS).

---

*Proposal created: 2026-06-01*
*Status: pending spec*
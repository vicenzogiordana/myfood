# SDD: Backend Gaps — Frontend Integration

## Metadata
- **Change ID**: backend-gaps-frontend-integration
- **Created**: 2026-06-03
- **Author**: el Gentleman (orchestrator)
- **Status**: proposal

## Problem Statement

After analyzing the frontend requirements (5 React Native views) and the current Elixir/Phoenix backend, 6 concrete gaps were identified that prevent the mobile app from fully consuming the API:

1. **Slot filtering missing**: No endpoint to get a specific `(date, slot)` meal
2. **Favorites injection in prompts**: Favorites exist but aren't passed to GenerationServer as optimization hints
3. **Can-create flag missing**: Frontend needs to know if a slot is empty to enable/disable the "+" button
4. **Shopping→Inventory transition incomplete**: Checkout confirm doesn't auto-populate inventory
5. **Auto-pruning of expired shopping items**: Items past their planned date aren't hidden
6. **WebSocket auth documentation**: Frontend team needs the token handshake flow documented

## Scope

### In Scope
- All 6 gaps above
- Corresponding tests for new/changed functions
- Elixir/Phoenix implementation only (backend side)
- Phoenix Channels for real-time events

### Out of Scope
- React Native frontend implementation
- Web scraping / price sync (separate concern)
- Migration scripts (assumed to exist)
- Performance optimization of existing code

## Goals
1. Provide complete API coverage for all 5 frontend views
2. Maintain backward compatibility with existing endpoints
3. Follow existing Clean Architecture patterns in the codebase

## Non-Goals
- Refactoring the AI/LLM integration (already working)
- Changing the database schema (schema is adequate)
- Adding new Phoenix Channels (all needed channels exist)

## Dependencies
- Current `main` branch of meal_planner_api
- Existing migrations already in `priv/repo/migrations/`
- Phoenix Channels already defined in `meal_planner_api_web/channels/`

## Risks
- **Low risk**: Changes are additive and isolated to specific controllers/services
- **Integration risk**: Changes to ShoppingService.checkout flow must be transactional
- **Testing risk**: New edge cases in slot filtering need coverage

## Open Questions
- Should Gap 6 (WS auth docs) be a separate deliverable or inline code comments?
- What's the retention policy for auto-pruned shopping items? (Hard delete vs soft delete)
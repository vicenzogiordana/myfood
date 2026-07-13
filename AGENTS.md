# MyFood — Project Root

MyFood is a mobile culinary assistant (React Native) backed by an Elixir/Phoenix
API. This file is the project-root agent context. Sub-projects have their own
agent files that take precedence within their directory tree.

## Sub-projects

- **`meal_planner_api/`** — Elixir/Phoenix API (Clean Architecture, Guardian JWT,
  Gemini SSE, OR-Tools, RevenueCat). See `meal_planner_api/AGENTS.md` for
  Phoenix-specific rules (LiveView, Ecto, channels, testing).

## Skills to load before work

This repo uses Matt Pocock's engineering skills. Before delegating or running
work that touches code, the orchestrator resolves the skill index from
`.atl/skill-registry.md` and passes matching `SKILL.md` paths to sub-agents.

## Agent skills

### Issue tracker

GitHub Issues on `vicenzogiordana/myfood` via the `gh` CLI. See
`docs/agents/issue-tracker.md`.

### Triage labels

Canonical five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Multi-context layout: project root + `meal_planner_api/` + a future mobile app
context. See `CONTEXT-MAP.md` and `docs/agents/domain.md`.

# Project-Root SDD Init Report

**Project**: `myfood` (repo: `vicenzogiordana/myfood`)
**Initialized**: 2026-06-16
**Init Phase Executor**: `sdd-init` (sub-agent)
**Artifact Store**: `openspec` (file-based, under `/Users/vicenzogiordana/Desktop/Progra/myfood/openspec/`)
**Persistence**: File-only (Engram MCP not available in this executor context)

---

## 1. Executive Summary

Project-root OpenSpec bootstrapped. The MyFood monorepo now has a top-level
`openspec/` tree that scopes **repo-wide** SDD changes (cross-sub-project
decisions, governance, and future mobile app). The Phoenix API sub-project
(`meal_planner_api/`) keeps its own `openspec/config.yaml` with
`strict_tdd: true` and continues to be the source of truth for backend
architecture; the project-root config mirrors that TDD discipline for any
change that the orchestrator launches from the root.

---

## 2. Detected Stack (project root)

| Layer            | Status        | Detail                                                                                              |
| ---------------- | ------------- | --------------------------------------------------------------------------------------------------- |
| Frontend (mobile) | **pending**   | React Native (iOS + Android) is the target per `context.md`, but no app directory exists yet.       |
| Backend (API)    | present       | Elixir + Phoenix 1.8 (API-only, `--no-html --no-assets`), PostgreSQL via Ecto, Guardian JWT.        |
| Real-time        | present       | Phoenix Channels / WebSockets (used for streaming AI chat responses).                               |
| External AI      | present       | Google Gemini, streamed via SSE.                                                                    |
| External solver  | present       | Google OR-Tools, executed via Python subprocess (`optimizador.py`, `generador.py`) at repo root.    |
| Billing          | present       | RevenueCat (webhooks + entitlement sync).                                                           |
| Architecture     | Clean Arch.   | Web / Application / Persistence / Infrastructure (per `meal_planner_api/ARCHITECTURE.md`).           |

### Domain rules (from `context.md`)

- Multi-tenancy via `Account` (`:individual` or `:group`).
- Budget-constrained AI meal planning.
- Zero-waste inventory prioritization.
- Freemium SaaS tiers (free vs. premium $3 USD/month).

### Ubiquitous language (canonical terms)

`Account`, `User`, `AccountMembership`, `MealPlan`, `Meal`, `ShoppingItem`,
`Budget`, `Inventory`, `PlanningSession`, `Message`. See `context.md` and
`docs/agents/domain.md` for the full glossary.

---

## 3. Testing Capabilities

**Strict TDD Mode**: enabled
**Mirrored from**: `meal_planner_api/openspec/config.yaml` (`strict_tdd: true`)
**Detected**: 2026-06-16

### Test Runner

- Command: `mix test`
- Framework: ExUnit (Elixir built-in)
- CWD: `meal_planner_api/`
- Sub-project note: `mix precommit` alias is the project-standard pre-merge gate.

### Test Layers

| Layer                | Available | Tool / Note                                                      |
| -------------------- | --------- | ---------------------------------------------------------------- |
| Unit                 | yes       | ExUnit (`test/meal_planner_api/...` in sub-project).             |
| Integration          | yes       | ExUnit + Ecto + `start_supervised!/1` (per sub-project AGENTS.md). |
| End-to-end (HTTP)    | partial   | ExUnit + `Phoenix.ConnTest` + `Phoenix.ChannelTest` in sub-project. |
| End-to-end (mobile)  | no        | No React Native app scaffolded yet.                              |
| Python (optimizer)   | no        | `pytest` is plausible but **not configured at repo root**.       |

### Coverage

- Available: partial (sub-project has historical `cover/` directory; no active coverage gate).
- Command: not enforced at project root.

### Quality Tools

| Tool                | Available | Command                                          |
| ------------------- | --------- | ------------------------------------------------ |
| Linter (Elixir)     | yes       | `mix credo` (in sub-project; not verified here). |
| Formatter (Elixir)  | yes       | `mix format` (sub-project; not verified here).   |
| Type checker        | n/a       | Elixir is dynamically typed; dialyzer is optional. |
| Linter (Python)     | partial   | `.ruff_cache/` is present (historical run); not currently configured. |
| Formatter (Python)  | n/a       | Not configured.                                   |
| Linter (TS/JS)      | n/a       | Mobile app not scaffolded.                       |

### Strict TDD Resolution

The orchestrator's preflight decision mirrored the api sub-project's
`strict_tdd: true`. With a working test runner present, strict TDD is the
default. If a future repo-root change has no test runner wired (e.g., a
docs-only change touching a script with no harness), the orchestrator may
override per change in `openspec/changes/<name>/tasks.md`.

---

## 4. Artifact Store Layout

Created at project root:

```
openspec/
├── config.yaml                 # Project-root SDD config (this init)
├── specs/                      # Empty placeholder; main specs root
│   └── .gitkeep
├── changes/                    # Active changes
│   ├── archive/                # Completed changes (audit trail)
│   │   └── .gitkeep
│   └── .gitkeep
└── init-report.md              # This report
```

### Existing SDD state (NOT touched by this init)

- `meal_planner_api/openspec/config.yaml` — sub-project config, `strict_tdd: true`, owned by the API team.
- `meal_planner_api/openspec/artifacts/` — sub-project SDD artifacts (10 entries; not enumerated here per scope).

### Pre-existing files preserved (not recreated)

- `AGENTS.md` — project-root agent context.
- `CONTEXT-MAP.md` — multi-context domain map.
- `context.md` — root domain context (lowercase by historical convention).
- `docs/agents/{issue-tracker,triage-labels,domain}.md` — agent skills.
- `.atl/skill-registry.md` — skill index (already present, not regenerated).
- `meal_planner_api/AGENTS.md` and `meal_planner_api/ARCHITECTURE.md` — sub-project context.

---

## 5. Preflight Decisions (cached for this session)

| Decision            | Value         |
| ------------------- | ------------- |
| Execution mode      | `auto`        |
| Artifact store      | `openspec`    |
| Chained PR strategy | `ask-always`  |
| Review budget       | 400 lines     |

These are persisted in `openspec/config.yaml` under the `preflight:` block so
the orchestrator can read them at session start without re-asking.

---

## 6. Skill Resolution

- **Mode**: `paths-injected` — the orchestrator injected the `sdd-init` SKILL
  path and the `_shared/skill-resolver.md` path explicitly in the launch
  prompt. No fallback or registry scan was needed.
- **Skills loaded**:
  - `/Users/vicenzogiordana/.config/opencode/skills/sdd-init/SKILL.md`
  - `/Users/vicenzogiordana/.config/opencode/skills/_shared/skill-resolver.md`
  - `/Users/vicenzogiordana/.config/opencode/skills/sdd-init/references/init-details.md`
  - `/Users/vicenzogiordana/.config/opencode/skills/_shared/openspec-convention.md`
  - `/Users/vicenzogiordana/.config/opencode/skills/_shared/sdd-phase-common.md`
  - `/Users/vicenzogiordana/.config/opencode/skills/_shared/sdd-status-contract.md`

---

## 7. Next Recommended Step

`sdd-new <change-name>` from the orchestrator, OR — if the user already has a
concrete change in mind — `/sdd-explore <topic>` followed by
`/sdd-propose`. Project-root changes are best suited for:

- **Repo-wide governance** (license, CI, monorepo tooling).
- **Cross-sub-project contracts** (the public schema between the future
  React Native app and the Phoenix API).
- **Mobile app kickoff** (scaffolding `mobile/` and its context file once the
  app appears).
- **Tooling for the Python optimizer** (a `pytest` harness at the root,
  ruff config, type stubs) — currently "not detected", so a repo-root change
  to add it is in-scope here, not in the API sub-project.

For backend-only architecture work, the orchestrator should launch the SDD
phases from `meal_planner_api/` (its `openspec/config.yaml` is the source of
truth for that scope) and pass the resolved skills from the registry.

---

## 8. Risks and Caveats

1. **Two OpenSpec roots**: the project root and `meal_planner_api/` each
   own a `config.yaml`. A change that crosses both must declare
   `owner_sub_project: repo-wide` (or similar) and link to the sub-project
   config so the orchestrator does not write artifacts in the wrong tree.
2. **Mobile app is "pending"**: the registry describes the React Native
   context (`mobile`) but no directory exists. Project-root proposals
   involving the mobile app are speculative until the app is scaffolded.
3. **Python tests not configured**: the `optimizador.py` and
   `generador.py` scripts are exercised by the API's integration tests
   (sub-project), but no isolated `pytest` harness exists at the root.
   Coverage of the Python layer therefore relies on the API's E2E tests.
4. **Engram persistence unavailable in this executor context**: this
   report is file-only. Cross-session recovery of the init observation
   requires re-reading `openspec/config.yaml` and this report.
5. **`context.md` vs `CONTEXT.md`**: the project root context file is
   lowercase for historical reasons. Engineering skills must treat it as
   `CONTEXT.md` per `CONTEXT-MAP.md`. A rename is safe in a follow-up
   cleanup change.
6. **Review budget is 400 lines** (per preflight). The orchestrator must
   stop and ask the user before applying any project-root change whose
   forecast exceeds that budget (chained-PR strategy is `ask-always`).

---

## 9. Open Questions Deferred to the Orchestrator

None blocking. The preflight answers covered all four required decisions.

---

## 10. Result Contract

| Field               | Value                                                                            |
| ------------------- | -------------------------------------------------------------------------------- |
| `status`            | `success`                                                                        |
| `executive_summary` | Project-root `openspec/` created; `strict_tdd: true` mirrored from sub-project. |
| `artifacts`         | `openspec/config.yaml`, `openspec/specs/`, `openspec/changes/`, `openspec/changes/archive/`, `openspec/init-report.md` |
| `next_recommended`  | `sdd-new` (orchestrator meta) or `sdd-explore` if a topic is already in mind.     |
| `risks`             | See section 8.                                                                   |
| `skill_resolution`  | `paths-injected`                                                                 |

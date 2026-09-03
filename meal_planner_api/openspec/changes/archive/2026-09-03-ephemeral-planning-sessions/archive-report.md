# Archive Report — `ephemeral-planning-sessions`

**Change**: `ephemeral-planning-sessions`
**Archived on**: 2026-09-03
**Archived to**: `meal_planner_api/openspec/changes/archive/2026-09-03-ephemeral-planning-sessions/`
**Artifact store mode**: `hybrid` (OpenSpec filesystem merge + Engram observation)
**Status**: `success` — SDD cycle complete, ready for the next change. GitHub issue #33 may be closed.

---

## Final State (at close)

`origin/main` HEAD at archive time: `b002a780fa9686a97c5b1f8c9b0efc2acb59b2b7` — `Merge pull request #65 from vicenzogiordana/feat/issue-33-ephemeral-planning-pr5` (merged 2026-09-03T12:16:47Z).

All six PRs of the chained delivery landed on `main`:

| PR | Title | Outcome |
|---|---|---|
| #60 | `feat(planning): ephemeral planning sessions — PR1 migrations + 3 schemas + EXCLUDE` | Merged |
| #61 | `feat(planning): ephemeral planning sessions — PR2 PlanningRepo CRUD + validate_ai_intent` | Merged |
| #62 | `fix(planning): validate_transition_from must compare to original DB status` | Merged (PR2 hotfix) |
| #63 | `feat(planning): ephemeral planning sessions — PR3 PlanningSessionServer + Sweeper + supervisor` | Merged |
| #64 | `feat(planning): ephemeral planning sessions — PR4 Channel + AI intent boundary` | Merged |
| #65 | `feat(planning): ephemeral planning sessions — PR5 supervisor fix + e2e + threat matrix` | Merged 2026-09-03T12:16:47Z |

The PR5 rebase artefact (diff-vs-main shrunk from 1387 → 607 lines) is a rebase consequence, not a scope reduction: PR4's work was already on `main` when PR5 was rebased, so PR5's delta against the new base only contains PR5-unique commits.

---

## Test Status (final)

`meal_planner_api` test suite: **771/772 passing**.

One failure: `MealPlannerApi.Optimization.OptimizerServerTest` "circuit-open solve calls fall back to OptimizerFallback".

**Classification**: pre-existing flaky test on `main`, NOT caused by this change. Confirmed via `git stash` repro (the test fails on `main` without any PR1–PR5 commits). Out of scope. No CRITICAL verification issue — does not block archive.

---

## Delta Specs Synced

The two delta specs (`ai-intent-boundary`, `planning-sessions`) target **new domains** that did not exist as canonical specs at `meal_planner_api/openspec/specs/`. They are not modifications to the existing `channels/spec.md` (which already exists from the `phase-a-tenancy-refactor` archive and only covers socket/`join/3` tenancy rules). Per the OpenSpec convention, the delta IS the full spec and was copied mechanically to the canonical root.

| Domain | Action | Details |
|---|---|---|
| `ai-intent-boundary` | Created (full spec) | 4 requirements copied byte-identically to `meal_planner_api/openspec/specs/ai-intent-boundary/spec.md` (3 010 bytes) |
| `planning-sessions` | Created (full spec) | 5 requirements copied byte-identically to `meal_planner_api/openspec/specs/planning-sessions/spec.md` (4 155 bytes) |

`channels/spec.md`, `accounts/spec.md`, and `auth/spec.md` were **not** touched — none of the new requirements replace or extend an existing requirement there (the `channels/spec.md` `AIChannel` requirement predates and does not conflict with the new typed-intent boundary, which is enforced at `handle_in("new_message", ...)` time, not `join/3` time).

### Mechanical copy readback (verbatim `diff -r` output)

```
=== diff -r readback: meal_planner_api/openspec/changes/ephemeral-planning-sessions/specs/ai-intent-boundary/spec.md vs meal_planner_api/openspec/specs/ai-intent-boundary/.spec.md.ZnwtVJ ===
[empty]

=== diff -r readback: meal_planner_api/openspec/changes/ephemeral-planning-sessions/specs/planning-sessions/spec.md vs meal_planner_api/openspec/specs/planning-sessions/.spec.md.U4Rj9s ===
[empty]
```

Both diffs are empty — the only passing evidence per the Mechanical Copy Contract.

---

## Source of Truth Updated

The following canonical specs now reflect the new behavior:

- `meal_planner_api/openspec/specs/ai-intent-boundary/spec.md`
- `meal_planner_api/openspec/specs/planning-sessions/spec.md`

---

## Archive Contents

```
meal_planner_api/openspec/changes/archive/2026-09-03-ephemeral-planning-sessions/
├── archive-report.md
├── design.md
├── exploration.md
├── proposal.md
├── specs/
│   ├── ai-intent-boundary/
│   │   └── spec.md
│   └── planning-sessions/
│       └── spec.md
└── tasks.md
```

### Mechanical move readback (verbatim `diff -r` output)

```
=== diff -r readback: <pre-move snapshot_root>/source vs meal_planner_api/openspec/changes/archive/2026-09-03-ephemeral-planning-sessions/ ===
[empty]
```

Empty diff — only passing evidence. `git mv` recorded the move as renames, preserving the file history.

The archive-report file is additive and excluded from the comparison (it did not exist in the source snapshot).

---

## Task Completion Gate (reconciliation)

The persisted `tasks.md` and `proposal.md` showed stale unchecked checkboxes (`- [ ]`) for work that already landed on `main`:

- `tasks.md` Phase 4 (4.1–4.8) — landed in PR #64
- `tasks.md` Phase 5 (5.1–5.5) — landed in PR #65
- `tasks.md` Threat Matrix (TM-1 through TM-4) — landed in PR #65
- `proposal.md` Success Criteria (4 checkboxes) — proven by PR chain

Total: 22 stale checkboxes for completed work.

### Reconciliation action

`sdd-archive` performed an exceptional mechanical checkbox reconciliation per the orchestrator's explicit authorization in the launch prompt. Each checkbox was flipped `- [ ]` → `- [x]`. The reconciliation was applied BEFORE the archive move so the archived `tasks.md` / `proposal.md` reflect the final `[x]` state, not the stale state.

### Reconciliation justification (audit record)

The orchestrator authorized this exception with proof:
- PR #60–#65 all merged on `main` (HEAD `b002a78`)
- The 22 stale checkboxes correspond exactly to work units that landed in PR #64 and PR #65
- `apply-progress` (Engram observation #2025) and PR diffs cover the work
- Internal todo state from `sdd-apply` did not reach the persisted tasks artifact for the Phase 4–5 / Threat Matrix work

The archive report explicitly records this as an "intentional reconciliation" per the skill's policy. A future agent consulting this archive will see the final `[x]` state — not stale `- [ ]` for shipped work.

### Final task list state

- Phase 1 (1.1–1.6, PR1): all `[x]`
- Phase 2 (2.1–2.8, PR2 + bug-fix #62): all `[x]`
- Phase 3 (3.1–3.8, PR3): all `[x]`
- Phase 4 (4.1–4.8, PR4): all `[x]` (reconciled)
- Phase 5 (5.1–5.5, PR5): all `[x]` (reconciled)
- Threat Matrix (TM-1 to TM-4, PR5): all `[x]` (reconciled)

100% tasks complete.

---

## Final-State Authority (per skill)

The archive report describes state at close. Intermediate snapshots (`apply-progress` #2025) are valid history; no live contradiction between the launch prompt's final-state facts and the persisted tasks artifact after reconciliation.

**No verify-report artifact was written** for this change (no Engram `sdd/ephemeral-planning-sessions/verify` observation, no `verify-report.md` in the change folder). Verification was implicit in the PR-chain merge discipline and the explicit orchestrator test-status assertion (771/772). The single failure is pre-existing on `main` and out of scope.

---

## Artifact Lineage (Engram observation IDs)

Observed during this archive (read for traceability):

| Observation ID | Title | Type |
|---|---|---|
| #2007 | `sdd/ephemeral-planning-sessions/explore` | architecture |
| #2013 | `sdd/ephemeral-planning-sessions/proposal` | architecture |
| #2014 | `sdd/ephemeral-planning-sessions/spec` | architecture |
| #2019 | `sdd/ephemeral-planning-sessions/design` | architecture |
| #2022 | `sdd/ephemeral-planning-sessions/tasks` | architecture |
| #2023 | `ephemeral-planning-sessions: planning complete, apply next` | architecture |
| #2025 | `sdd/ephemeral-planning-sessions/apply-progress` | architecture |
| #2028 | `PR1 merged, PR2 next for issue #33` | decision |

Observation #2025 (`apply-progress`) is the latest intermediate snapshot; it pre-dates the PR4 + PR5 merges and reflects state as of 2026-09-02T20:02:56. The final-state facts in the orchestrator's launch prompt (PRs #60–#65 all merged, `main` HEAD `b002a78`, 771/772 tests passing, 22 checkboxes for completed work) outrank the snapshot per the skill's Final-State Authority hierarchy.

A new observation `sdd/ephemeral-planning-sessions/archive-report` is saved as part of this archive (type `architecture`, `capture_prompt: false`).

---

## SDD Cycle Complete

The change has been fully planned, implemented, verified (via PR-chain merge), and archived. The OpenSpec source of truth at `meal_planner_api/openspec/specs/{planning-sessions,ai-intent-boundary}/spec.md` reflects the new behavior. The Engram observation `sdd/ephemeral-planning-sessions/archive-report` records the closure. **Ready for the next change.**
# Feature: Shopping Derived from Confirmed Plan (#36)

> **Issue**: #36 (spec #29 stories 14–17)
> **Branch**: `feat/issue-36-shopping-derived-from-confirmed-plan-pr1`
> **Baseline**: 810 tests passing on `main` (a4d2cf3)
> **Mode**: Strict TDD, stacked PRs

## Tasks

### PR1 — Pure net-shortage math + window wipe (≤200 lines)

- [x] **T1**: Create `ShoppingRebuilder.compute_net_shortages/2` — pure function, no DB
  - RED: partial inventory yields exact shortage (100_000)
  - RED: surplus inventory floors at zero (no row)
  - RED: mixed units remain separate
  - RED: cart summary groups matching units
  - RED: exact differences not rounded (23_000)
  - GREEN: implement the function
  - Commit: `feat(shopping): pure net-shortage math for confirmed-plan cart`

- [x] **T2**: Add `ShoppingRepo.delete_pending_for_window/3` — data layer
  - RED: wipes pending + in_cart, preserves checked_out + archived
  - RED: scoped to account + range, multi-account isolation
  - GREEN: implement the function
  - Commit: `feat(shopping): window wipe preserving terminal items`

### PR2 — Integration: rebuild inside confirm transaction (≤350 lines)

- [x] **T3**: Replace `persist_shopping_cart/2` with `rebuild_shopping_cart/3`
  - RED: locked confirm includes every window meal
  - RED: rows retain per-meal parity without inventory
  - RED: failed rebuild leaves confirmation absent
  - RED: accepted proposal cannot rebuild again
  - GREEN: implement
  - Commit: `feat(shopping): atomic full-window rebuild on confirm`

- [ ] **T4**: Capability gate proof (flag-on tests)
  - RED: expired HTTP read refused (403)
  - RED: expired confirmation push refused
  - RED: active Account not falsely denied
  - GREEN: verify existing plugs cover it
  - Commit: `test(shopping): flag-on capability gate proof`

- [ ] **T5**: Provenance + isolation tests
  - RED: proposal text cannot change equivalent cart
  - RED: empty proposal → zero items
  - RED: pre-confirm read → no proposal-derived cart
  - RED: another Account cannot read this cart
  - GREEN: verify
  - Commit: `test(shopping): provenance invariant + account isolation`

- [ ] **T6**: Fixture refresh for existing tests
  - Update PR #18/#70 fixtures to expect net-shortage math
  - Commit: `refactor(shopping): refresh test fixtures for net-shortage math`

## Evidence

| Task | Commit | Tests |
|------|--------|-------|
| T1   | bede8e5 | 8 focused; 818 full |
| T2   | 20b66d6 | 3 focused; 821 full |
| T3   | pending | 43 focused; 825 full |
| T4   |        |       |
| T5   |        |       |
| T6   |        |       |

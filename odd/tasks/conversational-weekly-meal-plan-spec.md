# Conversational weekly meal-plan specification

## Objective and scope
Prepare the corrected GitHub Issues publication path for the post-conversation meal plan spec: review existing issue #29, prepare a repository Issue Form, and present the issue text before any publication. The prior local draft is temporary source material, not the final artifact. User explicitly authorized commit, push, and PR for the form only; no issue creation, merge, or implementation.

## Problem and rationale
Current live generation uses server-owned candidates but broad nutritional bounds, does not apply conversational diet/preferences to optimization, and reads an account budget. Several chat/intent entrypoints are not wired to the same planner. A single product contract is needed before implementation.

## Decisions and constraints
- A requested ingredient appears in at least one selected meal during the planning week by default (explicit user choice).
- Excluded ingredients and diet incompatibility are hard candidate-eligibility constraints; inventory/favorites remain soft.
- Account/participant authority stays server-owned; no AI-authored recipe IDs, prices, nutrient numbers, or persistence operations.
- The user corrected the publication target: the to-spec artifact belongs in GitHub Issues, not a repository Markdown file. Keep the prior local draft only as temporary source material until disposition is confirmed.
- GitHub Issues is enabled for `github.com/vicenzogiordana/myfood`, but the default branch currently has no YAML Issue Form. GitHub loads forms from the default branch only; preparing a form is not publishing it.
- Preserve unrelated existing user changes and the current feature branch.
- TDD mode: not applicable to documentation-only scope; source: user request and selected documentation-only route; runner: none. Verification: readback and coverage checklist.
- Delivery strategy: ask-on-risk; the user explicitly authorized the form work-unit commit. Push/PR depend on repository issue-first policy; no merge or issue publication authorization.

## Tasks
- [x] S1 (delegated writer): Draft the local spec with domain vocabulary, hard/soft precedence, conversation-to-plan lifecycle, eligibility, budgeting, infeasibility, safety, and testable acceptance scenarios. Allowed surface: `meal_planner_api/docs/CONVERSATIONAL_MEAL_PLAN_SPEC.md`. Check: every requested preference has acceptance criteria and unresolved decisions are explicit. Route: delegated writer; preparation-for-write trigger.
- [x] S2 (parent structural readback): Verify spec against mapper evidence and conversation decision, check scope and git diff without changing unrelated files. Check: local document exists, no contradictory guarantee or unapproved publication. Route: direct structural check of one document; no executable tests for documentation-only change.
- [x] S3 (delegated writer): Prepare a focused GitHub Spec Issue Form on a new branch/worktree based on `main`, isolated from the existing inventory changes. Check: form YAML has required fields in review order and no implicit labels or first-person affirmation. Route: delegated writer, preparation-for-write trigger.
- [x] S4 (parent): Summarize duplicate analysis of #29, adapt the draft to the form, and show the issue text to the user before publication. Check: no GitHub mutations and explicit note that the form must reach `main` first.
- [x] S5 (parent): Commit only the verified form in the linked worktree, as explicitly authorized. Check: staged scope exactly `.github/ISSUE_TEMPLATE/spec.yml`, commit identity recorded, no unrelated cache files. Route: direct git state/delivery operation.
- [ ] S6 (blocked): Get an approved issue for the form and required PR policy assets/capability before push and PR. Check: linked `status:approved` issue, PR template and matching `type:*` label available, then proceed only through approved branch-pr workflow. Route: blocked on repository policy, no mutation in GitHub.

## Progress
- S1 complete: writer created `meal_planner_api/docs/CONVERSATIONAL_MEAL_PLAN_SPEC.md`, read it back, then corrected budget authority, invalid intents, and exclusion metadata.
- S2 complete: parent read the document and corrected sections, checked requested constraint coverage and scope; `git status --short` shows only the two new documentation/tracking paths for this feature. `git diff --check` returned clean but does not inspect untracked files. Executable tests skipped because this change is documentation-only.
- User corrected target: GitHub Issue, not local spec; no issue has been published.
- #29 is a broad existing planning spec; initial read-only keyword scan suggests it does not specifically cover conversational daily nutrients, ingredient inclusion/exclusion, meal slots and budget. Full duplicate decision must be repeated against the selected form before any GitHub write.
- S3 complete: created isolated linked worktree `../myfood-issue-form` on `docs/spec-issue-form` from `main` and prepared `.github/ISSUE_TEMPLATE/spec.yml` with five required and two optional textareas; writer validated YAML parsing and readback. Untracked form not committed, pushed or merged; default branch still has no form.
- S4 complete: read-only open/closed issue search and private read of #29 and #34 found related broader work but no demonstrated equivalent for all requested constraints. An English preview matching the form fields is ready to present in the response; repeat fresh duplicate classification after form reaches main. No GitHub mutation was performed.
- User explicitly authorized commit, push and PR for form only; no merge or issue publication. `branch-pr` requires an approved linked issue, a PR template, and exactly one `type:*` label. The repo lacks a form-bootstrap issue with `status:approved` and a PR template; `type:chore` exists. #29 is `ready-for-agent`, not approved and is broader planning. S6 blocked; no push/PR.
- Work-unit commit: `58a178b34021ca93a2a58b39677360133fe1dc88` (`chore(issues): add specification issue form`), only `.github/ISSUE_TEMPLATE/spec.yml`, on linked worktree `docs/spec-issue-form`. Ruby YAML parser passed with 5 required fields, `git show --check` passed, independent verifier confirmed exact file scope and 2 optional fields. Runtime harness N/A because GitHub exposes form only from default branch. Rollback boundary: revert only that 61-line form, no unrelated behavior. Native committed assessment was unavailable because tool-created untracked `.pi-lens` files require declaration; inspect excluded untracked but assesses continued failing. No native START was attempted against the unrelated workspace target; separate verification passed. Unrelated inventory changes preserved.

## Next step
Report local commit and blocked delivery prerequisites. A maintainer must bootstrap a proper issue with `status:approved` and a PR template on main before the allowed push/PR path can continue; do not use unrelated #29 as an approval substitute. Issue publication remains separately gated. Temporary local drafts remain untouched.

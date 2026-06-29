# Issue: Standardize structured acceptance criteria in wiggum's planner prompt

## Problem

Wiggum's planner prompt (`run_plan` in `lib/wiggum.sh`) currently mandates a
terse one-line `Acceptance:` per task and a `Files:` line. That per-task
discipline is good and must stay. But plans have no *higher-level*, standardized
acceptance criteria for a phase or the whole deliverable — so the criteria that
decide whether a phase actually works are ad hoc and inconsistent across runs.

## Goal

Make the planner emit a standardized, testable **Acceptance Criteria** section at
the **phase level** (which naturally rolls up to the whole workplan for a
single-phase plan — workplan level is the floor). Keep per-task `Acceptance:`
lines exactly as they are today.

## Requirements

1. **Do not change the per-task `Acceptance:` / `Files:` rules.** They stay terse,
   one-line, observable. This change only *adds* a phase-level section.

2. **New phase-level "Acceptance Criteria" section.** The planner prompt must
   instruct Claude to give each phase an `### Acceptance Criteria` section,
   organized by these four categories:
   - **Happy Path** — the primary flow works as intended.
   - **Edge Cases** — empty / boundary / large inputs.
   - **Error States** — invalid input or a failed/unavailable dependency fails
     safely with a clear error.
   - **Non-Functional** — performance / formatting / accessibility constraints.
     Each non-functional criterion MUST name an *observable check* (a benchmark
     command, a lint rule, a measurable threshold) — never a feeling. This is
     consistent with wiggum's existing "not a feeling ('looks better', 'works
     correctly')" rule.

3. **Given/When/Then is the recommended form, not mandated.** The prompt should
   recommend writing each criterion as "Given <context>, When <action>, Then
   <observable outcome>", but explicitly allow a plain observable pass/fail line
   where Given/When/Then would be overkill.

4. **Implement as a focused prompt helper.** Add a small function in
   `lib/wiggum.sh` (e.g. `prompt_acceptance_criteria`) that returns the new
   instruction text, and call it from `run_plan`'s planner prompt — mirroring the
   existing `prompt_plan_verification` / `prompt_workplan` pattern. Keep the
   function focused and the CLI entry point untouched.

5. **Update the skill documentation in BOTH places, kept in sync.** The
   "Create a wiggum-compatible workplan" section of the skill must document the
   new phase-level Acceptance Criteria section and its four categories. The skill
   text lives in two places that must stay identical:
   - the `wiggum_skill_content()` heredoc in `lib/wiggum.sh`, and
   - the committed copy at `.claude/skills/wiggum/SKILL.md`
     (`setup_wiggum_skill` regenerates this from the heredoc; a Bats test asserts
     the file matches the function output, so update both).

## Acceptance Criteria

### Happy Path
- Given a fresh checkout, When `bats test/wiggum.bats` runs, Then a new test
  asserting the planner prompt contains the phase-level Acceptance Criteria
  instruction (the four category names and the Given/When/Then recommendation)
  passes.
- Given `wiggum_skill_content` output, When grepped, Then it documents the
  phase-level Acceptance Criteria section, and `.claude/skills/wiggum/SKILL.md`
  contains the identical text.

### Edge Cases
- Given the per-task acceptance rules, When the planner prompt is inspected, Then
  the existing per-task `Acceptance:` and `Files:` instructions are still present
  and unchanged (the new section is additive, not a replacement).

### Error States
- Given the non-functional category, When the prompt is inspected, Then it
  requires every non-functional criterion to name an observable check rather than
  a subjective judgment.

### Non-Functional
- Given the codebase, When `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh`
  runs, Then it exits 0 with zero warnings.
- Given the suite, When `./test/run.sh` runs, Then lint and all Bats tests pass
  (exit 0). Existing tests must remain green.
- The new helper must keep `wiggum.sh` (CLI entry point) under 30 lines and follow
  the project's quoting / `set -euo pipefail` conventions.

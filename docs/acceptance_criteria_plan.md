# Workplan: Standardize phase-level Acceptance Criteria in wiggum's planner prompt

Source of truth: `docs/acceptance_criteria.md`. This plan ADDS a standardized,
testable phase-level **Acceptance Criteria** section to the planner's output and
to the skill docs. It does **not** touch the existing terse per-task
`Acceptance:` / `Files:` rules — the change is purely additive.

Key code facts confirmed before planning (do not re-derive — verify if editing):
- `run_plan()` builds the planner prompt inline at `lib/wiggum.sh:1691` via
  `run_claude -p "...$(prompt_workplan ...) ... $(prompt_plan_verification) ..."`.
- Prompt-helper pattern to mirror: `prompt_workplan` (`lib/wiggum.sh:1716`),
  `prompt_plan_verification` (`:1721`), `prompt_implement_verification` (`:1726`).
  Each is a small function that `echo`s one instruction string.
- Skill text lives in the `wiggum_skill_content()` heredoc (`<<'SKILL_EOF'`,
  starts `lib/wiggum.sh:1262`); the "Create a wiggum-compatible workplan" section
  is `lib/wiggum.sh:1348–1380`. `setup_wiggum_skill()` (`:1515`) regenerates the
  committed `.claude/skills/wiggum/SKILL.md` and compares with
  `diff -q <(wiggum_skill_content) "$skill_file"`.
- There is currently **no** Bats test diffing the committed `SKILL.md` against
  `wiggum_skill_content` output — Phase 3 adds one so the two copies stay in sync.
- Tests run via `bats test/wiggum.bats`; lint via
  `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh`; full gate `./test/run.sh`.

To keep the implementer and the tests in agreement, the new instruction text MUST
contain these exact literal strings (tests grep for them): `### Acceptance Criteria`,
`Happy Path`, `Edge Cases`, `Error States`, `Non-Functional`, `Given`, `When`,
`Then`, and `observable check`.

---

## Phase 1: Add the `prompt_acceptance_criteria` helper

- [x] **1.1** Add a focused helper `prompt_acceptance_criteria()` in `lib/wiggum.sh`,
  placed immediately after `prompt_plan_verification()` (around `lib/wiggum.sh:1723`),
  mirroring the existing helper style: a single function that `echo`s one
  instruction string under `set -euo pipefail`, with all expansions quoted. The
  string must instruct Claude to give **each phase** an `### Acceptance Criteria`
  section organized by four categories — `Happy Path` (primary flow works),
  `Edge Cases` (empty / boundary / large inputs), `Error States` (invalid input or
  a failed/unavailable dependency fails safely with a clear error), and
  `Non-Functional` (performance / formatting / accessibility) — where every
  `Non-Functional` criterion MUST name an `observable check` (a benchmark command,
  a lint rule, a measurable threshold), never a feeling. It must **recommend** the
  `Given <context>, When <action>, Then <observable outcome>` form while explicitly
  allowing a plain observable pass/fail line where Given/When/Then is overkill. It
  must state the section is additive (per-task `Acceptance:`/`Files:` lines stay).
  - Depends on: none.
  - Acceptance: `bash -c 'source lib/wiggum.sh; prompt_acceptance_criteria'` exits 0
    and its stdout contains all of `### Acceptance Criteria`, `Happy Path`,
    `Edge Cases`, `Error States`, `Non-Functional`, `Given`, `When`, `Then`, and
    `observable check`.
  - Files: `lib/wiggum.sh`

- [x] **1.2** Wire the helper into the planner prompt: insert
  `$(prompt_acceptance_criteria)` into the `run_claude -p "..."` string in
  `run_plan()` (`lib/wiggum.sh:1691`), after the per-task acceptance sentence and
  alongside `$(prompt_plan_verification)`, so the existing per-task text is kept
  verbatim and the new section instruction is appended.
  - Depends on: 1.1.
  - Acceptance: `grep -n 'prompt_acceptance_criteria' lib/wiggum.sh` shows it called
    inside `run_plan` (a line in the 1659–1708 range) in addition to its definition;
    and the literal substring `'Acceptance:' line stating an observable outcome`
    is still present in that same prompt string (the per-task rule is untouched).
  - Files: `lib/wiggum.sh`

- [x] **1.3** Add a unit test for the helper to `test/wiggum.bats`, modeled on the
  `prompt_plan_verification` tests (`run prompt_acceptance_criteria`; assert with
  `[[ "$output" == *"..."* ]]`). Cover: exit 0, the four category names, the
  Given/When/Then recommendation, and the `observable check` requirement for
  Non-Functional.
  - Depends on: 1.1.
  - Acceptance: `bats test/wiggum.bats -f 'prompt_acceptance_criteria'` runs at least
    one test and all matched tests pass (exit 0).
  - Files: `test/wiggum.bats`

- [x] **1.4** Add a wiring test to `test/wiggum.bats` that proves the helper text
  actually reaches the planner prompt. Stub `claude()` (as other `run_plan` tests
  do) to capture its arguments to a file, invoke `run_plan`, then assert the
  captured prompt contains the four category names AND still contains the
  unchanged per-task string `'Acceptance:' line stating an observable outcome`.
  - Depends on: 1.2.
  - Acceptance: `bats test/wiggum.bats -f 'run_plan.*[Aa]cceptance'` (or the test's
    chosen name) passes (exit 0), asserting both the new section text and the
    preserved per-task text appear in the prompt passed to `claude`.
  - Files: `test/wiggum.bats`

### Acceptance Criteria

**Happy Path**
- Given a fresh checkout, When `bats test/wiggum.bats -f 'prompt_acceptance_criteria'`
  runs, Then the new helper test(s) pass and the prompt advertises the phase-level
  Acceptance Criteria section.
- Given `run_plan` executes with a stubbed `claude`, When the captured prompt is
  inspected, Then it contains the four category names and the Given/When/Then
  recommendation (proves 1.2 wired the helper in).

**Edge Cases**
- Given the planner prompt, When inspected after wiring, Then the existing per-task
  `Acceptance:` sentence (`'Acceptance:' line stating an observable outcome`) and the
  `Files:` requirement from `prompt_plan_verification` are still present verbatim —
  the new section is additive, not a replacement.

**Error States**
- Given the `Non-Functional` category text, When `prompt_acceptance_criteria` output
  is grepped, Then it requires an `observable check` and forbids a subjective
  judgment (a feeling) — `grep -i 'observable check' ` over the output exits 0.

**Non-Functional**
- Given the edited library, When `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh`
  runs, Then it exits 0 with zero warnings.
- Given the helper, When `wiggum.sh` (the CLI entry point) is measured, Then it is
  still under 30 lines: `[ "$(grep -c '' wiggum.sh)" -lt 30 ]` exits 0 (the CLI is
  untouched by this change).

---

## Phase 2: Document the phase-level Acceptance Criteria in the skill (both copies)

- [x] **2.1** Update the "Create a wiggum-compatible workplan" section of the
  `wiggum_skill_content()` heredoc (`lib/wiggum.sh:1348–1380`) to document the new
  phase-level `### Acceptance Criteria` section and its four categories (`Happy Path`,
  `Edge Cases`, `Error States`, `Non-Functional`), noting that Non-Functional
  criteria must name an observable check and that Given/When/Then is the recommended
  (not mandated) form. Keep the existing per-task `Acceptance:`/`Files:` guidance in
  that section unchanged. Edit only inside the heredoc (do not break the `SKILL_EOF`
  quoting or the surrounding markdown).
  - Depends on: 1.1 (so the documented wording matches the helper's wording).
  - Acceptance: `bash -c 'source lib/wiggum.sh; wiggum_skill_content'` exits 0 and its
    stdout contains all of `### Acceptance Criteria`, `Happy Path`, `Edge Cases`,
    `Error States`, and `Non-Functional` within the workplan-creation guidance.
  - Files: `lib/wiggum.sh`

- [x] **2.2** Regenerate the committed skill copy so it is byte-identical to the
  function output: run `bash -c 'source lib/wiggum.sh; wiggum_skill_content' >
  .claude/skills/wiggum/SKILL.md`.
  - Depends on: 2.1.
  - Acceptance: `diff <(bash -c 'source lib/wiggum.sh; wiggum_skill_content')
    .claude/skills/wiggum/SKILL.md` produces no output and exits 0; and
    `grep -q '### Acceptance Criteria' .claude/skills/wiggum/SKILL.md` exits 0.
  - Files: `.claude/skills/wiggum/SKILL.md`

- [x] **2.3** Add a Bats test asserting `wiggum_skill_content` documents the new
  section: `run wiggum_skill_content`, then assert the output contains
  `### Acceptance Criteria` and the four category names.
  - Depends on: 2.1.
  - Acceptance: `bats test/wiggum.bats -f 'wiggum_skill_content'` passes (exit 0),
    including a test that checks for the phase-level Acceptance Criteria wording.
  - Files: `test/wiggum.bats`

- [x] **2.4** Add a Bats sync test that pins the two copies together: assert the
  committed `.claude/skills/wiggum/SKILL.md` (resolved from the repo root, e.g. via
  `$BATS_TEST_DIRNAME/..`) is identical to `wiggum_skill_content` output, using
  `diff -q <(wiggum_skill_content) "<repo>/.claude/skills/wiggum/SKILL.md"`. This is
  the test referenced by requirement #5 and does not exist yet.
  - Depends on: 2.2.
  - Acceptance: `bats test/wiggum.bats -f 'SKILL.md.*sync|in sync|matches'` (or the
    test's chosen name) passes (exit 0); deliberately editing the committed file
    afterward would make it fail (the diff is real, not a tautology).
  - Files: `test/wiggum.bats`

### Acceptance Criteria

**Happy Path**
- Given `wiggum_skill_content` output, When grepped, Then it documents the
  phase-level Acceptance Criteria section and its four categories, and the committed
  `.claude/skills/wiggum/SKILL.md` contains the identical text (the sync diff is
  empty).

**Edge Cases**
- Given a large skill heredoc, When `wiggum_skill_content` is regenerated to the
  committed file, Then no other section is altered: the only added content is the
  Acceptance Criteria documentation (existing `setup_wiggum_skill` grep tests for
  `wiggum execute`, `Preflight`, `--background`, etc. still pass).

**Error States**
- Given the two skill copies drifting, When the new sync test runs, Then it fails
  loudly via `diff` rather than silently passing — verified by the test failing if
  the committed file is hand-edited out of sync.

**Non-Functional**
- Given the documentation edit, When `shellcheck -s bash wiggum.sh lib/wiggum.sh
  install.sh` runs, Then it exits 0 with zero warnings (heredoc edits must not
  introduce shell issues).

---

## Phase 3: Full-suite verification and commit

- [x] **3.1** Run the lint gate and confirm zero warnings.
  - Depends on: 1.1, 1.2, 2.1, 2.2.
  - Acceptance: `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh` exits 0 and
    prints no warnings.
  - Files: *(none — verification only)*

- [x] **3.2** Run the full suite and confirm every test (existing + new) passes.
  - Depends on: 1.3, 1.4, 2.3, 2.4, 3.1.
  - Acceptance: `./test/run.sh` exits 0 (lint passes, then all Bats tests including
    the new ones pass; no existing test regressed).
  - Files: *(none — verification only)*

- [x] **3.3** Confirm the change stayed additive and within structural limits.
  - Depends on: 3.2.
  - Acceptance: `grep -q "'Acceptance:' line stating an observable outcome"
    lib/wiggum.sh` exits 0 (per-task rule intact); `prompt_plan_verification` still
    emits the `'Files:' line` text (`bash -c 'source lib/wiggum.sh;
    prompt_plan_verification' | grep -q "'Files:' line"` exits 0); and
    `[ "$(grep -c '' wiggum.sh)" -lt 30 ]` exits 0 (CLI entry point under 30 lines).
  - Files: *(none — verification only)*

### Acceptance Criteria

**Happy Path**
- Given all phases are complete, When `./test/run.sh` runs from a clean tree, Then it
  exits 0 with lint clean and the full Bats suite green.

**Edge Cases**
- Given previously-passing tests, When the suite is re-run, Then none of the existing
  `run_plan`, `prompt_plan_verification`, or `setup_wiggum_skill` tests regress.

**Error States**
- Given a residual drift between the helper text, the skill heredoc, and the
  committed `SKILL.md`, When the suite runs, Then the sync test (2.4) and the
  wiring test (1.4) fail rather than passing silently — so any inconsistency is
  caught before commit.

**Non-Functional**
- Given the finished change, When `shellcheck -s bash wiggum.sh lib/wiggum.sh
  install.sh` runs, Then it exits 0 with zero warnings.
- Given the project's commit discipline, When the work passes `./test/run.sh`, Then
  `lib/wiggum.sh`, `test/wiggum.bats`, and `.claude/skills/wiggum/SKILL.md` are
  committed together as one logical change with a short imperative single-line
  message (no prefixes, no trailers): `git log -1 --pretty=%s` shows one line and
  `git show --stat HEAD` lists those files.

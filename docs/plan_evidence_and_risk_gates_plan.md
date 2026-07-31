# Workplan: Diagnosis evidence and risk gates in the planner prompt

Source issue: `docs/plan_evidence_and_risk_gates.md`.

## Constraints

**In scope**

- Extend `prompt_plan_verification` (`lib/wiggum.sh:1752`) with two universal rules:
  `path:line` evidence for every claim about current behaviour, and test-task
  feasibility (read the target test file's harness before planning a test in it).
- Add three new single-concern prompt helpers in `lib/wiggum.sh`:
  `prompt_defect_diagnosis` (conditional), `prompt_risk_gates` (universal),
  `prompt_phase_sequencing` (universal).
- Add one predicate helper, `input_describes_defect`, that inspects the plan input
  files so the defect text is emitted only for defect-shaped input.
- Wire all of the above into `run_plan`'s prompt (`lib/wiggum.sh:1717`) and print a
  stderr line saying whether the diagnosis sections were enabled.
- Add Bats coverage for every new helper, for the detector (both directions), for
  the `run_plan` wiring, and for prompt size.
- Update the plan-format documentation in **both** copies that must stay identical:
  the `wiggum_skill_content()` heredoc (`lib/wiggum.sh:1348-1404`) and the committed
  `.claude/skills/wiggum/SKILL.md`.

**Out of scope**

- Changing `prompt_workplan`, `prompt_constraints_summary`, `prompt_acceptance_criteria`,
  `prompt_implement_verification`, or `prompt_commit`. Their text stays byte-identical.
- Changing the implementation/validation/commit loop (`run_execute`, `run_validation`),
  the checkbox-counting regex (`WIGGUM_TASK_PREFIX`, `lib/wiggum.sh:808`), or any CLI flag.
- README changes: README documents plan *structure* generically (`README.md:61-62`) and
  does not enumerate the planner prompt rules, so it needs no edit. (Confirmed by grep:
  `prompt_`, `## Constraints`, and `Acceptance Criteria` have no README hits.)
- Enforcing the new rules mechanically (no linter that parses produced plans for
  `## Symptoms`). This change is prompt text plus its tests.

**Never do**

- Do not modify `.wiggumrc`, `.wiggumrc.example`, or any user config to make verification pass.
- Do not weaken, skip, or delete an existing Bats test to accommodate new prompt text.
  If the `run_plan` wiring test (`test/wiggum.bats:2547`) fails, the prompt regressed —
  fix the prompt, not the assertion.
- Do not make the defect sections mandatory for every plan; a greenfield feature plan
  must not be pushed into inventing symptoms.
- Do not break the SKILL.md sync invariant (`test/wiggum.bats:1775`): the heredoc and the
  committed file must stay identical, and the file must be regenerated from the function,
  never hand-edited to "look close enough".
- Do not exceed 30 lines in `wiggum.sh` (currently 86 lines and untouched by this work —
  leave it alone rather than "fixing" it here).

## Evidence

Every claim this plan makes about current behaviour, with the line that proves it:

- The planner prompt is one string built from helpers — `lib/wiggum.sh:1717`.
- Existing helpers and their current text — `prompt_workplan` `lib/wiggum.sh:1742`,
  `prompt_constraints_summary` `:1747`, `prompt_plan_verification` `:1752`,
  `prompt_acceptance_criteria` `:1757`, `PROMPT_SUFFIX` `:1739`.
- `prompt_plan_verification` today covers only `Files:` + "confirm the APIs exist" —
  `lib/wiggum.sh:1753`. No citation rule exists anywhere in the file.
- Plan-mode positional inputs are validated to be existing files inside the project —
  `lib/wiggum.sh:775-791`; free text arrives via stdin and is written to a real temp
  file that is appended to `FILES` — `lib/wiggum.sh:763-770`. Therefore every element of
  `FILES` is a readable file and a content-based detector is feasible.
- Skill plan-format section that must be updated — `lib/wiggum.sh:1348-1404`.
- The heredoc/file sync is asserted by `diff <(wiggum_skill_content) "$committed"` —
  `test/wiggum.bats:1775-1781`.
- Existing prompt-helper test conventions (`run <helper>`, `[[ "$output" == *"..."* ]]`) —
  `test/wiggum.bats:1638-1729`.
- The prompt-capture pattern for `run_plan` (stub `claude` writing `"$@"` to a file) —
  `test/wiggum.bats:2547-2577`.
- Verification for this repo is shellcheck + bats, run together by `./test/run.sh` —
  `.wiggumrc:2-3`, `test/run.sh:8,14`.
- Measured baseline: the current planner prompt is ~2.5k characters
  (`prompt_plan_verification` 316 bytes, `prompt_acceptance_criteria` 860 bytes),
  which is what the size thresholds in Phase 5 are calibrated against.

## Design decisions

- **Requirement 5 (test-task feasibility) lands in `prompt_plan_verification`**, not a
  new helper: it is a "verify the assumption before you assert it" rule, the same concern
  that helper already owns.
- **Requirement 6 (sequencing) gets its own helper** `prompt_phase_sequencing` rather than
  being folded into `prompt_risk_gates`, to keep each helper single-concern per
  requirement 7.
- **Conditionality is real, not advisory.** `input_describes_defect` gates whether
  `prompt_defect_diagnosis` text is interpolated at all, so a feature plan's prompt grows
  by the universal rules only. The defect text *also* carries a "skip these sections if the
  input is not actually a defect" clause, because the detector is a heuristic.

---

## Phase 1: Evidence and test-feasibility rules (universal)

- [x] Extend `prompt_plan_verification` with the `path:line` evidence rule: every statement
      the plan makes about *current* behaviour must cite its source as `path:line`, and the
      planner must have read that line before citing it; state that this complements the
      `Files:` line (files the task will write) by covering the files the plan read to
      justify itself.
      Acceptance: `bats test/wiggum.bats -f "prompt_plan_verification"` passes and
      `bash -c 'source lib/wiggum.sh; prompt_plan_verification'` output contains `path:line`
      and `read that line`.
      Files: `lib/wiggum.sh`
- [x] Extend `prompt_plan_verification` with the test-task feasibility sentence: before
      specifying a task that adds a test to an existing file, read that file's harness —
      module-scope mocks (`vi.mock`, `jest.mock`, fixtures, monkeypatching) are hoisted per
      file and can make the intended test impossible there; the task must state whether the
      test can live in that file or needs a new one, and must never plan to weaken an
      existing mock to fit.
      Acceptance: helper output contains `module-scope mocks`, `vi.mock`, and
      `needs a new one`; the same command as above exits 0.
      Files: `lib/wiggum.sh`
      Depends on: previous task (same function body).
- [x] Add Bats tests `prompt_plan_verification: requires path:line citations for current
      behaviour` and `prompt_plan_verification: requires checking test-file harness
      feasibility`, placed in the existing prompt-helper block near
      `test/wiggum.bats:1640`.
      Acceptance: `bats test/wiggum.bats` reports the two new tests as `ok` and 0 failures.
      Files: `test/wiggum.bats`
      Depends on: both tasks above.
- [x] Confirm the two pre-existing `prompt_plan_verification` tests
      (`test/wiggum.bats:1640`, `:1647`) still pass unmodified — the change is additive, so
      neither assertion may be edited.
      Acceptance: `git diff test/wiggum.bats` shows no deletions or modifications inside
      lines 1640-1651 (additions only), and `bats test/wiggum.bats -f "prompt_plan_verification"`
      exits 0.
      Files: `test/wiggum.bats` (verification only, no edit expected)

### Acceptance Criteria

**Happy Path**
- Given a sourced `lib/wiggum.sh`, When `prompt_plan_verification` runs, Then its output
  contains the original `'Files:' line` / `actually exist` text *and* the new `path:line`
  and `module-scope mocks` rules, and it exits 0.

**Edge Cases**
- Given a plan whose tasks only create new files, When the citation rule is read, Then it
  applies to claims about current behaviour only, so a greenfield task with no such claim
  needs no citation (the rule text is scoped to "statements about current behaviour", not
  "every sentence").
- Given a helper invoked in a subshell under `set -u` with no arguments, When it runs, Then
  it exits 0 (it takes no parameters).

**Error States**
- Given the additive constraint, When any existing assertion in `test/wiggum.bats:1640-1651`
  is changed or removed, Then this phase is not done: `git diff` must show additions only.

**Non-Functional**
- Observable check: `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh` exits 0 with no
  output.
- Observable check: `prompt_plan_verification | wc -c` stays under 1200 bytes (baseline 316;
  the two rules must be tight, since this text is paid on every plan run).

---

## Phase 2: `prompt_risk_gates` and `prompt_phase_sequencing` (universal)

- [x] Add `prompt_risk_gates()` to `lib/wiggum.sh` next to the other prompt templates
      (after `prompt_acceptance_criteria`, ~`lib/wiggum.sh:1759`), emitting the four gates:
      (1) measure before you act — if a phase is justified by a claim about production data
      or runtime state, the first phase is a read-only measurement of that claim and each
      dependent phase states the result that would make it unnecessary; (2) activating
      never-run code is not a no-op — precede it with a read-only impact report over real
      inputs whose reviewed result gates shipping; (3) irreversible tasks carry four
      conditions — default to a dry run, export affected rows before the first real write,
      be idempotent, record the affected count per scope; (4) a new guard must pass on a
      clean tree — enumerate legitimate exceptions up front, and its acceptance states the
      guard passes against current code on its first run and fails when the defect is
      reintroduced.
      Acceptance: `bash -c 'source lib/wiggum.sh; prompt_risk_gates'` exits 0 and its output
      contains `read-only measurement`, `never`, `dry run`, `export`, `idempotent`,
      `affected count`, `legitimate exceptions`, and `first run`.
      Files: `lib/wiggum.sh`
- [x] Add `prompt_phase_sequencing()` emitting the sequencing rule: after the phases, state
      which phases can ship independently and which must wait, with the reason; note that
      this is distinct from the per-task dependency list, and give the discriminator
      (fixes that only turn nulls into values ship freely; fixes that can delete good data
      wait for a measurement).
      Acceptance: `bash -c 'source lib/wiggum.sh; prompt_phase_sequencing'` exits 0 and
      output contains `ship independently`, `must wait`, and `not the task-dependency list`.
      Files: `lib/wiggum.sh`
- [x] Wire both helpers into `run_plan`'s prompt string (`lib/wiggum.sh:1717`) after
      `$(prompt_acceptance_criteria)` and before the `Use the Write tool` clause, keeping
      every existing clause byte-identical.
      Acceptance: `grep -c 'prompt_risk_gates\|prompt_phase_sequencing' lib/wiggum.sh`
      returns at least 4 (2 definitions + 2 call sites) and
      `grep -n "'Acceptance:' line stating an observable outcome" lib/wiggum.sh` still
      matches inside `run_plan`.
      Files: `lib/wiggum.sh`
      Depends on: the two helper tasks above.
- [x] Add Bats tests for both helpers (`prompt_risk_gates: names the four risk gates`,
      `prompt_risk_gates: irreversible tasks carry all four conditions`,
      `prompt_phase_sequencing: separates ship-independence from task dependencies`) in the
      prompt-helper block.
      Acceptance: `bats test/wiggum.bats -f "prompt_risk_gates|prompt_phase_sequencing"`
      reports 3 passing tests, 0 failures.
      Files: `test/wiggum.bats`
      Depends on: the two helper tasks above.
- [x] Extend the existing `run_plan` wiring test (`test/wiggum.bats:2547`) — by adding
      assertions, not replacing any — so the captured prompt contains the risk-gate and
      sequencing text alongside the existing checkbox/`Acceptance:`/`Files:`/`## Constraints`
      assertions.
      Acceptance: `bats test/wiggum.bats -f "run_plan"` exits 0, and the test file's captured
      prompt assertions include `grep -q 'dry run' "$captured"` and
      `grep -q 'ship independently' "$captured"`.
      Files: `test/wiggum.bats`
      Depends on: the wiring task above.

### Acceptance Criteria

**Happy Path**
- Given `run_plan` with a stubbed `claude` that captures `"$@"`, When it runs on any input,
  Then the captured prompt contains all four risk gates and the sequencing rule, and the
  plan file is still written (`run_plan` exits 0).

**Edge Cases**
- Given a plan with no destructive task and no production-data claim, When the gate text is
  read, Then each gate is conditional ("if a task…", "if a phase is justified by…"), so no
  extra phase is mandated — verified by asserting the helper text contains `If` /
  conditional phrasing for each gate rather than an unconditional "always add a phase".
- Given a very long file list, When `run_plan` builds the prompt, Then the new helpers are
  appended once, not per file (`grep -c 'dry run' "$captured"` equals 1).

**Error States**
- Given a task that rewrites data, When the prompt is inspected, Then all four conditions
  (dry run, export, idempotent, recorded count) appear — a test asserts each of the four
  substrings independently, so naming only the dry run fails the suite.
- Given the guard gate, When the prompt is inspected, Then it requires the guard to pass on
  the current clean tree *and* fail when the defect is reintroduced (both halves asserted).

**Non-Functional**
- Observable check: `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh` exits 0.
- Observable check: `prompt_risk_gates | wc -c` under 2000 bytes and
  `prompt_phase_sequencing | wc -c` under 600 bytes.
- Observable check: `bats test/wiggum.bats` total runtime stays under 120s
  (`time bats test/wiggum.bats`), i.e. the added tests are content assertions, not new
  `claude` round-trips.

---

## Phase 3: `prompt_defect_diagnosis` behind an input detector (conditional)

- [x] Add `input_describes_defect()` to `lib/wiggum.sh` (near `looks_like_plan`,
      `lib/wiggum.sh:931`): takes file paths as arguments, returns 0 if any *readable* file
      matches a case-insensitive extended regex of strong defect signals
      (`bug|defect|regression|broken|breaks|crash|traceback|stack ?trace|incident|steps to
      reproduce|no longer|used to work|silently|wrong|incorrect|misreport`), else 1.
      Deliberately exclude weak words (`error`, `fail`, `missing`, `null` alone) that appear
      in ordinary feature specs. Guard unreadable/absent paths so the function never emits
      grep noise, and handle an empty argument list under `set -u`.
      Acceptance: `bats test/wiggum.bats -f "input_describes_defect"` passes; specifically a
      file containing `This is a Bug: the column is wrong` returns 0 and a file containing
      `Add a CSV export button to the reports page` returns 1.
      Files: `lib/wiggum.sh`
- [x] Add Bats tests for the detector covering: defect-shaped file → 0; feature-shaped file
      → 1; empty file → 1; nonexistent path → 1 with no stderr output; mixed list where only
      the second file is defect-shaped → 0; capitalized signal (`Bug`) → 0.
      Acceptance: `bats test/wiggum.bats -f "input_describes_defect"` reports 6 passing
      tests, 0 failures.
      Files: `test/wiggum.bats`
      Depends on: the detector task.
- [x] Add `prompt_defect_diagnosis()` emitting the four required sections that must precede
      the phases: `## Symptoms` (observable, in the terms of whoever sees it, each symptom
      tagged **observed** or **predicted**, and naming the *tell* that separates this defect
      from the benign explanation), `## Root cause` (numbered path from entry point to
      failure, each step carrying its `path:line`), `## Why existing verification missed it`
      (name the blind spot citing the tests that pass; say so if a passing test pins the
      buggy behaviour), and `## Blast radius` (what is affected and explicitly what is
      unaffected and why). End with the skip clause: if the input is not actually a defect,
      omit these sections rather than inventing symptoms.
      Acceptance: `bash -c 'source lib/wiggum.sh; prompt_defect_diagnosis'` exits 0 and
      output contains `## Symptoms`, `observed`, `predicted`, `tell`, `## Root cause`,
      `## Why existing verification missed it`, `## Blast radius`, `unaffected`, and a skip
      clause matching `not .* defect`.
      Files: `lib/wiggum.sh`
- [x] Add Bats tests for `prompt_defect_diagnosis` (`names the four diagnosis sections`,
      `requires every symptom tagged observed or predicted`, `requires the tell`,
      `requires path:line for each root-cause step`, `permits skipping for non-defect work`).
      Acceptance: `bats test/wiggum.bats -f "prompt_defect_diagnosis"` reports 5 passing
      tests, 0 failures.
      Files: `test/wiggum.bats`
      Depends on: the helper task.
- [ ] Wire the conditional into `run_plan`: build a local `defect_rules` variable that is
      `"$(prompt_defect_diagnosis) "` when `input_describes_defect "${FILES[@]}"` succeeds
      and empty otherwise, interpolate it right after `$(prompt_constraints_summary)`, and
      echo to stderr `Diagnosis sections: enabled (input looks like a defect report)` or
      `Diagnosis sections: skipped (input does not look like a defect report)` next to the
      existing `Input files:` line (`lib/wiggum.sh:1697`).
      Acceptance: with a stubbed `claude`, `run_plan` on a defect-shaped input prints
      `Diagnosis sections: enabled` to stderr and the captured prompt contains `## Symptoms`;
      on a feature-shaped input it prints `Diagnosis sections: skipped` and the captured
      prompt does **not** contain `## Symptoms`.
      Files: `lib/wiggum.sh`
      Depends on: the detector and the `prompt_defect_diagnosis` helper.
- [ ] Add two `run_plan` Bats tests — `run_plan: includes the diagnosis sections for
      defect-shaped input` and `run_plan: omits the diagnosis sections for a feature request`
      — using the existing capture pattern (`test/wiggum.bats:2547`), asserting both the
      prompt content and the stderr line.
      Acceptance: `bats test/wiggum.bats -f "run_plan"` exits 0 with the two new tests
      passing.
      Files: `test/wiggum.bats`
      Depends on: the wiring task.

### Acceptance Criteria

**Happy Path**
- Given an issue file reading "Login crashes after deploy — the traceback points at
  session.py", When `wiggum plan` builds the prompt, Then the prompt contains all four
  diagnosis sections and stderr shows `Diagnosis sections: enabled`.

**Edge Cases**
- Given a feature request with no defect signal, When the prompt is built, Then it contains
  no `## Symptoms` text at all and stderr shows `Diagnosis sections: skipped` — the planner
  is never asked to invent symptoms.
- Given an empty input file (0 bytes) or a path that no longer exists, When the detector
  runs, Then it returns 1 and writes nothing to stderr.
- Given several input files where only one is defect-shaped, When the detector runs, Then it
  returns 0.

**Error States**
- Given the observed/predicted rule, When the emitted prompt is inspected, Then it requires
  *every* symptom to be tagged, so an unverified symptom cannot be presented as observed
  (asserted on both the words `observed` and `predicted` plus the tagging instruction).
- Given `set -u` and an empty `FILES` array, When `input_describes_defect` is called with no
  arguments, Then it returns 1 instead of erroring (`run input_describes_defect;
  [ "$status" -eq 1 ]`).

**Non-Functional**
- Observable check: `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh` exits 0 —
  including the `${FILES[@]+"${FILES[@]}"}` expansion used at the call site.
- Observable check: the detector reads input files at most once per run
  (`grep -c 'grep -' ` in the function body shows a single scan loop) and adds no measurable
  time: `time bats test/wiggum.bats` stays under 120s.

---

## Phase 4: Skill documentation, both copies in sync

- [ ] Update the "Create a wiggum-compatible workplan" section of the
      `wiggum_skill_content()` heredoc (`lib/wiggum.sh:1348-1404`): extend the plan skeleton
      with the optional `## Symptoms` / `## Root cause` / `## Why existing verification
      missed it` / `## Blast radius` block (marked "defect work only"), and add "Rules for a
      good plan" bullets for the `path:line` evidence rule, the four risk gates, the
      test-file feasibility check, and the closing ship-independence note.
      Acceptance: `bash -c 'source lib/wiggum.sh; wiggum_skill_content' | grep -c
      '## Symptoms\|## Blast radius\|path:line\|dry run\|ship independently'` returns 5 or
      more.
      Files: `lib/wiggum.sh`
      Depends on: Phases 1-3 (the documented wording must match the shipped prompt text).
- [ ] Regenerate the committed skill file from the function rather than hand-editing:
      `bash -c 'source lib/wiggum.sh; wiggum_skill_content' > .claude/skills/wiggum/SKILL.md`.
      Acceptance: `diff <(bash -c 'source lib/wiggum.sh; wiggum_skill_content')
      .claude/skills/wiggum/SKILL.md` exits 0 with no output, and
      `bats test/wiggum.bats -f "stays in sync"` passes.
      Files: `.claude/skills/wiggum/SKILL.md`
      Depends on: the heredoc task.
- [ ] Add Bats tests `wiggum_skill_content: documents the defect diagnosis sections` and
      `wiggum_skill_content: documents the risk gates`, mirroring the existing
      `wiggum_skill_content: documents the phase-level Acceptance Criteria section`
      (`test/wiggum.bats:1758`).
      Acceptance: `bats test/wiggum.bats -f "wiggum_skill_content"` exits 0 with the two new
      tests passing.
      Files: `test/wiggum.bats`
      Depends on: the heredoc task.
- [ ] Verify the skill's existing invariants survive the edit: front matter intact,
      `$ARGUMENTS` present, no `disable-model-invocation`, and the CLI table untouched.
      Acceptance: `bats test/wiggum.bats -f "skill"` exits 0 (all pre-existing skill tests
      at `test/wiggum.bats:1733-1870` pass unmodified).
      Files: `test/wiggum.bats` (verification only)
      Depends on: the regeneration task.

### Acceptance Criteria

**Happy Path**
- Given a fresh checkout, When `wiggum_skill_content` is grepped, Then it documents the
  defect sections and the risk gates, and `.claude/skills/wiggum/SKILL.md` contains the
  identical text (`diff` exits 0).

**Edge Cases**
- Given a repo with no `.claude/skills/wiggum/SKILL.md`, When `setup_wiggum_skill` runs with
  `y`, Then the file is created containing the new sections
  (`grep -q '## Blast radius' .claude/skills/wiggum/SKILL.md`).
- Given an older skill file on disk, When it is overwritten via the documented regeneration
  command, Then the stale content is gone (`! grep -q 'old skill v0'`).

**Error States**
- Given a hand-edited SKILL.md that drifts from the heredoc by even one character, When
  `bats test/wiggum.bats -f "stays in sync"` runs, Then it fails — the invariant must remain
  enforced, not relaxed.

**Non-Functional**
- Observable check: the heredoc stays a quoted `<<'SKILL_EOF'` heredoc, so
  `shellcheck -s bash lib/wiggum.sh` exits 0 and no `$`/backtick in the new doc text is
  expanded (`grep -q '\$ARGUMENTS' .claude/skills/wiggum/SKILL.md` still passes).
- Observable check: the skill file stays under 400 lines
  (`wc -l < .claude/skills/wiggum/SKILL.md`), so the added documentation is bounded.

---

## Phase 5: Whole-suite verification, prompt budget, and commit

- [ ] Add a prompt-size Bats test `run_plan: feature-request prompt stays within budget`
      that captures the prompt for a non-defect input and asserts
      `[ "$(wc -c < "$captured")" -lt 6000 ]`, plus a companion asserting the defect-mode
      prompt is under 9000 characters and strictly larger than the feature-mode prompt.
      Acceptance: `bats test/wiggum.bats -f "budget"` exits 0; the thresholds are checked
      against the measured baseline (~2.5k today).
      Files: `test/wiggum.bats`
      Depends on: Phases 1-3.
- [ ] Run the lint gate exactly as configured: `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh`.
      Acceptance: command exits 0 and prints nothing.
      Files: none (verification only)
      Depends on: Phases 1-4.
- [ ] Run the full suite: `./test/run.sh`.
      Acceptance: exits 0, prints `Lint passed.`, and the bats summary shows 0 failures with
      a test count strictly greater than the pre-change count (record both numbers in the
      commit-time notes).
      Files: none (verification only)
      Depends on: the lint task.
- [ ] Sanity-check the real planner end to end without spending a Claude call: source the
      library, set `FILES` to the source issue `docs/plan_evidence_and_risk_gates.md`, stub
      `claude` to capture `"$@"`, and confirm the captured prompt contains the diagnosis
      sections (that issue is defect-shaped), the risk gates, the citation rule, and every
      pre-existing clause.
      Acceptance: the capture contains `## Symptoms`, `dry run`, `path:line`,
      `'Acceptance:' line stating an observable outcome`, and `## Constraints`; the command
      exits 0.
      Files: none (verification only)
      Depends on: the full-suite task.
- [ ] Commit lib, tests, and the regenerated skill file together as one logical change with
      a short single-line imperative message (no prefixes, no trailers), per `CLAUDE.md`.
      Acceptance: `git status --porcelain` is empty afterwards and
      `git log -1 --pretty=%s` prints a single-line message with no `:` prefix and no
      `Co-Authored-By` in `git log -1 --pretty=%B`.
      Files: `lib/wiggum.sh`, `test/wiggum.bats`, `.claude/skills/wiggum/SKILL.md`
      Depends on: all tasks above.

### Acceptance Criteria

**Happy Path**
- Given a fresh checkout with the change applied, When `./test/run.sh` runs, Then lint and
  all Bats tests pass (exit 0) and every new helper test is green.

**Edge Cases**
- Given the piped mode (`wiggum plan issue.md | …`), When `run_plan` runs with the new
  stderr diagnosis line, Then stdout still contains only the plan content — the existing
  tests `run_plan: outputs plan file content to stdout when piped` and
  `run_plan: piped mode suppresses claude stdout` (`test/wiggum.bats:2433`, `:2525`) still
  pass, proving the new line went to stderr.
- Given an input file of zero bytes reaching `run_plan`, When the prompt is built, Then no
  crash occurs and diagnosis sections are skipped (exit status governed by the existing
  empty-plan error path).

**Error States**
- Given a deliberately reintroduced regression (delete `path:line` from
  `prompt_plan_verification`), When `bats test/wiggum.bats` runs, Then it fails with a named
  test — verifying the new tests actually bind. Restore the text afterwards and re-run to
  green.
- Given a failing verify step, When `./test/run.sh` exits non-zero, Then no commit is made;
  the commit task is gated on a green suite, and `.wiggumrc` must not be edited to get there.

**Non-Functional**
- Observable check: `time ./test/run.sh` completes in under 180s on this repo.
- Observable check: `wc -l < wiggum.sh` is unchanged (86) — the CLI entry point is not
  touched by this work.
- Observable check: the non-defect planner prompt is under 6000 characters and the
  defect-mode prompt under 9000, asserted by the budget tests above.

---

## Sequencing — what can ship independently

- **Phase 1 ships alone.** It only adds instruction text to an existing universal helper;
  nothing downstream depends on it and no behaviour outside the planner prompt changes.
- **Phase 2 ships alone**, independently of Phase 1. Both are additive text plus tests; they
  touch adjacent lines in `lib/wiggum.sh` but no shared state.
- **Phase 3 ships alone but is the only phase with real conditional logic.** It is the one
  that can regress existing behaviour (a too-broad detector makes every feature plan pay for
  the defect text; a broken expansion breaks `run_plan` under `set -u`). It must not ship
  until its own detector tests pass in both directions and the prompt-budget test from
  Phase 5 is green — a passing "enabled" test alone is not enough, because the failure mode
  here is over-firing, not under-firing.
- **Phase 4 must wait for Phases 1-3.** The skill documentation states the rules the prompt
  actually emits; documenting wording that later changes would land the two copies out of
  sync with the shipped behaviour even though the `diff` sync test would still pass (that
  test compares the file to the heredoc, not the heredoc to the prompt).
- **Phase 5 must wait for everything.** It is the gate, not a step: the commit task is the
  last thing that runs, and only on a green `./test/run.sh`.
- No phase in this plan deletes or rewrites data, activates a never-run code path in
  production, or adds a repo-wide guard, so the corresponding risk gates apply vacuously —
  they are documented here as "not triggered", not silently omitted.

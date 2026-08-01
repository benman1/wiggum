# Execution summary: Diagnosis evidence and risk gates in the planner prompt

Plan: `docs/plan_evidence_and_risk_gates_plan.md` (24 tasks, 5 phases — all complete).
Source issue: `docs/plan_evidence_and_risk_gates.md`.
Commit range: `08587ab..c232758`.

## Why execution stopped

Complete. Every task in all five phases is checked, the Phase 5 gate (`./test/run.sh`)
is green, and the work is committed with a clean tree. Nothing remains pending.

## What was implemented

**Phase 1 — evidence and test-feasibility rules (universal).**
`prompt_plan_verification` (`lib/wiggum.sh:1829`) gained two rules on top of its existing
`Files:`/"APIs exist" text: every claim about *current* behaviour must cite `path:line` and
the planner must have read that line; and before planning a test into an existing file, the
planner must read that file's harness, because module-scope mocks (`vi.mock`, `jest.mock`,
fixtures, monkeypatching) are hoisted per file and can make the intended test impossible
there. Both pre-existing assertions were left untouched — the change is additive.

**Phase 2 — risk gates and sequencing (universal).**
Two new single-concern helpers: `prompt_risk_gates` (`:1839`) emitting the four gates
(measure before you act; activating never-run code is not a no-op; irreversible tasks carry
dry run + export + idempotence + recorded affected count; a new guard must pass on a clean
tree and fail when the defect is reintroduced), and `prompt_phase_sequencing` (`:1844`)
requiring a closing statement of which phases ship independently and which must wait, kept
explicitly distinct from the per-task dependency list. Both wired into `run_plan`'s prompt
after `prompt_acceptance_criteria`, with every pre-existing clause byte-identical.

**Phase 3 — conditional defect diagnosis.**
`input_describes_defect` (`:946`) scans the plan's input files for strong defect signals
(`bug|defect|regression|broken|crash|traceback|steps to reproduce|no longer|used to work|…`),
deliberately excluding weak words (`error`, `fail`, `missing`) that appear in ordinary feature
specs; it is quiet and returns 1 on unreadable, absent, or empty inputs, and survives an empty
`FILES` array under `set -u` via `${FILES[@]+"${FILES[@]}"}`. It gates whether
`prompt_defect_diagnosis` (`:1850`) — `## Symptoms` (each tagged **observed**/**predicted**,
naming the *tell*), `## Root cause` (numbered, each step with `path:line`), `## Why existing
verification missed it`, `## Blast radius` (including what is *unaffected*) — is interpolated
at all. `run_plan` prints `Diagnosis sections: enabled|skipped` to stderr beside `Input files:`.
Conditionality is real, not advisory: a feature plan's prompt never carries the defect text.

**Phase 4 — skill documentation, both copies in sync.**
The `wiggum_skill_content()` heredoc gained the optional defect-diagnosis block (marked
"defect work only") plus "Rules for a good plan" bullets for the citation rule, the four risk
gates, the test-file feasibility check, and the ship-independence note.
`.claude/skills/wiggum/SKILL.md` was **regenerated from the function**, never hand-edited.

**Phase 5 — budget, verification, commit.**
Two prompt-size budget tests plus the full-suite and end-to-end gates.

## Verification results

Re-run at summary time, from the committed tree:

| Check | Result |
| --- | --- |
| `./test/run.sh` | exit 0, `Lint passed.`, **388 tests, 0 failures**, 113s (< 180s budget) |
| Test count | 362 pre-change (`08587ab`) → 388 post-change |
| `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh` | exit 0, no output |
| SKILL.md sync | `diff <(wiggum_skill_content) .claude/skills/wiggum/SKILL.md` exits 0; 321 lines (< 400) |
| `wc -l < wiggum.sh` | 86 — unchanged, as required |
| Plan checkboxes | 24 checked, 0 unchecked |

End-to-end planner capture with a stubbed `claude` (no Claude call spent), both directions:

- Defect-shaped input (`docs/plan_evidence_and_risk_gates.md`): `run_plan` exits 0, stderr
  shows `Diagnosis sections: enabled`, prompt is 6133 bytes (< 9000) and contains all four
  diagnosis sections, all risk gates, the citation and mock-harness rules, the sequencing
  rule, and every pre-existing clause.
- Feature-shaped input: exits 0, stderr shows `Diagnosis sections: skipped`, prompt is 5057
  bytes (< 6000) and contains **zero** occurrences of `## Symptoms` / `## Root cause` /
  `## Why existing verification missed it` / `## Blast radius`, while retaining the universal
  rules.
- Each universal clause appears exactly once per prompt regardless of input-file count — the
  helpers are appended per prompt, not per file.

Helper sizes, all inside their plan budgets: `prompt_plan_verification` 1052 B (< 1200),
`prompt_risk_gates` 1228 B (< 2000), `prompt_phase_sequencing` 445 B (< 600),
`prompt_defect_diagnosis` 1034 B.

## Issues encountered

**A latent test-harness defect, found by the Phase 5 error-state check.** Deliberately deleting
`path:line` from `prompt_plan_verification` to prove the new tests bind revealed that the suite
did *not* fail. Under bash 3.2 (macOS system bash), `set -e` does not apply to a failing
`[[ ]]` inside a function, so **all 318 standalone `[[ ]]` assertions in `test/wiggum.bats`
were unenforced** unless they happened to be the test's last command — a silent
false-green across the whole suite, predating this work.

Fixed out of plan (`7de7e6f`): every standalone assertion is now bound with `|| return 1`, plus
a guard test that fails if an unbound one is reintroduced. With the assertions bound, the
reintroduced regression failed at a named test as the plan required; the text was restored and
the suite re-run to green. This is the single most valuable outcome of the run — the plan's
error-state check earned its place by catching a defect in the verification itself, not in the
feature.

## What was deferred

Nothing in scope was deferred. Deliberate non-goals, unchanged as planned:

- `prompt_workplan`, `prompt_constraints_summary`, `prompt_acceptance_criteria`,
  `prompt_implement_verification`, `prompt_commit` — byte-identical.
- `run_execute` / `run_validation`, `WIGGUM_TASK_PREFIX`, and all CLI flags — untouched.
- README — documents plan *structure* generically and never enumerates prompt rules, so no
  edit was warranted (re-confirmed by grep: no hits for `prompt_`, `## Constraints`,
  `Acceptance Criteria`).
- No mechanical enforcement of the new rules (no linter parsing produced plans for
  `## Symptoms`). This change is prompt text plus its tests, as scoped.

**One deviation from the plan's literal wording.** The final task said to commit lib, tests,
and the regenerated skill file "together as one logical change". They instead shipped across
the phase-by-phase commits `4642f38..7de7e6f`, because `CLAUDE.md` §3 requires committing as
soon as a change passes the suite, and rewriting 17 recorded commits to satisfy the wording
was not warranted. The task's stated acceptance still holds: the tree is clean, and every
commit in `08587ab..HEAD` is a single-line imperative message with no `:` prefix and no
trailer.

## Risk gates — applicability to this change

Recorded as "not triggered" rather than silently omitted: no phase deleted or rewrote data,
activated a never-run production code path, or added a repo-wide guard. The gates therefore
apply vacuously here. The one destructive-adjacent step — regenerating `SKILL.md` — is
idempotent and diff-verified against the committed tree.

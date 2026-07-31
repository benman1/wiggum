# Issue: Add diagnosis evidence and risk gates to wiggum's planner prompt

## Problem

Wiggum's planner prompt (`run_plan` in `lib/wiggum.sh:1717`, plus
`prompt_constraints_summary`, `prompt_plan_verification`, and
`prompt_acceptance_criteria` at `lib/wiggum.sh:1747-1759`) is well developed on
one axis and empty on another.

**Covered today:** how a task is written so it can be executed and checked —
checkbox form, one-line `Acceptance:`, `Files:`, phase-level Acceptance Criteria
in four categories, a `## Constraints` self-check, and "confirm the APIs exist".

**Not covered today:** whether the plan's *diagnosis* is right, and whether the
proposed fix is *bounded*. A plan can satisfy every current rule and still:

- assert what the current code does without ever having read it, so the whole
  plan is built on a misreading;
- fix a defect that has no live symptom while never saying so, which makes the
  work look more urgent than it is;
- specify a test in a file whose module-scope mocks make that test impossible;
- turn on a code path that has never executed in production and treat that as a
  no-op restoration;
- rewrite or delete historical data with no export, no dry run, and no count;
- fix a backend defect whose entire point is a number on a screen, and carry no
  task that checks the screen.

A recent plan reviewed by hand (`veritametrics/docs/relative-url-attribution-and-pii_plan.md`)
demonstrated the value of the missing half: every claim carried a `path:line`
citation, so the whole diagnosis was verifiable in minutes instead of
re-investigated. The same review found four defects in the plan that all fall in
the uncovered categories above.

## Goal

Add a diagnosis and risk layer to the planner prompt without diluting what is
already there. Three of the additions apply to every plan (evidence citations,
risk gates, surface propagation); the largest one is conditional on the input
describing something already broken, so feature plans pay almost nothing for it.

## Requirements

1. **Do not change the existing rules.** Per-task `Acceptance:`/`Files:` lines,
   the checkbox mandate, `## Constraints`, and the four-category phase-level
   Acceptance Criteria all stay exactly as they are. This change is additive.

2. **Evidence rule (all plans).** Extend `prompt_plan_verification` so that every
   statement the plan makes about *current* behaviour cites the source as
   `path:line`, and the planner must have read that line before citing it. A plan
   that says "the handler drops the header" without a citation is an assumption
   wearing a fact's clothes. Line numbers also make the plan reviewable: a human
   can confirm or refute each claim by opening one file. This complements the
   existing `Files:` line, which names files the task will *write*; the new rule
   covers files the plan *read* to justify itself.

3. **New `prompt_defect_diagnosis`, applied when the input describes a defect.**
   When the issue is that something already built is broken (a bug report, an
   incident, an observed wrong number) the plan must open with these sections
   before its phases:

   - `## Symptoms` — what is observable, in the terms of whoever sees it (an end
     user, an operator, a developer). Each symptom tagged **observed** or
     **predicted**. This distinction is the important one: a plan that presents a
     predicted symptom as an observed one overstates urgency and promises a
     dashboard number will change when it never was wrong. The section must also
     name the *tell*: the observation that distinguishes this defect from the
     benign explanation ("the URLs still contain `?utm_source=`, but the column
     is null" separates a parser bug from "no campaign traffic").
   - `## Root cause` — the numbered path from entry point to failure, each step
     carrying its `path:line`. Not a description of the bug: the route to it.
   - `## Why existing verification missed it` — if the code is broken and the
     suite is green, name the blind spot, citing the tests that pass. This
     directly determines which test the plan adds; without it, plans routinely add
     a test that would also have passed. If a passing test actively pins the buggy
     behaviour, say so, because the fix will break it and someone must decide
     which contract is right.
   - `## Blast radius` — what is affected, and explicitly what is **unaffected
     and why**. The unaffected list is what keeps execution from widening the
     change, and it is where a wrong diagnosis usually shows itself.

   For non-defect work (a new feature, a refactor, a migration) this section is
   skipped, and the prompt should say so plainly so the planner does not invent
   symptoms for a greenfield build.

4. **New `prompt_risk_gates` (all plans).** Four rules about the danger of the
   fix rather than the danger of the bug:

   - **Measure before you act.** If any phase is justified by a claim about
     production data or runtime state, the first phase is a read-only measurement
     of that claim, and each dependent phase states the result that would make it
     unnecessary. A backfill over zero rows is a phase that should never run.
   - **Activating never-run code is not a no-op.** If a task makes a code path
     execute that has been silently skipped (a swallowed exception, a dead
     branch, a disabled flag), its false positives have never been paid for. The
     plan must precede it with a read-only impact report over real inputs, and
     the reviewed result gates the change shipping.
   - **Irreversible tasks carry four conditions.** Any task that deletes or
     rewrites existing data must: default to a dry run, export the affected rows
     before the first real write, be idempotent, and record the affected count
     per scope. A plan that rewrites history without an export has no undo.
   - **A new guard must pass on a clean tree.** If a task adds a lint, a static
     check, or an invariant test, it must enumerate the legitimate exceptions up
     front, and its acceptance must state that the guard passes against the
     current code on its first run and fails when the defect is reintroduced. A
     guard that fails on day one gets disabled on day one.

5. **Test-task feasibility (one sentence in the planner prompt).** Before
   specifying a task that adds a test to an existing file, read that file's
   harness: module-scope mocks (`vi.mock`, `jest.mock`, fixtures, monkeypatching)
   are hoisted per file and can make the intended test impossible there. The task
   must state whether the test can live in that file or needs a new one. Never
   plan to weaken an existing mock so a new test fits, because that quietly
   reduces the coverage the file already had.

6. **Sequencing.** After the phases, state which phases can ship independently
   and which must wait, with the reason. This is not the existing task-dependency
   list: two phases can be technically independent while one is safe to ship
   alone and the other must wait for a measurement. Fixes that only turn nulls
   into values ship freely; fixes that can delete good data wait.

7. **New `prompt_surface_propagation` (all plans).** A change to behaviour is not
   finished at the layer that implements it. When a task changes something a user
   can eventually observe — a new or renamed field, a value that starts being
   populated, a new state or error, a removed capability, a changed shape — the
   plan must trace it to every surface that presents it and add a task for each
   one that needs to change. In practice: UI components, shared types and API
   client code, fixtures and mock data, empty states, exports, notification and
   email templates, and user-facing docs or help text.

   Three sub-rules make this real rather than a reminder:

   - **Enumerate consumers by grepping, not by memory.** Search for the changed
     symbol, field, endpoint, or column and list the call sites in the plan with
     `path:line`, the same citation discipline as requirement 2. A plan that says
     "update the front end if needed" has done none of this work.
   - **State the no-op explicitly.** If nothing downstream changes, the plan says
     so and gives the reason ("this field is written but never read; the dashboard
     reads the aggregate table"). Silence is indistinguishable from an oversight,
     and this mirrors the `## Blast radius` unaffected list.
   - **A backend fix that starts populating data is a front-end change.** Data
     that was always null and now has values will hit rendering paths that never
     ran: an empty state that should now be a populated view, a default tab chosen
     by a "do we have any of this?" check, a filter that returned nothing and now
     returns rows, a column that was blank in every export. These are the cases
     most often missed, because nothing in the diff looks like UI work.

   Acceptance for a front-end task must be observable **on the rendered surface**
   (a screenshot, a component test, a rendered-output assertion), not on the API
   response that feeds it. "The endpoint returns the field" is not evidence that
   anyone can see it. Where the project's own standards prescribe the evidence
   (for example a before/after screenshot at several widths), the task must cite
   that standard and produce that artifact.

   The same rule runs in the other direction: a UI task that needs a field the
   backend does not yet return must carry the backend task, not assume it.

8. **Implement as focused prompt helpers**, mirroring the existing pattern: small
   functions in `lib/wiggum.sh` returning instruction text, called from
   `run_plan`'s prompt. Keep `wiggum.sh` under 30 lines and the existing
   `prompt_*` functions single-concern.

9. **Update the skill documentation in BOTH places, kept in sync.** The
   "Create a wiggum-compatible workplan" section (`lib/wiggum.sh:1348-1402`)
   documents the plan format and its rules; the new sections and gates belong
   there too. The text lives in two places that must stay identical:
   - the `wiggum_skill_content()` heredoc in `lib/wiggum.sh`, and
   - the committed copy at `.claude/skills/wiggum/SKILL.md` (a Bats test asserts
     the file matches the function output, so update both).

## Acceptance Criteria

### Happy Path

- Given a fresh checkout, When `bats test/wiggum.bats` runs, Then new tests
  asserting each helper's content pass: `prompt_plan_verification` requires
  `path:line` citations; `prompt_defect_diagnosis` names Symptoms, Root cause,
  Why existing verification missed it, and Blast radius; `prompt_risk_gates`
  names the measure-first, never-run-code, irreversible-task, and clean-tree-guard
  rules.
- Given `run_plan`'s prompt, When inspected, Then it calls the new helpers and
  still contains the existing checkbox, `Acceptance:`, and `Files:` instructions
  verbatim.
- Given `prompt_surface_propagation`, When inspected, Then it requires consumers
  to be enumerated with `path:line`, requires an explicit no-op statement when
  nothing downstream changes, and requires front-end acceptance to be observable
  on the rendered surface rather than on the API response.
- Given `wiggum_skill_content` output, When grepped, Then it documents the defect
  sections, the risk gates, and the surface-propagation rule, and
  `.claude/skills/wiggum/SKILL.md` contains the identical text.

### Edge Cases

- Given a non-defect input (a feature request), When the planner prompt is
  inspected, Then it explicitly permits skipping the defect sections rather than
  requiring invented symptoms.
- Given a plan with no destructive task and no production-data claim, When the
  risk-gate instructions are followed, Then no extra phase is required: the gates
  are conditional, not mandatory scaffolding.
- Given a backend-only change with no user-visible effect (an internal refactor,
  a log line, a build script), When the surface-propagation rule is followed, Then
  the plan records the no-op and its reason instead of inventing a front-end task.
- Given a fix that changes a value from always-null to populated, When the
  surface-propagation rule is followed, Then the plan carries a task for the
  rendering paths that were previously unreachable (empty states, defaulted views,
  filters, exports), because no line of the diff looks like UI work.

### Error States

- Given the observed/predicted rule, When the prompt is inspected, Then it
  requires every symptom to be tagged, so an unverified symptom cannot be
  presented as observed.
- Given a task that rewrites data, When the prompt is inspected, Then all four
  conditions (dry run, export, idempotent, recorded count) are named, not just
  the dry run.

### Non-Functional

- Given the codebase, When `shellcheck -s bash wiggum.sh lib/wiggum.sh install.sh`
  runs, Then it exits 0 with zero warnings.
- Given the suite, When `./test/run.sh` runs, Then lint and all Bats tests pass
  (exit 0). Existing tests must remain green.
- Given prompt length, When the new helpers are added, Then the defect-specific
  text is conditional on defect-shaped input, so a feature plan's prompt grows by
  the three universal rules only. Prompt text is attention spent on every run;
  additions must earn their place.

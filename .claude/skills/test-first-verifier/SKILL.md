---
name: test-first-verifier
description: Implement a code change with trustworthy verification — plan and list the files that change, verify assumptions (APIs exist, imports resolve, config values), write tests first when none cover the change, then gate completion on tests + lint + type-check + happy/edge/failure spot checks. Use when implementing or fixing code and you want it actually verified, not assumed.
argument-hint: [task description or file to implement]
---

# Test-First Verifier

A discipline for implementing a code change you can actually trust. Apply it to: **$ARGUMENTS**

If no argument is given, apply it to the task currently under discussion.

The rule underneath every step: **a claim is not verified until you have run the thing and seen the result.** "Should work" is not "works."

## 0. Discover the project's checks (once, before anything else)

Find the real commands for **tests**, **lint**, and **type-check** for this repo. Look in this order and stop at the first that applies:

- `package.json` `scripts` (e.g. `test`, `lint`, `type-check`, `tsc`)
- `Makefile` / `justfile` targets
- `.wiggumrc` / `.wiggumrc.example` — use the `verify =` and `autofix =` lines verbatim
- `pyproject.toml` / `tox.ini` / `setup.cfg` (pytest, ruff, mypy), `Cargo.toml`, `go.mod`, etc.
- `README.md` / `CONTRIBUTING.md` testing section

Write down the exact command you'll use for each category. **If you cannot find one of the three, say so explicitly now** — do not silently skip it later.

## 1. Before writing code

- State the plan in 2–5 bullets.
- List the **exact files** you expect to create or modify, by path.
- Flag which listed files do not exist yet.

## 2. Verify assumptions (cheap to check now, expensive to get wrong later)

Before writing logic that depends on them, confirm — don't assume:

- **APIs exist.** Every function/method/endpoint you'll call: grep or read its definition (in the source or the dependency) and confirm the signature.
- **Imports resolve.** Every import you'll add: confirm the module is installed and the symbol is actually exported.
- **Config values exist.** Every config key / env var / flag you rely on: confirm it's defined and read its actual value.

If any assumption can't be confirmed, **stop and surface it** rather than coding around a guess.

## 3. Tests first

- If tests already cover this area, run them now to establish a green baseline.
- If **no test covers the change**, write the minimal test(s) **first**, pinning the intended behavior. Run them and confirm they **fail for the right reason** before you implement.

## 4. Implement

Make the change, scoped to the plan and file list from step 1. If the set of files changes, say why.

## 5. Run the full check suite (the mechanical gate)

Run the commands from step 0, capturing output, in order:

1. tests
2. lint
3. type-check

If anything fails: fix the **source code** — never weaken a test or edit config just to go green — and re-run the **entire** suite from the top. Repeat until clean.

## 6. Three spot checks (the judgment gate)

Automated tests don't catch everything. Reason through three concrete scenarios and **show your work** (input → expected → actual), running real values where you can:

- **Happy path** — a representative valid input produces the expected result.
- **Edge case** — boundary / empty / large / unusual input still holds.
- **Failure case** — invalid input or an error condition fails *safely*, with a clear, intentional error.

## 7. Completion gate

Do **not** report the task as done until **every** line is true, each backed by output you actually saw:

- ✓ Tests pass
- ✓ Lint clean
- ✓ No type errors
- ✓ All three spot checks pass
- ✓ Every assumption from step 2 confirmed

If any item fails or could not be verified, report exactly which one and why. Never round an unverified result up to "done."

## Rules

- Never declare completion on an unverified claim.
- If a check command genuinely doesn't exist for this project, state that explicitly — don't pretend it passed.
- Don't edit tests or config to satisfy the gate; fix the code.
- Stay scoped to the task. Verification is the goal, not a license to refactor.

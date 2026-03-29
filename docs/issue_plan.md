# Wiggum — Best Practices Refactoring Plan

> **Source:** `issue.md` — Bash best practices audit
> **Project:** `wiggum` — Self-driving agent loop (CLI + lib)
> **Files in scope:** `wiggum.sh`, `lib/wiggum.sh`, `test/wiggum.bats`

---

## Phase 1: Audit & Assessment

- [x] **1.1 Map current violations** — Read through `lib/wiggum.sh` and `wiggum.sh`, annotating each function against the best-practices checklist. Produce a tally of what already passes and what needs work.

**Acceptance criteria:** A clear list of which best-practice rules are already satisfied and which are violated, with line references.

---

## Phase 2: Keep a Clear Main Entrypoint

> *"Keep a clear main entrypoint"* (repeated 3× for emphasis)

- [x] **2.1 Guard library from direct execution** — `lib/wiggum.sh` should be source-only. Add a guard (`return 0 2>/dev/null` or `[[ "${BASH_SOURCE[0]}" != "$0" ]]`) so running `bash lib/wiggum.sh` directly is a no-op or error.
- [x] **2.2 Wrap CLI dispatch in a `main` function** — In `wiggum.sh`, move the top-level logic (lines 14–27: `parse_args`, `load_config`, `derive_output_file`, `case`) into a `main()` function and call `main "$@"` at the bottom. This makes the entrypoint explicit and testable.
- [x] **2.3 Verify entrypoint clarity** — Confirm `wiggum.sh` is ≤30 LOC and does nothing besides source + dispatch.

**Acceptance criteria:** `bash lib/wiggum.sh` alone does not execute side effects. `wiggum.sh` has a single `main` function. All tests still pass.

**Dependencies:** None.

---

## Phase 3: Pass Data via Arguments, Not Globals

- [x] **3.1 Inventory global state** — List every global variable (`MODE`, `FILES`, `PLAN_FILE`, `SUMMARY_FILE`, `ITERATIONS`, `MAX_VALIDATION_RETRIES`, `INIT_PRESET`, `VERIFY_STEPS`, `VERBOSE`, `CLAUDE_EXTRA_ARGS`). Determine which are truly needed as globals vs. which can be passed as function arguments.
- [x] **3.2 Convert `detect_preset` / `generate_rc`** — Already pure (take args, return via stdout). No change needed — verify and document.
- [x] **3.3 Convert `derive_output_file`** — Currently reads `FILES`, `MODE`, `PLAN_FILE`, `SUMMARY_FILE` from globals and mutates `PLAN_FILE`/`SUMMARY_FILE`. Refactor to accept mode, base file, and current value as args; print the derived path to stdout. Caller captures.
- [x] **3.4 Convert `load_config_from`** — Currently appends to global `VERIFY_STEPS` and mutates `ITERATIONS`/`MAX_VALIDATION_RETRIES`. Refactor to print a serialized config (e.g., declare-based or key=value lines) that the caller evals or parses.
- [ ] **3.5 Convert `run_validation`** — Currently reads `VERIFY_STEPS` and `MAX_VALIDATION_RETRIES` from globals. Refactor to accept them as arguments (pass the array via positional args or a nameref).
- [ ] **3.6 Update tests** — Adjust `test/wiggum.bats` for any signature changes. Add new tests for argument-passing behavior.

**Acceptance criteria:** Functions that previously relied on globals now accept arguments. Global mutation is limited to `parse_args` and `wiggum_reset`. All tests pass.

**Dependencies:** Phase 2 (main entrypoint wraps globals).

---

## Phase 4: Return via stdout, Not `return`

- [ ] **4.1 Audit return-value patterns** — Identify functions that communicate results via global mutation rather than stdout. (`detect_preset`, `find_config` already use stdout correctly.)
- [x] **4.2 Fix `derive_output_file`** — Make it echo the derived path instead of mutating `PLAN_FILE`/`SUMMARY_FILE` directly (ties into 3.3).
- [x] **4.3 Fix `load_config_from`** — Output parsed config to stdout instead of mutating globals (ties into 3.4).

**Acceptance criteria:** No function communicates its result by setting a global. Results flow through stdout capture (`$(func arg)`).

**Dependencies:** Phase 3 tasks 3.3, 3.4.

---

## Phase 5: Use Exit Codes Intentionally

- [x] **5.1 Define exit code constants** — Create named constants for distinct failure modes: `EXIT_BAD_ARGS=1`, `EXIT_NO_CONFIG=2`, `EXIT_VALIDATION_FAILED=3`, `EXIT_CLAUDE_FAILED=4`, etc.
- [x] **5.2 Apply exit codes** — Replace bare `return 1` with specific exit codes throughout `lib/wiggum.sh`. Ensure `run_validation` returns a distinct code for "max retries exhausted" vs. other errors.
- [x] **5.3 Test exit codes** — Add BATS tests verifying specific exit codes for specific failure scenarios.

**Acceptance criteria:** Each error path returns a documented, distinct exit code. Tests assert on exact codes, not just non-zero.

**Dependencies:** None (can run in parallel with Phase 3–4).

---

## Phase 6: Quote Everything

- [ ] **6.1 Run `shellcheck` with strict quoting rules** — Run `shellcheck -S warning lib/wiggum.sh wiggum.sh` and fix all quoting warnings (SC2086, SC2046, SC2248, etc.).
- [ ] **6.2 Audit `eval` usage** — `run_validation` uses `eval "$cmd"`. This is a known risk. Document why it's necessary (user-provided commands from `.wiggumrc`) and add a comment. Consider whether a safer dispatch is possible.
- [ ] **6.3 Audit `xargs` trimming** — `load_config_from` uses `echo "$key" | xargs` for whitespace trimming. Replace with a pure-bash trim pattern (`key="${key#"${key%%[![:space:]]*}"}"`) to avoid word-splitting surprises with special characters.

**Acceptance criteria:** `shellcheck` passes clean (it already runs in CI via `.wiggumrc`). No unquoted variable expansions remain. `eval` usage is documented.

**Dependencies:** None.

---

## Phase 7: Avoid Subshell Surprises

- [ ] **7.1 Audit subshell mutations** — Check that no function modifies globals inside a subshell (e.g., `$(func)` that sets a global — the set is lost). Current `load_config_from` is called directly (not in a subshell), so it works, but if Phase 4 changes it to stdout-based, ensure the caller properly captures + applies results.
- [ ] **7.2 Document subshell boundaries** — Add brief comments where subshells are intentional (e.g., `WIGGUM_ROOT="$(cd ... && pwd)"`).

**Acceptance criteria:** No global mutation happens inside `$(...)`. Any subshell usage is intentional and commented.

**Dependencies:** Phase 3–4 (refactoring may introduce new subshell patterns).

---

## Phase 8: Separate I/O from Logic

- [ ] **8.1 Extract I/O from `run_validation`** — The function currently mixes `echo` progress output with logic. Separate the validation logic (run command, check exit code, decide retry) from the user-facing messages. Consider a `log()` helper that respects `VERBOSE`.
- [ ] **8.2 Extract I/O from `run_execute`** — Phase banners and progress messages are interleaved with orchestration logic. Move banner printing to a thin wrapper; keep the core loop I/O-free.
- [ ] **8.3 Extract I/O from `run_init`** — The interactive overwrite prompt (`read -r answer`) is embedded in logic. Factor the prompt into the caller or a dedicated `confirm_overwrite()` function.
- [ ] **8.4 Ensure `load_config` I/O is clean** — `load_config` prints "Loading config from ..." — this is informational I/O mixed into a data-loading function. Move the message to the caller.

**Acceptance criteria:** Core logic functions can be tested without capturing/asserting on interleaved I/O. Logging/progress is handled by a wrapper or a `log()` utility.

**Dependencies:** Phase 3–4 (signature changes should land first).

---

## Phase 9: Use Consistent Naming

- [ ] **9.1 Audit naming conventions** — Verify all functions use `snake_case`. Verify all local variables use `lowercase`. Verify all "constants" (exit codes, version) use `UPPER_CASE`.
- [ ] **9.2 Namespace internal helpers** — Prefix internal/private functions with `_wiggum_` or `__` to distinguish them from public API functions (`parse_args`, `run_plan`, etc.).
- [ ] **9.3 Rename `CLAUDE_EXTRA_ARGS`** — Consider whether this should just be folded into `run_execute`/`run_plan` as a local, since it's only constructed in `parse_args` and consumed in one place.

**Acceptance criteria:** Naming is consistent across the entire library. No single-letter variables outside tight loops. Internal helpers are clearly distinguished.

**Dependencies:** Phase 3 (some renames overlap with argument-passing refactor).

---

## Phase 10: Fail Fast Inside Functions

- [ ] **10.1 Validate arguments at function entry** — Each public function should validate its preconditions at the top (e.g., `run_plan` should assert `PLAN_FILE` is set, `run_execute` should assert `FILES` is non-empty) rather than relying on `set -u` to catch it later.
- [ ] **10.2 Guard `run_validation` retries** — Validate `MAX_VALIDATION_RETRIES` is a positive integer at function entry, not mid-loop.
- [ ] **10.3 Validate config values** — `load_config_from` should reject non-numeric values for `iterations` and `max_validation_retries` immediately, not silently accept them.
- [ ] **10.4 Add tests for early failures** — BATS tests for invalid config values, missing preconditions, etc.

**Acceptance criteria:** Every public function validates its inputs at entry. Invalid state is caught before any work is done. Tests cover invalid inputs.

**Dependencies:** Phase 3 (argument signatures must be settled first).

---

## Phase 11: Final Verification

- [ ] **11.1 Full shellcheck pass** — `shellcheck -S warning wiggum.sh lib/wiggum.sh`
- [ ] **11.2 Full test suite** — `bats test/wiggum.bats` — all tests pass
- [ ] **11.3 Manual smoke test** — Run `wiggum init node` in a temp dir, confirm `.wiggumrc` is created correctly
- [ ] **11.4 Review diff** — Ensure no behavioral regressions; only structural improvements

**Acceptance criteria:** CI-equivalent checks pass. No functional regressions.

**Dependencies:** All previous phases.

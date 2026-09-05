# Explain a plan, and make `wiggum plan` answer the questions a reader will ask

Wiggum writes plans that say *what* will be done and how it will be verified.
It says very little about *why this shape and not another*, what the work is
worth to a user, or which choices are still open. A reader — the person about to
approve a run, or the person reading the plan six weeks later — has to
reconstruct all of that.

Two changes, sharing one body of analysis.

## Expected benefits

1. A plan states its open decisions, so a human can settle them before a run
   burns iterations on a guess.
2. A plan states who the work is for and how they'll hear about it, so the
   documentation and website work is planned rather than remembered afterwards.
3. The same analysis is available on demand, without regenerating a plan, for a
   plan somebody else wrote or one already part-executed.

## 1. New command: `wiggum explain <plan-or-issue-file>`

Read-only. Runs no implementation, writes no commits. It answers, about the
files it is given:

- **What does this contain?** The phases and tasks, summarised in plain terms.
- **What benefit does it bring?** What becomes true when it is done.
- **What is the benefit to users?** In the words of somebody who uses the
  product, not the words of the implementation.
- **How is that communicated?** Which documentation, README sections, help text
  or web pages would have to change for a user to find out about it — and
  whether the plan currently covers those.
- **Which decisions are still open?** For each: the context, the realistic
  options, what each option buys and costs, and a rough effort estimate.

Output goes to stdout by default so it can be piped or read; `--explain-file
<path>` writes it to a file instead.

## 2. `wiggum plan` gains a feedback step

After the plan is written and before it is reported as created, a second pass
reviews the plan it just produced and **updates the file in place**, adding:

- `## Open decisions` — the decision, the options, benefit and cost of each, and
  the effort involved. A plan with nothing genuinely open says so in one line
  rather than inventing a dilemma.
- The user-benefit and communication analysis, folded into the plan's existing
  `## Expected benefits` section rather than duplicated beside it.

The feedback step must not rewrite the tasks or renumber the phases; it adds
context around them.

## 3. Planning must reference the issues it comes from

`prompt_issue_ledger` reconciles the issue ledger in phase 3, but nothing tells
the *planner* to look at it. So a plan rarely names the issues it addresses, and
phase 3 then has to guess which ledger entries this work closes.

Planning should find where the repository tracks issues — the issue or spec files
the plan was built from, and any tracker in version control (`ISSUES.md`,
`TODO.md`, `ROADMAP.md`, `docs/issues*.md`) — and cite, per phase or per task,
which open entries it addresses. If the repo keeps no ledger, the plan says so
in one line. It must not invent a tracker or backfill entries.

The `/wiggum` skill's plan-writing rules need the same instruction, and the
skill's committed copy must stay in sync with the heredoc.

## Constraints

- In scope: `lib/wiggum.sh` prompts and modes, the CLI dispatch, completions,
  `README.md`, the skill heredoc and its committed copy, and Bats tests.
- Out of scope: changing what phase 3 does with the ledger; changing the plan
  file format beyond adding sections; the landing page in `site/`.
- Never do: invent an issue tracker that isn't there, make `explain` write to the
  repository, or let the plan feedback step rewrite tasks.

## Acceptance

- `wiggum explain <file>` exists, is dispatched from the CLI, documented in
  `wiggum --help`, its own `wiggum explain --help`, the README command
  reference, and both shell completions.
- The plan prompt and the explain prompt share their analysis text through
  common `prompt_*` helpers rather than duplicating it.
- `wiggum plan` writes a plan containing an `## Open decisions` section.
- The plan prompt instructs the planner to cite the issue ledger entries the
  plan addresses, or to state that the repo keeps none.
- Every new function has a Bats test; `./test/run.sh` passes.

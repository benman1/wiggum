# Claude Code native capabilities: gap analysis against wiggum (as of 2026-11-22)

This note records Claude Code capabilities available on 2026-11-22 so the wiggum gap report can separate native features from orchestration wiggum still supplies. A local `2.1.330 (Claude Code)` binary and official docs provide the evidence.

Source order: official Claude Code docs first, local `claude --help` output second, GitHub issue 107421 only as corroboration for `.agents/skills`. Several webfetch outputs were truncated; unresolved points stay in Gaps.

## Key question 1: What CLI surface does Claude Code expose?

### Takeaway
Claude Code ships one CLI with interactive and non-interactive modes, session resume, background agents, permission and effort controls, model selection, plugin and MCP loading, cloud and desktop entry points, and subcommands for auth, MCP, plugins, logs, stop, respawn, and update. Wiggum uses a narrow slice of this surface: one prompt call with effort, permission, model, session id, and resume/fork flags.

### Cited Findings
- Local `claude --version` returned `2.1.330 (Claude Code)`. The release-notes page is generated from the GitHub changelog and names `2.1.330`, dated `November 20, 2026`. [Release notes](https://code.claude.com/docs/en/release-notes); local `claude --version`, 2026-11-22.
- The CLI starts an interactive session by default. `-p/--print` prints a response and exits for scripts and pipes. [CLI reference](https://code.claude.com/docs/en/cli-reference); local `claude --help`, v2.1.330.
- Local subcommands include `agents`, `attach`, `auth`, `auto-mode`, `doctor`, `gateway`, `import`, `install`, `logs`, `mcp`, `plugin|plugins`, `purge`, `respawn`, `rm`, `setup-token`, `stop|kill`, `ultrareview`, and `update|upgrade`: local `claude --help`, v2.1.330.
- Prompt and context flags include `--add-dir`, `--agents <json-or-file>`, `--append-system-prompt`, `--system-prompt`, `--system-prompt-snapshot <on|off>`, `--settings`, `--setting-sources`, `--mcp-config`, `--plugin-dir`, and `--tools`: local `claude --help`, v2.1.330.
- Output and control flags include `--input-format <text|stream-json>`, `--output-format <text|json|stream-json>`, `--json-schema`, `--include-partial-messages`, `--include-hook-events`, `--max-budget-usd`, `--verbose`, and `--debug`: local `claude --help`, v2.1.330.
- The docs caution that `claude --help` does not list every flag, so absence from help output does not prove a flag is unavailable. [CLI reference](https://code.claude.com/docs/en/cli-reference).
- Wiggum validates five effort levels and six permission values, then injects `--effort`, `--permission-mode`, and optional `--model` into each agent call; its Claude adapter adds `--session-id <uuid>` and `--resume <prior> --fork-session` on continuation. [wiggum_baseline.md:71-78](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L71-L78).

### Inferences
- The native CLI already covers the transport that wiggum's Claude adapter implements: one-shot prompts, continuation, fork, session id, effort, permission, and model.
- Native controls outside wiggum's shared vocabulary include structured output, budgets, MCP config, strict tool lists, plugin loading, worktrees, cloud sessions, and remote control. Wiggum's `--agent` abstraction does not expose them.

### Gaps
- Release notes were fetched as web pages with truncated output; exact entry text for older items should be rechecked against the GitHub changelog before quoting.
- The docs and local help disagree about `ultracode`; see the effort section.

## Key question 2: Native planning, goals, tasks, and hooks

### Takeaway
Claude Code has plan mode, a task tool set, recurring prompts, a goal directive, and a hook that can send failure text back to the model for read-only exploration and in-session work tracking. No native artifact defines a durable workplan file with acceptance criteria, checkbox state, or a caller-owned verification waterfall. Wiggum reads and updates those artifacts.

### Cited Findings
- Plan mode separates exploration from edits. `Shift+Tab` twice enters it, tools stay read-only until the user approves a plan, `claude --permission-mode plan` starts a session in it, plans are saved under `~/.claude/plans/`, and `ExitPlanMode` requests approval. [Common workflows](https://code.claude.com/docs/en/common-workflows); [CLI reference](https://code.claude.com/docs/en/cli-reference).
- Built-in task tracking exposes `TaskCreate`, `TaskUpdate`, `TaskList`, and `TaskGet`. Tasks live for the session and are not persistent across sessions. The docs present them for multi-step and non-trivial work. [Common workflows](https://code.claude.com/docs/en/common-workflows).
- `/goal` keeps Claude working across turns until a condition is met. [Goal](https://code.claude.com/docs/en/goal).
- Scheduled tasks include `/loop`, cron tools, and task-list views for scheduled, goal, and forked work. Session loops are restored by `--resume` and `--continue` until they expire; cloud, Desktop, and GitHub Actions options provide schedules outside the terminal session. [Scheduled tasks](https://code.claude.com/docs/en/scheduled-tasks).
- Release notes captured during this research mention a 30-day retention window for recurring and loop work, down from seven days. The webfetch output was truncated around that text, so keep the number as a recheck item. [Release notes](https://code.claude.com/docs/en/release-notes).
- The `Stop` hook fires when Claude finishes responding. A prompt-based hook can return `{"ok": false, "reason": "..."}` to make Claude continue. A deterministic verifier can exit `2` with stderr feedback so Claude repairs the same turn. [Hooks guide](https://code.claude.com/docs/en/hooks-guide/).
- Wiggum writes a structured workplan with expected benefits, signals, critical path, float, constraints, one Mermaid diagram, acceptance lines, dependencies, phase criteria, and issue references. It uses `[ ]`, `[x]`, and `[~]` as control flow. [wiggum_baseline.md:13-19](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L13-L19).

### Inferences
- Plan mode maps to wiggum's read-only `explain` and planning calls. The plan file generated by Claude Code has no documented schema that wiggum could consume as task state.
- Task tools are session-local scratch state. They cannot hold wiggum's retry counters, sidecars, ledger, or run registry.
- A `Stop` hook gives Claude Code a native repair loop at turn boundaries; wiggum's waterfall runs configured shell commands in order, restarts from the top after a fix, and caps retries. [wiggum_baseline.md:18-19](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L18-L19).

### Gaps
- No official page defines a native plan artifact with per-task acceptance checks, a plan-level progress counter, or a handoff from planner to executor.
- The exact retention period for loops and the exact list of built-in scheduled-task views need a fresh changelog check.

## Key question 3: Execution, sessions, background agents, and supervision

### Takeaway
Claude Code supports headless execution through `claude -p` and the Agent SDK, durable sessions with resume and fork, and native background sessions with attach, logs, stop, remove, and respawn. Wiggum adds plan-level supervision: sidecars, machine-wide `top`, exit taxonomy, scoped process-tree kills, bounded iterations, and commits.

### Cited Findings
- `claude -p` and the Python and TypeScript Agent SDKs provide non-interactive execution and full programmatic control. [Headless](https://code.claude.com/docs/en/headless).
- In print mode the workspace trust dialog is skipped, and settings files that fail validation are ignored without an error dialog. The help text advises running only in trusted directories: local `claude --help`, v2.1.330.
- Session entry points are `claude --continue`, `claude --resume`, `claude --resume <name>`, `claude --resume <session-id>`, `claude --resume <transcript-path>`, `claude --from-pr <number>`, and `/resume`. Sessions are saved continuously to local `.jsonl` transcripts. [Sessions](https://code.claude.com/docs/en/sessions).
- `--session-id <uuid>` uses a specific id. `--fork-session` creates a new session id when resuming or continuing. Wiggum passes both, with `--resume <prior> --fork-session` on retries: local `claude --help`, v2.1.330; [wiggum_baseline.md:73](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L73).
- `--bg, --background` starts a session in the background and prints an id. `claude agents` lists active sessions, and `attach`, `logs`, `stop|kill`, `rm`, and `respawn` operate on that id: local `claude --help`, v2.1.330.
- `claude agents --json` prints active interactive and background sessions as JSON; `--all` adds completed sessions; `--cwd <path>` filters by launch directory: local `claude agents --help`, v2.1.330.
- `claude agents` can dispatch sessions with defaults for `--agent`, `--effort`, `--model`, `--permission-mode`, `--mcp-config`, `--plugin-dir`, `--setting-sources`, and `--restricted`: local `claude agents --help`, v2.1.330.
- Workflow scripts are JavaScript programs written by Claude and run in the background to coordinate multiple subagents. The docs list plan requirements and paid access conditions. [Workflows](https://code.claude.com/docs/en/workflows).
- Wiggum's background runs write `.pid`, `.out`, and `.log` sidecars. `status`, `watch`, `kill`, and `top` report plan-level state and activity, and `top` monitors all runs on the machine. [wiggum_baseline.md:22-24](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L22-L24).

### Inferences
- Native background agents cover session-level process handling. Wiggum's supervision covers the workplan and the OS process tree, including safe kill boundaries and a machine-wide registry.
- Native session ids and fork flags match wiggum's retry design. Wiggum still owns the id, transcript retention, attempt count, and failure report.
- Workflow scripts cover multi-agent orchestration. They do not provide wiggum's project verification commands, issue-ledger closure, commit policy, or plan checkbox stopping rule.

### Gaps
- No measurement compares native background agents with wiggum sidecars for reliability, latency, or memory under load.
- Workflow access conditions depend on account and platform; the exact plan used for this research was not probed.

## Key question 4: Permission and tool controls

### Takeaway
Claude Code has six local permission modes plus flags that allow or deny tools, connect an SDK permission handler, start restricted mode, and enable bypass as an option. Wiggum's six-value vocabulary overlaps but is not identical: it accepts `default`, while the local CLI accepts `manual`, and it omits the native `--permission-prompts`, `--tools`, `--allowedTools`, and `--disallowedTools` switches.

### Cited Findings
- Local `--permission-mode` choices are `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, and `plan`: local `claude --help`, v2.1.330.
- `--dangerously-skip-permissions` skips all permission checks and equals `--permission-mode bypassPermissions`. `--allow-dangerously-skip-permissions` adds bypass to the `Shift+Tab` cycle without starting in it. [CLI reference](https://code.claude.com/docs/en/cli-reference); local `claude --help`, v2.1.330.
- `--permission-prompts <host|none>` decides who answers permission prompts in print mode. `none` denies anything that would prompt; the permission mode still decides other actions: local `claude --help`, v2.1.330.
- `--tools`, `--allowedTools`, and `--disallowedTools` choose built-in tools or named tool calls. `--restricted` removes code-running tools and WebFetch unless named, ignores user and local settings, and refuses bypassPermissions: local `claude --help`, v2.1.330.
- Documented modes are `default` with manual approval, `acceptEdits`, `plan`, `auto`, and `bypassPermissions`. `auto` uses a second classifier model; interactive terminal and VS Code support for it starts at `v2.1.283`, with earlier versions limited to paid tiers. [Permission modes](https://code.claude.com/docs/en/permission-modes).
- Wiggum validates `acceptEdits|auto|bypassPermissions|default|dontAsk|plan` and injects its value on every call. A `.claude/settings.local.json` allow list does not gate a wiggum run because no call site overrides the injected flag. [wiggum_baseline.md:71-75](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L71-L75); [cerebrum.md:45-47](/Users/ben/wiggum/.wolf/cerebrum.md#L45-L47).

### Inferences
- The `default` versus `manual` mismatch is the clearest flag drift. Wiggum's value list came from an earlier Claude vocabulary; local v2.1.330 asks for `manual`.
- Native tool-level flags give finer control than wiggum's six modes. Wiggum's single string cannot express an allowed tool list or an SDK handler.
- `bypassPermissions` is well represented in both tools. `acceptEdits`, `auto`, and `plan` map directly by name; `default` needs translation to `manual`.

### Gaps
- The docs mode table and local help differ in mode naming. The exact release that renamed `default` to `manual` was not found.
- `--permission-prompts` and `--restricted` were observed in help output only; no run used them.

## Key question 5: Effort, model, output, and budget controls

### Takeaway
Claude Code lets each session choose a reasoning effort, a model or alias, fallback models, output format, JSON schema, and a dollar budget in print mode. Wiggum matches the local effort list and passes one model per phase. The `ultracode` value appears in docs from earlier releases but not in the local v2.1.330 help.

### Cited Findings
- Local `--effort` choices are `low`, `medium`, `high`, `xhigh`, and `max`. Wiggum validates the same five values and defaults to `xhigh`: local `claude --help`, v2.1.330; [wiggum_baseline.md:71](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L71).
- CLI reference text captured in this research mentions `ultracode` as an effort value requiring `v2.1.203+` and dependent on model availability. The local v2.1.330 help omits it. [CLI reference](https://code.claude.com/docs/en/cli-reference); local `claude --help`, v2.1.330.
- `--model` accepts aliases and provider-specific names: Anthropic full model names, Bedrock inference profile ARNs, Foundry deployment names, and Google Cloud version names. Aliases include `default`, `best`, `fable`, `sonnet`, `opus`, `haiku`, and `sonnet[1m]`. [Model config](https://code.claude.com/docs/en/model-config); local `claude --help`, v2.1.330.
- `ANTHROPIC_BASE_URL` changes where requests go. It does not choose the answering model. [Model config](https://code.claude.com/docs/en/model-config).
- `--fallback-model` takes a comma-separated list used when the main model is busy or unavailable, with the main model retried at the start of each turn: local `claude --help`, v2.1.330.
- `--max-budget-usd`, `--output-format`, `--input-format`, `--json-schema`, and `--include-partial-messages` apply only with `--print`: local `claude --help`, v2.1.330.
- Wiggum selects `model_plan` for plan calls and `model_execute` for execute and chain calls. [wiggum_baseline.md:81](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L81).

### Inferences
- Wiggum's effort vocabulary is aligned with the installed CLI. The `ultracode` discrepancy affects docs claims and cross-version reuse; the local v2.1.330 path is clear.
- Budget, structured output, streaming input, and fallback models are native capabilities that wiggum's shared adapter does not expose.

### Gaps
- The exact reason `ultracode` is absent from local help was not found.
- No run tested `--max-budget-usd`, `--json-schema`, or fallback-model behaviour.

## Key question 6: Skills, commands, and config directories

### Takeaway
Claude Code loads skills from `SKILL.md` files, folds legacy slash commands into skills, and reads instruction and config files from project and home directories. Official docs list `.claude/skills/` locations; no official `.agents/skills/` discovery path was found. Wiggum installs a Claude skill and rule, an `AGENTS.md` block, and an OpenCode command from one generator.

### Cited Findings
- Skills are folders with `SKILL.md` and YAML frontmatter. Claude can invoke a skill when its description matches the task, or the user can call `/skill-name`. [Skills](https://code.claude.com/docs/en/skills).
- Custom slash commands have been merged into skills. Existing `.claude/commands/` files still work. `disable-model-invocation: true` keeps a skill user-callable and stops Claude from invoking it on its own. [Commands](https://code.claude.com/docs/en/commands).
- Claude Code skills follow the Agent Skills open standard. Claude Code additions include invocation control, subagent execution, and runtime context injection. [Skills](https://code.claude.com/docs/en/skills).
- Documented skill locations are `.claude/skills/`, `~/.claude/skills/`, the managed settings directory, and plugins. No official docs page lists `.agents/skills/`. [Skills](https://code.claude.com/docs/en/skills).
- GitHub issue 107421 is titled `[Feature Request] Load skills from ~/.agents/skills/ and <project>/.agents/skills/`. It was closed as a duplicate. A comment reports that as of `v2.1.318`, skills load only from `.claude/skills/` locations and plugins, and that AGENTS.md support skips anything under `.agents/`. The issue suggests a symlink from `~/.claude/skills/` to `~/.agents/skills/`. [GitHub issue 107421](https://github.com/anthropics/claude-code/issues/107421).
- Claude Code commands start only at the start of a message. Up to six chained skills are supported. `/status`, `/tasks`, and `/usage` run immediately. Fullscreen `/theme` and `/help` became immediate after `v2.1.234`. [Commands](https://code.claude.com/docs/en/commands).
- Project `.claude/` holds `CLAUDE.md`, `.mcp.json`, settings, hooks, skills, commands, subagents, workflows, rules, output styles, themes, and auto memory. `~/.claude/` holds personal settings and history; `~/.claude.json` holds user-level state; `CLAUDE_CONFIG_DIR` relocates `~/.claude` paths. [Claude directory](https://code.claude.com/docs/en/claude-directory).
- `CLAUDE.md` and auto memory load at session start. Auto memory loads up to the first `200` lines or `25KB` of `MEMORY.md`. `AGENTS.md` can be read in place of `CLAUDE.md`; the exact version requirement and precedence when both files exist were not settled. [Memory](https://code.claude.com/docs/en/memory); [Claude directory](https://code.claude.com/docs/en/claude-directory).
- Wiggum `init` installs `.claude/skills/wiggum/SKILL.md`, `.claude/rules/wiggum.md`, a marked block in `AGENTS.md`, and `.opencode/commands/wiggum.md`. It leaves `CLAUDE.md` untouched. [wiggum_baseline.md:11-13](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L11-L13).

### Inferences
- Wiggum's Claude integration files use native discovery paths. Its `AGENTS.md` block reaches other agents, while the skill and rule target Claude-specific locations.
- `.agents/skills/` is a compatibility ask recorded in GitHub, not an official Claude Code discovery path. A symlink is the documented workaround in that issue thread.
- Claude commands and skills give wiggum a natural install target for user-facing `/wiggum` entry points; the wiggum workplan itself remains a file owned by wiggum.

### Gaps
- The exact Claude Code release that added AGENTS.md support was not found.
- No run confirmed that the installed v2.1.330 binary loads this repository's skill and rule from `.claude/`.

## Key question 7: Which Claude Code features are redundant, additive, or lossy against wiggum?

### Takeaway
Claude Code already supplies prompt execution, plan mode, task tools, session persistence, fork, background agents, permissions, effort, model aliases, skills, commands, hooks, and instruction files. Wiggum remains additive for durable plan state, verification policy, retry and stall rules, OS-level run supervision, commits, issue-ledger closure, chaining, and scheduling. The lossy seams are permission naming, the plan artifact, task persistence, and shell-level verification policy.

### Cited Findings
- **Redundant:** one-shot prompts, continuation, session ids, resume, fork, background sessions, and session listing are native. [Headless](https://code.claude.com/docs/en/headless); [Sessions](https://code.claude.com/docs/en/sessions); local `claude --help`, v2.1.330.
- **Redundant:** plan mode, task tools, skills, commands, memory, and instruction discovery cover the basic forms of exploration and in-session coordination. [Common workflows](https://code.claude.com/docs/en/common-workflows); [Skills](https://code.claude.com/docs/en/skills); [Commands](https://code.claude.com/docs/en/commands); [Memory](https://code.claude.com/docs/en/memory).
- **Additive (wiggum):** workplan artifacts, acceptance criteria, `[ ]`/`[x]`/`[~]` state, critical path, float, risk gates, and issue refs give the loop a durable contract. [wiggum_baseline.md:13-19](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L13-L19).
- **Additive (wiggum):** the verification waterfall, autofix pass, 60-line failure capture, retry cap, stall detection, benchmark injection, and commit policy live outside the agent session. [wiggum_baseline.md:18-20](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L18-L20); [wiggum_baseline.md:48-55](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L48-L55).
- **Additive (wiggum):** `status`, `watch`, `kill`, `top`, `chain`, `--queue`, and `--at` manage runs at plan and process-tree granularity. Native `claude agents` manages sessions and worktrees. [wiggum_baseline.md:22-24](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L22-L24); local `claude --help`, v2.1.330.
- **Lossy: permission:** wiggum's `default` is absent from local v2.1.330, where the matching value is `manual`. Native tool allow lists and SDK prompt handlers sit outside wiggum's one-string mode. [wiggum_baseline.md:71-75](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L71-L75); local `claude --help`, v2.1.330.
- **Lossy: plan state:** Claude plan files under `~/.claude/plans/` have no documented checkbox state machine, acceptance fields, or consumer that advances a workplan. [Common workflows](https://code.claude.com/docs/en/common-workflows).
- **Lossy: task state:** native task tools are session-local. Wiggum's plans, sidecars, registry, config, ledger, and summaries survive between calls. [Common workflows](https://code.claude.com/docs/en/common-workflows); [wiggum_baseline.md:59-60](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L59-L60).
- **Lossy: hooks:** the native `Stop` hook can make Claude continue after a verifier fails, while wiggum records retries, restarts the whole waterfall, and reports failure transcripts. [Hooks guide](https://code.claude.com/docs/en/hooks-guide/); [wiggum_baseline.md:18-20](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L18-L20).
- **Version risk:** the installed binary is v2.1.330 and matches the top fetched release note. Docs derived from other releases still mention `ultracode` and may name modes differently. [Release notes](https://code.claude.com/docs/en/release-notes); local `claude --help`, v2.1.330.

### Inferences
- The strongest reuse path is to let Claude Code own sessions, plan mode, task tools, skills, commands, and permission prompts, then keep wiggum as the plan, verify, retry, supervise, commit, and ledger layer.
- The two flag values to review before adapting wiggum are `permission_mode = default` and any effort value above `max`. Both diverge from the installed CLI help.
- `claude agents` reduces the need for wiggum's own agent list at session level. It does not replace wiggum's plan-level status, exit taxonomy, or scoped kill rules.

### Gaps
- No measured comparison of reliability, latency, or token cost exists for a wiggum loop versus native Claude Code plan mode, task tools, `Stop` hooks, or workflow scripts.
- Several docs pages were fetched with truncated output. Exact wording for long flag tables, AGENTS.md support, and older release entries needs a second pass if the final report quotes them.
- No native run was used for permission, effort, hook, or background-agent probes in this research. Flag facts come from help output and official docs.

# OpenAI Codex CLI — capability notes for wiggum gap analysis

**Research date:** 2026-11-22
**Scope:** Current Codex CLI / Codex agent behavior as documented by official OpenAI Codex docs. Focused on gaps relevant to wiggum (planning, autonomous execution/verification loop, CLI flags, reasoning effort, skills/AGENTS.md, and redundancy/additive/lossy mapping).

## Sources (authoritative first)

| Source | URL | Notes |
|---|---|---|
| Codex CLI command reference | https://learn.chatgpt.com/docs/developer-commands.md | Primary CLI command/flag reference; page renders some option tables dynamically. |
| Command line options (docs mirror) | https://learn.chatgpt.com/docs/cli/reference.md | Plain markdown with explicit flag definitions; useful for exact flag names/values. |
| Non-interactive mode | https://learn.chatgpt.com/docs/non-interactive-mode | `codex exec` behavior, safety, JSONL output, schema, resume, CI patterns. |
| Config basics | https://learn.chatgpt.com/docs/config-file/config-basic.md | Config precedence, common keys, approval/sandbox defaults, reasoning/personality/web search. |
| Config reference | https://learn.chatgpt.com/docs/config-file/config-reference.md | Config key types/defaults/accepted values; dynamic table rendering. |
| Custom instructions with AGENTS.md | https://learn.chatgpt.com/docs/agent-configuration/agents-md.md | AGENTS discovery, precedence, fallback filenames, size limit. |
| Build skills | https://learn.chatgpt.com/docs/build-skills.md | Skill format, progressive disclosure, locations, config, plugins. |
| Customization overview | https://learn.chatgpt.com/docs/customization/overview | AGENTS/skills/MCP/rules/subagents layering context. |
| Model selection | https://learn.chatgpt.com/docs/model-selection | Model/effort guidance; confirms effort is model-dependent. |
| Speed / Fast & Ultrafast | https://learn.chatgpt.com/docs/agent-configuration/speed.md | `/fast`, `/ultrafast`, CLI speed controls; not core execution loop. |

**Local verification:** `codex` CLI was not installed in this environment (`codex not found`; `codex --help` / `codex exec --help` returned command not found). Exact CLI help output could not be captured locally; findings below are based on official docs above.

## 1) Native planning / review / task tracking

### Built-in planning/review surfaces

- **Plan mode (interactive slash command):** `/plan` switches the active chat into plan mode; can include inline prompt text; Codex proposes an execution plan before implementation. While Codex is already working, `/plan` is temporarily unavailable. After planning, user can choose to clear context and implement with the complete plan. (Developer commands: https://learn.chatgpt.com/docs/developer-commands.md)
- **Code review:** `codex review` runs a non-interactive code review; choose exactly one review target or pass custom review instructions. Flags include `--uncommitted`, `--base`, `--commit`, `--title` (title only with `--commit`); targets conflict with each other/custom prompt. Interactive `/review` asks Codex to review working tree. (Developer commands)
- **Task/goal tracking:** `/goal` sets/edits/pauses/resumes/views/clears a task goal; objective must be non-empty and at most 4,000 chars. Goals give Codex a persistent target while a larger task runs. (Developer commands)
- **Subagents / agent threads:** `/subagents` switches active subagent thread; `/agents` opens command center for chats/agents; config includes `[features].multi_agent` (stable, default true) and `agents.*` settings (`max_concurrent_threads_per_session`, default reasoning effort for spawned agents, etc.). (Developer commands, Config reference)
- **Session/task management:** `/resume`, `/fork`, `/archive`, `/delete`, `codex resume`, `codex fork`, `codex archive/unarchive/delete`, `codex queue` for queuing messages to existing sessions. (Developer commands)

### Comparison to wiggum

- **Codex has native planning/review primitives**, but they are **agent/session features**, not a wiggum-style external workplan file contract with deterministic orchestration.
- **No documented native equivalent of wiggum's plan-file-driven execute loop** where a CLI reads `docs/<slug>_plan.md`, executes task-by-task, runs repo verification commands, commits per logical task, and emits `docs/<slug>_summary.md`. Codex plan mode is conversational/TUI-oriented; `codex exec` runs a prompt non-interactively but does not natively consume a wiggum plan format.
- **Task tracking exists (`/goal`, subagents, threads)** but is not the same as wiggum's explicit plan checklist with per-task verification/commit discipline. Wiggum's plan file is the source of truth; Codex goals are session-scoped objectives.

## 2) Native execution / autonomous loop

### `codex exec` (non-interactive)

- **Purpose:** Scripted/CI-style runs that should finish without human interaction. Alias: `codex e`. (Developer commands, CLI reference, Non-interactive mode)
- **Basic behavior:** `codex exec "..."` runs a task; streams progress to stderr and prints final agent message to stdout. (Non-interactive mode)
- **No built-in wiggum verify-retry loop:** Codex executes the requested task in a session/turn; it can run commands/tests if prompted and allowed, but there is no documented native "run verify commands, on failure feed output back, retry until pass" loop with wiggum's plan/task/commit semantics. Retries/verification are prompt- or workflow-driven.
- **Session resume/fork:** `codex exec resume [SESSION_ID]` continues non-interactive task; `--last` picks most recent session from current working dir, `--all` searches across all sessions. `codex exec fork <SESSION_ID> [PROMPT]` copies a saved session into a new session; session arg accepts UUID or name; no prompt creates fork without starting turn; `-` reads prompt from stdin; `--image` attaches images. (Developer commands, CLI reference)
- **Worktree:** `codex exec --worktree "..."` and `codex exec fork <SESSION_ID> --worktree "..."` create managed Git worktree. `--worktree` requires local execution; don't combine with `resume`, `review`, `--ephemeral`, or `--ignore-user-config`. (Developer commands, Non-interactive mode)
- **Ephemeral:** `--ephemeral` runs without persisting session rollout files to disk. Trust persists with `--ephemeral`; `--trust` conflicts with `--ignore-user-config`. (CLI reference, Non-interactive mode)
- **Git repo check:** Codex requires commands run inside a Git repo to prevent destructive changes; override with `codex exec --skip-git-repo-check` if environment is safe. (Non-interactive mode)

### JSON output / machine-readable events

- **`--json` / `--experimental-json`:** Print newline-delimited JSON events instead of formatted text. With `--json`, stdout becomes JSONL stream capturing events emitted while running. (CLI reference, Non-interactive mode)
- **Event types documented:** `thread.started`, `turn.started`, `turn.completed`, `turn.failed`, `item.*`, `error`. Item types include agent messages, reasoning, command executions, file changes, MCP tool calls, web searches, and plan updates. (Non-interactive mode)
- **Final message file:** `-o <path>` / `--output-last-message <path>` writes assistant's final message to file; still prints to stdout. Useful for scripting. (CLI reference, Non-interactive mode)
- **Structured output:** `--output-schema <path>` requests final response conforming to JSON Schema. (CLI reference, Non-interactive mode)
- **Color:** `--color always|never|auto` controls ANSI color in stdout. (CLI reference)

### Sandbox modes, approval policy, safety

- **Sandbox modes:** `read-only | workspace-write | danger-full-access` for `--sandbox/-s`. Default for `codex exec` is read-only sandbox. (CLI reference, Non-interactive mode, Config basics)
- **Workspace-write behavior:** allows edits/commands in workspace; network disabled by default unless enabled in config (`[sandbox_workspace_write].network_access = true`). Use `--add-dir` to grant additional writable dirs rather than `danger-full-access`. (Config basics, sandbox docs referenced by CLI ref)
- **Approval policy:** Global/interactive `--ask-for-approval/-a` accepts `on-request | never`. Config key `approval_policy` also documented as `on-request`/`never` in current basics; config reference notes granular object form and that `untrusted` unsupported, `on-failure` deprecated. (CLI reference, Config basics, Config reference)
- **Exec flag caveat:** CLI reference shows `--ask-for-approval/-a` as global flag; several docs/cheatsheets note `codex exec --help` may not expose it the same way as top-level interactive command. Non-interactive mode emphasizes sandbox/approval presets and `--approve-for-me`/`--yolo`; verify with target Codex version before scripting. (CLI reference, Developer commands, Non-interactive mode; local CLI unavailable)
- **Full-auto / bypass:** `--full-auto` is no longer supported for `codex exec`; use `--sandbox workspace-write` or `--approve-for-me`. `--dangerously-bypass-approvals-and-sandbox/--yolo` runs without approvals or sandboxing; only in externally hardened environment. `--approve-for-me/--not-so-yolo` uses automatic approval review with `on-request` approvals and `workspace-write` sandbox; conflicts with `--sandbox` and `--yolo`; interactive CLI rejects `--ask-for-approval` with it. (CLI reference, Non-interactive mode)
- **Config isolation:** `--ignore-user-config` skips `$CODEX_HOME/config.toml` (auth still uses `CODEX_HOME`); `--ignore-rules` skips user/project execpolicy `.rules`; `--trust` saves project trust for this/future chats, conflicts with `--ignore-user-config`. (CLI reference, Non-interactive mode)

### Hooks / verification

- **Hooks exist as a feature:** `[features].hooks` stable, default true; lifecycle hooks configured via `hooks.json` or inline `[hooks]`. `/hooks` command views/manages hooks. (Config basics, Developer commands)
- **Not a wiggum verify loop:** Hooks can react to lifecycle events, but Codex docs do not describe a built-in "run configured lint/test commands after each task, parse failures, retry agent with failure context until pass" orchestration equivalent to wiggum's `verify`/self-heal cycle. Verification remains user/prompt/workflow-defined.

## 3) Exact `codex exec --help` / CLI flag reference (documented)

> Local `codex exec --help` unavailable in this environment, so this section is extracted from official docs (CLI reference/developer commands/non-interactive mode). Where the official reference page renders dynamic tables, values were cross-checked against the markdown mirror at `https://learn.chatgpt.com/docs/cli/reference.md` and the non-interactive docs. Verify against the installed Codex version before scripting.

### Global flags (selected, relevant)

| Flag | Accepted values / type | Notes |
|---|---|---|
| `--model, -m` | string (e.g. `gpt-6.2-sol`) | Overrides configured model. |
| `--sandbox, -s` | `read-only \| workspace-write \| danger-full-access` | Sandbox policy for model-generated shell commands. |
| `--ask-for-approval, -a` | `on-request \| never` | When Codex pauses for human approval before running command. |
| `--approve-for-me, --not-so-yolo` | boolean | Automatic approval review with `on-request` approvals and `workspace-write` sandbox; conflicts with `--sandbox` and `--yolo`; interactive CLI rejects `--ask-for-approval`. |
| `--dangerously-bypass-approvals-and-sandbox, --yolo` | boolean | No approvals/sandboxing; only in externally hardened environment. |
| `-c, --config` | `key=value` (TOML if possible, else literal string) | Repeatable config override; precedence above project/profile/user config for invocation. |
| `--profile, -p` | string | Loads `$CODEX_HOME/profile-name.config.toml` over base user config. |
| `--cd, -C` | path | Set working directory before processing. |
| `--add-dir` | path | Grant additional writable dirs; repeatable. |
| `--search` | boolean | Enable live web search (`web_search="live"`). |
| `--oss` | boolean | Use local open source model provider. |
| `--local-provider` | `lmstudio \| ollama` | Local provider with `--oss`. |

Source: https://learn.chatgpt.com/docs/cli/reference.md, https://learn.chatgpt.com/docs/developer-commands.md

### `codex exec` flags/options (documented)

| Flag / arg | Accepted values / type | Notes |
|---|---|---|
| `PROMPT` | string or `-` (stdin) | Initial instruction; `-` reads prompt from stdin. |
| `--image, -i` | path[,path...] | Attach images to first message; repeatable/comma-separated. |
| `--model, -m` | string | Override configured model for run. |
| `--oss` | boolean | Local OSS provider; uses `--local-provider` or configured `oss_provider`. |
| `--local-provider` | `lmstudio \| ollama` | Local provider with `--oss`. |
| `--sandbox, -s` | `read-only \| workspace-write \| danger-full-access` | Sandbox policy; defaults to configuration/read-only for exec. |
| `--profile, -p` | string | Profile config layer. |
| `--approve-for-me, --not-so-yolo` | boolean | Auto approval review + workspace-write; conflicts with `--sandbox`/`--yolo`. |
| `--dangerously-bypass-approvals-and-sandbox, --yolo` | boolean | Bypass approvals/sandboxing. |
| `--dangerously-bypass-hook-trust` | boolean | Run enabled hooks without requiring persisted hook trust for this invocation; only for automation that already vets hook sources. |
| `--cd, -C` | path | Set workspace root before executing. |
| `--add-dir` | path | Grant additional writable dirs; repeatable. (Global flag; relevant to exec.) |
| `--worktree` | boolean | Run new/forked session in managed Git worktree; local execution only; not with `resume`, `review`, `--ephemeral`, `--ignore-user-config`. |
| `--skip-git-repo-check` | boolean | Allow running outside Git repo. |
| `--trust` | boolean | Save project trust for run/future chats; conflicts with `--ignore-user-config`. |
| `--ephemeral` | boolean | No persisted session rollout files. |
| `--ignore-user-config` | boolean | Do not load `$CODEX_HOME/config.toml`; auth still uses `CODEX_HOME`. |
| `--ignore-rules` | boolean | Do not load user/project execpolicy `.rules` files. |
| `--output-schema` | path | JSON Schema for model's final response. |
| `--color` | `always \| never \| auto` | ANSI color control; default `auto`. |
| `--json, --experimental-json` | boolean | Newline-delimited JSON events instead of formatted text. |
| `--output-last-message, -o` | path | Write assistant's final message to file. |
| `-c, --config` | key=value | Inline config override; repeatable. |

Source: https://learn.chatgpt.com/docs/cli/reference.md, https://learn.chatgpt.com/docs/non-interactive-mode

### Resume/fork syntax (documented)

| Command | Syntax / flags | Notes |
|---|---|---|
| Resume exec | `codex exec resume [SESSION_ID] [PROMPT?]` | Continue non-interactive session. `--last` picks most recent session from current working directory; `--all` searches across all sessions. Accepts follow-up prompt. |
| Fork exec | `codex exec fork <SESSION_ID> [PROMPT]` | Copy saved session into new session. SESSION_ID accepts UUID or name. No prompt creates fork without starting turn. `-` reads prompt from stdin. `--image` attaches images. Prompt required when using images, `--output-schema`, `--output-last-message`, or `--ephemeral`. |

Source: https://learn.chatgpt.com/docs/developer-commands.md, https://learn.chatgpt.com/docs/cli/reference.md

## 4) Reasoning effort levels and wiggum mapping

### Codex documented behavior

- **Config key:** `model_reasoning_effort` (string). Config reference description: "Reasoning effort advertised by the selected model, such as `low`, `medium`, `high`, `xhigh`, `max`, or `ultra`. Available levels depend on the model and client." (Config reference: https://learn.chatgpt.com/docs/config-file/config-reference.md)
- **Plan mode override:** `plan_mode_reasoning_effort` uses a level supported by the selected model; when unset, Plan mode uses built-in preset default. (Config reference)
- **Model-dependent:** Official docs repeatedly state available levels depend on model/client. Model selection/catalog should be treated as source of truth for a specific model. (Config reference, Model selection, Speed docs)
- **CLI/runtime controls:** `/model` can choose model and reasoning effort when available; `codex -c model_reasoning_effort=...` or `--config model_reasoning_effort=...` can set per run. (Developer commands, Config basics)

### Wiggum mapping (`low|medium|high|xhigh|max`)

| Wiggum level | Codex mapping | Notes |
|---|---:|---|
| `low` | `low` | Direct match when model supports it. |
| `medium` | `medium` | Direct match. |
| `high` | `high` | Direct match. |
| `xhigh` | `xhigh` | Direct match when model supports it. |
| `max` | `max` | Direct match when model supports it. |

**Gaps/caveats:**
- Codex may expose **additional** model-specific levels such as `ultra` (documented as example in config reference) and may omit some levels depending on model. Wiggum's fixed enum would need validation/pass-through policy for Codex.
- Older/third-party sources mention `minimal` or `none`; current official config reference examples list `low, medium, high, xhigh, max, ultra` and says model-dependent. Do not hardcode historical values without checking selected model catalog.
- For Codex integration, wiggum should map its known levels directly, pass through unknown Codex-supported values only if explicitly allowed, and surface a clear error when the target model rejects a level.

## 5) Skills, AGENTS.md, and `.agents/skills` behavior

### AGENTS.md

- **Discovery order:** At startup (once per run; in TUI usually once per launched session). Global scope: `$CODEX_HOME` (default `~/.codex`) reads `AGENTS.override.md` if exists, else `AGENTS.md`; only first non-empty file at that level. Project scope: from project root (typically Git root) down to current working directory; if no project root found, only checks current directory. In each directory checks `AGENTS.override.md`, then `AGENTS.md`, then any fallback names in `project_doc_fallback_filenames`. At most one file per directory. (AGENTS.md docs)
- **Merge/precedence:** Files concatenated root down, joined by blank lines; files closer to CWD override earlier guidance because they appear later in combined prompt. (AGENTS.md docs)
- **Size limit:** Skips empty files and stops adding files once combined size reaches `project_doc_max_bytes` (32 KiB default). Raise limit or split across nested dirs when hitting cap. (AGENTS.md docs; Config reference)
- **Fallback filenames:** `project_doc_fallback_filenames` config adds alternate filenames; checks `AGENTS.override.md`, `AGENTS.md`, then configured fallbacks. (AGENTS.md docs, Config reference)
- **Project trust:** Project-scoped `.codex/` layers load only in trusted projects; untrusted projects skip project config/hooks/rules. AGENTS loading behavior is tied to project trust/instruction loading; config reference and core behavior indicate project instructions are constrained by trust/budget. (Config basics, AGENTS.md docs)

### Skills

- **Format:** Skill directory with required `SKILL.md` containing `name` and `description`; optional `scripts/`, `references/`, `assets/`, `agents/openai.yaml`. (Build skills)
- **Progressive disclosure:** Codex starts with skill name/description/path metadata; loads full `SKILL.md` only when skill selected. Initial list uses at most 2% of model context window, or 8,000 chars when context window unknown; descriptions shortened first; some skills may be omitted for large sets with warning. `skills.max_context_tokens` sets different budget, up to 10,000 tokens. Budget applies only to initial skills list. (Build skills, Config reference)
- **Locations (repo/user/admin/system):** `REPO` `$CWD/.agents/skills`; `REPO` `$CWD/../.agents/skills` (above CWD inside Git repo); `REPO` `$REPO_ROOT/.agents/skills`; `USER` `$HOME/.agents/skills`; `ADMIN` `/etc/codex/skills`; `SYSTEM` bundled with Codex. Symlinked skill folders supported/followed. (Build skills)
- **Precedence/conflicts:** If two skills share same `name`, Codex does not merge them; both can appear in selectors. (Build skills)
- **Invocation:** Explicit via `/skills` or `$skill-name` in Codex CLI/IDE; implicit when task matches description. (Build skills)
- **Config controls:** `[[skills.config]]` entries can disable by path/name; `skills.bundled.enabled=false` in trusted project config disables bundled system skills for that project. (Build skills, Config reference)

### Wiggum relevance

- Codex skills are **richer/native agent packaging** than wiggum's current prompt/skill conventions, but they are Codex-specific (`.agents/skills`, `SKILL.md`, `$skill` invocation).
- AGENTS.md is conceptually similar to persistent repo instructions; wiggum should avoid duplicating/conflicting instruction sources when running inside Codex environments.
- For wiggum integration, `.agents/skills` is a natural place to expose wiggum workflows as Codex skills, but wiggum must account for discovery scope, name collisions, and context budget.

## 6) Wiggum capability mapping (redundant / additive / lossy)

| Wiggum capability | Codex native capability | Mapping | Evidence / caveat |
|---|---|---|---|
| Plan generation from issue/description | `/plan` plan mode; interactive planning; `codex exec` can be prompted to plan | **Additive / partial overlap** | Codex can plan, but not natively in wiggum's `docs/<slug>_plan.md` contract with task structure expected by wiggum executor. |
| Plan file as execution contract | No native wiggum-plan executor | **Lossy if replaced by Codex-only** | Wiggum's deterministic plan format, task sequencing, and summary artifact are not Codex-native. |
| Execute plan task-by-task | `codex exec` non-interactive runs; subagents/goals | **Additive but lossy on orchestration** | Codex can implement work, but wiggum's per-task control loop, verify-after-task, and commit-per-task are external orchestration. |
| Verification loop (lint/tests/typecheck, retry on failure) | Can run commands in sandbox; hooks feature exists | **Lossy if relying on Codex native behavior** | No documented built-in wiggum-equivalent verify-retry-commit loop. Wiggum should keep owning verification policy. |
| Git commit discipline (one logical change, no trailers) | Codex can run git commands if instructed/allowed | **Additive / risky** | Codex can commit, but wiggum's strict commit policy must be enforced by prompt/guardrails; native Codex behavior may vary. |
| Session resume / chaining | `codex exec resume --last/--all`, `codex fork`, interactive resume/fork, worktrees | **Additive** | Good primitives for long-running or branched work; wiggum chain semantics still need external state/plan management. |
| JSON/machine-readable automation | `codex exec --json` JSONL events, `--output-last-message`, `--output-schema` | **Additive** | Strong fit for wiggum supervisor/parsing. Event schema details should be validated on target CLI version. |
| Sandbox/approval controls | `--sandbox`, `--ask-for-approval`, `--approve-for-me`, `--yolo`, config/requirements | **Additive** | Maps well to wiggum execution modes; care needed for flag placement/version differences (`exec` vs global). |
| Reasoning effort control | `model_reasoning_effort`, `/model`, `-c model_reasoning_effort=...` | **Additive with mapping gap** | Direct mapping for wiggum's low/medium/high/xhigh/max; Codex also has model-dependent/extra levels. |
| Skills/instruction loading | AGENTS.md, `.agents/skills`, skill config, plugins | **Additive / potential duplication** | Can host wiggum guidance natively, but may duplicate or conflict with existing repo instructions/skills. |
| Review gate | `codex review`, `/review`, auto-review/approval features | **Additive** | Useful complement; not identical to wiggum verification/test gates. |

## 7) Integration cautions for wiggum

1. **Do not assume Codex replaces wiggum's orchestrator.** Codex provides agent capabilities; wiggum provides deterministic workflow control, plan artifacts, verification gates, and commit policy.
2. **Pin/inspect CLI version before scripting.** Docs show evolving flags/behavior (`--full-auto` removed for exec, `--json`/`--experimental-json`, approval policy evolution, worktree support). Local binary unavailable here.
3. **Treat `--ask-for-approval` carefully on `exec`.** Global docs list `on-request|never`; some sources note subcommand placement/version differences. Validate with `codex exec --help` on target install.
4. **Model-dependent reasoning levels.** Do not hardcode beyond model-validated set; map wiggum enum conservatively and expose pass-through only intentionally.
5. **AGENTS/skills context budget is real.** Large AGENTS or many skills can be truncated/omitted from initial skill list. Keep wiggum skill descriptions sharp and AGENTS concise.
6. **Security/trust boundaries.** `--yolo`/danger-full-access are high risk; `--trust`, `--ignore-user-config`, `--ignore-rules`, and project trust affect what instructions/MCP/rules load.

## Quick facts (for gap matrix)

- **Non-interactive command:** `codex exec` / `codex e`
- **JSON events:** `--json` (alias `--experimental-json`) -> JSONL on stdout
- **Final message file:** `--output-last-message/-o <path>`
- **Structured final output:** `--output-schema <path>`
- **Sandbox values:** `read-only | workspace-write | danger-full-access`
- **Approval values (documented global):** `on-request | never`
- **Resume:** `codex exec resume [SESSION_ID] [PROMPT]`, `--last`, `--all`
- **Fork:** `codex exec fork <SESSION_ID> [PROMPT]`, UUID or name, `-` stdin, `--image`
- **Reasoning config:** `model_reasoning_effort` string; examples `low, medium, high, xhigh, max, ultra`; model-dependent
- **AGENTS size limit:** `project_doc_max_bytes` default 32 KiB
- **Skills locations:** repo `.agents/skills` (CWD up to repo root), `~/.agents/skills`, `/etc/codex/skills`, bundled system skills

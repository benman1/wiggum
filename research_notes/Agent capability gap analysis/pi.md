# Pi Coding Agent

## What native planning features exist (plan mode extension/commands, built-in planning or todo tracking)? What is built in versus user-driven?

### Takeaway
Pi has no built-in planning mode or todo system in core; planning/todo workflows are user-driven via extensions, prompt templates, skills, or external files. The official docs ship `plan-mode` and `todo` as example extensions, and the CLI notes that extensions can add flags such as `--plan`. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Pi Extensions docs](https://docs.pi.dev/latest/extensions), [Installed pi --help, pi 1.6.0](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi), [Local plan-mode example](file:///Users/ben/.nvm/versions/node/v24.11.1/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/plan-mode/README.md), [Local todo example](file:///Users/ben/.nvm/versions/node/v24.11.1/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/todo.ts)

### Cited Findings
- Pi's built-in tools are `read`, `bash`, `powershell`, `edit`, `write`, `grep`, `find`, and `ls`; built-in extensions add inactive `codemode` and `tool_search` tools. No built-in plan/todo tool is listed. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi)
- The CLI help states: "Extensions can register additional flags (e.g., --plan from plan-mode extension)." — [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi), [Pi CLI docs](https://docs.pi.dev/latest/cli)
- The Extensions docs describe extension capabilities including custom tools, commands, shortcuts, flags, event interception, and state persistence; example use cases include "Stateful tools (todo lists, connection pools)". — [Pi Extensions docs](https://docs.pi.dev/latest/extensions)
- The installed examples include a `plan-mode` extension with `/plan`, `/todos`, `Ctrl+Alt+P`, and `--plan` flag behavior; it enforces read-only exploration by disabling edit/write, allowlisting bash commands, extracting `Plan:` steps, tracking `[DONE:n]`, and persisting state. — [Local plan-mode README](file:///Users/ben/.nvm/versions/node/v24.11.1/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/plan-mode/README.md), [Local plan-mode index](file:///Users/ben/.nvm/versions/node/v24.11.1/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/plan-mode/index.ts)
- The installed `todo.ts` example registers a `todo` tool and `/todos` command, storing state in tool result details for branch-aware reconstruction. — [Local todo example](file:///Users/ben/.nvm/versions/node/v24.11.1/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/todo.ts)
- Pi supports prompt templates (`/` commands from Markdown), skills (`SKILL.md` loaded on demand or `/skill:name`), and context files (`AGENTS.md`/`CLAUDE.md`) as user-driven instruction mechanisms, not built-in planning engines. — [Pi Prompt Templates docs](https://docs.pi.dev/latest/prompt-templates), [Pi Skills docs](https://docs.pi.dev/latest/skills), [Pi Configuration docs](https://docs.pi.dev/latest/configuration)

### Inferences
- For wiggum gap analysis, Pi's "planning" is composition/extensibility, not a native plan artifact lifecycle comparable to wiggum's `plan -> explain -> execute -> reconcile` workflow. Any plan-mode parity would require installing/authoring extensions and conventions.
- Todo tracking in Pi is possible but not standardized; branch-aware todo state depends on extension implementation details (e.g., storing state in session/tool-result details).

### Gaps
- I did not find a first-party, core-supported `plan` command or built-in plan file schema in Pi docs/help; absence is based on reviewed official docs and installed help/examples, not an exhaustive source audit of all Pi packages.
- I did not evaluate third-party Pi packages from pi.dev package gallery for maturity/feature parity of planning extensions.

## What native execution/autonomous loop features exist (`pi --print`, JSON/RPC modes, extensions, sessions, tools, retries, verification)?

### Takeaway
Pi provides native one-shot execution (`--print`), structured JSONL event streaming (`--mode json`), long-lived RPC control (`--mode rpc`), persistent sessions/forking, built-in coding tools, automatic retry/compaction/recovery events, and extension hooks. It does not provide wiggum-style built-in verify-waterfall/autofix/commit orchestration; verification and autonomous task loops are user- or extension-driven. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Pi CLI Integration docs](https://docs.pi.dev/latest/cli-integration), [Pi JSON docs](https://docs.pi.dev/latest/json), [Pi RPC docs](https://docs.pi.dev/latest/rpc), [Pi RPC Commands docs](https://docs.pi.dev/latest/rpc-commands), [Pi Sessions docs](https://docs.pi.dev/latest/sessions), [Pi Settings docs](https://docs.pi.dev/latest/settings)

### Cited Findings
- Invocation/output modes: `-p/--print` runs supplied prompts, writes final assistant text to stdout, exits; `--mode text|json|rpc`; JSON emits JSONL events; RPC reads JSONL commands from stdin and writes responses/events to stdout until shutdown. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi)
- CLI integration states all modes use same agent, sessions, resources, and tools. Print is one-shot final text; JSON is one-shot structured progress; RPC is long-lived bidirectional control; SDK is in-process alternative. — [Pi CLI Integration docs](https://docs.pi.dev/latest/cli-integration)
- JSON mode emits session header + events; `agent_end` is not final-idle, `agent_settled` means no remaining automatic work; includes tool execution, queue, compaction, retry, and bash execution update events. — [Pi JSON docs](https://docs.pi.dev/latest/json)
- RPC supports prompt/steer/follow_up/abort, model/thinking controls, compaction, retry controls, bash, session management, tree/entries/fork/clone, and command discovery. `prompt` response means accepted/queued/handled, not completed. — [Pi RPC docs](https://docs.pi.dev/latest/rpc), [Pi RPC Commands docs](https://docs.pi.dev/latest/rpc-commands)
- Sessions persist by default unless `--no-session`; supports continue/resume/session/fork/session-id/name/session-dir/export/share/bug; active branch supplies context; compaction summarizes older history. — [Pi Sessions docs](https://docs.pi.dev/latest/sessions), [Pi CLI docs](https://docs.pi.dev/latest/cli)
- Tools are configurable (`--tools`, `--no-tools`, `--no-builtin-tools`, `--exclude-tools`) and include built-ins plus extension/MCP tools; default enabled tools are `read,bash,edit,write` unless changed. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Pi Settings docs](https://docs.pi.dev/latest/settings)
- Retry/compaction settings exist: `retry.enabled`, `retry.maxRetries`, `retry.baseDelayMs`, `retry.maxAgentDelayMs`, provider retry settings; compaction settings include enabled/reserveTokens/keepRecentTokens/modelOverrides. RPC exposes `set_auto_retry`, `abort_retry`, `compact`, `set_auto_compaction`. — [Pi Settings docs](https://docs.pi.dev/latest/settings), [Pi RPC Commands docs](https://docs.pi.dev/latest/rpc-commands)
- Extensions can intercept tool calls, block commands, modify context/system prompt, register tools/commands/flags, handle session events, and implement custom workflows (permission gate, plan mode, todo, summarization, subagent patterns in examples). — [Pi Extensions docs](https://docs.pi.dev/latest/extensions)
- Security model: Pi runs with process permissions, does not ask for approval before every tool call by default; project trust gates loading project resources but is not a sandbox/permission boundary for tool calls. — [Pi Security docs](https://docs.pi.dev/latest/security)

### Inferences
- Pi has strong primitives for autonomous/agentic integrations (RPC/JSON, sessions, tool gating, retries), but "autonomous loop" behavior like wiggum's iterate-verify-fix-commit-stop conditions is an orchestration layer to build on top, not a built-in wiggum-equivalent command.
- Verification in Pi is possible through bash/tool calls and extension gates, but there is no native declarative verify/autofix waterfall config equivalent to `.wiggumrc` `verify`/`autofix`.

### Gaps
- I did not run a live Pi RPC/JSON session to observe event timing or retry behavior; findings are from official docs and local CLI/help.
- I did not inspect Pi source implementation beyond installed docs/examples/package metadata; behavior details are cited as documented.

## Exact CLI flags and accepted values from https://docs.pi.dev/latest/cli and installed `pi --help` if available

### Takeaway
Installed `pi --help` (v1.6.0) and docs.pi.dev CLI page align on the requested flags. Key accepted values: `--mode text|json|rpc`, `--thinking off|minimal|low|medium|high|xhigh|max`; `--approve/--no-approve` are trust overrides, not permission-mode enums. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi)

### Cited Findings
| Flag | Accepted values / form (docs + installed help) | Notes |
|---|---|---|
| `--print`, `-p` | boolean flag | Non-interactive; process prompt and exit. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi) |
| `--mode <mode>` | `text`, `json`, `rpc` | Output/interface mode; `text` may still open TUI on terminal unless `--print`. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi) |
| `--thinking <level>` | `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max` | Overrides model suffix; clamped to model capabilities. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi) |
| `--tools`, `-t <tools>` | comma-separated tool names/patterns (`*`), `+name`/`-name` delta entries; MCP kept unless entry starts with `mcp__` | Plain names replace defaults; `+/-` list modifies defaults. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi) |
| `--exclude-tools`, `-xt <tools>` | comma-separated tool names/patterns (`*`) | Applied after other selection options; MCP included. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi) |
| `--no-tools`, `-nt` | boolean flag | Disables all built-in/extension/custom/MCP tools by default. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi) |
| `--approve`, `-a` | boolean flag | Trust project-local files for this run. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi) |
| `--session-id <id>` | ID string; letters/numbers/`.`,`_`,`-`; must start and end with letter/number | Opens current dir's existing session with ID or creates it. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi) |
| `--fork <path|id>` | session file path or full/partial ID | Forks into new session in current directory; cannot combine with `--session`, `--continue`, `--resume`, `--no-session`. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi) |
| `--session <path|id>` | session file path or full/partial ID | Opens/resumes in session's working directory; may offer fork if ID matches other dir. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi) |
| `--skill <path>` | file or directory path, repeatable | Loads skill file/directory; explicit paths still load with `--no-skills`. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi) |
| `--no-context-files`, `-nc` | boolean flag | Disables `AGENTS.md` and `CLAUDE.md` discovery/loading. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Installed pi --help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi) |

- Installed version observed: `pi 1.6.0` (`pi --version`). — [Installed pi --version](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi)
- npm metadata for `@mariozechner/pi-coding-agent`: version `0.73.1`, description "Coding agent CLI...", homepage `https://github.com/badlogic/pi-mono#readme`, Node `>=20.6.0`. The installed binary reports `1.6.0` and package path `@earendil-works/pi-coding-agent`, indicating a different package/distribution line than the npm `@mariozechner/pi-coding-agent` metadata queried. — [npm view @mariozechner/pi-coding-agent](https://www.npmjs.com/package/@mariozechner/pi-coding-agent), [Installed pi --version/help](file:///Users/ben/.nvm/versions/node/v24.11.1/bin/pi)

### Inferences
- For automation, Pi's flag surface is rich for tool/model/session control, but permission/sandbox semantics are not expressed as Claude-style permission modes; they require tool selection, project trust, extensions, or external sandboxing.

### Gaps
- I did not confirm whether docs.pi.dev "latest" exactly corresponds to installed 1.6.0 build provenance; content matched on requested flags.
- I did not exhaustively diff every CLI flag between docs and `--help`; only requested flags were validated in detail.

## How should wiggum permission modes acceptEdits/auto/bypassPermissions/default/dontAsk/manual/plan map to Pi tool flags? Is there any sandbox or true permission-mode equivalent?

### Takeaway
Pi has no direct equivalent to wiggum/Claude permission modes. Closest controls are tool allow/deny flags (`--tools`, `--exclude-tools`, `--no-tools`), project trust flags (`--approve/--no-approve`), and extension `tool_call` blocking. True sandboxing/permission enforcement is external (OS/container/VM) or custom extension logic; Pi explicitly states project trust is not a sandbox and it runs with process permissions. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Pi Security docs](https://docs.pi.dev/latest/security), [Pi Extensions docs](https://docs.pi.dev/latest/extensions), [Wiggum README](file:///Users/ben/wiggum/README.md), [Wiggum .wiggumrc.example](file:///Users/ben/wiggum/.wiggumrc.example)

### Cited Findings
- Wiggum permission modes are Claude-vocabulary modes: `acceptEdits | auto | bypassPermissions | default | dontAsk | plan`; config default in code is `bypassPermissions` when absent, while `.wiggumrc.example` sets `permission_mode = auto` and docs describe auto as guarded unattended mode. — [Wiggum .wiggumrc.example](file:///Users/ben/wiggum/.wiggumrc.example), [Wiggum lib/wiggum.sh](file:///Users/ben/wiggum/lib/wiggum.sh), [Wiggum README](file:///Users/ben/wiggum/README.md)
- Pi security: "does not ask for approval before every tool call"; project trust controls resource loading, not tool-call access/effect; sandboxing requires OS/container/VM boundaries. — [Pi Security docs](https://docs.pi.dev/latest/security)
- Pi tool controls: `--tools` allowlist/delta, `--exclude-tools` denylist, `--no-tools` disables all, `--no-builtin-tools` disables built-ins only. Default tools `read,bash,edit,write`. — [Pi CLI docs](https://docs.pi.dev/latest/cli)
- Pi trust controls: `--approve` trusts project-local files for run; `--no-approve` ignores trust-gated project-local files; `defaultProjectTrust` setting. Trust is not permission prompt for tool actions. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Pi Settings docs](https://docs.pi.dev/latest/settings), [Pi Security docs](https://docs.pi.dev/latest/security)
- Pi extensions can block tool calls via `tool_call` event and can implement permission gates/plan mode; example `permission-gate.ts` prompts for dangerous bash commands, blocks by default in non-interactive mode without UI; example `plan-mode` disables edit/write and allowlists bash. — [Pi Extensions docs](https://docs.pi.dev/latest/extensions), [Local permission-gate example](file:///Users/ben/.nvm/versions/node/v24.11.1/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/permission-gate.ts), [Local plan-mode example](file:///Users/ben/.nvm/versions/node/v24.11.1/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/plan-mode/README.md)

### Inferences
| Wiggum mode | Approximate Pi mapping | Lossiness / caveats |
|---|---|---|
| `plan` | No native mode. Approximate with read-only tools `--tools read,grep,find,ls` or custom plan-mode extension that blocks writes/destructive bash. | Lossy: no built-in plan artifact/review workflow; bash can still be risky unless excluded/filtered; requires extension for true parity. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Pi Extensions docs](https://docs.pi.dev/latest/extensions) |
| `acceptEdits` | No direct equivalent. Approximate by allowing `read,edit,write,grep,find,ls` and excluding/guarding `bash` via `--exclude-tools bash` or extension gate. | Lossy: no fine-grained "accept edits only" permission classifier; extension needed for prompts/allowlists. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Pi Extensions docs](https://docs.pi.dev/latest/extensions) |
| `auto` | No native classifier mode. Approximate with default tools plus permission-gate extension; for non-interactive, custom extension must encode policy. | Lossy: not built-in; behavior depends on extension quality; no standard audited policy. — [Pi Security docs](https://docs.pi.dev/latest/security), [Pi Extensions docs](https://docs.pi.dev/latest/extensions) |
| `bypassPermissions` | Closest: default/full tools with no permission extension, run in trusted/sandboxed environment as needed. | Lossy naming: Pi has no permission prompts to bypass; actual safety depends on OS/container sandbox. — [Pi Security docs](https://docs.pi.dev/latest/security) |
| `default` / `dontAsk` | No direct equivalent. `default`-like interactive confirmation can be approximated only by extension UI prompts; `dontAsk`/headless deny-on-prompt by extension returning block when no UI. | Highly lossy: no native permission mode matrix; extension-specific. — [Pi Extensions docs](https://docs.pi.dev/latest/extensions) |
| `manual` (if used by wiggum/Claude semantics) | No native mode. Approximate by disabling tools and running human-driven steps, or extension that blocks all mutating tools. | Lossy: manual approval workflow not built in. — [Pi CLI docs](https://docs.pi.dev/latest/cli) |

- There is no true Pi permission-mode equivalent like Claude/wiggum mode enums. The closest native controls are tool availability and project trust; true enforcement boundary is external sandboxing or extension policy. — [Pi Security docs](https://docs.pi.dev/latest/security), [Pi CLI docs](https://docs.pi.dev/latest/cli)

### Gaps
- I did not inspect wiggum's non-default agent adapters beyond visible README/config/lib snippets; mapping is based on wiggum's documented Claude-vocabulary modes and Pi's documented controls.
- No authoritative Pi "permission mode" feature was found; this is a documented absence/inference from official docs.

## Does Pi read AGENTS.md/CLAUDE.md? Where does it discover skills and prompt templates?

### Takeaway
Yes. Pi discovers `AGENTS.md`/`CLAUDE.md` context files by default from agent dir, cwd, and ancestor directories; `--no-context-files` disables them. Skills load from agent/project conventional dirs and `.agents/skills`, plus configured paths/packages; prompt templates load from agent/project prompts dirs, configured paths/packages. Project resources are gated by project trust, while context-file discovery is not. — [Pi Configuration docs](https://docs.pi.dev/latest/configuration), [Pi CLI docs](https://docs.pi.dev/latest/cli), [Pi Skills docs](https://docs.pi.dev/latest/skills), [Pi Prompt Templates docs](https://docs.pi.dev/latest/prompt-templates), [Pi Settings docs](https://docs.pi.dev/latest/settings)

### Cited Findings
- `--no-context-files, -nc` disables `AGENTS.md` and `CLAUDE.md` discovery and loading. — [Pi CLI docs](https://docs.pi.dev/latest/cli)
- Agent dir loads `AGENTS.override.md`, `AGENTS.md`, `AGENTS.MD`, `CLAUDE.md`, or `CLAUDE.MD` as user instructions across working directories. — [Pi Configuration docs](https://docs.pi.dev/latest/configuration)
- Context files are discovered from agent directory, working directory, and parent directories; `AGENTS.override.md` replaces `AGENTS.md`/`CLAUDE.md` only in same directory. Context-file discovery does not require project trust. — [Pi Configuration docs](https://docs.pi.dev/latest/configuration)
- Skills: conventional locations `<agent-dir>/skills/`, `.pi/skills/`; also supports `~/.agents/skills/` and `.agents/skills/` (project `.agents/skills` discovered from cwd through ancestors, stopping at repo root). Startup scans configured locations, adds name/description/path to system prompt, loads full `SKILL.md` on demand; `/skill:name` forces loading. — [Pi Skills docs](https://docs.pi.dev/latest/skills), [Pi Configuration docs](https://docs.pi.dev/latest/configuration)
- Prompt templates: `<agent-dir>/prompts/` and `.pi/prompts/` conventional dirs; filename becomes `/command`; can be loaded from explicit path or package; project templates require trust. — [Pi Prompt Templates docs](https://docs.pi.dev/latest/prompt-templates), [Pi Configuration docs](https://docs.pi.dev/latest/configuration)
- Settings support `skills`, `prompts`, `packages`, `enableSkillCommands`; resource arrays support `!`, `+`, `-` filters; project settings merge/overlay user settings. — [Pi Settings docs](https://docs.pi.dev/latest/settings)
- Project trust gates project settings/resources under `.pi` and project `.agents/skills`, but context files load regardless of trust unless context loading disabled. — [Pi Security docs](https://docs.pi.dev/latest/security)

### Inferences
- Pi is compatible with AGENTS/CLAUDE instruction ecosystems and Agent Skills conventions, making it easier to align with repos already using those files; however, trust semantics differ for context files vs executable project resources.

### Gaps
- I did not empirically test precedence edge cases across all filename variants and nested overrides; statements follow documented behavior.

## Which wiggum capabilities are redundant, which are additive, and where would a mapping be lossy?

### Takeaway
Pi overlaps with wiggum on basic agent execution primitives (CLI invocation, tools, sessions, model/thinking selection, context files, skills/prompts/extensions). Wiggum adds opinionated SDLC orchestration: plan/execute/check/docs/run lifecycle, verify/autofix waterfall, task-checkbox progress/stall detection, commit discipline, background supervision/chain, and permission-mode abstraction. Mapping is lossy around deterministic workflow control, verification policy, and permissions/sandbox semantics. — [Wiggum README](file:///Users/ben/wiggum/README.md), [Wiggum AGENTS/CLAUDE instructions](file:///Users/ben/wiggum/CLAUDE.md), [Pi CLI docs](https://docs.pi.dev/latest/cli), [Pi Sessions docs](https://docs.pi.dev/latest/sessions), [Pi RPC/JSON docs](https://docs.pi.dev/latest/rpc), [Pi Security docs](https://docs.pi.dev/latest/security)

### Cited Findings
- Wiggum provides `init`, `plan`, `explain`, `execute`, `check`, `docs`, `run`, plus supervision `status/watch/kill/top/chain`, background runs, delayed runs, and structured plan/summary artifacts. — [Wiggum README](file:///Users/ben/wiggum/README.md)
- Wiggum executes plans through phases: diagnostic/sync, implementation loop with verify waterfall and self-heal, final reconciliation/summary/commit; tracks `[ ]/[x]/[~]` checkboxes and stalls. — [Wiggum README](file:///Users/ben/wiggum/README.md)
- Wiggum config includes `verify`/`autofix`/`benchmark`, iteration/retry limits, `effort`, `permission_mode`, and per-phase model selection. — [Wiggum .wiggumrc.example](file:///Users/ben/wiggum/.wiggumrc.example)
- Pi provides interactive/print/json/rpc modes, session resume/fork/tree/id, tool controls, model/thinking controls, extension system, skills/prompt templates, AGENTS/CLAUDE context loading, MCP, and SDK/RPC integration. — [Pi CLI docs](https://docs.pi.dev/latest/cli), [Pi CLI Integration docs](https://docs.pi.dev/latest/cli-integration), [Pi Sessions docs](https://docs.pi.dev/latest/sessions), [Pi Extensions docs](https://docs.pi.dev/latest/extensions)
- Pi has no built-in permission-mode enum equivalent; security relies on process permissions and external sandboxing, with project trust for resource loading. — [Pi Security docs](https://docs.pi.dev/latest/security)
- Pi has automatic retry/compaction and evented lifecycle, but no built-in wiggum-style verify/autofix waterfall or plan-checkbox orchestration command. — [Pi Settings docs](https://docs.pi.dev/latest/settings), [Pi JSON docs](https://docs.pi.dev/latest/json), [Wiggum README](file:///Users/ben/wiggum/README.md)

### Inferences
| Area | Redundant / overlapping | Additive in Pi | Additive in Wiggum | Mapping lossiness |
|---|---|---|---|---|
| Execution primitives | Agent CLI runs, model selection, thinking/effort-like controls, tool invocation | Rich RPC/JSON/SDK interfaces, extension API, MCP, package system | N/A | Low for basic prompt execution; medium for lifecycle semantics (`agent_end` vs settled/run completion). |
| Planning | Both can produce plans via prompts/files | Skills/templates/extensions can implement custom planners | Native `plan`/`explain` workflow, plan structure conventions, feedback pass, issue-ledger reconciliation rules | High: Pi lacks built-in plan lifecycle and reconciliation semantics. |
| Verification/quality | Both can run shell commands/tests | Extensions can intercept tool results/events; codemode/tooling | Declarative verify/autofix waterfall, validation retries, benchmark hooks, self-heal loop tied to plan progress | High: must be reimplemented as orchestration/extensions. |
| Autonomy/supervision | Sessions and retries exist in both ecosystems | RPC event stream, queueing/steer/follow-up, session tree APIs | `status/watch/kill/top/chain`, background/delayed run ops, stall detection on checkbox progress | High: Pi gives primitives, Wiggum gives operator workflow. |
| Permissions/safety | Tool restriction possible | Fine-grained tool allow/deny patterns, extension hooks, project trust controls | Simple permission-mode abstraction across agents, unattended defaults/policy | High: no 1:1 mode mapping; sandboxing external in Pi. |
| Repo conventions | Context files/skills/prompts | Broad package/resource ecosystem, AGENTS/CLAUDE discovery controls | Opinionated git/commit/plan/issue-ledger behavior in execution loop | Medium-high: policy can be prompted, less enforceable by default. |

### Gaps
- No hands-on benchmark comparing Pi+custom extensions vs wiggum on same tasks; redundancy/lossiness assessment is documentation-based.
- Pi package ecosystem may contain planning/orchestration extensions that reduce gaps; not surveyed.
# OpenCode native capabilities — gap analysis against wiggum (as of 2026-11-22)

## Key question 1: Native planning features — what is built in vs user-driven?

### Takeaway
OpenCode ships a restricted `plan` primary agent and a set of generic TUI commands; it has no built-in workplan generator, no plan file format, no acceptance-criteria engine, and no plan-driven execution loop. Structured planning is user-driven (a custom agent, command, skill, or an external CLI such as wiggum). Todo tracking exists as an opt-in tool in V2.

### Cited Findings
- V2 built-in agents are `build` (primary, default coding agent), `plan` (primary, read-only planning agent), `general` (subagent), `explore` (subagent); hidden `compaction`, `title`, `summary` perform maintenance and cannot be selected. There is no built-in `scout` in V2 — [Agents](https://opencode.ai/docs/agents).
- `plan` is a *permission profile*, not a planning workflow: it explores and plans without editing normal project files, may write OpenCode plan files when asked, and its shell commands remain permission-controlled — [Agents](https://opencode.ai/docs/agents).
- Plan file locations are documented inconsistently across official pages. The Agents page says Markdown plan files in `.opencode/plans/` and the plans directory under OpenCode's data directory; the Permissions page says edits are denied except under `~/.opencode/plan` (singular). Treat the exact path as version-dependent — [Agents](https://opencode.ai/docs/agents); [Permissions](https://opencode.ai/docs/permissions).
- In the installed V1 line, `OPENCODE_EXPERIMENTAL_PLAN_MODE` makes Plan save its plan to `.opencode/plans/` for Git projects, or `plans/` under the data directory otherwise — [OpenCode V1 CLI / environment variables](https://opencode.ai/v1/docs/cli).
- Plan's defaults are applied before the top-level permission config and the last matching rule wins, so a global `"*": "allow"` also re-enables edits for Plan. Restricting it requires explicit per-agent permissions — [Agents (cached V1-era text)](http://opencode.ai:2082/docs/agents); [Permissions](https://opencode.ai/docs/permissions).
- Todo tracking in V2 is opt-in: `"experimental": { "todo": true }` gives agents a `todowrite` tool; default `false` — [Config](https://opencode.ai/docs/config). V1 exposed `todowrite` as a permission key but did not document an always-on todo tool — [V1 permissions (cached)](http://opencode.ai:2082/docs/permissions).
- Built-in TUI commands are generic session/model/navigation actions: `/new`, `/sessions`, `/models`, `/agents`, `/undo`, `/redo`, `/editor`, `/btw`, `/mcps`, `/highlights`, plus the Ctrl+P palette. No `/plan` command is listed as built in — [TUI](https://opencode.ai/docs/tui).
- A user can create `/plan` themselves as a Markdown command with `agent: plan` frontmatter, or select Plan via `/agents` / Shift+Tab — [Commands](https://opencode.ai/docs/commands); [TUI](https://opencode.ai/docs/tui).
- Agent options relevant to bounded work: `steps` sets a positive maximum number of model steps, after which tools are removed and the model summarises; new user input resets the allowance — [Agents](https://opencode.ai/docs/agents).
- Wiggum by contrast generates a structured workplan (benefits with observable signals, backwards-derived critical path, constraints, checkboxes, acceptance criteria, issue references) and consumes it as control flow — [wiggum_baseline.md:13-19](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L13-L19).

### Inferences
- OpenCode's `plan` agent replaces only wiggum's "read-only analysis" mode. It has no plan artifact contract, no per-task acceptance checks, no progress counter, and no handoff to an executor.
- `todowrite` is a model-facing scratchpad, not a durable plan file that survives sessions or drives retries; wiggum's checkbox state machine has no OpenCode equivalent.
- `steps` is a per-agent step ceiling, a weaker cousin of wiggum's `max_iterations` and validation-retry caps.

### Gaps
- No official page documents a built-in OpenCode command that generates a file-based workplan with phases and acceptance criteria; the negative claim rests on the Agents, Commands, TUI and Config pages listing none.
- The exact V2 plan file path could not be settled because two official pages disagree (`~/.opencode/plan` vs `.opencode/plans/`).

## Key question 2: Native execution / autonomous-loop features

### Takeaway
OpenCode provides the primitives for unattended work (one-shot `run`, JSON event stream, HTTP server, session fork/wait APIs, always-background subagents, permission auto-approval) but no opinionated loop: no built-in verify→fix→retry waterfall, no plan-progress stopping rule, no per-run supervision registry, and no commit step.

### Cited Findings
- `opencode run "prompt"` submits a prompt without the TUI, designed for scripts and CI — [CLI](https://opencode.ai/docs/cli).
- `--format json` emits raw JSON events; `--format default` is formatted output (the default) — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md); [V1 CLI](https://opencode.ai/v1/docs/cli#run).
- `--command` runs a saved command with the message as its arguments; `-f/--file` attaches files — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md).
- `opencode serve` starts a headless HTTP server; `opencode web` adds a web UI; `opencode acp` speaks nd-JSON over stdin/stdout; `opencode mini` is a minimal interactive interface — [V1 CLI](https://opencode.ai/v1/docs/cli); [CLI](https://opencode.ai/docs/cli).
- V2 uses one shared background server per user by default; every local client connects to it and it owns sessions, configuration, integrations, permissions and tool execution. `--standalone` gives a private server, `--server <url>` connects to a specific one, and `opencode service set disabled true` disables the shared service — [CLI](https://opencode.ai/docs/cli).
- `opencode run --attach http://localhost:4096` reuses a running server to avoid MCP cold boots; `--port` selects a local server port (random when omitted) — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md); [V1 CLI](https://opencode.ai/v1/docs/cli#run).
- The V2 HTTP API exposes the loop substrate: `POST /api/session` (with `parentID` for child sessions), `POST /api/session/{id}/prompt`, `POST /api/session/{id}/fork`, `POST /api/experimental/session/{id}/wait` (wait until the agent loop is idle), `POST /api/session/{id}/agent`, `POST /api/session/{id}/model`, `POST /api/session/{id}/command`, `POST /api/experimental/session/{id}/skill`, `POST /api/session/{id}/compact`, and revert staging — [API reference](https://opencode.ai/docs/api).
- Subagents run only in child sessions, always in the background, and report to the parent when idle and after each later round; `subagent_depth` defaults to `1`, so a subagent cannot start another — [Agents](https://opencode.ai/docs/agents); [Config](https://opencode.ai/docs/config).
- The shell tool supports `background: true` for long processes: the call returns immediately and notifies the session on completion — [Tools](https://opencode.ai/docs/tools).
- Retries/verification: V1 had a `doom_loop` permission triggered when the same tool call repeats three times with identical input; V2's permissions page states `doom_loop` and `lsp` are not current V2 Core permission actions — [V1 permissions (cached)](http://opencode.ai:2082/docs/permissions); [Permissions](https://opencode.ai/docs/permissions).
- No documented native hook runs a project's lint/test/build commands after each edit and feeds failures back for repair. The nearest built-in is `formatter`, which formats files after `write`/`edit`/`patch`, and the `question` tool for interactive approvals — [Config](https://opencode.ai/docs/config); [Tools](https://opencode.ai/docs/tools).
- OpenCode has no built-in commit step and no machine-wide run registry; wiggum owns bounded iterations, an ordered verify/autofix waterfall, retry caps, single-line imperative commits, `status`/`watch`/`kill`/`top`, chaining and delayed runs — [wiggum_baseline.md:17-25](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L17-L25).

### Inferences
- A wiggum-like loop can be rebuilt on OpenCode by scripting `opencode run --format json` plus the session API, but every policy layer (what counts as done, which commands verify, when to stop, how to commit) must be written by the caller.
- OpenCode's background subagents and `session.wait` cover wiggum's "detached run + watch" need at session granularity, not at plan/task granularity.
- `steps` and the step-boundary behaviour of `session.compact` / `location.reload` give natural checkpoints for a caller-owned loop.

### Gaps
- No official documentation was found for a native verification-hook mechanism or a built-in retry-with-fix loop; the claim is based on absence from the Tools, Config, Permissions, Agents and API pages.
- Whether V2 plugins can implement verification hooks was not researched; plugin docs were outside the pages fetched.
- Exact V2 `opencode run --help` flags were not re-derived from a V2 binary (see version caveat in Key question 3).

## Key question 3: Exact `opencode run --help` flags and accepted values

### Takeaway
The installed binary is OpenCode **1.19.6** at `/Users/ben/.opencode/bin/opencode`. Its `run` help exposes 22 options; the values below are transcribed verbatim from that binary and cross-checked against the V1 CLI documentation. Current stable release is V2 (2.3.2), so V2 flag surfaces may differ.

### Cited Findings
- Version caveat: `opencode --version` → `1.19.6`. GitHub releases show **v2.3.2**, published 2026-11-18, as the current stable; the official docs default to V2 and keep V1 docs at `/v1/docs` — [GitHub releases](https://api.github.com/repos/anomalyco/opencode/releases?per_page=5); [V1 CLI](https://opencode.ai/v1/docs/cli); [CLI](https://opencode.ai/docs/cli).
- Invocation: `opencode run [message..]`; `message` is an array positional, default `[]` — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md).
- Global flags present on `run`: `-h, --help` (boolean), `-v, --version` (boolean), `--print-logs` (boolean), `--log-level` with choices `DEBUG | INFO | WARN | ERROR` (string), `--pure` (boolean, run without external plugins) — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md).
- `-c, --continue` (boolean): continue the last session — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md).
- `-s, --session` (string): session id to continue — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md).
- `--fork` (boolean): fork the session before continuing; **requires `--continue` or `--session`** — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md).
- `-m, --model` (string): model in `provider/model` format — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md).
- `--agent` (string): agent to use; the help text enumerates no accepted values — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md).
- `--format` (string) with choices `default` (formatted) or `json` (raw JSON events), default `default` — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md).
- `--variant` (string, free-form): "model variant (provider-specific reasoning effort, e.g., high, max, minimal)"; no enumerated choices in the CLI — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md).
- `--thinking` (boolean): **"show thinking blocks"**, default false. It is a display flag, not an effort selector — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md); [V1 CLI](https://opencode.ai/v1/docs/cli#run).
- `-i, --interactive` (boolean, default false): direct interactive split-footer mode — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md).
- `--auto` (boolean, default false): "auto-approve permissions that are not explicitly denied (dangerous!)" — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md).
- Remaining flags: `-f, --file` (array), `--title` (string), `--attach` (string), `-p, --password` (string, defaults to `OPENCODE_SERVER_PASSWORD`), `-u, --username` (string, defaults to `OPENCODE_SERVER_USERNAME` or `opencode`), `--dir` (string), `--port` (number, defaults to a random port), `--command` (string) — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md); [V1 CLI](https://opencode.ai/v1/docs/cli#run).
- The V2 CLI documentation page describes `opencode run` and the background service but does not publish a flag table, so the V2 equivalents of `--variant`, `--thinking`, `--auto` and `--format` could not be confirmed from that page — [CLI](https://opencode.ai/docs/cli).
- Wiggum's OpenCode adapter emits `run --format json`, adds `--session <id> --fork` on continuation, `-m <model>`, `--variant <variant>` and an unconditional `--auto`; it does not pass `--thinking` to OpenCode — [lib/wiggum.sh:3111-3131](/Users/ben/wiggum/lib/wiggum.sh#L3111-L3131).

### Inferences
- The flag names wiggum uses all exist in the installed V1 binary; the risk is accepted *values*, not flag spelling.
- `--auto` matches wiggum's unattended-execution need but collapses every permission mode into one boolean.

### Gaps
- No V2 binary was installed, so exact V2 `run --help` output and any renamed/removed flags remain unverified.
- The allowed set of `--agent` values is enumerated in docs (build/plan/general/explore plus custom agents) but not in `--help`; see [Agents](https://opencode.ai/docs/agents).

## Key question 4: Reasoning variants and wiggum effort mapping

### Takeaway
Effort is expressed as a named **model variant**, appended as `#variant` to a model selector; names are provider/model-catalog-specific and unrecognised names fail. `--thinking` only toggles display of thinking blocks. Wiggum's five-level effort maps to three usable OpenCode variants and is lossy for `xhigh`/`max` and for models that lack the requested variant.

### Cited Findings
- Variants are named options for one model, often reasoning effort or token budgets; add `#variant` when selecting one for a run, session, agent or command — [Models](https://opencode.ai/docs/models).
- Variant names come from the selected model's current catalog metadata. Names such as `low`, `high` and `max` are not available for every model; an unknown variant produces a model-resolution error — [Models](https://opencode.ai/docs/models).
- Examples of variant selectors: `openai/gpt-6.1-sol#high`, `openrouter/anthropic/claude-sonnet-5.5#high`; provider is case-sensitive, model may contain `/`, variant follows `#` — [Models](https://opencode.ai/docs/models).
- Variants can be defined or overridden in `providers.<id>.models.<model>.variants[]` with `id`, `settings`, `headers`, `body`; `settings.reasoningEffort` accepts e.g. `low`, `medium`, `high` — [Models](https://opencode.ai/docs/models).
- Reasoning variants can also be generated from `capabilities.reasoning`: `supported`, `toggle` (adds a `none` variant), `effort` (list such as `["low","medium","high"]`), and `budget` (`min`/`max` tokens, ignored when `effort` is set) — [Models](https://opencode.ai/docs/models).
- Root `model` config currently retains only provider and model, not a variant; select variants for a session, run, agent or command instead — [Models](https://opencode.ai/docs/models); [Config](https://opencode.ai/docs/config).
- Agent and command `model` fields accept `provider/model#variant`, e.g. `anthropic/claude-sonnet-5-5#high` — [Agents](https://opencode.ai/docs/agents); [Commands](https://opencode.ai/docs/commands).
- Wiggum accepts `low | medium | high | xhigh | max` and maps OpenCode `xhigh|max → max`, everything else passes through — [lib/wiggum.sh:3121-3127](/Users/ben/wiggum/lib/wiggum.sh#L3121-L3127); [README.md:924-930](/Users/ben/wiggum/README.md#L924-L930).
- Wiggum's default effort is `xhigh`, so the default OpenCode run asks for variant `max` — [README.md:928](/Users/ben/wiggum/README.md#L928); [lib/wiggum.sh:3121-3127](/Users/ben/wiggum/lib/wiggum.sh#L3121-L3127).

### Inferences
- Suggested mapping: `low→low`, `medium→medium`, `high→high`, `xhigh→max`, `max→max` (wiggum's current behaviour); `xhigh` and `max` are indistinguishable on OpenCode, and any level is invalid on a model whose catalog lacks that variant name.
- A lossless mapping would need to read the model catalog at run time and choose the closest offered variant (or define custom variants in config), then record which variant was actually used.
- The distinction between reasoning *effort* (`--variant`) and thinking-block *display* (`--thinking`) must be preserved in any adapter; conflating them would change behaviour.

### Gaps
- No authoritative table of which providers offer which variant names was found; the docs explicitly defer to per-model catalog metadata at models.dev, so a fixed wiggum table cannot be guaranteed correct.
- Whether V2 retains `--variant` with identical semantics was not verified against a V2 binary.

## Key question 5: Permission controls

### Takeaway
OpenCode has a fine-grained, per-agent allow/ask/deny system keyed by tool action and resource. V2 uses an ordered `permissions` array with last-match-wins; V1 (the installed binary) uses a `permission` object with tool-name keys. `--auto` auto-approves everything not explicitly denied and is the only headless permission switch in `run`.

### Cited Findings
- V2 rules are `{ action, resource, effect }` triples; effect is `allow`, `deny`, or `ask`; last matching rule wins; no match means `ask` — [Permissions](https://opencode.ai/docs/permissions).
- V1 used different names: V2 `permissions`/`shell`/`subagent` replace V1 `permission`/`bash`/`task`; as of V1 1.1.1 the old `tools` boolean config was deprecated and merged into `permission` — [Permissions](https://opencode.ai/docs/permissions); [V1 permissions (cached)](http://opencode.ai:2082/docs/permissions).
- V2 built-in actions include `read`, `edit`, `glob`, `grep`, `shell`, `subagent`, `skill`, `question`, `webfetch`, `websearch`, `experimental_image_generate`, `external_directory`, `<server>_<tool>` for MCP, and `execute` for Code Mode; `doom_loop` and `lsp` are not current V2 Core actions — [Permissions](https://opencode.ai/docs/permissions).
- V1 permission keys included `read`, `edit`, `glob`, `grep`, `bash`, `task`, `todowrite`, `webfetch`, `websearch`, `lsp`, `skill`, `question`, `external_directory`, `doom_loop`, with shorthand `allow|ask|deny` or object syntax mapping patterns to actions — [V1 permissions (cached)](http://opencode.ai:2082/docs/permissions).
- Base policy in V2: allow all actions, then `ask` for reading `*.env` and `*.env.*`, then allow `*.env.example`; shipped agents append policies (Plan denies edits except plan files, general denies questions and subagents, explore is read/search-only, title/summary deny all) — [Permissions](https://opencode.ai/docs/permissions).
- External paths are allowed by default; an explicit `external_directory` rule is needed to prompt or block access outside the Location/worktree — [Permissions](https://opencode.ai/docs/permissions).
- Approvals support `once`, `always` (saves a project-scoped allow rule) and `reject`; saved approvals never override a configured `deny` — [Permissions](https://opencode.ai/docs/permissions).
- Policies are separate from permissions: binary allow/deny, never prompt, can hard-deny after permission rules and saved approvals, and can be Console-managed with higher precedence than project config — [Permissions](https://opencode.ai/docs/permissions); [Policies](https://opencode.ai/docs/policies).
- `--auto` on `opencode run` auto-approves permissions that are not explicitly denied and is marked "dangerous!" — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md).
- Wiggum's six Claude-style permission modes are documented as mapping to each agent's own gatekeeper, but its OpenCode adapter always appends `--auto` and reads no permission value — [README.md:930](/Users/ben/wiggum/README.md#L930); [lib/wiggum.sh:3111-3131](/Users/ben/wiggum/lib/wiggum.sh#L3111-L3131).

### Inferences
- `--auto` is closest to wiggum's `bypassPermissions` (subject to configured `deny` rules), not to `auto`/`default`/`plan`. `plan` would need `--agent plan` plus permissions that deny edits; `acceptEdits` would need a tailored allow rule.
- Wiggum's permission vocabulary cannot be round-tripped through OpenCode: six values collapse to one boolean plus config-file rules, and the config rules are project-scoped rather than per-call flags.
- OpenCode's `ask` default means a non-interactive `run` without `--auto` may block on approval; non-interactive clients must decide how to handle approval requests.

### Gaps
- No single CLI flag reproduces wiggum's per-call `plan` or `acceptEdits` semantics; achieving them requires a combination of `--agent`, config rules, or a separate config file.
- Whether V2's `run` still exposes `--auto` with the same text was not confirmed from a V2 binary.

## Key question 6: Session resume, fork, and session-level model/agent controls

### Takeaway
OpenCode has durable sessions with resume by id or "last session", fork-on-resume, a REST API to fork/wait/switch agent or model, undo/redo via snapshots, and session export/import. Wiggum's use of `--session <id> --fork` is valid V1 syntax; its failure hint uses a different form (`opencode -s <id>`).

### Cited Findings
- `--session <id>` continues a specific session; `--continue` continues the last one; `--fork` forks before continuing and requires one of the other two — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md).
- TUI equivalents: Ctrl+X then L or `/sessions` to return to a session; Ctrl+O for recent sessions and projects; tabs on by default — [TUI](https://opencode.ai/docs/tui).
- `/undo` reverts the latest user message and the work that followed it; `/redo` restores it. These rely on filesystem snapshots, which can be disabled with `"snapshots": false` — [TUI](https://opencode.ai/docs/tui); [Config](https://opencode.ai/docs/config).
- V2 API: `POST /api/session/{id}/fork` creates a child session by copying projected history before a message (omit `before` for full history); `POST /api/experimental/session/{id}/wait` waits until the agent loop is idle; `POST /api/session/{id}/agent` and `.../model` switch agent/model for subsequent turns; `POST /api/session/{id}/move` moves a session to another directory — [API reference](https://opencode.ai/docs/api).
- V1 CLI has `opencode session list|delete`, `opencode export [--sanitize]` and `opencode import <file>` for session portability — [V1 CLI](https://opencode.ai/v1/docs/cli).
- `opencode run` can attach to a running server and set a session title; `sessionID` appears in the JSON event stream — [installed CLI v1.19.6: `opencode run --help`](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/opencode.md); [lib/wiggum.sh:3197-3212](/Users/ben/wiggum/lib/wiggum.sh#L3197-L3212).
- Wiggum forks from a captured OpenCode session id on continuation and suggests `opencode -s <id>` when a run fails — [lib/wiggum.sh:3117-3119](/Users/ben/wiggum/lib/wiggum.sh#L3117-L3119); [lib/wiggum.sh:3214-3221](/Users/ben/wiggum/lib/wiggum.sh#L3214-L3221).

### Inferences
- OpenCode's fork is a first-class session operation, so wiggum's retry-from-predecessor strategy maps directly; the mismatch is only in the human-facing resume hint.
- Session-level model/agent switching is available through the API rather than `run` flags, so a caller-owned loop would need the server to vary model or agent mid-run.

### Gaps
- `--fork` accepts no "from message" argument in the V1 CLI; fine-grained fork points require the API.
- V2 CLI equivalents of `--continue`, `--session`, `--fork` were not verified against a V2 binary; the V2 CLI intro page mentions session options only for `opencode mini`.

## Key question 7: Skills, slash commands, and instruction/config directories

### Takeaway
OpenCode reads `.opencode/` natively and also honours `.claude/` and `.agents/` compatibility directories for both skills and instructions. Wiggum's generated `.opencode/commands/wiggum.md` and `.claude/skills/wiggum/SKILL.md` are therefore natively discoverable; no conversion is needed.

### Cited Findings
- Skills discovery locations: global `~/.config/opencode/skills`; global compatibility `~/.claude/skills` and `~/.agents/skills`; project `.opencode/skills`; project compatibility `.claude/skills` and `.agents/skills` — [Skills](https://opencode.ai/docs/skills).
- Project skill sources are searched from the current directory up to the project root and included at every level. Each source accepts flat `*.md` files at its root or directories containing a file named exactly `SKILL.md`; hidden files/directories and `node_modules` are skipped; search stops six directories below the source root — [Skills](https://opencode.ai/docs/skills).
- Skill precedence, low→high: built-ins → `.claude/skills` → `.agents/skills` → `~/.config/opencode/skills` → project `.opencode/skills` → explicit `skills` config entries. Later definitions of the same ID win — [Skills](https://opencode.ai/docs/skills).
- Skill IDs come from the path, not frontmatter `name`; the model loads a skill with the `skill` tool using its exact ID, or the user can mention `@skill-id` — [Skills](https://opencode.ai/docs/skills).
- `metadata.opencode/autoinvoke: false` or `disable-model-invocation: true` hides a skill from the model's advertised list while leaving it loadable by ID; skill permission rules can allow/ask/deny by skill ID — [Skills](https://opencode.ai/docs/skills).
- Additional skill sources can be configured with the `skills` array in `opencode.json(c)`, including local paths, `~/` paths, absolute paths and HTTP catalogs with `index.json` — [Skills](https://opencode.ai/docs/skills).
- Slash commands live in `~/.config/opencode/commands/` and `.opencode/commands/`; only `.md` files are discovered, nested paths become `/` names (e.g. `/team/review`), and the legacy singular `command/` is still discovered — [Commands](https://opencode.ai/docs/commands).
- Command frontmatter accepts `description`, `agent`, `model` (`provider/model#variant`) and `subagent` (run in a background child session); `subtask` is a deprecated alias. `$ARGUMENTS`, `$1`/`$2` and shell blocks `!`...`` are supported; shell blocks run before the agent's permission flow — [Commands](https://opencode.ai/docs/commands).
- Commands can also be defined in JSON config under `commands`; MCP prompts become commands named `<server>:<prompt>` — [Commands](https://opencode.ai/docs/commands); [MCP servers](https://opencode.ai/docs/mcp-servers).
- Instructions: `AGENTS.md` global at `~/.config/opencode/AGENTS.md`, then every `AGENTS.md` from the workspace up to the project root; for workspaces outside the home directory discovery stops at the project root. Nested `AGENTS.md` files load when files in their subtree are read — [Instructions](https://opencode.ai/docs/instructions).
- CLAUDE.md fallback: any directory without `AGENTS.md` falls back to `CLAUDE.md`; without a global `~/.config/opencode/AGENTS.md`, OpenCode reads `~/.claude/CLAUDE.md`. `AGENTS.md` always wins. Toggles: `OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1`, `OPENCODE_DISABLE_CLAUDE_CODE=1`, `OPENCODE_DISABLE_PROJECT_CONFIG=1` — [Instructions](https://opencode.ai/docs/instructions).
- Config files: system `/Library/Application Support/opencode` (macOS), `/etc/opencode` (Linux), `%ProgramData%\opencode` (Windows), plus MDM managed preferences for `ai.opencode.managed`; global `~/.config/opencode/opencode.json(c)`; project `opencode.json(c)` or `.opencode/opencode.json(c)`. Search runs from the current directory to the filesystem root; direct configs merge first, then `.opencode` configs, so every `.opencode` config overrides every direct config — [Config](https://opencode.ai/docs/config).
- Other directories loaded from the system/global config roots include `agents/`, `commands/`, `skills/` and `plugins/`; agent files live at `~/.config/opencode/agents/<name>.md` and `.opencode/agents/<name>.md`, with nested paths becoming part of the agent ID — [Config](https://opencode.ai/docs/config); [Agents](https://opencode.ai/docs/agents).
- `opencode debug paths` prints local paths; selectors include `db`, `home`, `data`, `config`, `cache`, `state`, `tmp`, `bin`, `log`, `repos` — [CLI](https://opencode.ai/docs/cli).
- Wiggum `init` installs `.opencode/commands/wiggum.md` and `.claude/skills/wiggum/SKILL.md`, and writes an agent-neutral "Working with wiggum" block into `AGENTS.md` — [README.md:109](/Users/ben/wiggum/README.md#L109); [README.md:601-603](/Users/ben/wiggum/README.md#L601-L603); [lib/wiggum.sh:2903-3013](/Users/ben/wiggum/lib/wiggum.sh#L2903-L3013).

### Inferences
- OpenCode's compatibility discovery means wiggum's Claude-oriented install layout already works in OpenCode; a dedicated OpenCode command exists mainly to pass `--agent opencode`.
- Config precedence is file-based and project-scoped, unlike wiggum's per-run flags; setting a variant or permission for one run requires CLI flags or a temporary config.
- Because `AGENTS.md` is read natively and CLAUDE.md is a fallback, wiggum's `AGENTS.md` block reaches OpenCode without extra installation.

### Gaps
- V1 and V2 differ in several directory names and config shapes (for example V2 `mcp.servers` vs V1 `mcp`); V1-specific directory behaviour was checked only through the V1 CLI page and cached V1 pages.
- No test was run to confirm OpenCode actually loads this repository's `.claude/skills/wiggum` and `.opencode/commands/wiggum.md`; the claim is based on documented discovery paths.

## Key question 8: Which wiggum capabilities are redundant, additive, or lossy against OpenCode?

### Takeaway
OpenCode absorbs wiggum's single-call execution, session forking, basic permission gating, instructions, skills, commands and read-only planning agent. Wiggum remains additive for durable plan state, verification/retry policy, progress-based stopping, commits, supervision, chaining and scheduling. The lossy seams are permission semantics, effort levels, failure diagnosis, and the plan artifact itself.

### Cited Findings
- **Redundant:** `opencode run --format json`, `--session/--fork`, `--model`, `--agent`, `--auto`, background server, subagents and config-driven skills/commands cover wiggum's thin adapter layer's transport needs — [V1 CLI](https://opencode.ai/v1/docs/cli#run); [CLI](https://opencode.ai/docs/cli); [Tools](https://opencode.ai/docs/tools); [Agents](https://opencode.ai/docs/agents).
- **Redundant:** OpenCode's `plan` agent and per-agent permissions cover read-only analysis; its `AGENTS.md`/CLAUDE.md discovery and `.opencode/commands` cover wiggum's init-installed instruction and command files — [Agents](https://opencode.ai/docs/agents); [Instructions](https://opencode.ai/docs/instructions); [Commands](https://opencode.ai/docs/commands); [README.md:601-603](/Users/ben/wiggum/README.md#L601-L603).
- **Additive (wiggum):** structured workplans with benefits, critical path, float, acceptance criteria and `[ ]`/`[x]`/`[~]` state; verify/autofix waterfall with retry caps; stall detection; commit messages and issue-ledger reconciliation — [wiggum_baseline.md:13-19](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L13-L19); [wiggum_baseline.md:25](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L25).
- **Additive (wiggum):** machine-wide `top`, `status`, `watch`, `kill`, `chain`, `--queue` and one-shot `--at` scheduling, with bounded process-tree kills — [wiggum_baseline.md:22-24](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L22-L24). OpenCode's shared server manages sessions, not OS-level run supervision — [CLI](https://opencode.ai/docs/cli).
- **Lossy — permissions:** six wiggum modes collapse to `--auto`; OpenCode's allow/ask/deny rules are config-file based and cannot express `acceptEdits` vs `auto` vs `plan` as per-call flags — [lib/wiggum.sh:3111-3131](/Users/ben/wiggum/lib/wiggum.sh#L3111-L3131); [Permissions](https://opencode.ai/docs/permissions).
- **Lossy — effort:** five wiggum levels collapse to three OpenCode variants and depend on the chosen model's catalog; `xhigh` and `max` are identical — [lib/wiggum.sh:3121-3127](/Users/ben/wiggum/lib/wiggum.sh#L3121-L3127); [Models](https://opencode.ai/docs/models).
- **Lossy — failure diagnosis:** wiggum's Claude-specific failure markers and retry bookkeeping are shared across agents; OpenCode JSON events were not mapped into that logic in the tree — [lib/wiggum.sh:3225-3250](/Users/ben/wiggum/lib/wiggum.sh#L3225-L3250); [wiggum_baseline.md:99-108](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L99-L108).
- **Lossy — plan artifact:** OpenCode's plan file is a permission-limited Markdown file with no defined schema or consumer; wiggum's plan is executable state — [Agents](https://opencode.ai/docs/agents); [wiggum_baseline.md:15-19](/Users/ben/wiggum/research_notes/Agent%20capability%20gap%20analysis/wiggum_baseline.md#L15-L19).
- **Version risk:** the local OpenCode is 1.19.6 while the latest release is 2.3.2; V1/V2 config keys and permission action names differ, so any adapter written against the local help output may need a version switch — [GitHub releases](https://api.github.com/repos/anomalyco/opencode/releases?per_page=5); [Permissions](https://opencode.ai/docs/permissions).

### Inferences
- The highest-value reuse is to let OpenCode own session persistence, permissions, skills and commands, and keep wiggum as the plan/verify/supervise policy layer.
- The highest-risk simplification is treating `--variant` and `--auto` as full equivalents of wiggum's `effort` and `permission_mode`; both lose information that wiggum currently records.
- Migrating wiggum's own integration files is unnecessary: the native discovery paths already cover them.

### Gaps
- No measured comparison of reliability, latency or token cost between a wiggum loop on OpenCode and OpenCode's native session/subagent loop.
- Whether OpenCode plugins can supply verification hooks or retry policies was not researched, so "additive" here means additive to V2 Core as documented.
- No V2 `run --help` transcript, so V2-specific redundancy could not be assessed precisely.

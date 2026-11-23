---
description: Plan or execute a wiggum workplan
---
The request is: $ARGUMENTS

Use the Bash tool to drive the `wiggum` CLI. Pass `--agent opencode` so the loop uses this agent.

- If the request names an existing plan file or asks to execute a plan, read that plan, then run `wiggum execute <plan-file> --agent opencode`.
- Otherwise run `wiggum plan <issue-or-description> --agent opencode` and report the generated plan path.
- Let wiggum run the implementation, verification and commit in its own agent sessions.
- Report the command, exit status, plan path and summary path. Execute without asking for confirmation.

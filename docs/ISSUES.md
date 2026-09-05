# Issue ledger

Known defects and gaps in wiggum itself, newest first. One entry per issue: what
breaks, how it was seen, and what a fix has to do. Closed entries keep their
commit so the next person can read the fix rather than rediscover the bug.

`openwolf bug search <term>` searches the machine-local buglog in `.wolf/`; this
file is the tracked one, and it is the one to update.

## Open

### 1. A pid alone is not an identity, and `kill` acts on it

`process_alive()` is `kill -0 "$pid"` (`lib/wiggum.sh:3520`), the pidfile holds a
bare number, and a registry entry holds only the plan path keyed by pid
(`register_run`). Nothing records *which* process that pid was.

The OS recycles pids. A stale pidfile — left by a crash, a `kill -9`, or a box
that rebooted mid-run, all states the code already expects elsewhere — will
eventually name a pid that belongs to somebody else. Then:

- `wiggum top` and `wiggum status` report a phantom run as `running`, and
  `find_registered_runs` never prunes the entry because the pid answers.
- `wiggum kill <plan>` sends `SIGTERM` to that process **and its children**
  (`pkill -TERM -P "$pid"` in `kill_run`), with no check that it is a wiggum.

The second one is the reason this is not cosmetic: on this machine the
casualties would be exactly the long unattended runs the pidfile exists to
protect.

**A fix has to record identity at claim time** — the process start time
(`ps -o lstart= -p "$pid"`) beside the pid, or the run's own command line — and
verify it before believing a pidfile or signalling anything. Bare pidfiles
written by older versions must degrade to "unknown", not to "alive".

### 2. `top` shows no resource cost, which is the question it is asked

`top` answers "what is running" but not "what is it costing", so "is it safe to
launch another run?" still means shelling out to `ps`, `uptime` and
`sysctl vm.swapusage` and correlating by hand. Two separate wants:

- **Per-run `RSS` and `%CPU`**, summed over the run's process group. Measured on
  pid 70613 at 18:05: the run's own bash is 1.3 MB at 0.0%, its `claude` child is
  288.9 MB — 290.2 MB for the group. `ps` on the pid `top` already prints tells
  you nothing about what the run costs.
- **A machine footer** — load against core count, and swap used — because that
  is the launch decision, and this box degrades badly above ~90% swap.

Caveat for whoever builds it: an instantaneous sample misses the expensive
moment. The run that pushed this machine to 84% swap was quiet by the time it
was looked at. A high-water figure recorded by the run beats a live one read by
`top`, and that means `execute` has to sample, not just `top`.

## Closed

- **`install.sh` rewrote the installed script in place, killing live runs.**
  `cp` truncates and rewrites the same inode; bash reads a script by byte offset
  as it goes, so a run that started before the install resumed inside the new
  text and died with `syntax error near unexpected token ';;'`, exit 2, having
  finished its work. Fixed in `117da66` by installing through `rename(2)`.
- **`run_privileged` never escalated, and would have escalated too far.** It
  tested `-w "$(dirname "$1")"` where `$1` was the command word, so it read the
  cwd and never sudo'd; installing to a root-owned prefix failed instead. Fixed
  in `70aaa8c` by deciding per destination, which also keeps the copies into
  `$HOME` unprivileged.

## Operational note (not a code defect)

A chain launched before `a146922` (2026-09-05 12:38) holds the old library in
memory and cannot re-register itself as it advances, so `top` names the plan it
started on and freezes that row's tally and activity clock. Live example: pid
70613, launched 09:41, shown against `site-improvements` while working
`compare-campaigns`. Read the plan's own `.log` until that chain ends; chains
started since report correctly.

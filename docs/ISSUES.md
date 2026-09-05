# Issue ledger

Known defects and gaps in wiggum itself, newest first. One entry per issue: what
breaks, how it was seen, and what a fix has to do. Closed entries keep their
commit so the next person can read the fix rather than rediscover the bug.

`openwolf bug search <term>` searches the machine-local buglog in `.wolf/`; this
file is the tracked one, and it is the one to update.

## Open

### 1. `top` samples, and the expensive moment is usually over

The `RSS`/`CPU` columns added in `6fb6ba3` read the process tree at the instant
you look. The run that took this machine to 84% swap was quiet by the time
anyone looked at it, so a cheap-looking row is not evidence a run is cheap.

**A fix means `execute` sampling its own process group each iteration** and
recording a high-water mark into the run's sidecar, for `top` to show beside the
live figure. That is a change to the run loop, not to `top`, which is why it was
split out of the columns rather than bolted onto them.

## Closed

- **A pid alone was an identity, and `kill` acted on it.** `process_alive()` was
  a bare `kill -0`, the `.pid` held a number and the registry entry held only a
  path, so a sidecar naming a recycled pid made `top` invent a running run and
  made `wiggum kill` signal a stranger's process tree, children included. Fixed
  in `295f445`: sidecars and registry entries record the process start time beside
  the pid, and `top`, `status`, `watch`, `kill`, `cancel` and the claim checks
  all compare it before believing or signalling a pid. Sidecars from older
  versions carry none and fall back to bare liveness, which `kill` says out
  loud rather than trusting silently.
- **`top` said nothing about what a run costs.** Answering "which run is
  expensive" or "can I launch another" meant shelling out to `ps`, `uptime` and
  `sysctl` and correlating by hand. Fixed in `6fb6ba3`: `RSS` and `CPU` columns
  summed over each run's whole process tree, over a footer giving load against
  cores, swap used, and the live run count. Still an instantaneous sample — the
  high-water mark stays open below.
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

# Issue ledger

Known defects and gaps in wiggum itself, newest first. One entry per issue: what
breaks, how it was seen, and what a fix has to do. Closed entries keep their
commit so the next person can read the fix rather than rediscover the bug.

`openwolf bug search <term>` searches the machine-local buglog in `.wolf/`; this
file is the tracked one, and it is the one to update.

## Open

### 1. A chain has no supervision primitive, and everyone hand-rolls a broken one

`wiggum watch` attaches to a plan's pidfile. A plan whose turn in the chain has not
come has no pidfile, so watching it **exits 1 immediately** -- which reads as "that run
finished" and means "that run has not started". There is no way to ask "what is this
chain on, and tell me when it moves", so supervision gets rebuilt by hand, badly:
2026-09-05 produced six hand-rolled monitors, three of them wrong, one of which fired
while the chain was alive and nearly stacked a second chain over 15 unfinished tasks.

The tell that this is a defect rather than a limitation: the skill carries paragraphs
of anti-pattern documentation -- `pgrep -f` erroring on non-UTF-8 command lines, `ps`
truncating to terminal width, waiters reading any non-zero exit as "gone" -- and that
prose exists because people keep writing the same broken loop. A limitation everybody
works around by writing the same bug is a missing primitive wearing a doc.

**The pieces are already there.** The registry keys a run by pid and names the plan it
is on, and since `a146922` a chain re-registers on every plan transition (asserted by
*run_chain: the registry follows the chain*). What is missing is a watch that follows
that entry: given the chain's pid, stream the active plan's `.out`, notice when the
registry entry changes to the next plan, and exit when the pid does.

## Closed

- **A sidecar written before the identity check could not be verified at all.**
  Every `.pid` from before `295f445` holds a bare number, so a reused pid there
  would still have been believed -- and was: on 2026-09-05 Chrome inherited pid
  13708 and `top` reported a plan that finished on 27 August as running, which
  tripped a stall warning on work that had been complete for a week. Fixed in
  `af55326` with the check that needs no identity: a run whose `.out` records a
  final status is over, whatever its pid now answers, so `kill` clears such a
  sidecar and signals nothing. Read for the current run only, so a relaunch
  over the same sidecars is not mistaken for the last run's finish.
- **Per-run high-water sampling: decided against, not deferred.** The question
  anyone actually asks is "can I launch another run?", and that is a machine
  question the kernel already answers for free -- load average is a decaying
  average over 1/5/15 minutes, so it captures a vitest-plus-Chrome spike with
  nothing sampling anything. The footer shipped in `6fb6ba3` answers it in one
  `sysctl` call. Per-run peak answers the rarer "which of my runs is expensive",
  only matters with two or more concurrent, and would cost a spawned sampler
  process wiggum must own and reap -- a new orphan class in the exact area the
  identity work exists to police. Revisit only with a case the footer cannot
  answer.
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

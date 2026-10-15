# The alert lifecycle

How memwatch's alert surfaces (the HUD, the critical banner, the menu's
process actions and the unattended action) decide what to show, what to
signal, and when to ask again. The rules below are what `lua/memwatch.lua`
implements and what `test_glue.lua` drives against a fake Hammerspoon.

## Rules every change is checked against

1. **Verify, then signal, in one step.** Every STOP, CONT, TERM and KILL goes
   to a process verified in the same step against the start time bound for
   the action. A compensating signal is a new action and verifies again: the
   STOP that re-freezes a process whose quit could not be sent is a freeze,
   with a freeze's verifier, and the CONT that undoes a STOP that reached the
   pid's next process goes only to a process the verifier's own probe saw
   stopped. That undo goes to whatever process memwatch's STOP reached,
   protected or not: memwatch never leaves its own STOP on a process it did
   not mean, and it cannot tell its STOP apart from a stop by anyone else on
   that same process. Nothing is signaled on a probe that could not answer.
2. **The ledger says what was sent.** A freeze writes its entry before its
   STOP and records whether the STOP went out; one whose STOP could not be
   sent goes at once, because a process stopped by anyone else is not
   memwatch's to resume. A reload keeps a pending entry only if its STOP
   went out, or may have. Every entry carries a start time; one without
   (written by an older version) is dropped at reload and named in a
   notice, in case that program is still stopped.
3. **Each writer owns only its own entry.** A freeze's verifier changes the
   slot only while it holds that freeze's own entry (or nothing), so a late
   verifier never undoes a newer action on the same process. The entry is
   named by the freeze's own token, written to the ledger with it, so it
   stays the freeze's after an in-process restart's reconcile rebuilds it.
   The token is made of durable parts (the pid, the freeze's time in
   milliseconds and a count of the run's entries), so one left in the ledger
   by an earlier run names nothing this run made. A verifier settles its
   freeze's entry where the slot holds it (rebuilt and shifted since), never
   by putting back the copy it captured. A resume's verifier drops only the
   entry it resumed, by the same token: a newer freeze of the same process
   keeps its own. Writers that act on a process found gone own the entry for
   the start time they acted on. An entry with no start time is owned by no
   writer.
4. **An action is in flight until its final outcome, with a backstop.**
   Progress pushes its deadlines out. At the deadline the operator is told
   the result has not come back; one more hold window with no progress
   releases the in-flight hold, so the process can be acted on again. The
   released action is superseded: it sends no further escalation (no KILL
   over the newer action, and no retry of one) and touches nothing the newer
   action owns (HUD, hold, retry state, ledger entry); its late outcome only
   replaces its own receipt, which says why the KILL was withheld (released
   by the backstop, or answered by the operator). A freeze's verifier still
   undoes a STOP of its own that reached the pid's next process, under
   rule 1. An operator's answer on the process supersedes memwatch's own
   action in flight on it the same way: Freeze, Force Quit, Ignore, Activity
   Monitor or closing the alert, from the HUD, the banner or the menu's
   process rows, and Resume or Force Quit from the frozen rows. The menu's
   own Activity Monitor item names no process, so it answers none. A veto matches by pid and name
   even when the answer could not bind a start time (a menu opened while
   probes failed), because it only ever withholds; two bound start times
   must still agree. A Resume vetoes but leaves the process a candidate,
   since it is meant to run. A click handed to a signal engine (Freeze or
   Force Quit) answers only once it did something, and each click holds its
   own veto until then; its outcome settles it the moment it arrives (only
   the HUD lingers), so a click that did nothing has given its veto up
   before memwatch's escalation reads it. A click that signals nothing gives
   up its own hold,
   and the veto is withdrawn (memwatch's action carries on) only when no
   other answer holds it and the action is still in flight. One the backstop
   has released stays superseded, so a late click that did nothing never
   revives its escalation. A click that did something, and every answer
   that needs no signal engine, holds its veto for good. A vetoed action
   gives up its HUD hold at once, and still owes its receipt: one whose
   result never comes back is announced at its deadline.
5. **One live receipt per action.** Once a receipt has said the result has
   not come back, the final outcome, whatever it is, replaces it; the old
   receipt is withdrawn only when its replacement is up. An outcome after a
   signal went out is always announced, whatever it is. Within one run of
   memwatch: a reload ends an action in flight with its timers, and its
   receipt goes unannounced (a known limit; the frozen ledger, which says
   what memwatch stopped, does survive the reload).
6. **Surfaces retire by state.** A shown HUD whose process has been answered
   (frozen, gone, ignored) goes at the next tick, whichever surface answered
   it. A freeze of that process still inside its pending window is no answer
   yet; a freeze stops counting as pending when its window ends. Names
   compare by the prefix rule, so a process whose truncated name is a
   prefix of another's can be read as answered by that one's freeze while
   unbound, a known limit of truncated names.
7. **Marks are per process.** A frozen or gone mark never holds for a
   process with another name, and a mark that growth has proved stale stays
   released.
8. **A wall clock stepped back never lengthens a wait.** Every wall read
   goes through one detector, which compares the wall clock's advance with
   the monotonic clock's since the previous read (a sleep only makes the
   wall advance more). A step back of more than 2 s shifts every stamp
   memwatch holds by the step (holds, pending freezes, marks, receipts'
   deadlines, the grace before the next unattended attempt, the sampler's
   watchdog, cooldowns, the tracker's sample times and latches), at the
   first read after it and before that read's value is used. So a stamp a
   callback writes between the step and the next tick is shifted once,
   never twice, and each wait keeps the length it had left. A callback is
   never shifted under: a step seen in the middle of one that has already
   read the clock is taken out when it ends, and until then its reads stay
   on the basis it began with, so the stamps it writes move with the rest.
   Each holder is shifted under its own guard: one that fails is logged by
   name and costs only its own stamps. A source scan
   holds the shift to every time-named stamp, matched by its whole path. A
   wall reading kept in a function's local is out of the shift's reach (a
   callback that captures it keeps the old basis), so the scan also lists
   every time-named function local with how it is used. Pure durations (a
   poller's error run, the language-model server's deadlines and its
   fast-crash window, request latency, the error log's rate limit) run on
   the monotonic clock and need no shift. The shifted frozen ledger is
   written out at once. A grace stamp found after now (a step the shift
   could not take out) restarts the grace from now: one grace, never the
   step's length and never none. A pending window persisted ahead of now (a
   step back across a reload) lasts at most one window more, and a freeze
   stamp persisted ahead of now reads as now. Without a
   monotonic clock, memwatch says so at start, and a step back shows only
   when the wall clock runs backwards between two reads; durations then run
   on the wall clock read through the detector, with every step it took out
   added back, so a step back it saw never lengthens one (a step forward,
   which it cannot see, shortens a wait).

## The episode

A critical episode starts on the first critical tick and ends when the state
has been below critical for 10 seconds with no action narrative holding the
HUD, or when the run ends (`stop`, `start`, a self-test, a simulation). The
end of an episode clears all of its memory (banner history, snooze, grace
clocks, interaction marks, the bind throttle and the banner cooldown) and
withdraws its banner, so the next episode starts clean.

## Identity

A process is identified by its pid, its name and its start time (`lstart`).
The start time is what makes a signal safe: a same-name process can reuse a
pid, and only the start time tells them apart.

**Probes are tri-state.** Every process probe is one `ps` call that also
lists memwatch's own pid as a positive control. A missing target row means
the process is gone only when the control row came back. Otherwise the
probe is *unknown*: the fork failed or the answer is incomplete. Under memory
pressure forks fail, so an unknown probe is common exactly when memwatch
matters. Unknown is never read as "exited", anywhere: not when acting, not
when verifying an action, not in the frozen ledger.

**A start time names one process, with one accepted exception.** `ps`
prints local time in whole seconds, so in the hour a daylight-saving change
repeats, two processes started exactly 3600 s apart print the same start
time. memwatch accepts that text as one identity: a same-name process would
have to take the very pid exactly an hour later, to the second, for a
signal to reach the wrong one. Refusing every process started in that hour
would leave it unprotectable for its whole life.

**Destructive actions need a bound identity.** Every freeze and terminate
from an alert surface passes the start time it bound, and the signal path
refuses when the live process differs. With no bound start time the action
is refused, never sent by name alone.

| Surface | Identity it acts on |
|---|---|
| HUD Freeze / Force Quit | the HUD's bound offender; unbound: bind now, ask for another click |
| Banner Force Quit | the identity captured when the banner was posted |
| Menu offender Force Quit | the HUD's or banner's binding for that process, else bound at the click |
| Menu process rows | bound when the menu opens (one probe for all rows); unbound rows are disabled |
| Menu frozen rows | the frozen ledger's identity |
| Unattended freeze / terminate | the HUD's bound offender; skipped while unbound |

A refreshed offender inherits the binding of the process the HUD already
shows. An inherited start time can be stale (the pid was reused), but it can
only cause a refusal, never a wrong signal. **A refusal from any surface
rebinds every surface:** the HUD binds fresh and treats the process holding
the pid as a new question, and a banner naming the old process is withdrawn.

Three comparisons are kept apart:

- *Continuity* ("is this still the process on screen?") compares pid and
  name, and the start time when both sides have one. Names compare with the
  same prefix rule the signal path uses, because names sourced from `top`
  are truncated.
- *Memory* ("was this exact process announced?") is strict: a record made
  without a start time never vouches for a process whose start time is
  known. A banner record made while unbound is upgraded in place when that
  banner binds.
- *Exact identity* ("is this the very process the action was on?") routes an
  action's outcome from the menu or a banner to the HUD: pid, name, and
  both start times bound and equal. An unbound HUD is never answered by an
  outcome; it rebinds on its own, and it goes as soon as its process has
  been answered by state (frozen and verified, gone, ignored), whichever
  surface answered it.

Per-process records (grace clocks, interaction marks) are filed by pid and
carry the name and start time they were made for. A record made while
unbound never transfers to the process once it binds, because the pid may
hold a newcomer by then: that process's grace and answers start over. The
ignore and gone marks carry their process's name (and start time when
bound), so two processes whose names share a prefix are never one mark.

## Answers

An action's result is what the signal path reports, never a re-probe after
the fact:

| Outcome | Meaning | The alert |
|---|---|---|
| `frozen` | stopped and verified, or already frozen by memwatch | done |
| `terminated` | verified gone after the signal | done |
| `exited` | verified gone before any signal | done |
| `stale` | the pid now holds a different process (nothing signaled) | rebind; the newcomer is a new question |
| `replaced` | terminated, and another process holds the pid now | rebind; the newcomer is a new question |
| `refused` | the policy gate refused (protected, not ours) | snoozed |
| `failed` | signaled, but it survived (did not stop, still present) | snoozed |
| `unconfirmed` | a signal went out, but its result could not be verified | stands as it was; announced |
| `unverified` | nothing was signaled: the probe failed first, or the signal could not be sent | stands as it was: visible, unanswered, retryable |

The answer applies whichever surface started the action: the HUD's own
narrative, or a menu or banner action on the process the HUD names (a HUD
held by a narrative of its own is left to that narrative).

An answered process stops being a candidate by its own state, not by a note
in a list: memwatch holds it frozen, it is gone, or it is ignored. Nothing
else is remembered as "handled", so a process that is resumed, or that
memwatch failed to stop, is alertable again.

A frozen or gone mark is about one process, not a pid. It stops counting
as soon as the pid shows a run of growth after the mark (a stopped process
cannot grow, and an exited one makes no samples), holds a process with
another name, or, on a surface that has bound the process there, has a
different start time. A mark growth has released stays released: a
newcomer that then plateaus is not hidden again. Either way a
newcomer holds the pid, and it is alertable at once, without waiting for
the frozen-ledger sweep, which cannot run while probes fail. Candidates
themselves carry no start time, so a newcomer that does not grow stays
behind a frozen mark until the sweep proves the mark stale. A freeze click answers "already frozen" only
for the same process verified stopped; a freeze still being verified
stands; a ledger entry for another start time is dropped and the newcomer
is frozen.

- **Close** is "not now": the same process returns after the raise cooldown,
  or at once if it escalates.
- **Ignore 30m** puts the process on the ignore list for 30 minutes; it is no
  candidate for the HUD, the banner or the largest-process fallback while
  the ignore lasts. A name `top` truncated and the full name `ps` reports
  later are one process (the prefix rule); two different names are not,
  even when they share a prefix. Candidates carry no start time, so a
  same-name process that reuses the pid inside the window is ignored too.
- **Resume** returns a frozen process to the candidates.

## Grace and interaction

Unattended action (off by default) acts on an extreme runaway only after its
alert has gone unanswered for the grace window. The grace is per process:
each identity accumulates the seconds it has headed an active alert as
`extreme` (shown, or muted but armed). A different process starts at zero,
two processes alternating at the top each keep their own clock, a generic
alert that later names an offender starts that offender's clock when it is
named, and a hog that escalates to `extreme` starts its clock then. Every
raise (the HUD coming back after being down) starts all clocks over.

An operator action on a process, from any surface, marks it answered for
unattended purposes until the next raise. Ignore, close and opening
Activity Monitor answer at once. A freeze or Force Quit answers when its
outcome arrives: one that signaled nothing (`unverified`, the probe failed
before any signal) is no answer, and one whose outcome never arrives stops
counting at the hold deadline (45 seconds). A click that did nothing in
any other way (an unbound refusal, a self-test button) is not an answer
either. memwatch never retries a freeze or terminate that already failed
on the same process.

Receipts for unattended actions say what happened and are posted when the
action completes, even with desktop alerts muted: `frozen`, `terminated`,
`replaced` (terminated, and another process holds the pid), `failed` (it
survived), or `unconfirmed` (a signal went out but its result could not be
verified). An action that signaled nothing (`unverified`, `refused`,
`stale`, `exited`) is logged, not announced, unless a receipt has already
said its result has not come back: then its outcome, whatever it is,
replaces that receipt.

An action stays in flight until its final outcome arrives. Each progress
step pushes its deadlines (the HUD's hold, a pending interaction mark, the
owed receipt) out by 45 seconds, so a slow narrative is not a lost one.
If an unattended action's outcome has still not arrived by its deadline
(a stalled run loop), a receipt says so, and no second action starts on
that process while the first is in flight. If the outcome then arrives, it
replaces that receipt: one action, one live receipt. One more hold window
with no progress releases the in-flight hold, so a narrative that will
never finish cannot keep the process from being acted on again; its outcome
still replaces the receipt if it ever arrives.

## The frozen ledger

Every writer changes only its own entry. A freeze's verifier holds the
entry its freeze wrote and changes the slot only while the slot holds that
very entry (or nothing): an entry another action wrote since, for this
process or the pid's next one, is never its to touch. A resume, a kill and
the reconcile each drop the entry for the start time they acted on, never
an entry for the pid's next process, and a kill a newer action superseded
drops none. An entry with no start time is owned by no writer.

An entry is written before its STOP and records whether the STOP went out;
if it could not be sent, the entry goes at once, and both the sweep and a
reload drop an entry whose STOP never went out, whatever state the process
is in by then: a process stopped by anyone else is not memwatch's to
resume. The verifier still runs and says what it found ("it is stopped,
but not by memwatch"). A freeze still being verified when memwatch reloads keeps its
entry (its STOP may land after the reload) until the sweep can decide. If
the freeze's verifier finds the pid taken over, the STOP reached the
newcomer its own probe found: it is continued if that probe saw it
stopped, and if that CONT cannot be sent a fresh probe decides whether it
stays in the ledger, bound to its own start time, so the menu can resume
it.

A frozen process continued for a Force Quit whose TERM cannot be sent is
frozen again as a new freeze: verified afresh, so a newcomer that took the
pid is never stopped, and pending until its own verifier settles it, so a
reload in between keeps it. Its outcome is told in the new freeze's own
words, which say whether its own STOP went out.

A freeze stays pending only inside its window. Its verifier settles it; if
the verifier never runs (a reload), the entry simply stops counting as
pending when the window ends, and the sweep then decides it like any other.
An entry whose size was never measured (a process found holding the pid
mid-freeze) shows "size unknown" in the menu, never another process's size.

An entry written by an older version without a start time is dropped at
reload and named in a notice, in case that program is still stopped (it
can be resumed in Activity Monitor). Nothing ties such an entry to the
process it froze: the pid may hold another process by now, and its freeze
stamp cannot be dated against this clock, because a step across the reload
shows nowhere. No entry without a start time is ever signaled through.

## Banners

One banner per process per episode, upgraded in place (no new cooldown)
when a generic banner gains a name, an unbound banner binds, or the
offender's kind escalates. A banner naming a process that has since been
answered (frozen, gone, ignored) is withdrawn. With no offender named,
whatever is up stays.

## Diagnostics

`memwatch.test()` (at either level) and `memwatch.simulate()` end the live
episode and start a fresh one; a critical test and a simulation show a
synthetic offender: never bound, buttons inert, no banner action. Each run
has its own generation, so a later diagnostic, a stop or a restart orphans
an earlier one's resume, and an action narrative from an earlier run does
nothing to the new run's alert when it completes. The signal engine itself
finishes an action it started on a verified identity (a Force Quit's KILL
still goes to the process it verified), and a verified exit is kept: both
are facts about the process, not about the episode.

## Held pollers

A poller whose predicate errors continuously for two minutes gives up
explicitly: the give-up is logged and handled by its owner (the LFM health
poll retires the server and latches it offline), never treated as success.

The LFM server is signaled (TERM or KILL, on retire, or as a crash orphan
at the next start) only while its pid holds the process recorded when it
started: the same start time and name, from a probe that answered. With no
recorded start time, the pid itself gets no signal; only the task handle
and a port listener verified as an llama-server on memwatch's model
directory are signaled.

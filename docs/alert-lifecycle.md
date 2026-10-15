# The alert lifecycle

How memwatch's alert surfaces (the HUD, the critical banner, the menu's
process actions and the unattended action) decide what to show, what to
signal, and when to ask again. The rules below are what `lua/memwatch.lua`
implements and what `test_glue.lua` drives against a fake Hammerspoon.

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

Two comparisons are kept apart:

- *Continuity* ("is this still the process on screen?") compares pid and
  name, and the start time when both sides have one. Names compare with the
  same prefix rule the signal path uses, because names sourced from `top`
  are truncated.
- *Memory* ("was this exact process announced?") is strict: a record made
  without a start time never vouches for a process whose start time is
  known. A banner record made while unbound is upgraded in place when that
  banner binds.

## Answers

An action's result is what the signal path reports, never a re-probe after
the fact:

| Outcome | Meaning | The alert |
|---|---|---|
| `frozen` | stopped and verified, or already frozen by memwatch | done |
| `terminated` | verified gone after the signal | done |
| `exited` | verified gone before any signal | done |
| `stale` | the pid now holds a different process | rebind; the newcomer is a new question |
| `refused` | the policy gate refused (protected, not ours) | snoozed |
| `failed` | signaled, but it survived (did not stop, still present) | snoozed |
| `unverified` | identity or result could not be verified | stands as it was: visible, unanswered, retryable |

An answered process stops being a candidate by its own state, not by a note
in a list: memwatch holds it frozen, it is gone, or it is ignored. Nothing
else is remembered as "handled", so a process that is resumed, or that
memwatch failed to stop, is alertable again.

A frozen or gone mark is about one process, not a pid. It stops counting
as soon as the pid shows a run of growth after the mark (a stopped process
cannot grow, and an exited one makes no samples), or the process there has
a different bound start time. Either way a newcomer holds the pid, and it
is alertable at once, without waiting for the frozen-ledger sweep, which
cannot run while probes fail. A freeze click answers "already frozen" only
for the same process verified stopped; a freeze still being verified
stands; a ledger entry for another start time is dropped and the newcomer
is frozen.

- **Close** is "not now": the same process returns after the raise cooldown,
  or at once if it escalates.
- **Ignore 30m** puts the process on the ignore list for 30 minutes; it is no
  candidate for the HUD, the banner or the largest-process fallback while
  the ignore lasts. The ignore and gone lists key a process by its pid and
  the first 15 characters of its name, so a name `top` truncated and the
  full name `ps` reports later are one entry. The ignore carries no start
  time: a same-name process that reuses the pid inside the window is
  ignored too.
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
unattended purposes until the next raise. A click that did nothing (an
unbound refusal, a self-test button) is not an answer. memwatch never
retries a freeze or terminate that already failed on the same process.

Receipts for unattended actions report what happened (frozen, terminated,
refused, could not verify), and are posted when the action completes.

## Banners

One banner per process per episode, upgraded in place (no new cooldown)
when a generic banner gains a name, an unbound banner binds, or the
offender's kind escalates. A banner naming a process that has since been
answered (frozen, gone, ignored) is withdrawn. With no offender named,
whatever is up stays.

## Diagnostics

`memwatch.test()` and `memwatch.simulate()` start a fresh episode with a
synthetic offender: never bound, buttons inert, no banner action. Each run
has its own generation, so a later diagnostic, a stop or a restart orphans
an earlier one's resume, and an action narrative from an earlier run does
nothing when it completes.

## Held pollers

A poller whose predicate errors continuously for two minutes gives up
explicitly: the give-up is logged and handled by its owner (the LFM health
poll retires the server and latches it offline), never treated as success.

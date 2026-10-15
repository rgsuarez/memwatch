# The observation ledger: design

The observation ledger (`memwatch-observe.jsonl`, local and gitignored)
records what memwatch saw at each would-be decision point, and every 45 s
while pressure is up, and what became of the process and the machine 60,
120 and 180 s later. It is raw material for an outcome-labeled evaluation
set. It never acts, never forks and never leaves the machine. The README
lists the fields; this note states the rules the code holds to, so a change
can be checked against them.

## One observation's lifecycle

| State | Entered when | Left when |
|---|---|---|
| written | its row is appended (a row that cannot be written gets no follow-ups) | at once |
| collecting | the row is written: its record is in `obs.pending` | its last horizon's follow-up runs, or 10 min after that horizon (`expiresAt`) |
| reporting | each horizon timer runs | the follow-up line is appended |
| done | collecting ends | (the timers' closures keep the record for a timer that runs later) |

While collecting, every event that can bear on the observed process folds
into its record (`observe.newEvidence`): each process table, each signal
memwatch sends, each operator touch on that process, each operator action
anywhere, and each change in whether the frozen ledger holds the process.
Each tick also logs the machine's available memory and state
(`obs.ticks`), kept only as far back as a collecting record can ask.

## Invariants

1. **As of the horizon.** A follow-up is a function of its record, the tick
   log and its horizon instant `tH = observed + h`, and of nothing read when
   its timer runs. A late timer reports the horizon it names. (The jetsam
   count reads the reports directory, filtered by file time up to `tH`.)
2. **Identity before attribution.** An event counts for the observation only
   when it is provably the observed process: same program, and a start time
   inside the observation's start window when that window could not also
   hold the pid's next process. What cannot be told apart is counted apart
   (uncertain touches, an uncertain signal) or yields `unknown`, never a
   confident answer about the wrong process.
3. **Order, then dates.** Which tables came after the observation is decided
   by the sampler's launch order. Wall-clock times date events against a
   horizon. A wall clock stepped back after the observation makes that
   dating impossible: the record says `clock-step` and its follow-ups carry
   no readings. A forward step (a sleep) is harmless: a process seen after
   it was alive before it.
4. **Whole tables only prove absence.** A process missing from a table has
   exited only if the sampler exited cleanly and the table lists memwatch's
   own process. A partial table proves nothing.
5. **Bounded.** A record stops collecting 10 min after its last horizon; the
   tick log holds only what a collecting record can ask; a row stays under
   60 KB; the file rotates at 4 MB keeping three generations; a rotation
   that keeps failing stops the live file at twice the cap.
6. **Bookkeeping never interrupts an action.** Every fold called from an
   action or the tick is error-bounded, and the writers are called under
   `pcall` from the alert path.

## Clock model

- The wall clock (`hs.timer.secondsSinceEpoch`) dates rows, horizons and
  events.
- The sampler's launch order (an integer per launch) orders tables.
- A process's start window comes from `ps` etime, a duration on the wall
  clock: `[launch - etime - 1, delivery - etime]`, spanning both sides when
  the clock stepped back while the table was in flight.
- A backward step is seen at the next tick, or in a table launched after the
  observation that reads earlier, or delivered before its own launch. Then
  every collecting record not already proven gone is marked, and the
  advisory cadence and decision windows re-base to the step.

## Identity model

- The observed process: the start window of its latest process sample
  (`identityBasis: window`); for a process only the top stream named, the
  start time the alert bound, unless it falls in a daylight-saving fold
  (`lstart`); otherwise none, and its follow-ups can only read `unknown`
  or `exited`.
- A sample: the same program in an overlapping window that rules out a
  successor is a sighting; another program or a disjoint window is a reuse
  (the observed process is gone); anything else is `identity-uncertain`.
- A signal or touch: matched by the target's program and start time.
- The frozen ledger: matched by the entry's start time; an entry that cannot
  be told apart makes a living process `frozen-uncertain`.

## Deliberately not done

- Advisory rows are not decision points: their `wouldAct` is `none`.
- Collecting records do not survive a reload.
- Jetsam reports are counted in the window, not attributed to a process.
- The stored name is a sanitized local basename, never model input, and is
  stripped from any dataset built from the ledger, like the row's `pid`.

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
| collecting | the row is written: its record is in `obs.pending` | its last horizon's follow-up runs, 10 min after that horizon (`expiresMono`, on the monotonic clock), or a clock step closes it |
| reporting | each horizon timer runs | the follow-up line is appended |
| done | collecting ends | (the timers' closures keep the record for a timer that runs later) |

While collecting, every event that can bear on the observed process folds
into its record (`observe.newEvidence`): each process table, each signal
memwatch sends, each operator touch on that process, each operator action
anywhere (every menu, HUD and banner action; at most 256 times per record,
the rest counted), and each change in whether the frozen ledger holds the
process. Each tick also logs the machine's available memory and state
(`obs.ticks`), and each collecting record keeps the reading of every
horizon it has passed (`observe.snapshotHorizons`), so a follow-up that
runs after its record stopped collecting still reads its own horizon.

## Invariants

1. **As of the horizon.** A follow-up is a function of its record (with the
   horizon readings it kept) and its horizon instant `tH = observed + h`,
   and of nothing read when its timer runs. A late timer reports the horizon
   it names: the fate, the reason for an unknown one, the weight (a reading
   delivered within 15 s of the horizon), the peak, the counts and the
   machine's reading are each the ones known by `tH`. (The jetsam count
   reads the reports directory, filtered by file time up to `tH`.)
2. **Identity before attribution.** An event counts for the observation only
   when it is provably the observed process: same program, and a start time
   inside the observation's start window when that window could not also
   hold the pid's next process. What cannot be told apart is counted apart
   (uncertain touches, an uncertain signal) or yields `unknown`, never a
   confident answer about the wrong process.
3. **Order, then dates.** Which tables came after the observation is decided
   by the sampler's launch order. Wall-clock times date events against a
   horizon. A wall clock stepped back after the observation makes that
   dating impossible: the record stops collecting, and its follow-ups carry
   no readings (jetsam included); its fate is `unknown` (`clock-step`)
   unless an exit was proven before the step, which stands. A forward step
   (a sleep) is harmless: a process seen after it was alive before it.
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
- A backward step is seen at the first wall read after it (`clock.now`:
  how far the wall clock advanced against how far the monotonic clock did
  since the previous read; any size beyond 2 s, and a sleep only makes the
  wall advance more), or in a table launched after the observation that
  reads earlier, or delivered before its own launch. Then every collecting
  record is closed, and the advisory cadence, the decision windows and the
  tick log re-base to the step.
- A sampler's launch is read two ways. Its start windows use the wall
  reading taken at launch, which no step moves (they are anchored to the
  kernel's start record). The unattended-state GC uses the launch record
  the shift moves with the tracker's sightings, so a step between the launch
  and the delivery, back or forward, never puts the two on two bases. A
  launch that never started leaves no record; the records are bounded to
  the last 16 launches; and a delivery without its record leaves the launch
  unknown, so the GC prunes nothing.
- Every follow-up reads the clock first, so a step back since the last tick
  closes its record before anything is read from it.
- Report files (jetsam counts) carry the wall time they were written, which
  no shift moves. After a step back, an observation written before the new
  clock catches up with the pre-step times reads the count as unknown.
- Durations run on the monotonic clock: a record's life after its last
  horizon, and the age of the last row written (`debug().observe`).

## Identity model

- An etime of 0 places no start: a process in its first second, or one
  younger than a step back, whose clamped etime makes its window follow the
  clock instead of the kernel's start record. Such a sample, or an
  observation whose reference sample is one, carries no window, so identity
  reads unknown, never a reuse.
- The observed process: the start window of its latest process sample
  (`identityBasis: window`); for a process only the top stream named, the
  start time the alert bound (on decision and advisory rows alike), unless
  it falls in a daylight-saving fold (`lstart`); otherwise `none`, and its
  follow-ups can only read `unknown` or `exited`.
- A sample: the same program in an overlapping window that rules out a
  successor is a sighting; another program or a disjoint window is a reuse
  (the observed process is gone); anything else is `identity-uncertain`.
- A signal or touch: matched by the target's program and start time.
- The frozen ledger: matched by the entry's start time; an entry that cannot
  be told apart makes a living process `frozen-uncertain`. `frozen` means
  the ledger held the process at the horizon, including a freeze still
  inside its verify window.
- A start time in a daylight-saving fold names two epochs, so it is never
  placed: a signal, touch or ledger entry started then counts as uncertain,
  never as another process.

## Deliberately not done

- Advisory rows are not decision points: their `wouldAct` is `none`.
- Collecting records do not survive a reload.
- Jetsam reports are counted in the window, not attributed to a process.
- The stored name is a sanitized local basename, never model input, and is
  stripped from any dataset built from the ledger, like the row's `pid`.

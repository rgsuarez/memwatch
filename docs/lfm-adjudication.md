# LFM adjudication

An optional on-device language model that decides what to do about a
runaway process when memory goes critical and nobody is at the keyboard.
It is **off by default**: a plain install of memwatch is exactly the
deterministic sentinel, with no inference runtime, no model download, and
no behavior change.

## What it does

memwatch's deterministic core knows what is *growing*; it does not know
what things *are*. It cannot tell that a virtual-machine host is an
innocent bystander, that an installer burst is self-limiting, or that a
browser renderer is disposable. That semantic judgment is what a small
local model adds.

When memory is critical and the alert HUD has gone unanswered for the
grace window, and the feature is enabled, memwatch asks a locally-served
LFM2.5 model to classify the single already-selected offender and choose
one of `wait`, `freeze`, or `terminate`. The choice is then passed through
deterministic rails that can only ever make it *safer*, never more
aggressive.

## The safety contract

The model is an advisor inside hard rails, never an autonomous authority.

- **The model never names its own target.** The deterministic detector
  selects the offending process; its pid is bound by the caller and is
  never placed in the model's context. No code path derives a signal
  target from anything the model returns. The model's text output is
  display-only.
- **The rails only reduce severity, in a fixed order.** (1) The unattended
  ceiling caps the action (`off` forces wait; `freeze` caps a terminate to
  a freeze). (2) A process that is not a proven extreme grower, or that is
  the foreground app, is never terminated autonomously (capped to freeze).
  (3) Confidence floors: a terminate needs >= 0.70 confidence or it
  becomes a freeze; a freeze needs >= 0.50 or it becomes a wait. (4) The
  same kill-policy gate that guards manual kills (same user, system-process
  denylist, never init, never memwatch or its own model server) has the
  final word.
- **The decision path never waits on the model.** Adjudication is
  asynchronous. Verdicts are computed ahead of the decision point and
  cached per process; the grace-expiry decision consumes a fresh cached
  verdict or, if none exists, acts deterministically at once. The extreme
  detection and alerting path issues no synchronous model call ever.
- **A verdict answers the snapshot it was given.** A cached verdict is
  consumed only if it was computed for the same detector kind the decision
  now sees. A verdict about a large, steady bystander is never applied to
  the same process after it has been caught in a runaway; the offender is
  re-adjudicated instead. Entries without a recorded kind are never used.
- **A verdict is filed only under its own process.** The snapshot is built
  from the tracker's data for a pid, and the request is skipped when the
  probed process is provably not the one that data came from (a pid taken
  over since the last sample). A verdict whose process cannot be tied to its
  snapshot (a process too young for its start window, or one only the top
  stream has named that no alert has bound yet) is asked and logged, but
  never drives a decision, in any mode: the deterministic policy acts. It is
  not counted as fresh, so the offender is asked again once the alert has
  bound it. A verdict records the start time the alert had bound when it
  was asked: once the alert binds another (a newcomer that took the pid),
  that verdict is evicted from the cache, and the newcomer is asked about
  once (one request is in flight at a time). Consumption also re-checks the
  live process against the verdict's own start time, so a verdict about one
  process never acts on another.
- **A clock stepped back never extends a wait.** A verdict or a first model
  wait stamped after now reads as stale, or as spent.
- **A model wait is bounded in time, then by headroom, then in time
  again.** A model wait defers the deterministic policy for `maxDeferSec`
  (120 s by default) from the first wait on that offender. Past that bound
  the floor decides, and the deterministic policy acts when any of these
  holds:
  - available memory is at or below `floorAvailPct` (12% by default);
  - headroom cannot be read (the memory size was unreadable, so the
    reading is not a real 100%): the floor fails closed;
  - `maxHoldSec` (600 s by default) has run since the first wait, whatever
    the headroom: a model holds the decision for a while, never for good.
    A first wait stamped after now (a clock step that could not be taken
    out) counts as run.

  Otherwise the wait holds: a burst still holding more headroom than the
  floor would stall work for nothing if frozen.
- **A held wait is re-checked every tick.** Past the bound, the floor is
  checked every tick, so a runaway that eats the headroom is frozen the
  tick it falls to the floor, not a grace window later. That check ends
  the wait it was holding: after any decision, the next one waits out the
  grace again unless the floor holds the wait again, so an action that
  fails is never retried every tick. Each such act is a decision point
  the observation ledger records on its own tick.
- **The records say why.** A held wait's decision record carries the rail
  `deferral-floor-held-by-headroom`. An act past the bound carries
  `deferral-floor-fired-by-headroom`, `-by-unknown-headroom` or
  `-by-hold-cap`. Both carry the threshold, the hold cap, the deferred
  seconds and the headroom read (`headroomPct`). `floorAvailPct` 0 restores
  the old floor: the policy acts at the bound regardless, with no floor
  rail.
- **Disabled or unavailable means the base system.** If the feature is off,
  the model server is not running, a request times out, or the reply is
  malformed, memwatch behaves exactly as it does without the feature: the
  deterministic unattended policy acts (or the HUD simply waits for you),
  and one rate-limited log line notes the degradation. Turning the feature
  off takes effect at once: a verdict cached before the switch decides
  nothing after it, and a held wait arms no every-tick check.
- **memwatch protects its own adjudicator.** The model server is filtered
  out of the runaway and ranked lists and refused by the kill-policy gate,
  so memwatch can never freeze or kill the process it depends on. An
  independent footprint circuit kills the server (and latches the feature
  offline) if the server itself ever exceeds its memory budget.

## Prompt-injection hardening

Process names and paths are attacker-controlled and reach the model as
data. The defenses:

- By default the model never sees a raw name at all. `redactNames` (on by
  default, applied on every serving path, local and remote) replaces each
  name with a category from a fixed vocabulary, so no attacker-controlled
  string reaches the model.
- With redaction off, names are structurally sanitized before
  serialization: validated as UTF-8, backticks neutralized so a name cannot
  break the data fence, and bidirectional-control characters stripped.
- The snapshot is fenced and labeled as data, and the system prompt states
  that instruction-looking text inside the data is itself evidence of
  suspicion.
- The output is constrained to a fixed JSON schema by the server's
  grammar, then whitelisted by the client to four bounded fields.
- The model-selection bake-off gates on **zero injection compliance**
  across a dedicated injection suite (instruction text, base64, unicode
  homoglyphs, fence escapes, and kill-redirect attempts), in both the
  make-me-lenient and redirect-the-kill directions.

## Enabling it

```
./install.sh --with-lfm
```

This installs the llama.cpp runtime (via Homebrew) if it is missing,
prints the model's license terms, fetches the default model and its
license from the hash-pinned registry, and writes the enable config. You
can also toggle the feature from the menu bar at any time. The default
model is chosen empirically; see [bakeoff-methodology.md](bakeoff-methodology.md).

**Evaluation caveat.** Live snapshots now carry each process's real age
(`ageSec`), while the 74-scenario bake-off corpus (`eval/gen-scenarios.lua`)
still hardcodes ages by kind (40 s for an extreme grower, one day
otherwise), so no bake-off score yet covers the ages a live model sees. The
corpus is being replaced by an episode generator, and the adjudicator stays
disabled until then.

The model weights are **not** part of this repository and are licensed
separately from memwatch's MIT code under the LFM Open License v1.0; see
`NOTICE-LFM` and `licenses/`.

## What it records

Every adjudication (advisory or acting) lands in an append-only decision
ledger (`memwatch-lfm.jsonl`, gitignored). Each row holds:

- the exact serialized snapshot the model was given, and its hash (a row
  that would exceed 60 KB drops the snapshot, keeps the hash and carries
  `snapshotDropped = true`);
- the model, latency and validated verdict;
- the detector kind the verdict answered;
- the rails applied and the effective action;
- a 60-second outcome follow-up.

That makes every row that keeps its snapshot replayable through a
different model.

The **Open value report** menu item renders the ledger into a
self-contained dashboard. Nothing in the ledger or report leaves the
machine.

With the feature on or off, the passive observation ledger
(`memwatch-observe.jsonl`; see the README) records, at each grace-expiry
decision point and every 45 s while pressure is up, what an adjudicator
would have faced and what happened afterward. That is the outcome record
new models are evaluated against.

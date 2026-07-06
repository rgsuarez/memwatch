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
- **Disabled or unavailable means the base system.** If the feature is off,
  the model server is not running, a request times out, or the reply is
  malformed, memwatch behaves exactly as it does without the feature: the
  deterministic unattended policy acts (or the HUD simply waits for you),
  and one rate-limited log line notes the degradation.
- **memwatch protects its own adjudicator.** The model server is filtered
  out of the runaway and ranked lists and refused by the kill-policy gate,
  so memwatch can never freeze or kill the process it depends on. An
  independent footprint circuit kills the server (and latches the feature
  offline) if the server itself ever exceeds its memory budget.

## Prompt-injection hardening

Process names and paths are attacker-controlled and reach the model as
data. The defenses:

- Names are structurally sanitized before serialization: validated as
  UTF-8, backticks neutralized so a name cannot break the data fence, and
  bidirectional-control characters stripped.
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

The model weights are **not** part of this repository and are licensed
separately from memwatch's MIT code under the LFM Open License v1.0; see
`NOTICE-LFM` and `licenses/`.

## What it records

Every adjudication (advisory or acting) lands in an append-only decision
ledger (`memwatch-lfm.jsonl`, gitignored): the snapshot hash, model,
latency, the raw and validated verdict, the rails applied, the effective
action, and a 60-second outcome follow-up. The **Open value report** menu
item renders the ledger into a self-contained dashboard. Nothing in the
ledger or report leaves the machine.

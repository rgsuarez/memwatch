# memwatch

A glanceable menu-bar memory-pressure gauge for macOS, driven by Hammerspoon.
It exists to give early warning before the machine repeats the 2026-05-29
unrecoverable freeze, which was a memory-compressor thrash livelock (compressor
climbed from ~11 GB at a mid-morning jetsam to ~17-18 GB at the freeze, on a
36 GB machine, with no kernel panic).

## What it does

An always-present dot in the menu bar:

| State | Look | Meaning |
|-------|------|---------|
| `ok`   | dim green dot | healthy |
| `warn` | amber dot, slow pulse, shows compressor GB | pressure building |
| `crit` | red dot, fast flash, shows compressor GB | critical; fires a silent notification naming the top memory consumers |

Click the dot for live compressor / swap / available numbers, the top 5 memory
consumers, and a shortcut to Activity Monitor.

## Signals and thresholds (the "Balanced" profile)

Sampled every 5 seconds. A level trips if ANY of its conditions are met.

| Signal | Source | warn | crit |
|--------|--------|------|------|
| Compressor (pages stored in compressor x page size) | `vm_stat` | >= 8 GB | >= 14 GB |
| Swap used | `sysctl vm.swapusage` | >= 2 GB | >= 6 GB |
| Available (free + speculative + purgeable + file-backed) | `vm_stat` + `hw.memsize` | <= 15% | <= 8% |

"Available" is reclaimable headroom rather than raw free, because macOS keeps
free pages low by design and raw free would false-alarm constantly.

Compressor is the leading indicator: it is what tracked the descent into the
freeze most cleanly. Thresholds live in `lua/memwatch_core.lua` (`M.cfg`).

## Layout

```
~/projects/memwatch/
  lua/memwatch_core.lua   pure logic: parse vm_stat / swap, derive metrics, classify (no Hammerspoon dependency)
  lua/memwatch.lua        Hammerspoon UI: menu bar item, poll timer, flash, notification, logging
  test_core.lua           unit tests for the pure logic (ok / warn / crit + parsers)
  install.sh              idempotent wiring into ~/.hammerspoon/init.lua (with backup)
  memwatch.log            appended on every threshold crossing (created on first crossing)
```

## Install

```sh
bash ~/projects/memwatch/install.sh
```

This appends a `BEGIN memwatch / END memwatch` block to `~/.hammerspoon/init.lua`
(after backing it up), adds the project `lua/` dir to `package.path`, and
`require("memwatch")`, then reloads Hammerspoon. Re-running is safe.

## Test

Pure-logic unit tests:

```sh
cd ~/projects/memwatch && lua test_core.lua
```

Live visual check (forces a state for 12 seconds, then returns to live reading):

```sh
hs -c "memwatch.test('warn')"
hs -c "memwatch.test('crit')"   # also fires the notification
hs -c "memwatch.status()"        # one-line current reading
```

## Uninstall

Delete the `BEGIN memwatch ... END memwatch` block from `~/.hammerspoon/init.lua`
(a backup `init.lua.bak.*` was created at install time) and reload Hammerspoon.

## Notes

- Auto-starts at login because Hammerspoon does; no launchd job.
- Alerts are silent by design (icon + notification, no sound).
- Editing the module does not auto-reload (the existing pathwatcher only watches
  `~/.hammerspoon/`); run `hs -c "hs.reload()"` after changes.

-- memwatch_core.lua
-- Pure logic for the memwatch menu-bar memory-pressure gauge.
-- NO Hammerspoon dependency: every function here is unit-testable with a
-- standalone `lua` interpreter (see ../test_core.lua). The Hammerspoon glue
-- in memwatch.lua does the actual command execution and UI; it delegates all
-- parsing and classification to this module.

local M = {}

-- Apple silicon default page size (bytes). Overridable; also auto-detected
-- from the vm_stat header by parsePageSize().
M.PAGE = 16384

-- Thresholds (the "Balanced" profile), calibrated to the 2026-05-29 freeze on
-- this machine: the morning jetsam event sat at ~11 GB compressor with under
-- 600 MB free; the terminal freeze was reached at ~17-18 GB compressor.
-- A signal trips a level if ANY of its conditions are met.
M.cfg = {
  pageSize          = M.PAGE,
  pollSec           = 5,    -- how often the gauge samples
  notifyCooldownSec = 180,  -- min seconds between critical notifications
  -- Pulse the dot on warn/crit? Off by default: the color and the compressor-GB
  -- readout already signal the level, and a blinking menu-bar item is distracting.
  -- Set to true to restore the warn slow-pulse / crit fast-flash.
  flash             = false,
  -- Absolute compressor/swap/avail thresholds. INFORMATIONAL ONLY: on macOS
  -- these are cumulative or homeostatic (the kernel can hold 30 GB in the
  -- compressor and 8 GB of swap for days while reporting normal pressure),
  -- so they no longer drive alerts. classify() survives for the legacy
  -- readout; the state machine below is what alerting listens to.
  warn = { compGB = 8,  swapGB = 2, availPct = 15 },
  crit = { compGB = 14, swapGB = 6, availPct = 8  },
  -- Activity-rate thresholds in pages/sec (16 KiB pages; 1 GB/s = 61,035 pg/s).
  rates = {
    swapLo = 200,    -- ~3 MB/s: sustained disk eviction means the compressor is full
    swapHi = 2000,   -- ~32 MB/s: thrash signature
    compLo = 5000,   -- ~80 MB/s: meaningful sustained compression
    compHi = 20000,  -- ~320 MB/s: the compressor is being force-fed
  },
  avail = {
    low      = 10,   -- % of RAM: headroom thinning
    floor    = 5,    -- % of RAM: near the floor
    exitHyst = 3,    -- leave ELEVATED only above low + exitHyst
  },
  -- State-machine confirmation and release windows.
  sm = {
    confirmElev     = 2,  -- consecutive ticks to raise ok -> elevated (~10s)
    confirmCrit     = 2,  -- consecutive ticks to raise to critical (~10s);
                          -- kernel-critical and extreme runaways take one
    releaseTicks    = 3,  -- consecutive all-clear ticks to step down (~15s)
    minDwellElevSec = 20,
    minDwellCritSec = 30,
  },
  -- Cooldowns and grace windows.
  cool = {
    ignoreSec        = 1800, -- per-offender "Ignore 30 min"
    hudRaiseSec      = 60,   -- min seconds between HUD raises (a new offender preempts)
    autoKillGraceSec = 60,   -- HUD unanswered this long before auto-kill (if enabled)
    frozenSweepSec   = 60,   -- calm-state frozen-ledger liveness sweep cadence
  },
  -- Unattended action at critical + grace expiry. The deterministic
  -- autonomous layer (successor to autoKill), model-free and shipping in
  -- Phase 0:
  --   "off"    alert only, exactly today's default
  --   "freeze" SIGSTOP the offender (reversible; memory not released)
  --   "kill"   SIGTERM/SIGKILL the offender
  -- It fires only for an extreme-growth runaway while critical, after the
  -- HUD has gone unanswered for the grace window, and only if the kill
  -- policy allows the target. When the LFM feature is enabled and a fresh
  -- verdict is available, the glue consults it to refine the action within
  -- the "off"|"freeze"|"kill" ceiling; the model never widens it.
  unattended = "off",
  -- Compat shim: the old boolean still works. autoKill=true maps to
  -- unattended="kill" (see M.resolveUnattended); leave it false and set
  -- unattended directly for new config.
  autoKill = false,
  -- One-click kill behavior and its safety rails.
  kill = {
    escalateSec = 7,   -- SIGTERM, then SIGKILL after this long if still alive
    verifySec   = 2,   -- wait after KILL before the death check
    settleSec   = 3,   -- wait before measuring reclaimed memory
    -- Basename denylist. uid must also match the operator, so root-owned
    -- daemons are already unreachable; this list guards same-uid session
    -- infrastructure. No pid<=100 rule on purpose: WindowServer is pid 600
    -- on this machine, so a low-pid floor would protect nothing real.
    deny = {
      ["kernel_task"] = true, ["launchd"] = true, ["WindowServer"] = true,
      ["loginwindow"] = true, ["Finder"] = true, ["Dock"] = true,
      ["SystemUIServer"] = true, ["WindowManager"] = true,
      ["ControlCenter"] = true, ["Spotlight"] = true, ["coreaudiod"] = true,
      ["cfprefsd"] = true, ["Hammerspoon"] = true, ["hidd"] = true,
      ["logd"] = true, ["opendirectoryd"] = true,
    },
  },
}

-- Detect the VM page size from a vm_stat header line, else fall back to M.PAGE.
function M.parsePageSize(vmStatText)
  return tonumber((vmStatText or ""):match("page size of (%d+) bytes")) or M.PAGE
end

-- Parse `vm_stat` output into a { [label] = pageCount } table.
-- Lines look like:  "Pages stored in compressor:            1119899."
function M.parseVmStat(vmStatText)
  local t = {}
  for line in (vmStatText or ""):gmatch("[^\n]+") do
    local key, val = line:match("^(.-):%s+(%d+)%.?$")
    if key and val then t[key] = tonumber(val) end
  end
  return t
end

-- Parse `sysctl -n vm.swapusage` -> swap USED in bytes.
-- Input form: "total = 4096.00M  used = 1.50G  free = 2.00G  (encrypted)"
function M.parseSwapUsed(swapText)
  local num, unit = (swapText or ""):match("used%s*=%s*([%d%.]+)%s*([KMG]?)")
  if not num then return 0 end
  local mult = ({ K = 1024, M = 1024 ^ 2, G = 1024 ^ 3 })[unit] or 1
  return tonumber(num) * mult
end

-- Derive human-facing metrics from parsed inputs.
--   vm         : table from parseVmStat
--   swapBytes  : number from parseSwapUsed
--   totalBytes : hw.memsize
--   pageSize   : bytes per page
-- "available" is reclaimable headroom (free + speculative + purgeable +
-- file-backed), NOT raw free, because macOS deliberately keeps free pages low;
-- raw free would false-alarm constantly.
function M.metrics(vm, swapBytes, totalBytes, pageSize)
  vm = vm or {}
  pageSize = pageSize or M.cfg.pageSize
  local function p(k) return vm[k] or 0 end
  local storedPages = p("Pages stored in compressor")
  local availPages  = p("Pages free") + p("Pages speculative")
                    + p("Pages purgeable") + p("File-backed pages")
  totalBytes = totalBytes or 0
  return {
    compGB   = (storedPages * pageSize) / 1e9,
    swapGB   = (swapBytes or 0) / 1e9,
    availPct = totalBytes > 0 and (availPages * pageSize / totalBytes * 100) or 100,
  }
end

-- Derive metrics from hs.host.vmStat()'s native table (no fork needed).
-- Field note: the native API names vm_stat's "Pages stored in compressor"
-- `uncompressedPages` (the logical volume held by the compressor);
-- `pagesUsedByVMCompressor` is the compressor's physical footprint and is NOT
-- what the compressor row in the UI reports. Also carries the cumulative
-- counters whose deltas give activity rates.
function M.metricsFromVmStat(v, swapBytes)
  v = v or {}
  local pageSize = v.pageSize or M.cfg.pageSize
  local total = v.memSize or 0
  local function n(k) return v[k] or 0 end
  local availPages = n("pagesFree") + n("pagesSpeculative")
                   + n("pagesPurgeable") + n("fileBackedPages")
  return {
    compGB   = n("uncompressedPages") * pageSize / 1e9,
    swapGB   = (swapBytes or 0) / 1e9,
    availPct = total > 0 and (availPages * pageSize / total * 100) or 100,
    totalGB  = total / 1e9,
    counters = {
      swapOuts   = n("swapOuts"),
      compressed = n("pagesCompressed"),
      pageOuts   = n("pageOuts"),
    },
  }
end

-- Per-second rate from a cumulative counter pair. Clamps to 0 on the first
-- sample, a non-positive interval, or a counter reset (reboot / wraparound):
-- a negative delta must never read as activity.
function M.rate(cur, prev, dt)
  if not cur or not prev or not dt or dt <= 0 or cur < prev then return 0 end
  return (cur - prev) / dt
end

-- Parse the consolidated sampler blob. Line 1 is
-- `sysctl -n kern.memorystatus_vm_pressure_level` (1 normal / 2 warn / 4
-- critical); the vm.swapusage line follows. A missing or garbled blob parses
-- to the calm defaults (level 1, swap 0) so a failed fork can never raise an
-- alert on its own.
function M.parseSampler(text)
  text = text or ""
  local kern = tonumber(text:match("^%s*(%d+)%s*\n")) or tonumber(text:match("^%s*(%d+)%s*$")) or 1
  return { kernLevel = kern, swapBytes = M.parseSwapUsed(text) }
end

-- Classify metrics into "ok" | "warn" | "crit".
function M.classify(m, cfg)
  cfg = cfg or M.cfg
  local function hit(th)
    return m.compGB >= th.compGB or m.swapGB >= th.swapGB or m.availPct <= th.availPct
  end
  if hit(cfg.crit) then return "crit" end
  if hit(cfg.warn) then return "warn" end
  return "ok"
end

------------------------------------------------------------------------------
-- Pressure signals and state machine
------------------------------------------------------------------------------

-- Boolean pressure signals for one tick.
--   m              : metrics table (availPct is what matters here)
--   rates          : { swapOut =, comp =, pageOut = } in pages/sec
--   kern           : kern.memorystatus_vm_pressure_level (1 normal / 2 warn / 4 critical)
--   runawayExtreme : true when the process tracker confirmed an extreme grower
-- availPct is never a solo trigger: macOS defends a low-free equilibrium, so
-- thin headroom only matters while the compressor is actively being fed.
function M.signals(m, rates, kern, runawayExtreme, cfg)
  cfg = cfg or M.cfg
  local r, a = cfg.rates, cfg.avail
  rates = rates or {}
  local swapOut = rates.swapOut or 0
  local comp    = rates.comp or 0
  local avail   = (m and m.availPct) or 100
  kern = kern or 1
  local s = {
    kernWarn   = kern >= 2,
    kernCrit   = kern >= 4,
    swapActive = swapOut >= r.swapLo,
    swapStorm  = swapOut >= r.swapHi,
    compActive = comp >= r.compLo,
    compStorm  = comp >= r.compHi,
    availLow   = avail <= a.low,
    availFloor = avail <= a.floor,
    runawayExtreme = runawayExtreme or false,
  }
  s.elevCond = s.kernWarn or s.swapActive or s.compStorm or (s.availLow and s.compActive)
  s.critFast = s.kernCrit or s.runawayExtreme
  s.critSlow = s.swapStorm or (s.availFloor and s.compActive)
  s.critCond = s.critFast or s.critSlow
  -- Exit conditions are stricter than "not entering" (hysteresis): stepping
  -- down needs genuinely calm rates and restored headroom, not a threshold
  -- undershoot.
  s.calmCrit = (not s.critCond) and kern < 4 and swapOut < r.swapLo
  s.calmElev = (not s.elevCond) and (not s.critCond) and kern <= 1
           and swapOut < (r.swapLo / 2) and avail > (a.low + a.exitHyst)
  return s
end

function M.newSMState(now)
  return { state = "ok", since = now or 0, elevCount = 0, critCount = 0, releaseCount = 0 }
end

-- Advance the pressure state machine one tick. Returns state, changed, reason.
-- States: ok -> elevated -> critical. Asymmetric on purpose: upgrades need a
-- short confirmation (none for kernel-critical or a confirmed extreme
-- runaway), downgrades need a minimum dwell plus consecutive all-clear ticks.
-- Absolute compressor/swap levels never appear here.
function M.smStep(sm, s, now, cfg)
  cfg = cfg or M.cfg
  local c = cfg.sm
  local prev = sm.state

  local function enter(st, reason)
    sm.state, sm.since = st, now
    sm.elevCount, sm.critCount, sm.releaseCount = 0, 0, 0
    return st, st ~= prev, reason
  end

  if sm.state ~= "critical" then
    if s.critFast then
      return enter("critical", s.kernCrit and "kernel-critical" or "runaway-extreme")
    end
    if s.critSlow then
      sm.critCount = sm.critCount + 1
      if sm.critCount >= c.confirmCrit then
        return enter("critical", s.swapStorm and "swap-storm" or "avail-floor")
      end
    else
      sm.critCount = 0
    end
  end

  if sm.state == "ok" then
    if s.elevCond then
      sm.elevCount = sm.elevCount + 1
      if sm.elevCount >= c.confirmElev then return enter("elevated", "pressure-building") end
    else
      sm.elevCount = 0
    end
  elseif sm.state == "elevated" then
    if s.calmElev then
      sm.releaseCount = sm.releaseCount + 1
      if (now - sm.since) >= c.minDwellElevSec and sm.releaseCount >= c.releaseTicks then
        return enter("ok", "recovered")
      end
    else
      sm.releaseCount = 0
    end
  else -- critical
    if s.calmCrit then
      sm.releaseCount = sm.releaseCount + 1
      if (now - sm.since) >= c.minDwellCritSec and sm.releaseCount >= c.releaseTicks then
        return enter("elevated", "easing")
      end
    else
      sm.releaseCount = 0
    end
  end
  return sm.state, false, ""
end

------------------------------------------------------------------------------
-- Kill policy (pure; the glue executes signals, this decides legitimacy)
------------------------------------------------------------------------------

-- proc = { pid, uid, comm }. Same-uid only, curated basename denylist, never
-- init and never the host process. protectedPids (optional 5th arg) is a
-- pid-set { [pid]=true } refused outright; the glue builds it from the
-- watchdog pid and its own llama-server so memwatch can never signal its
-- adjudicator. It is an explicit fifth argument, NOT a cfg field, because
-- cfg here is a full replace (cfg = cfg or M.cfg), so a partial cfg table
-- would silently drop the denylist. Returns allowed, reason.
function M.killAllowed(proc, ownUid, selfPid, cfg, protectedPids)
  cfg = cfg or M.cfg
  if not proc or not proc.pid then return false, "no process" end
  if proc.pid <= 1 then return false, "protected pid" end
  if selfPid and proc.pid == selfPid then return false, "own process" end
  if protectedPids and protectedPids[proc.pid] then return false, "protected pid (memwatch)" end
  if proc.uid ~= ownUid then return false, "not your process" end
  local base = (proc.comm or ""):match("([^/]+)$") or ""
  if cfg.kill.deny[base] then return false, "protected process" end
  return true, "ok"
end

M.UNATTENDED_MODES = { off = true, freeze = true, kill = true }

-- Resolve the effective unattended mode, honoring the autoKill compat shim.
-- Explicit unattended wins; autoKill=true with unattended unset -> "kill".
-- FAILS CLOSED: any value that is not exactly off|freeze|kill resolves to
-- "off" (a typo like "disabled" must never arm autonomous SIGSTOP/SIGKILL).
-- Returns mode, invalidValue-or-nil so the caller can log the rejected input.
function M.resolveUnattended(cfg)
  cfg = cfg or M.cfg
  local u = cfg.unattended
  if u ~= nil and not M.UNATTENDED_MODES[u] then
    -- Unknown mode: never fall through to the compat shim; fail to off.
    return "off", u
  end
  if u and u ~= "off" then return u end
  if cfg.autoKill then return "kill" end
  return "off"
end

------------------------------------------------------------------------------
-- Title rendering (pure: text + level; the glue applies color and font)
------------------------------------------------------------------------------

M.DOT = "\u{25CF}" -- ● geometric circle (not an emoji)

local TITLE_NAME_MAX = 14

-- Compact a process name for the menu bar: strip helper suffixes, cap length.
function M.shortName(name)
  if not name or name == "" then return nil end
  name = name:gsub("%s+Helper.*$", "")
  if #name > TITLE_NAME_MAX then
    name = name:sub(1, TITLE_NAME_MAX - 1) .. "\u{2026}"
  end
  return name
end

-- Top-stream staleness decision (pure, 2026-07-13 drill finding). The `top`
-- attribution stream is the ONLY feed that sees compressed pages, and a fast
-- compressible allocator lives almost entirely in the compressor (its RSS
-- collapses as the kernel compresses it in real time). A stream can stay
-- ALIVE while silently ceasing to publish: the task handle is not proof of
-- liveness, fresh samples are. When that happens the growth rings freeze, a
-- 190 MB/s runaway reads as a steady hog, and the autonomous freeze never
-- becomes eligible - the watchdog goes blind exactly during the crisis it
-- exists to catch (observed live: a 5-hour-old stream with a 77s-stale cache
-- missed a 3.8 GB/21s leaker entirely; a fresh stream caught the identical
-- leaker at 9063 MB/min). Returns true when a live stream has gone quiet past
-- staleSec (measured from its last publish, or from its start if it has never
-- published) and the respawn cooldown has elapsed, so a storm cannot thrash
-- forks retrying a spawn that is starving.
function M.topStreamStale(alive, lastPublishAt, startedAt, lastRespawnAt, now, staleSec, cooldownSec)
  if not alive then return false end
  if (startedAt or 0) <= 0 then return false end
  local last = math.max(lastPublishAt or 0, startedAt or 0)
  if (now - last) <= (staleSec or 30) then return false end
  if (now - (lastRespawnAt or 0)) <= (cooldownSec or 60) then return false end
  return true
end

-- Frozen-ledger liveness decision (pure): given the persisted frozen map
-- ([pid] = entry carrying lstart) and probe(pid) -> { lstart, state } | nil,
-- partition into entries still identity-valid AND stopped versus dead wood,
-- with a named reason per drop. The startup reconcile validates at load;
-- this is the same decision for the calm-state sweep, because a frozen
-- process that exits BETWEEN reloads must not haunt the ledger (2026-07-09
-- field finding: a dead VM pid held frozenCount=1 for two days).
function M.pruneFrozen(entries, probe)
  local kept, dropped = {}, {}
  for pid, e in pairs(entries or {}) do
    local p = probe(pid)
    local why = nil
    if not p then
      why = "exited"
    elseif e.lstart and p.lstart and e.lstart ~= p.lstart then
      why = "pid-recycled"
    elseif p.state ~= "T" then
      why = "resumed-externally"
    end
    if why then
      dropped[#dropped + 1] = { entry = e, why = why }
    else
      kept[pid] = e
    end
  end
  return kept, dropped
end

-- What the menu-bar title should say. Quiet until trouble:
--   ok        ●                    (dim)
--   elevated  ● <watch>↑           (amber; hint only while a grower is watched)
--   critical  ● <offender> <N>G    (red; falls back to the cause tag)
function M.renderTitle(state, snap)
  snap = snap or {}
  if state == "critical" then
    if snap.offenderName then
      return { text = string.format("%s %s %.0fG", M.DOT, M.shortName(snap.offenderName), snap.offenderGB or 0),
               level = "crit" }
    end
    return { text = M.DOT .. " " .. (snap.causeTag or "MEM"), level = "crit" }
  end
  if state == "elevated" then
    local w = M.shortName(snap.watchName)
    return { text = w and (M.DOT .. " " .. w .. "\u{2191}") or M.DOT, level = "warn" }
  end
  return { text = M.DOT, level = "ok" }
end

return M

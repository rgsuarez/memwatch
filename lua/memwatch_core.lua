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
    frozenSweepSec   = 60,   -- frozen-ledger liveness sweep cadence (every state)
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

-- Parse one `ps -p <pids>,<self> -o pid=,uid=,state=,lstart=,comm=` reply.
-- memwatch's own pid is always in the list as a positive control: without
-- its row the probe did not run (a fork failed under pressure, or the reply
-- is cut short), so nothing in the reply may be read as a process being
-- gone. Every line must parse: one that does not is a reply cut off or
-- garbled, and a missing row beside it proves nothing either. Returns
-- pid -> { pid, uid, state, lstart, comm }, or nil (unknown).
function M.parseProbeRows(out, selfPid)
  if type(out) ~= "string" then return nil end
  local rows = {}
  for line in out:gmatch("[^\n]+") do
    if line:match("%S") then
      local pid, uid, state, lstart, comm = line:match(
        "^%s*(%d+)%s+(%d+)%s+(%S+)%s+(%a+%s+%a+%s+%d+%s+%d+:%d+:%d+%s+%d+)%s+(.-)%s*$")
      if not pid then return nil end
      pid = tonumber(pid)
      rows[pid] = { pid = pid, uid = tonumber(uid), state = state, lstart = lstart, comm = comm }
    end
  end
  if selfPid == nil or rows[selfPid] == nil then return nil end
  return rows
end

-- One pid's probe result: "present", proc | "absent" | "unknown". Absent
-- needs the control row; a probe that did not run is never an exit.
function M.probeResult(rows, pid)
  if rows == nil then return "unknown" end
  local p = rows[pid]
  if p then return "present", p end
  return "absent"
end

-- May a signal go to a process memwatch recorded (ident: pid, lstart and
-- optionally name), given a fresh probe of its pid (status, and the live
-- start time and name)? Only when the probe saw it with the recorded start
-- time (and name). A record without a start time, or a probe that could
-- not tell, never allows a signal: the pid may hold another process.
function M.identityHolds(ident, status, liveLstart, liveName)
  if type(ident) ~= "table" or ident.lstart == nil then return false end
  if status ~= "present" or liveLstart ~= ident.lstart then return false end
  return ident.name == nil or M.sameName(liveName, ident.name)
end

-- A probed process is stopped (SIGSTOP): its state starts with T.
function M.isStopped(proc)
  return proc ~= nil and type(proc.state) == "string" and proc.state:sub(1, 1) == "T"
end

-- Frozen-ledger liveness decision (pure): given the persisted frozen map
-- ([pid] = entry carrying lstart) and probe(pid) -> "present", { lstart,
-- state } | "absent" | "unknown", partition into entries still
-- identity-valid AND stopped versus dead wood,
-- with a named reason per drop. The startup reconcile validates at load;
-- this is the same decision for the calm-state sweep, because a frozen
-- process that exits BETWEEN reloads must not haunt the ledger (2026-07-09
-- field finding: a dead VM pid held frozenCount=1 for two days).
-- Unknown keeps the entry: a probe that could not run proves nothing, and
-- dropping a live entry would strand a stopped process with no way back.
-- A freeze still being verified (pendingUntil in the future) is kept as it
-- is: the STOP may not have taken effect yet, and its verifier decides.
function M.pruneFrozen(entries, probe, now)
  local kept, dropped = {}, {}
  for pid, e in pairs(entries or {}) do
    local st, p = "pending", nil
    if not (e.pendingUntil and now and now < e.pendingUntil) then st, p = probe(pid) end
    local why = nil
    if st == "absent" then
      why = "exited"
    elseif st == "present" then
      if e.lstart and p.lstart and e.lstart ~= p.lstart then
        why = "pid-recycled"
      elseif not M.isStopped(p) then
        why = "resumed-externally"
      end
    end
    if why then
      dropped[#dropped + 1] = { entry = e, why = why }
    else
      kept[pid] = e
    end
  end
  return kept, dropped
end

-- Process names from the top stream are truncated at ~16 characters, so a
-- long name may be a prefix of the full one from ps (the same rule the
-- signal path applies); shorter names must match exactly.
function M.sameName(a, b)
  if a == b then return true end
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  if #a > #b then a, b = b, a end
  return #a >= 15 and b:sub(1, #a) == a
end

-- Continuity for the alert surfaces ("is this still the process on
-- screen?"): pid and name, plus the start time (lstart) when both sides
-- have one bound. A missing start time never forces a mismatch (it is
-- bound lazily), but two bound ones must agree, so a pid reused by a
-- same-name process reads as a different offender.
function M.sameOffender(a, b)
  if a == nil or b == nil then return a == b end
  if a.pid ~= b.pid or not M.sameName(a.name, b.name) then return false end
  return a.lstart == nil or b.lstart == nil or a.lstart == b.lstart
end

-- Memory ("was this exact process here before?"), for records that last
-- the whole episode: a record made without a start time never vouches for
-- a process whose start time is known (the pid may have been reused in
-- between). With both bound they must agree; with the candidate unbound,
-- pid and name are all anyone knows about it.
function M.sameRecord(rec, cand)
  if rec == nil or cand == nil then return false end
  if rec.pid ~= cand.pid or not M.sameName(rec.name, cand.name) then return false end
  if cand.lstart == nil then return true end
  return rec.lstart == cand.lstart
end

-- Severity of an offender kind, for escalation: a process that moves up
-- this ladder is new information even if it is the same process.
local KIND_RANK = { hog = 1, absolute = 2, sustained = 3, extreme = 4 }
function M.kindRank(kind) return KIND_RANK[kind] or 0 end

-- The critical banner's next step. One banner per offender per episode:
--   * a live banner for the current offender stays (never re-posted, even
--     after a manual dismissal, which macOS does not report), except that it
--     is replaced in place, without the cooldown, when it gains a bound
--     identity (its Force Quit becomes safe to offer) or its kind escalates;
--   * a live generic banner (no offender identified) is replaced in place as
--     soon as an offender is named: the episode's breadcrumb gains a name;
--   * a live banner naming someone else goes at once, so its Force Quit can
--     never act on a process the alerts have moved off; the new offender's
--     banner follows when the cooldown allows (damping offender flap; the
--     episode's end resets it) and only if it has not had one this episode;
--   * with no offender named, whatever is up stays (no churn), and a
--     generic banner is posted at most once per episode;
--   * a live banner naming a process since answered (memwatch holds it
--     frozen, it is gone, or it is ignored) goes, even once the episode has
--     no named offender at all. An answered process is never the offender.
-- a: { hasBanner, banner = {pid,name,lstart,kind,canAct}|nil (nil with
--      hasBanner means a generic banner is up), bannerHandled (the live
--      banner's process is answered), offender = {pid,name,lstart,kind}|nil,
--      canAct (the offender's identity is bound now), notified,
--      sinceLastPostSec, cooldownSec }
--   -> { withdraw = bool, post = bool, replace = bool }; replace means
--      withdraw and post now, regardless of the cooldown.
function M.bannerStep(a)
  local off, b = a.offender, a.banner
  local cooled = (a.sinceLastPostSec or math.huge) >= (a.cooldownSec or 0)
  local keep = { withdraw = false, post = false, replace = false }
  -- Whether a new banner may go up for the current offender (or a generic
  -- one when none is named), with nothing in the way.
  local function mayPost() return (not a.notified) and cooled end
  if a.hasBanner and a.bannerHandled then
    -- The live banner names an offender already answered: it goes, whoever
    -- heads the episode now.
    return { withdraw = true, post = mayPost(), replace = false }
  end
  if a.hasBanner then
    if off == nil then return keep end
    if b ~= nil and M.sameOffender(b, off) then
      if (a.canAct and not b.canAct) or M.kindRank(off.kind) > M.kindRank(b.kind) then
        return { withdraw = false, post = false, replace = true }
      end
      return keep
    end
    if b == nil then return { withdraw = false, post = false, replace = true } end
    return { withdraw = true, post = mayPost(), replace = false }
  end
  return { withdraw = false, post = mayPost(), replace = false }
end

-- One poll of a held predicate (the glue's untilHeld): "done" when it ran
-- and reported done, "giveup" once it has errored continuously for
-- giveUpSec (never a success), else "poll" again. An erroring poll keeps
-- polling because escalations live inside predicates; a poll that runs
-- ends the error run. st carries the run across polls.
function M.untilStep(st, ok, done, now, giveUpSec)
  if ok then
    st.erroringSince = nil
    return (done == true) and "done" or "poll"
  end
  st.erroringSince = st.erroringSince or now
  if (now - st.erroringSince) >= giveUpSec then return "giveup" end
  return "poll"
end

-- The unattended gate, apart from the mode: whether this tick's offender is
-- one memwatch would act on unattended. The live unattended step and the
-- observation ledger's decision rows both ask it, so a decision row marks
-- exactly the ticks where the live gate stands open under any mode.
-- a: { kind, alertActive, hudHold, sameAsHud (the offender is the process
--      the alert surfaced), answered (frozen, gone or ignored), interacted
--      (the operator acted on it since the raise), bound (its start time is
--      bound), exposureSec (its grace so far), graceSec }
-- -> "open" | "unbound" (open but for identity: the live step skips and
--    logs) | "closed"
function M.unattendedGate(a)
  if type(a) ~= "table" or a.kind ~= "extreme" then return "closed" end
  if a.alertActive ~= true or a.hudHold or not a.sameAsHud then return "closed" end
  if a.answered or a.interacted then return "closed" end
  if type(a.graceSec) ~= "number" or type(a.exposureSec) ~= "number"
     or a.exposureSec < a.graceSec then
    return "closed"
  end
  if not a.bound then return "unbound" end
  return "open"
end

-- What an action's outcome means for the alert that asked for it (the
-- signal engines report the outcome; nothing is re-probed after the fact):
--   done    frozen, terminated, or verified gone before any signal
--   rebind  the pid holds another process: forget the binding, and treat
--           whoever holds the pid now as a new question
--   snooze  refused by policy, or signaled but survived: ask again later
--   stand   unverified (or unknown): nothing is concluded, and the alert
--           stays as it was, visible and retryable
--   (unconfirmed, a signal sent whose result could not be verified, also
--   stands; unlike unverified, something may have changed, so it is
--   announced)
local ANSWER = { frozen = "done", terminated = "done", exited = "done",
                 stale = "rebind", refused = "snooze", failed = "snooze" }
function M.answerFor(outcome) return ANSWER[outcome] or "stand" end

-- Should the HUD raise now? Never while the episode's alert is already up
-- (visible covers muted-but-armed). For a named offender (never an
-- answered one: a process memwatch holds frozen, that is gone or ignored is
-- no candidate at all):
--   * one the operator closed (snoozed) returns when the snooze ends, or at
--     once if its kind escalates (a quiet hog turning into a runaway);
--   * any other process than the one this episode last raised for preempts
--     the raise cooldown.
-- The same process again, and no identified offender, wait the cooldown.
-- a: { visible, offender, episode, snooze = { off, kind, untilAt }|nil,
--      sinceRaiseSec, raiseSec, now }
function M.hudRaiseDue(a)
  if a.visible then return false end
  local off = a.offender
  if off then
    local sn = a.snooze
    if sn and M.sameOffender(sn.off, off) then
      return M.kindRank(off.kind) > M.kindRank(sn.kind) or (a.now or 0) >= (sn.untilAt or 0)
    end
    if not M.sameOffender(a.episode, off) then return true end
  end
  return (a.sinceRaiseSec or math.huge) >= (a.raiseSec or 0)
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

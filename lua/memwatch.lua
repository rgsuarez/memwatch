-- memwatch.lua
-- Menu-bar memory-pressure gauge for Hammerspoon.
-- Project: ~/projects/memwatch  (wired into ~/.hammerspoon/init.lua)
--
-- An always-present, glanceable dot in the menu bar:
--   green (dim) = ok        no active pressure; the dot stays quiet
--   amber       = elevated  memory demand is building (rates or kernel warn)
--   red         = critical  the system is actively degrading; the title names
--                           the offending process when one is identified
-- Alerting is driven by activity rates (swap-out / compression pages per
-- second), the kernel's own pressure verdict, and runaway-process growth,
-- never by absolute compressor or swap size: macOS keeps those high
-- indefinitely, so they only carry information, not alarm.
-- The dot is steady by default; set core.cfg.flash = true to pulse on trouble.
-- State transitions are appended to memwatch.log.

local core  = require("memwatch_core")
local procs = require("memwatch_procs")

local M = {}

-- runtime state
local menu        = nil
local pollTimer   = nil
local flashTimer  = nil
local flashState  = nil   -- the state the flash animation is currently rendering
local flashLit    = true
local lastNotifyAt = 0
local lastMetrics = { compGB = 0, swapGB = 0, availPct = 100 }
local lastRates   = { swapOut = 0, comp = 0, pageOut = 0 }
local lastKern    = 1
local smState     = core.newSMState(0)
local titleSnap   = {}    -- offenderName / offenderGB / watchName / causeTag
local prevCounters, prevCountersAt = nil, nil

-- per-process pipeline state
local tracker      = procs.newTracker()
local topCache     = { map = nil, at = 0 }  -- per-pid CMPRS from async top
local lastPsList   = {}
local lastRanked   = {}   -- top hogs by RSS+CMPRS weight (menu rows)
local lastRuns     = {}   -- current runaway list, ignores applied
local lastOffender = nil  -- the process alerts name right now
local ignoredUntil = {}   -- ["pid|name"] = epoch when the ignore expires
local runawayLogAt = {}   -- ["pid|kind"] = last time this runaway was logged

local KERN_NAME = { [1] = "NORMAL", [2] = "WARN", [4] = "CRITICAL" }

------------------------------------------------------------------------------
-- logging and error containment
------------------------------------------------------------------------------

local LOG_MAX_BYTES = 1e6

-- Append a line, rotating to .1 when the log exceeds the cap.
local function appendLog(line)
  local f = io.open(LOG_PATH, "a")
  if not f then return end
  if f:seek("end") > LOG_MAX_BYTES then
    f:close()
    os.rename(LOG_PATH, LOG_PATH .. ".1")
    f = io.open(LOG_PATH, "a")
    if not f then return end
  end
  f:write(line)
  f:close()
end

-- Failures in timers and task callbacks land here (rate-limited per label)
-- instead of dying silently in the Hammerspoon console.
local lastErrorAt = {}
local function logError(label, err)
  local now = os.time()
  if (now - (lastErrorAt[label] or 0)) < 60 then return end
  lastErrorAt[label] = now
  appendLog(string.format("%s state=%s reason=error:%s err=%s\n",
    os.date("%Y-%m-%d %H:%M:%S"), smState.state, label, tostring(err)))
end

-- Wrap a callback so an error can never kill the loop that owns it.
local function guard(label, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then logError(label, err) end
  end
end

local LOG_PATH = os.getenv("HOME") .. "/projects/memwatch/memwatch.log"

-- RGB (0-1) per level. Apple system green / orange / red.
local COLOR = {
  ok   = { red = 0.20, green = 0.78, blue = 0.35 },
  warn = { red = 1.00, green = 0.62, blue = 0.04 },
  crit = { red = 1.00, green = 0.23, blue = 0.19 },
}

------------------------------------------------------------------------------
-- shell helpers
------------------------------------------------------------------------------

local function sh(cmd)
  local out = hs.execute(cmd)
  return out or ""
end

-- Sample memory metrics. Native hs.host.vmStat() first (no fork, and it
-- carries the cumulative counters the rate signals need); the vm_stat popen
-- path survives only as a fallback. Swap usage and the kernel pressure level
-- arrive asynchronously from the consolidated sampler fork.
local lastSwapBytes = 0

local function readMetrics()
  local ok, v = pcall(hs.host.vmStat)
  if ok and type(v) == "table" and v.pageSize then
    return core.metricsFromVmStat(v, lastSwapBytes)
  end
  local vmText   = sh("/usr/bin/vm_stat")
  local swapText = sh("/usr/sbin/sysctl -n vm.swapusage")
  local memText  = sh("/usr/sbin/sysctl -n hw.memsize")
  local pageSize = core.parsePageSize(vmText)
  local vm       = core.parseVmStat(vmText)
  local swapByte = core.parseSwapUsed(swapText)
  local totalByt = tonumber((memText):match("%d+")) or 0
  return core.metrics(vm, swapByte, totalByt, pageSize)
end

-- Throttled async top for per-process CMPRS attribution (~756 ms measured,
-- so it never runs on the main thread, never more than once per interval,
-- and only while the system is interesting). top truncates command names;
-- results are joined to ps rows by pid.
local TOP_CMD = "/usr/bin/top -l 1 -n 20 -o mem -stats pid,command,mem,cmprs"
local TOP_MIN_INTERVAL = 10
local topTask = nil

local function topRefresh()
  if topTask then return end
  local now = hs.timer.secondsSinceEpoch()
  if (now - topCache.at) < TOP_MIN_INTERVAL then return end
  topCache.at = now  -- stamp at launch so a slow top cannot double-fire
  topTask = hs.task.new("/bin/sh", guard("top", function(exitCode, stdOut)
    topTask = nil
    if exitCode == 0 and stdOut and stdOut ~= "" then
      topCache.map = procs.parseTop(stdOut)
    end
  end), { "-c", TOP_CMD })
  if topTask then topTask:start() end
end

------------------------------------------------------------------------------
-- rendering
------------------------------------------------------------------------------

-- Paint the menu-bar title for the current state. Content comes from the pure
-- core.renderTitle; only color, alpha, and font live here.
local function renderTitleNow()
  if not menu then return end
  local spec = core.renderTitle(smState.state, titleSnap)
  local c = COLOR[spec.level] or COLOR.ok
  local alpha
  if spec.level == "ok" then
    alpha = 0.35                 -- steady, understated
  else
    alpha = flashLit and 1.0 or 0.12
  end
  menu:setTitle(hs.styledtext.new(spec.text, {
    color = { red = c.red, green = c.green, blue = c.blue, alpha = alpha },
    font  = { name = "Menlo", size = 13 },
  }))
end

local function applyFlash(state)
  if flashTimer then flashTimer:stop(); flashTimer = nil end
  flashLit = true
  flashState = state
  -- Steady render unless the pulse is explicitly enabled. "ok" is always steady.
  if state == "ok" or not core.cfg.flash then
    renderTitleNow()
    return
  end
  local interval = (state == "critical") and 0.45 or 1.0
  renderTitleNow()
  flashTimer = hs.timer.doEvery(interval, function()
    flashLit = not flashLit
    renderTitleNow()
  end)
end

------------------------------------------------------------------------------
-- menu, notification, logging
------------------------------------------------------------------------------

local function buildMenu()
  local m = lastMetrics
  local items = {
    { title = string.format("Memory: %s", smState.state:upper()), disabled = true },
    { title = "-" },
    { title = string.format("Kernel pressure: %s (%d)", KERN_NAME[lastKern] or "?", lastKern), disabled = true },
    { title = string.format("Swap-out %.0f pg/s \u{00B7} Comp %.0f pg/s", lastRates.swapOut, lastRates.comp), disabled = true },
    { title = string.format("Available %.0f%%  \u{00B7}  Swap used %.1f GB", m.availPct, m.swapGB), disabled = true },
    { title = string.format("Compressor (info) %.1f GB", m.compGB), disabled = true },
    { title = "-" },
  }
  local cmprsNote = ""
  if not topCache.map then
    cmprsNote = " (compressed pending)"
  elseif (hs.timer.secondsSinceEpoch() - topCache.at) > 60 then
    cmprsNote = " (compressed stale)"
  end
  items[#items + 1] = { title = "Top by weight, RSS+compressed" .. cmprsNote, disabled = true }
  if #lastRanked == 0 then
    items[#items + 1] = { title = "   sampling\u{2026}", disabled = true }
  end
  for _, p in ipairs(lastRanked) do
    items[#items + 1] = {
      title = string.format("   %-22s %5.1f GB  (pid %d)", p.name:sub(1, 22), p.weightMB / 1024, p.pid),
      disabled = true,
    }
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Open Activity Monitor",
    fn = function() hs.application.launchOrFocus("Activity Monitor") end }
  items[#items + 1] = { title = "Log snapshot now",
    fn = function() M.logSnapshot("manual") end }
  return items
end

local function notifyCrit(m)
  local now = os.time()
  if now - lastNotifyAt < core.cfg.notifyCooldownSec then return end
  lastNotifyAt = now
  local sub
  if lastOffender then
    sub = string.format("%s (pid %d) \u{00B7} %.1f GB",
      lastOffender.name, lastOffender.pid, (lastOffender.weightMB or 0) / 1024)
  else
    sub = string.format("swap-out %.0f pg/s | avail %.0f%% | swap %.1f GB",
      lastRates.swapOut, m.availPct, m.swapGB)
  end
  local names = {}
  for i, p in ipairs(lastRanked) do
    if i > 3 then break end
    names[#names + 1] = string.format("%s (%.1f GB)", p.name, p.weightMB / 1024)
  end
  hs.notify.new({
    title           = "Memory pressure: CRITICAL",
    subTitle        = sub,
    informativeText = "Top: " .. table.concat(names, ", "),
    withdrawAfter   = 0,      -- stays in Notification Center until dismissed
    hasActionButton = false,
    -- intentionally no soundName: alerts are silent by design
  }):send()
end

-- Append one line to memwatch.log. Cheap forensic trail for the next incident.
function M.logSnapshot(reason)
  local m = lastMetrics
  local line = string.format(
    "%s state=%s reason=%s kern=%d swapout=%.0f comprate=%.0f comp=%.1fGB swap=%.1fGB avail=%.0f%%\n",
    os.date("%Y-%m-%d %H:%M:%S"), smState.state, reason or "", lastKern,
    lastRates.swapOut, lastRates.comp, m.compGB, m.swapGB, m.availPct)
  appendLog(line)
end

------------------------------------------------------------------------------
-- main loop
------------------------------------------------------------------------------

-- One consolidated fork per tick carries everything the native API cannot
-- provide: the kernel pressure verdict, swap usage, and the process list.
-- ~32 ms measured; always async so the main thread never blocks, with an
-- in-flight guard so a wedged fork skips ticks instead of stacking tasks.
local SAMPLER_CMD = "/usr/sbin/sysctl -n kern.memorystatus_vm_pressure_level vm.swapusage; "
                 .. "/bin/ps -Axo pid,uid,rss,comm -m | /usr/bin/head -40"
local SAMPLE_WATCHDOG_SEC = 20

local sampleTask, sampleStartedAt = nil, 0
local lastPsBlob = ""   -- consumed by the process tracker

local function launchSampler(onDone)
  local now = hs.timer.secondsSinceEpoch()
  if sampleTask then
    if (now - sampleStartedAt) < SAMPLE_WATCHDOG_SEC then return end
    pcall(function() sampleTask:terminate() end)
    sampleTask = nil
  end
  sampleStartedAt = now
  sampleTask = hs.task.new("/bin/sh", guard("sampler", function(exitCode, stdOut)
    sampleTask = nil
    onDone((exitCode == 0 and stdOut) and stdOut or "")
  end), { "-c", SAMPLER_CMD })
  if sampleTask then sampleTask:start() end
end

-- Second half of the tick, run when the sampler fork returns. All state
-- decisions live here because they need the kernel verdict and the ps list.
local function onSample(blob)
  local now = hs.timer.secondsSinceEpoch()
  local samp = core.parseSampler(blob)
  lastKern = samp.kernLevel
  if blob ~= "" then lastSwapBytes = samp.swapBytes end
  lastPsBlob = blob
  lastMetrics.swapGB = lastSwapBytes / 1e9

  -- Per-process pipeline: track growth, spot runaways, rank the hogs.
  lastPsList = procs.parsePsList(blob)
  procs.update(tracker, lastPsList, now)
  local totalMB = (lastMetrics.totalGB or 0) * 1024
  local runs = procs.runaways(tracker, now, smState.state, totalMB > 0 and totalMB or nil)
  local kept = {}
  for _, r in ipairs(runs) do
    if (ignoredUntil[r.pid .. "|" .. r.name] or 0) < now then kept[#kept + 1] = r end
  end
  lastRuns = kept
  lastRanked = procs.rankByWeight(lastPsList, topCache.map, 5)

  local extreme = false
  for _, r in ipairs(kept) do
    if r.kind == "extreme" then extreme = true end
    local lk = r.pid .. "|" .. r.kind
    if (now - (runawayLogAt[lk] or 0)) > 300 then
      runawayLogAt[lk] = now
      M.logSnapshot(string.format("runaway-%s:%s(%d)@%.0fMB/min",
        r.kind, r.name, r.pid, r.slopeMBmin))
    end
  end

  local sig = core.signals(lastMetrics, lastRates, lastKern, extreme)
  local state, changed, reason = core.smStep(smState, sig, now)

  local offender, watch = procs.pickOffender(kept, lastRanked, state)
  if offender and not offender.weightMB then
    local t = topCache.map and topCache.map[offender.pid]
    offender.weightMB = (offender.rssMB or 0) + (t and t.cmprsMB or 0)
  end
  lastOffender = offender
  titleSnap.offenderName = offender and offender.name or nil
  titleSnap.offenderGB   = offender and (offender.weightMB / 1024) or nil
  titleSnap.watchName    = watch and watch.name or nil
  titleSnap.causeTag = sig.swapStorm and "SWAP" or string.format("MEM %.0f%%", lastMetrics.availPct)

  if state ~= "ok" or #kept > 0 then topRefresh() end
  if changed then M.logSnapshot("state:" .. reason) end
  if state == "critical" then notifyCrit(lastMetrics) end
  -- Drive the flash from flashState, not just transitions, so the animation
  -- always matches the real state and self-heals (e.g. after a self-test).
  if state ~= flashState then applyFlash(state) end
  if not flashTimer then renderTitleNow() end
end

local function tick()
  local now = hs.timer.secondsSinceEpoch()
  local m = readMetrics()   -- native, fork-free
  lastMetrics = m
  -- Activity rates from the cumulative counter deltas.
  if m.counters then
    if prevCounters then
      local dt = now - prevCountersAt
      lastRates.swapOut = core.rate(m.counters.swapOuts,   prevCounters.swapOuts,   dt)
      lastRates.comp    = core.rate(m.counters.compressed, prevCounters.compressed, dt)
      lastRates.pageOut = core.rate(m.counters.pageOuts,   prevCounters.pageOuts,   dt)
    end
    prevCounters, prevCountersAt = m.counters, now
  end
  -- Repaint the title every tick from what is already known, even when the
  -- fork is skipped: the gauge must keep breathing while the system is dying.
  if not flashTimer then renderTitleNow() end
  launchSampler(onSample)
end

------------------------------------------------------------------------------
-- public control surface
------------------------------------------------------------------------------

function M.start()
  M.stop()
  menu = hs.menubar.new()
  if not menu then return M end
  -- Recomputed fresh on every click; a menu-build error must never leave a
  -- dead menu, so it degrades to a pointer at the log instead.
  menu:setMenu(function()
    local ok, items = pcall(buildMenu)
    if ok then return items end
    logError("menu", items)
    return { { title = "memwatch: menu error (see memwatch.log)", disabled = true } }
  end)
  smState = core.newSMState(hs.timer.secondsSinceEpoch())
  flashState = nil                -- force first tick to set the flash state
  renderTitleNow()
  pollTimer = hs.timer.doEvery(core.cfg.pollSec, guard("tick", tick))
  tick()                          -- immediate first sample
  return M
end

function M.stop()
  if pollTimer then pollTimer:stop(); pollTimer = nil end
  if flashTimer then flashTimer:stop(); flashTimer = nil end
  if sampleTask then pcall(function() sampleTask:terminate() end); sampleTask = nil end
  flashState = nil
  if menu then menu:delete(); menu = nil end
end

-- One-line current state, for `hs -c "memwatch.status()"`.
function M.status()
  local m = lastMetrics
  local off = lastOffender
    and string.format(" offender=%s(%d)", lastOffender.name, lastOffender.pid) or ""
  return string.format(
    "state=%s kern=%d swapout=%.0fpg/s comprate=%.0fpg/s avail=%.0f%% swap=%.1fGB compressor=%.1fGB%s",
    smState.state, lastKern, lastRates.swapOut, lastRates.comp,
    m.availPct, m.swapGB, m.compGB, off)
end

-- Force a visual state for ~12s to verify the icon + notification paths.
-- Usage: hs -c "memwatch.test('elevated')"  /  hs -c "memwatch.test('critical')"
function M.test(level, seconds)
  local alias = { warn = "elevated", crit = "critical",
                  elevated = "elevated", critical = "critical" }
  local state = alias[tostring(level)] or "critical"
  local dur = tonumber(seconds) or 12
  -- Freeze live sampling so the faked state is not overwritten mid-demo.
  if pollTimer then pollTimer:stop(); pollTimer = nil end
  smState.state = state
  smState.since = hs.timer.secondsSinceEpoch()
  lastMetrics = { compGB = 16, swapGB = 7, availPct = (state == "critical") and 6 or 12 }
  titleSnap = (state == "critical")
    and { offenderName = "FakeProc", offenderGB = 22, causeTag = "SWAP" }
    or  { watchName = "FakeProc" }
  applyFlash(state)
  if state == "critical" then
    lastNotifyAt = 0
    notifyCrit(lastMetrics)
  end
  hs.timer.doAfter(dur, guard("test-resume", function()
    smState = core.newSMState(hs.timer.secondsSinceEpoch())
    titleSnap = {}
    pollTimer = hs.timer.doEvery(core.cfg.pollSec, guard("tick", tick))
    tick()                                                -- revert to the real state
  end))
  return string.format("memwatch.test(%s) running for %ds (live sampling paused)", state, dur)
end

_G.memwatch = M  -- expose for the hs CLI
M.start()
return M

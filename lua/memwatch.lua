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

local core = require("memwatch_core")

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

local KERN_NAME = { [1] = "NORMAL", [2] = "WARN", [4] = "CRITICAL" }

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
-- path survives only as a fallback.
local lastSwapBytes = 0

local function readMetrics()
  local ok, v = pcall(hs.host.vmStat)
  if ok and type(v) == "table" and v.pageSize then
    lastSwapBytes = core.parseSwapUsed(sh("/usr/sbin/sysctl -n vm.swapusage"))
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

-- Top N processes by resident memory: { {name=, mb=}, ... }
local function topConsumers(n)
  n = n or 5
  local out = sh("/bin/ps -Aceo rss,comm -m 2>/dev/null | /usr/bin/head -n " .. (n + 1))
  local list = {}
  for line in out:gmatch("[^\n]+") do
    local rss, comm = line:match("^%s*(%d+)%s+(.+)$") -- header row has no leading digits, so it is skipped
    if rss and comm then
      list[#list + 1] = { name = comm, mb = tonumber(rss) / 1024 }
    end
  end
  return list
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
    { title = "Top memory consumers", disabled = true },
  }
  for _, p in ipairs(topConsumers(5)) do
    items[#items + 1] = { title = string.format("   %-24s %6.0f MB", p.name, p.mb), disabled = true }
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
  local names = {}
  for _, p in ipairs(topConsumers(3)) do
    names[#names + 1] = string.format("%s (%.0f MB)", p.name, p.mb)
  end
  hs.notify.new({
    title           = "Memory pressure: CRITICAL",
    subTitle        = string.format("swap-out %.0f pg/s | avail %.0f%% | swap %.1f GB",
                                    lastRates.swapOut, m.availPct, m.swapGB),
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
  local f = io.open(LOG_PATH, "a")
  if f then f:write(line); f:close() end
end

------------------------------------------------------------------------------
-- main loop
------------------------------------------------------------------------------

local function tick(silent)
  local now = hs.timer.secondsSinceEpoch()
  local m = readMetrics()
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
  -- Kernel verdict (sync for now; the consolidated async sampler replaces this).
  lastKern = tonumber(sh("/usr/sbin/sysctl -n kern.memorystatus_vm_pressure_level")) or 1
  local sig = core.signals(m, lastRates, lastKern, false)
  local state, changed, reason = core.smStep(smState, sig, now)
  titleSnap.causeTag = sig.swapStorm and "SWAP" or string.format("MEM %.0f%%", m.availPct)
  if changed and not silent then M.logSnapshot("state:" .. reason) end
  if state == "critical" then notifyCrit(m) end
  -- Drive the flash from flashState, not just transitions, so the animation
  -- always matches the real state and self-heals (e.g. after a self-test).
  if state ~= flashState then applyFlash(state) end
  -- Repaint the title every tick. The flash timer used to do this as a side
  -- effect; with the steady dot there is no other repaint path, and the title
  -- would otherwise freeze at whatever value it had when the state last changed.
  if not flashTimer then renderTitleNow() end
end

------------------------------------------------------------------------------
-- public control surface
------------------------------------------------------------------------------

function M.start()
  M.stop()
  menu = hs.menubar.new()
  if not menu then return M end
  menu:setMenu(buildMenu)         -- recomputed fresh on every click
  smState = core.newSMState(hs.timer.secondsSinceEpoch())
  flashState = nil                -- force first tick to set the flash state
  renderTitleNow()
  pollTimer = hs.timer.doEvery(core.cfg.pollSec, tick)
  tick()                          -- immediate first sample
  return M
end

function M.stop()
  if pollTimer then pollTimer:stop(); pollTimer = nil end
  if flashTimer then flashTimer:stop(); flashTimer = nil end
  flashState = nil
  if menu then menu:delete(); menu = nil end
end

-- One-line current state, for `hs -c "memwatch.status()"`.
function M.status()
  local m = lastMetrics
  return string.format(
    "state=%s kern=%d swapout=%.0fpg/s comprate=%.0fpg/s avail=%.0f%% swap=%.1fGB compressor=%.1fGB",
    smState.state, lastKern, lastRates.swapOut, lastRates.comp,
    m.availPct, m.swapGB, m.compGB)
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
  hs.timer.doAfter(dur, function()
    smState = core.newSMState(hs.timer.secondsSinceEpoch())
    titleSnap = {}
    pollTimer = hs.timer.doEvery(core.cfg.pollSec, tick)  -- resume live sampling
    tick(true)                                            -- silent revert to the real state
  end)
  return string.format("memwatch.test(%s) running for %ds (live sampling paused)", state, dur)
end

_G.memwatch = M  -- expose for the hs CLI
M.start()
return M

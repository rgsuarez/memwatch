-- memwatch.lua
-- Menu-bar memory-pressure gauge for Hammerspoon.
-- Project: ~/projects/memwatch  (wired into ~/.hammerspoon/init.lua)
--
-- An always-present, glanceable dot in the menu bar:
--   green (dim)    = healthy
--   amber (steady) = warning, pressure building
--   red   (steady) = critical; also fires a silent notification naming the
--                    top memory consumers
-- The dot is steady by default; set core.cfg.flash = true to pulse warn/crit.
-- Click the dot for live compressor / swap / available numbers and the top 5
-- memory consumers. Threshold crossings are appended to memwatch.log.
--
-- Calibrated to the 2026-05-29 freeze. See memwatch_core.lua for thresholds.

local core = require("memwatch_core")

local M = {}

-- runtime state
local menu        = nil
local pollTimer   = nil
local flashTimer  = nil
local flashLevel  = nil   -- the level the flash animation is currently rendering
local flashLit    = true
local lastLevel   = "ok"
local lastNotifyAt = 0
local lastMetrics = { compGB = 0, swapGB = 0, availPct = 100 }

local LOG_PATH = os.getenv("HOME") .. "/projects/memwatch/memwatch.log"

-- RGB (0-1) per level. Apple system green / orange / red.
local COLOR = {
  ok   = { red = 0.20, green = 0.78, blue = 0.35 },
  warn = { red = 1.00, green = 0.62, blue = 0.04 },
  crit = { red = 1.00, green = 0.23, blue = 0.19 },
}

local DOT = "\u{25CF}" -- ● geometric circle (not an emoji)

------------------------------------------------------------------------------
-- shell helpers
------------------------------------------------------------------------------

local function sh(cmd)
  local out = hs.execute(cmd)
  return out or ""
end

-- Sample the three pressure signals and return derived metrics.
local function readMetrics()
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

local function setIcon(level, m, lit)
  if not menu then return end
  local c = COLOR[level] or COLOR.ok
  local alpha
  if level == "ok" then
    alpha = 0.40                 -- steady, understated
  else
    alpha = lit and 1.0 or 0.12  -- blink between bright and near-invisible
  end
  local label = DOT
  if level ~= "ok" then
    label = string.format("%s %.0fG", DOT, m.compGB) -- show compressor GB when elevated
  end
  local styled = hs.styledtext.new(label, {
    color = { red = c.red, green = c.green, blue = c.blue, alpha = alpha },
    font  = { name = "Menlo", size = 13 },
  })
  menu:setTitle(styled)
end

local function applyFlash(level)
  if flashTimer then flashTimer:stop(); flashTimer = nil end
  flashLit = true
  flashLevel = level
  -- Steady render unless the pulse is explicitly enabled. "ok" is always steady.
  if level == "ok" or not core.cfg.flash then
    setIcon(level, lastMetrics, true)
    return
  end
  local interval = (level == "crit") and 0.45 or 1.0
  setIcon(level, lastMetrics, true)
  flashTimer = hs.timer.doEvery(interval, function()
    flashLit = not flashLit
    setIcon(level, lastMetrics, flashLit)
  end)
end

------------------------------------------------------------------------------
-- menu, notification, logging
------------------------------------------------------------------------------

local function buildMenu()
  local m = readMetrics()
  local level = core.classify(m)
  local items = {
    { title = string.format("Compressor:  %.1f GB", m.compGB), disabled = true },
    { title = string.format("Swap used:   %.1f GB", m.swapGB), disabled = true },
    { title = string.format("Available:   %.0f%%", m.availPct), disabled = true },
    { title = string.format("Status:      %s", level:upper()), disabled = true },
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
    subTitle        = string.format("Compressor %.0f GB | swap %.1f GB | avail %.0f%%",
                                    m.compGB, m.swapGB, m.availPct),
    informativeText = "Top: " .. table.concat(names, ", "),
    withdrawAfter   = 0,      -- stays in Notification Center until dismissed
    hasActionButton = false,
    -- intentionally no soundName: alerts are silent by design
  }):send()
end

-- Append one line to memwatch.log. Cheap forensic trail for the next incident.
function M.logSnapshot(reason)
  local m = readMetrics()
  local line = string.format(
    "%s level=%s reason=%s comp=%.1fGB swap=%.1fGB avail=%.0f%%\n",
    os.date("%Y-%m-%d %H:%M:%S"), core.classify(m), reason or "", m.compGB, m.swapGB, m.availPct)
  local f = io.open(LOG_PATH, "a")
  if f then f:write(line); f:close() end
end

------------------------------------------------------------------------------
-- main loop
------------------------------------------------------------------------------

local function tick(silent)
  local m = readMetrics()
  lastMetrics = m
  local level = core.classify(m)
  if level ~= lastLevel then
    if not silent then M.logSnapshot("level-change:" .. lastLevel .. "->" .. level) end
    lastLevel = level
  end
  -- Drive the flash from flashLevel, not just transitions, so the animation
  -- always matches the real level and self-heals (e.g. after a self-test).
  if level ~= flashLevel then applyFlash(level) end
  if level == "crit" then notifyCrit(m) end
end

------------------------------------------------------------------------------
-- public control surface
------------------------------------------------------------------------------

function M.start()
  M.stop()
  menu = hs.menubar.new()
  if not menu then return M end
  menu:setMenu(buildMenu)         -- recomputed fresh on every click
  lastLevel = "ok"
  flashLevel = nil                -- force first tick to set the flash state
  setIcon("ok", lastMetrics, true)
  pollTimer = hs.timer.doEvery(core.cfg.pollSec, tick)
  tick()                          -- immediate first sample
  return M
end

function M.stop()
  if pollTimer then pollTimer:stop(); pollTimer = nil end
  if flashTimer then flashTimer:stop(); flashTimer = nil end
  flashLevel = nil
  if menu then menu:delete(); menu = nil end
end

-- One-line current state, for `hs -c "memwatch.status()"`.
function M.status()
  local m = readMetrics()
  return string.format("level=%s comp=%.1fGB swap=%.1fGB avail=%.0f%%",
    core.classify(m), m.compGB, m.swapGB, m.availPct)
end

-- Force a visual state for ~12s to verify the icon + notification paths.
-- Usage: hs -c "memwatch.test('warn')"  /  hs -c "memwatch.test('crit')"
function M.test(level, seconds)
  level = (level == "crit" or level == "warn") and level or "crit"
  local dur = tonumber(seconds) or 12
  -- Freeze live sampling so the faked metrics are not overwritten mid-demo
  -- (the bug behind "red flashing 0G": the poll loop reset compGB to the live 0).
  if pollTimer then pollTimer:stop(); pollTimer = nil end
  lastLevel = level
  lastMetrics = { compGB = (level == "crit") and 16 or 9, swapGB = (level == "crit") and 7 or 2, availPct = (level == "crit") and 6 or 14 }
  applyFlash(level)
  if level == "crit" then
    lastNotifyAt = 0
    notifyCrit(lastMetrics)
  end
  hs.timer.doAfter(dur, function()
    pollTimer = hs.timer.doEvery(core.cfg.pollSec, tick)  -- resume live sampling
    tick(true)                                            -- silent revert to the real level
  end)
  return string.format("memwatch.test(%s) running for %ds (live sampling paused)", level, dur)
end

_G.memwatch = M  -- expose for the hs CLI
M.start()
return M

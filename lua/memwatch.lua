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
local lfm   = require("memwatch_lfm")

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
local lastExtreme  = false -- extreme runaway currently on the books
local lastSampleAt = 0    -- when a sampler callback last landed
local lastStaleLogAt = 0
-- All of the above are declared here, at the top, on purpose: a local
-- declared below a function that references it silently splits into a
-- global writer and a local reader. Three live incidents came from that.
local ignoredUntil = {}   -- ["pid|name"] = epoch when the ignore expires
local runawayLogAt = {}   -- ["pid|kind"] = last time this runaway was logged

-- Phase 0 freeze + LFM adjudication state (cross-section, so declared here).
local protectedPids = {}  -- pid-set memwatch never flags or signals (self + adjudicator)
local frozen        = {}  -- [pid] = persisted frozen-ledger entry
local unattendedFiredFor = {} -- one unattended action per offender pid
local lfmServerTask  = nil    -- hs.task handle for llama-server
local lfmServerPid   = nil
local lfmServerPort  = nil
local lfmServerReady = false
local lfmOffline     = false  -- timeout/self-police latch; clears at an elevated tick
local lfmCalmSince   = nil    -- retire-on-calm bookkeeping
local lfmLastAdvisoryAt = 0
local lfmReqNonce    = 0      -- monotonic request generation
local lfmInFlight    = nil    -- { nonce, pid, hash, at, ident }
local verdictCache   = {}     -- [pid] = { verdict, snapshotHash, reqNonce, at, ident }
-- Forward declarations, assigned in the kill-engine section: alertSurfaces
-- (defined earlier in the file) calls these at tick time, and a top-level
-- local referenced above its declaration silently splits into a global.
local resolveUnattendedAction
local writeDecisionOutcome

local KERN_NAME = { [1] = "NORMAL", [2] = "WARN", [4] = "CRITICAL" }

------------------------------------------------------------------------------
-- logging and error containment
------------------------------------------------------------------------------

-- Declared here, above appendLog: a reference to a local declared later in
-- the file silently compiles as a nil global inside the earlier function.
local LOG_PATH = os.getenv("HOME") .. "/projects/memwatch/memwatch.log"
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
  -- pcall: the error reporter must never become a second error source.
  pcall(appendLog, string.format("%s state=%s reason=error:%s err=%s\n",
    os.date("%Y-%m-%d %H:%M:%S"), smState.state, label, tostring(err)))
end

-- Wrap a callback so an error can never kill the loop that owns it.
local function guard(label, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then logError(label, err) end
  end
end

------------------------------------------------------------------------------
-- local config (memwatch-local.json, gitignored)
--
-- Read at require time, BEFORE M.start() fires at the bottom of this file,
-- so operator overrides (unattended mode, LFM enablement) shape the very
-- first tick. The runtime toggle and install.sh --with-lfm write the same
-- file. Absent file == all defaults == model-free memwatch.
------------------------------------------------------------------------------

local LOCAL_CONFIG_PATH = os.getenv("HOME") .. "/projects/memwatch/memwatch-local.json"

local function applyLocalConfig()
  local f = io.open(LOCAL_CONFIG_PATH, "r")
  if not f then return end
  local raw = f:read("a")
  f:close()
  local conf, err = lfm.jsonDecode(raw)
  if type(conf) ~= "table" then
    logError("local-config", err or "not an object")
    return
  end
  if type(conf.unattended) == "string" then core.cfg.unattended = conf.unattended end
  if type(conf.autoKill) == "boolean" then core.cfg.autoKill = conf.autoKill end
  if type(conf.lfm) == "table" then
    for k, v in pairs(conf.lfm) do
      if lfm.cfg[k] ~= nil and type(v) == type(lfm.cfg[k]) then lfm.cfg[k] = v end
    end
  end
end

local function saveLocalConfig()
  local conf = {
    unattended = core.cfg.unattended,
    lfm = {
      enabled = lfm.cfg.enabled,
      model = lfm.cfg.model,
      resident = lfm.cfg.resident,
      promptVariant = lfm.cfg.promptVariant,
    },
  }
  local enc = lfm.jsonEncode(conf)
  if not enc then return end
  local f = io.open(LOCAL_CONFIG_PATH, "w")
  if not f then return end
  f:write(enc, "\n")
  f:close()
end

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

-- Assess the tracked processes: runaway classification, ignore filtering,
-- extreme flag, offender/watch selection, runaway logging. Called from both
-- attribution feeds (the ps sampler and the streaming top), so whichever one
-- is still alive under load keeps the picture current.
local function assessProcesses(now)
  local totalMB = (lastMetrics.totalGB or 0) * 1024
  local runs = procs.runaways(tracker, now, smState.state, totalMB > 0 and totalMB or nil)
  local kept = {}
  for _, r in ipairs(runs) do
    if (ignoredUntil[r.pid .. "|" .. r.name] or 0) < now
       and not protectedPids[r.pid] then
      kept[#kept + 1] = r
    end
  end
  lastRuns = kept
  lastExtreme = false
  for _, r in ipairs(kept) do
    if r.kind == "extreme" then lastExtreme = true end
    local lk = r.pid .. "|" .. r.kind
    if (now - (runawayLogAt[lk] or 0)) > 300 then
      runawayLogAt[lk] = now
      M.logSnapshot(string.format("runaway-%s:%s(%d)@%.0fMB/min",
        r.kind, r.name, r.pid, r.slopeMBmin))
    end
  end
  local offender, watch = procs.pickOffender(kept, lastRanked, smState.state)
  if offender and not offender.weightMB then offender.weightMB = offender.rssMB or 0 end
  lastOffender = offender
  -- A hog is named in the HUD and menu with its "largest, not growing"
  -- framing; the menu-bar title shows the systemic cause tag instead, so a
  -- steady bystander never headlines as the culprit.
  local named = offender and offender.kind ~= "hog"
  titleSnap.offenderName = named and offender.name or nil
  titleSnap.offenderGB   = named and (offender.weightMB / 1024) or nil
  -- The elevated title hint names whichever grower we know about, watch or
  -- offender: an amber dot with a name beats a bare amber dot.
  titleSnap.watchName    = (watch and watch.name) or (named and offender.name) or nil
end

-- Streaming top: ONE long-lived `top -l 0` process, started at the onset of
-- pressure while the system can still spawn it, feeding per-pid footprint
-- (MEM, CMPRS) every 5s right through the storm. Live drills proved that
-- fork-per-tick attribution starves for minutes exactly when it matters;
-- an already-resident top keeps sampling. Sorted by CMPRS so the pids whose
-- weight lives in the compressor are always in the block.
local TOPSTREAM_ARGS = { "-l", "0", "-s", "5", "-n", "30", "-o", "cmprs",
                         "-stats", "pid,command,mem,cmprs" }
local topTask = nil
local topStream = nil
local topIdleSince = nil

local function stopTopStream()
  if topTask then pcall(function() topTask:terminate() end); topTask = nil end
  topStream = nil
end

local function startTopStream()
  if topTask then return end
  topStream = procs.newTopStream()
  topTask = hs.task.new("/usr/bin/top",
    guard("topstream-exit", function(exitCode, _, stdErr)
      topTask = nil
      -- A dying stream is a fact worth recording: it is the attribution
      -- lifeline under load, and the next interesting tick respawns it.
      M.logSnapshot(string.format("topstream-exit:%s:%s",
        tostring(exitCode), tostring(stdErr):sub(1, 80):gsub("%s+", " ")))
    end),
    function(_, stdOut)
      local ok, err = pcall(function()
        local published = procs.feedTopStream(topStream, stdOut or "")
        if published then
          local now = hs.timer.secondsSinceEpoch()
          topCache.map = published
          topCache.at = now
          procs.updateFromTop(tracker, published, now)
          assessProcesses(now)
        end
      end)
      if not ok then logError("topstream", err) end
      return true  -- keep streaming
    end,
    TOPSTREAM_ARGS)
  if topTask then
    topTask:start()
    M.logSnapshot("topstream-start")
  else
    logError("topstream-spawn", "hs.task.new returned nil")
  end
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
-- alert HUD (hs.canvas): the reliable one-click surface. Never steals
-- keyboard focus (clickActivating false), floats on every Space, and there is
-- only ever one instance, reused.
------------------------------------------------------------------------------

local hud            = nil
local hudShownAt     = 0
local hudInteracted  = false
local hudHold        = false  -- a kill narrative owns the body text
local hudBelowCritSince = nil
local lastHudRaiseAt = 0
local hudOffender    = nil    -- { pid, name, weightMB, slopeMBmin, kind } at raise

local HUD_W, HUD_H = 380, 176

local function hudFrame()
  local scr = hs.screen.mainScreen()
  local f = scr and scr:fullFrame() or { x = 0, y = 0, w = 1440, h = 900 }
  return { x = f.x + f.w - HUD_W - 20, y = f.y + 37, w = HUD_W, h = HUD_H }
end

function M.hideHud()
  if hud then hud:hide() end
  hudOffender = nil
  hudHold = false
end

local function hudBodyText()
  if hudOffender then
    if hudOffender.kind == "hog" then
      -- Largest process, not a proven cause: never dress a steady VM or
      -- model server up as a caught runaway.
      return string.format("%s (pid %d)\n%.1f GB held \u{00B7} largest process, not growing",
        hudOffender.name, hudOffender.pid, (hudOffender.weightMB or 0) / 1024)
    end
    local slope = (hudOffender.slopeMBmin and hudOffender.slopeMBmin > 0)
      and string.format(", +%.0f MB/min", hudOffender.slopeMBmin) or ""
    return string.format("%s (pid %d)\n%.1f GB%s",
      hudOffender.name, hudOffender.pid, (hudOffender.weightMB or 0) / 1024, slope)
  end
  return "No single offender identified.\n" .. (titleSnap.causeTag or "")
end

local function buildHud()
  if hud then return hud end
  hud = hs.canvas.new(hudFrame())
  hud:level(hs.canvas.windowLevels.overlay)
  hud:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
  if hud.clickActivating then hud:clickActivating(false) end
  hud:canvasMouseEvents(false, true, false, false)  -- mouseUp only
  hud[1] = { id = "bg", type = "rectangle", action = "fill",
             roundedRectRadii = { xRadius = 12, yRadius = 12 },
             fillColor = { red = 0.11, green = 0.11, blue = 0.12, alpha = 0.94 } }
  hud[2] = { id = "title", type = "text", frame = { x = 16, y = 10, w = HUD_W - 60, h = 24 },
             text = "Memory CRITICAL",
             textColor = { red = 1, green = 0.32, blue = 0.28, alpha = 1 },
             textSize = 15, textFont = "Menlo-Bold" }
  hud[3] = { id = "body", type = "text", frame = { x = 16, y = 38, w = HUD_W - 32, h = 52 },
             text = "", textColor = { white = 0.92, alpha = 1 },
             textSize = 12, textFont = "Menlo" }
  local function button(idx, id, x, y, w, label, fill)
    hud[idx] = { id = id, type = "rectangle", action = "fill",
                 frame = { x = x, y = y, w = w, h = 30 },
                 roundedRectRadii = { xRadius = 7, yRadius = 7 },
                 fillColor = fill, trackMouseUp = true }
    hud[idx + 1] = { id = id .. "-label", type = "text",
                     frame = { x = x, y = y + 4, w = w, h = 22 },
                     text = label, textAlignment = "center",
                     textColor = { white = 1, alpha = 0.95 },
                     textSize = 12, textFont = "Menlo-Bold", trackMouseUp = true }
  end
  -- Two rows: Freeze is the primary action (reversible; the right unattended
  -- default), Force Quit the red one. Utility actions ride the second row.
  local row1, row2 = HUD_H - 82, HUD_H - 44
  button(4,  "freeze",  16,  row1, 172, "Freeze",       { red = 0.16, green = 0.42, blue = 0.75, alpha = 1 })
  button(6,  "kill",    200, row1, 164, "Force Quit",   { red = 0.75, green = 0.16, blue = 0.13, alpha = 1 })
  button(8,  "ignore",  16,  row2, 172, "Ignore 30m",   { white = 0.28, alpha = 1 })
  button(10, "monitor", 200, row2, 164, "Activity Mon", { white = 0.28, alpha = 1 })
  hud[12] = { id = "close", type = "text", frame = { x = HUD_W - 30, y = 8, w = 22, h = 22 },
              text = "\u{2715}", textAlignment = "center",
              textColor = { white = 0.6, alpha = 1 }, textSize = 13, trackMouseUp = true }
  hud:mouseCallback(guard("hud-click", function(_, evt, id)
    if evt ~= "mouseUp" then return end
    hudInteracted = true
    if id == "freeze" or id == "freeze-label" then
      if hudOffender then
        local target = hudOffender
        hudHold = true
        M.freezePid(target.pid, target.name, function(text, done)
          if hud then hud[3].text = text end
          if done then
            hs.timer.doAfter(4, guard("hud-close", function() M.hideHud() end))
          end
        end, { weightMB = target.weightMB })
      end
    elseif id == "kill" or id == "kill-label" then
      if hudOffender then
        local target = hudOffender
        hudHold = true
        M.killPid(target.pid, target.name, function(text, done)
          if hud then hud[3].text = text end
          if done then
            hs.timer.doAfter(4, guard("hud-close", function() M.hideHud() end))
          end
        end)
      end
    elseif id == "ignore" or id == "ignore-label" then
      if hudOffender then M.ignore(hudOffender.pid, hudOffender.name) end
      M.hideHud()
    elseif id == "monitor" or id == "monitor-label" then
      hs.application.launchOrFocus("Activity Monitor")
    elseif id == "close" then
      M.hideHud()
    end
  end))
  return hud
end

local function raiseHud(offender, titleText)
  buildHud()
  hudOffender = offender
  hudInteracted = false
  hudHold = false
  hudShownAt = hs.timer.secondsSinceEpoch()
  hud:frame(hudFrame())
  hud[2].text = titleText or "Memory CRITICAL"
  hud[3].text = hudBodyText()
  hud:show()
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
  local sinceSample = lastSampleAt > 0 and (hs.timer.secondsSinceEpoch() - lastSampleAt) or 0
  if sinceSample > 15 then
    items[#items + 1] = {
      title = string.format("\u{26A0} process data %.0fs stale (system under load)", sinceSample),
      disabled = true,
    }
  end
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
    local pid, name, wMB = p.pid, p.name, p.weightMB
    items[#items + 1] = {
      title = string.format("%-22s %5.1f GB  (pid %d)", name:sub(1, 22), p.weightMB / 1024, pid),
      menu = {
        { title = "Freeze " .. name,
          fn = function() M.freezePid(pid, name, nil, { weightMB = wMB }) end },
        { title = "Force Quit " .. name,
          fn = function() M.killPid(pid, name) end },
        { title = "Ignore for 30 min",
          fn = function() M.ignore(pid, name) end },
        { title = "Show in Activity Monitor",
          fn = function() hs.application.launchOrFocus("Activity Monitor") end },
      },
    }
  end
  -- Frozen-by-memwatch section: what is held, for how long, and the way out.
  local frozenRows = {}
  for pid, e in pairs(frozen) do frozenRows[#frozenRows + 1] = { pid = pid, e = e } end
  table.sort(frozenRows, function(a, b) return (a.e.frozenAt or 0) < (b.e.frozenAt or 0) end)
  if #frozenRows > 0 then
    items[#items + 1] = { title = "-" }
    items[#items + 1] = { title = "Frozen by memwatch", disabled = true }
    for _, row in ipairs(frozenRows) do
      local pid, e = row.pid, row.e
      local mins = (hs.timer.secondsSinceEpoch() - (e.frozenAt or 0)) / 60
      items[#items + 1] = {
        title = string.format("   %-20s %4.1f GB held \u{00B7} %.0f min", (e.name or "?"):sub(1, 20),
          (e.weightMB or 0) / 1024, mins),
        menu = {
          { title = "Resume " .. (e.name or "?"),
            fn = function() M.resumePid(pid) end },
          { title = "Force Quit " .. (e.name or "?"),
            fn = function() M.killPid(pid, e.name) end },
        },
      }
    end
    if #frozenRows > 1 then
      items[#items + 1] = { title = "Resume all", fn = function() M.resumeAll() end }
    end
  end
  items[#items + 1] = { title = "-" }
  if lastOffender then
    local off = lastOffender
    local label = (off.kind == "hog")
      and string.format("Force Quit largest process (%s, pid %d)", off.name, off.pid)
      or  string.format("Force Quit %s (pid %d)", off.name, off.pid)
    items[#items + 1] = { title = label,
      fn = function() M.killPid(off.pid, off.name) end }
    items[#items + 1] = { title = string.format("Ignore %s for 30 min", off.name),
      fn = function() M.ignore(off.pid, off.name) end }
    items[#items + 1] = { title = "-" }
  end
  items[#items + 1] = { title = "Open Activity Monitor",
    fn = function() hs.application.launchOrFocus("Activity Monitor") end }
  items[#items + 1] = { title = "Log snapshot now",
    fn = function() M.logSnapshot("manual") end }
  items[#items + 1] = { title = string.format("LFM adjudication: %s",
      lfm.cfg.enabled and (lfmServerReady and "on (warm)" or "on") or "off"),
    fn = function() M.setLfmEnabled(not lfm.cfg.enabled) end }
  return items
end

local function notifyCrit(m)
  local now = os.time()
  if now - lastNotifyAt < core.cfg.notifyCooldownSec then return end
  lastNotifyAt = now
  local sub
  if lastOffender and lastOffender.kind == "hog" then
    sub = string.format("largest: %s (pid %d) \u{00B7} %.1f GB, not growing",
      lastOffender.name, lastOffender.pid, (lastOffender.weightMB or 0) / 1024)
  elseif lastOffender then
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
  -- Action button is best-effort: macOS only renders it reliably when
  -- Hammerspoon notifications are set to the Alerts style. The HUD is the
  -- dependable one-click surface; this is the breadcrumb.
  local off = lastOffender
  hs.notify.new(guard("notify-action", function(notif)
    if off and notif:activationType() == hs.notify.activationTypes.actionButtonClicked then
      M.killPid(off.pid, off.name)
    end
  end), {
    title             = "Memory pressure: CRITICAL",
    subTitle          = sub,
    informativeText   = "Top: " .. table.concat(names, ", "),
    withdrawAfter     = 0,      -- stays in Notification Center until dismissed
    hasActionButton   = off ~= nil,
    actionButtonTitle = off and "Force Quit" or nil,
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
-- The ps table is deliberately uncapped: a runaway whose pages are being
-- compressed away in real time can hold a tiny RSS, and any top-N-by-RSS cut
-- would drop exactly the process this tool exists to catch. ~600 rows parse
-- in well under a millisecond. No -m: we sort ourselves, and ps's
-- memory-sort is precisely the work that crawls when the system is dying.
local SAMPLER_CMD = "/usr/sbin/sysctl -n kern.memorystatus_vm_pressure_level vm.swapusage; "
                 .. "/bin/ps -Axo pid,uid,rss,comm"
local SAMPLE_WATCHDOG_SEC = 20
local SAMPLE_STALE_SEC    = 30

local sampleTask, sampleStartedAt = nil, 0
local lastPsBlob = ""     -- consumed by the process tracker

local function launchSampler(onDone)
  local now = hs.timer.secondsSinceEpoch()
  if sampleTask then
    if (now - sampleStartedAt) < SAMPLE_WATCHDOG_SEC then return end
    pcall(function() sampleTask:terminate() end)
    sampleTask = nil
  end
  sampleStartedAt = now
  -- The full ps table runs ~55-70KB, which straddles the 64KB pipe buffer:
  -- without a streaming drain hs.task never reads the pipe, ps blocks
  -- mid-write, and the task deadlocks until the watchdog TERMs it (observed
  -- live as intermittent sampler death that tracked the process count).
  -- The streaming callback exists purely to drain; assembly happens at exit.
  local acc = {}
  sampleTask = hs.task.new("/bin/sh",
    guard("sampler", function(exitCode)
      sampleTask = nil
      -- Keep partial output even on a nonzero exit: under memory pressure ps
      -- can fail mid-table, and a partial process list beats a blank one.
      -- The parsers treat garbage as calm, never as alarm.
      if exitCode ~= 0 then
        logError("sampler-exit", "code " .. tostring(exitCode))
      end
      onDone(table.concat(acc))
    end),
    function(_, stdOut)
      acc[#acc + 1] = stdOut or ""
      return true
    end,
    { "-c", SAMPLER_CMD })
  if sampleTask then sampleTask:start() end
end

-- Enrichment half: runs when the sampler fork returns. Refreshes the kernel
-- verdict, swap usage, and the per-process pipeline. Deliberately makes NO
-- state decision: under heavy pressure this fork can starve for tens of
-- seconds (a live drill measured ~95s of stalled callbacks during a swap
-- storm), and the verdict must never be hostage to it.
local function onSample(blob)
  local now = hs.timer.secondsSinceEpoch()
  lastSampleAt = now
  local samp = core.parseSampler(blob)
  lastKern = samp.kernLevel
  if blob ~= "" then lastSwapBytes = samp.swapBytes end
  lastPsBlob = blob
  lastMetrics.swapGB = lastSwapBytes / 1e9

  -- Per-process pipeline: fresh identities and RSS from ps, then the shared
  -- assessment. Attribution continuity under load is the top stream's job.
  lastPsList = procs.parsePsList(blob)
  procs.update(tracker, lastPsList, now, topCache.map)
  lastRanked = procs.rankByWeight(lastPsList, topCache.map, 5)
  -- The watchdog and its own adjudicator never appear as offenders.
  for i = #lastRanked, 1, -1 do
    if protectedPids[lastRanked[i].pid] then table.remove(lastRanked, i) end
  end
  assessProcesses(now)
end

-- Alert surfaces: the HUD is the actionable one, the notification the
-- breadcrumb. One reusable HUD, raise-cooldown gated, a new offender
-- preempts the cooldown, and the body tracks live numbers unless a kill
-- narrative owns it.
local function alertSurfaces(state, now)
  if state == "critical" then
    hudBelowCritSince = nil
    local offender = lastOffender
    local visible = hud and hud:isShowing()
    if not visible then
      local newOffender = offender and (not hudOffender or hudOffender.pid ~= offender.pid)
      if (now - lastHudRaiseAt) >= core.cfg.cool.hudRaiseSec or newOffender then
        lastHudRaiseAt = now
        raiseHud(offender)
      end
    elseif not hudHold then
      hudOffender = offender or hudOffender
      hud[3].text = hudBodyText()
    end
    notifyCrit(lastMetrics)
    -- Unattended action: opt-in, extreme growers only, HUD unanswered for
    -- the grace window, once per offender. The LFM (when enabled and warm)
    -- refines the action within the mode ceiling via the async verdict
    -- cache; with no fresh verdict the deterministic policy acts exactly as
    -- the legacy autoKill did. Both paths execute through the same signal
    -- engines (identity probe + policy gate inside).
    local mode = core.resolveUnattended(core.cfg)
    if mode ~= "off" and offender and offender.kind == "extreme"
       and hud and hud:isShowing() and not hudInteracted and not hudHold
       and (now - hudShownAt) >= core.cfg.cool.autoKillGraceSec
       and not unattendedFiredFor[offender.pid] then
      unattendedFiredFor[offender.pid] = true
      local action, adjudicator, rationale, rails, extra = resolveUnattendedAction(mode, offender)
      M.logSnapshot(string.format("unattended-%s:%s(%d):%s",
        action, offender.name, offender.pid, adjudicator))
      writeDecisionOutcome(offender, action, adjudicator, rationale, rails, extra)
      hs.notify.new({ title = "memwatch unattended " .. action,
                      subTitle = string.format("%s (pid %d)", offender.name, offender.pid),
                      informativeText = (adjudicator == "lfm")
                        and ("Model-adjudicated (unverified): " .. (rationale or "")):sub(1, 120)
                        or "Extreme runaway, no response to the alert.",
                      withdrawAfter = 0 }):send()
      if action ~= "wait" then
        hudHold = true
        local narrate = function(text, done)
          if hud then hud[3].text = "AUTO: " .. text end
          if done then hs.timer.doAfter(6, guard("hud-close", function() M.hideHud() end)) end
        end
        if action == "terminate" then
          M.killPid(offender.pid, offender.name, narrate)
        else
          M.freezePid(offender.pid, offender.name, narrate, { weightMB = offender.weightMB })
        end
      end
    end
  else
    if hud and hud:isShowing() then
      hudBelowCritSince = hudBelowCritSince or now
      if (now - hudBelowCritSince) >= 10 and not hudHold then M.hideHud() end
    else
      hudBelowCritSince = nil
    end
  end
end

-- Decision half: fork-free, runs every tick no matter what. Everything it
-- needs is native (rates and headroom from hs.host.vmStat counters) or
-- last-known (kernel level, extreme flag), so the state machine, title, and
-- alert surfaces keep working even while the sampler fork is starving.
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

  local sig = core.signals(m, lastRates, lastKern, lastExtreme)
  local state, changed, reason = core.smStep(smState, sig, now)
  titleSnap.causeTag = sig.swapStorm and "SWAP" or string.format("MEM %.0f%%", m.availPct)
  if changed then M.logSnapshot("state:" .. reason) end
  alertSurfaces(state, now)

  -- Honesty when degraded: if the fork has not reported for a while, say so.
  if lastSampleAt > 0 and (now - lastSampleAt) > SAMPLE_STALE_SEC
     and (now - lastStaleLogAt) > 60 then
    lastStaleLogAt = now
    M.logSnapshot(string.format("sampler-stale:%.0fs", now - lastSampleAt))
  end

  -- Attribution stream lifecycle: spawn at the onset of anything interesting
  -- (while spawning still works), retire after a calm minute.
  local interesting = state ~= "ok" or #lastRuns > 0
    or lastRates.comp >= core.cfg.rates.compLo
    or lastRates.swapOut >= core.cfg.rates.swapLo
  if interesting then
    topIdleSince = nil
    startTopStream()
  elseif topTask then
    topIdleSince = topIdleSince or now
    if (now - topIdleSince) > 60 then stopTopStream() end
  end

  -- Drive the flash from flashState, not just transitions, so the animation
  -- always matches the real state and self-heals (e.g. after a self-test).
  if state ~= flashState then applyFlash(state) end
  -- Repaint the title every tick from what is already known, even when the
  -- fork is skipped: the gauge must keep breathing while the system is dying.
  if not flashTimer then renderTitleNow() end
  launchSampler(onSample)
end

------------------------------------------------------------------------------
-- kill engine
------------------------------------------------------------------------------

local ownUid  = tonumber(sh("/usr/bin/id -u")) or -1
local selfPid = hs.processInfo.processID
protectedPids[selfPid] = true

-- Look up a live process; returns { pid, uid, comm, lstart } or nil if gone.
-- lstart (process start time) is the identity component a recycled pid
-- cannot fake; the frozen ledger persists it across reloads.
local function probePid(pid)
  local out = sh(string.format("/bin/ps -p %d -o uid=,lstart=,comm= 2>/dev/null", pid))
  local uid, lstart, comm = out:match("^%s*(%d+)%s+(%a+%s+%a+%s+%d+%s+%d+:%d+:%d+%s+%d+)%s+(.-)%s*$")
  if not uid then return nil end
  return { pid = pid, uid = tonumber(uid), comm = comm, lstart = lstart }
end

local function pidAlive(pid)
  return sh(string.format("/bin/ps -p %d -o pid= 2>/dev/null", pid)):match("%d") ~= nil
end

local function pidState(pid)
  return (sh(string.format("/bin/ps -p %d -o state= 2>/dev/null", pid)):match("%a") or "")
end

-- The single identity gate every signal path goes through (kill, freeze,
-- resume, and the frozen-ledger reconcile), so probe discipline never
-- drifts between them. Names sourced from the top stream are truncated at
-- ~16 chars, so a long expected name may be a prefix of the live one; short
-- names must match exactly. Returns proc (with .liveName) or nil, reason.
local function resolveSignalTarget(pid, expectedName, expectedLstart)
  local proc = probePid(pid)
  if not proc then return nil, "exited" end
  local liveName = procs.friendlyName(proc.comm)
  local nameMatches = (liveName == expectedName)
    or (expectedName ~= nil and #expectedName >= 15
        and liveName:sub(1, #expectedName) == expectedName)
  if expectedName and not nameMatches then
    return nil, string.format("pid-reused:%s", liveName)
  end
  if expectedLstart and proc.lstart and proc.lstart ~= expectedLstart then
    return nil, "pid-reused:start-time"
  end
  proc.liveName = liveName
  return proc
end

-- Default progress surface for menu-initiated kills (the menu closes on
-- click, so feedback lands as a brief on-screen alert).
local function alertUpdate(text)
  hs.alert.show("memwatch: " .. text, 2.5)
end

------------------------------------------------------------------------------
-- frozen ledger (Phase 0 freeze)
--
-- SIGSTOPped processes must survive hs.reload without being orphaned, so
-- every freeze persists to memwatch-frozen.json and start-up reconciles the
-- file against live identity (pid + name + start time). Stop persists;
-- resume is always a deliberate action, never automatic.
------------------------------------------------------------------------------

local FROZEN_PATH = os.getenv("HOME") .. "/projects/memwatch/memwatch-frozen.json"

local function saveFrozen()
  local list = lfm.jsonArray({})
  for _, e in pairs(frozen) do list[#list + 1] = e end
  table.sort(list, function(a, b) return (a.frozenAt or 0) < (b.frozenAt or 0) end)
  local enc = lfm.jsonEncode(list)
  if not enc then return end
  local f = io.open(FROZEN_PATH, "w")
  if not f then return end
  f:write(enc, "\n")
  f:close()
end

local function loadFrozen()
  local f = io.open(FROZEN_PATH, "r")
  if not f then return {} end
  local raw = f:read("a")
  f:close()
  local list = lfm.jsonDecode(raw)
  return type(list) == "table" and list or {}
end

-- Re-probe every persisted entry: identity-confirmed and still stopped stays
-- managed; anything exited, recycled, or externally resumed is dropped with
-- a log line, never managed. A one-time notification surfaces survivors.
local function frozenReconcile()
  local list = loadFrozen()
  frozen = {}
  local survivors = {}
  for _, e in ipairs(list) do
    if type(e) == "table" and type(e.pid) == "number" then
      local proc, why = resolveSignalTarget(e.pid, e.name, e.lstart)
      if not proc then
        M.logSnapshot(string.format("frozen-reconcile-drop:%s(%d):%s", e.name or "?", e.pid, why))
      elseif pidState(e.pid) ~= "T" then
        M.logSnapshot(string.format("frozen-reconcile-drop:%s(%d):resumed-externally", e.name or "?", e.pid))
      else
        frozen[e.pid] = e
        survivors[#survivors + 1] = e.name
      end
    end
  end
  saveFrozen()
  if #survivors > 0 then
    hs.notify.new({
      title = "memwatch: frozen processes persist",
      subTitle = table.concat(survivors, ", "):sub(1, 100),
      informativeText = string.format(
        "%d process(es) remain frozen from the previous session. Resume from the memwatch menu.",
        #survivors),
      withdrawAfter = 0,
    }):send()
  end
end

-- Freeze: same identity probe and policy gate as kill, then SIGSTOP with a
-- verified stop state and a persisted ledger entry. Memory is NOT released
-- by a freeze; the win is stopping the growth reversibly.
function M.freezePid(pid, expectedName, onUpdate, opts)
  onUpdate = onUpdate or alertUpdate
  opts = opts or {}
  local proc, twhy = resolveSignalTarget(pid, expectedName)
  if not proc then
    if twhy == "exited" then
      M.logSnapshot(string.format("freeze-skip:%s(%d)-already-exited", expectedName or "?", pid))
      onUpdate(string.format("%s already exited", expectedName or tostring(pid)), true)
    else
      M.logSnapshot(string.format("freeze-refuse:%s:%d(want %s)", twhy, pid, expectedName or "?"))
      onUpdate(string.format("pid %d identity changed (%s), refusing", pid, twhy), true)
    end
    return
  end
  local allowed, why = core.killAllowed(proc, ownUid, selfPid, nil, protectedPids)
  if not allowed then
    M.logSnapshot(string.format("freeze-refuse:%s(%d):%s", proc.liveName, pid, why))
    onUpdate(string.format("refusing to freeze %s: %s", proc.liveName, why), true)
    return
  end
  if frozen[pid] then
    onUpdate(string.format("%s is already frozen", proc.liveName), true)
    return
  end
  sh(string.format("/bin/kill -STOP %d 2>/dev/null", pid))
  hs.timer.doAfter(0.5, guard("freeze-verify", function()
    if pidState(pid) == "T" then
      frozen[pid] = {
        pid = pid, name = proc.liveName, lstart = proc.lstart,
        weightMB = opts.weightMB or 0,
        frozenAt = hs.timer.secondsSinceEpoch(),
      }
      saveFrozen()
      M.logSnapshot(string.format("freeze-done:%s(%d)", proc.liveName, pid))
      onUpdate(string.format(
        "%s frozen \u{00B7} memory is NOT released until it is resumed or quit", proc.liveName), true)
    else
      M.logSnapshot(string.format("freeze-failed:%s(%d)-state=%s", proc.liveName, pid, pidState(pid)))
      onUpdate(string.format("%s did not stop (state %s)", proc.liveName, pidState(pid)), true)
    end
  end))
end

-- Resume: identity re-validated against the ledger entry (a recycled pid is
-- dropped AND the signal blocked), then SIGCONT with a verified state.
function M.resumePid(pid, onUpdate)
  onUpdate = onUpdate or alertUpdate
  local e = frozen[pid]
  if not e then
    onUpdate(string.format("pid %d is not in the frozen ledger", pid), true)
    return
  end
  local proc, twhy = resolveSignalTarget(pid, e.name, e.lstart)
  if not proc then
    frozen[pid] = nil
    saveFrozen()
    M.logSnapshot(string.format("resume-drop:%s(%d):%s", e.name or "?", pid, twhy))
    onUpdate(string.format("%s is gone (%s); ledger entry dropped", e.name or tostring(pid), twhy), true)
    return
  end
  sh(string.format("/bin/kill -CONT %d 2>/dev/null", pid))
  hs.timer.doAfter(0.5, guard("resume-verify", function()
    if pidState(pid) ~= "T" then
      frozen[pid] = nil
      saveFrozen()
      M.logSnapshot(string.format("resume-done:%s(%d)", e.name, pid))
      onUpdate(string.format("%s resumed after %.0f min frozen", e.name,
        (hs.timer.secondsSinceEpoch() - (e.frozenAt or 0)) / 60), true)
    else
      M.logSnapshot(string.format("resume-failed:%s(%d)-still-stopped", e.name, pid))
      onUpdate(string.format("%s is still stopped; try again or use Activity Monitor", e.name), true)
    end
  end))
end

function M.resumeAll()
  for pid in pairs(frozen) do M.resumePid(pid) end
end

------------------------------------------------------------------------------
-- decision ledger + unattended adjudication
------------------------------------------------------------------------------

local LFM_LEDGER_PATH = os.getenv("HOME") .. "/projects/memwatch/memwatch-lfm.jsonl"
local LFM_LEDGER_MAX_BYTES = 2e6

local function appendLedger(line)
  local f = io.open(LFM_LEDGER_PATH, "a")
  if not f then return end
  if f:seek("end") > LFM_LEDGER_MAX_BYTES then
    f:close()
    os.rename(LFM_LEDGER_PATH, LFM_LEDGER_PATH .. ".1")
    f = io.open(LFM_LEDGER_PATH, "a")
    if not f then return end
  end
  f:write(line)
  f:close()
end

-- One decision record per unattended adjudication (either adjudicator).
-- The ledger is local and gitignored; the value report renders it.
writeDecisionOutcome = function(offender, action, adjudicator, rationale, rails, extra)
  local rec = {
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    adjudicator = adjudicator,
    action = action,
    offender = { name = offender.name, kind = offender.kind or "?",
                 weightMB = math.floor(offender.weightMB or 0),
                 slopeMBmin = math.floor(offender.slopeMBmin or 0) },
    state = smState.state,
    availPct = math.floor(lastMetrics.availPct or 0),
    rationale = rationale,
    rails = rails and lfm.jsonArray(rails) or nil,
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do rec[k] = v end
  end
  local line = lfm.ledgerLine(rec)
  if line then appendLedger(line) end
  -- 60s outcome follow-up: what actually happened to the process and the
  -- availability trajectory after the action.
  local pid = offender.pid
  local availBefore = math.floor(lastMetrics.availPct or 0)
  hs.timer.doAfter(60, guard("ledger-outcome", function()
    local fate
    if not pidAlive(pid) then fate = "exited"
    elseif pidState(pid) == "T" then fate = "frozen"
    else fate = "running" end
    local out = lfm.ledgerLine({
      at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      outcome_for = rec.at, action = action, adjudicator = adjudicator,
      fate = fate, availPctBefore = availBefore,
      availPctAfter = math.floor(lastMetrics.availPct or 0),
      state = smState.state,
    })
    if out then appendLedger(out) end
  end))
end

-- Consume the freshest cached verdict for the bound offender: pid keyed,
-- identity re-validated live, age-bounded. The snapshot hash in the entry is
-- ledger correlation, never a consumption predicate.
local function consumeVerdict(offender)
  local e = verdictCache[offender.pid]
  if not e or not e.verdict then return nil end
  if (hs.timer.secondsSinceEpoch() - (e.at or 0)) > lfm.cfg.verdictFreshSec then return nil end
  local proc = resolveSignalTarget(offender.pid,
    e.ident and e.ident.name or offender.name,
    e.ident and e.ident.lstart or nil)
  if not proc then return nil end
  return e
end

-- Choose the unattended action. A fresh model verdict is refined through
-- the deterministic rails within the mode ceiling; no verdict means the
-- deterministic policy acts exactly as the legacy autoKill did (the mode is
-- the action, extreme-only, policy-gated inside the signal path).
resolveUnattendedAction = function(mode, offender)
  local e = consumeVerdict(offender)
  if e then
    local proc = probePid(offender.pid)
    local allowed = false
    if proc then
      allowed = core.killAllowed(proc, ownUid, selfPid, nil, protectedPids)
    end
    local eff, rails = lfm.applyVerdict(e.verdict, mode, allowed, {
      offenderKind = offender.kind,
      offenderForeground = offender.foreground,
    })
    return eff, "lfm", e.verdict.rationale, rails,
      { model = lfm.cfg.model, snapshotHash = e.snapshotHash, confidence = e.verdict.confidence }
  end
  local action = (mode == "kill") and "terminate" or "freeze"
  return action, "deterministic-fallback", nil, { "deterministic" }, nil
end

-- One-click kill: re-validate identity first (pid-reuse guard), check the
-- pure policy, SIGTERM, escalate to SIGKILL after cfg.kill.escalateSec if the
-- target is still alive (re-validated again), then verify death and report
-- how much memory actually came back. onUpdate(text, done) drives whichever
-- surface initiated the kill.
function M.killPid(pid, expectedName, onUpdate)
  onUpdate = onUpdate or alertUpdate
  local k = core.cfg.kill
  local frozenEntry = frozen[pid]
  local proc, twhy = resolveSignalTarget(pid, expectedName,
    frozenEntry and frozenEntry.lstart or nil)
  if not proc then
    if twhy == "exited" then
      M.logSnapshot(string.format("kill-skip:%s(%d)-already-exited", expectedName or "?", pid))
      onUpdate(string.format("%s already exited", expectedName or tostring(pid)), true)
    else
      -- Identity mismatch: drop any stale ledger entry AND block the action.
      if frozenEntry then frozen[pid] = nil; saveFrozen() end
      M.logSnapshot(string.format("kill-refuse:%s:%d(want %s)", twhy, pid, expectedName or "?"))
      onUpdate(string.format("pid %d identity changed (%s), refusing", pid, twhy), true)
    end
    return
  end
  local liveName = proc.liveName
  local allowed, why = core.killAllowed(proc, ownUid, selfPid, nil, protectedPids)
  if not allowed then
    M.logSnapshot(string.format("kill-refuse:%s(%d):%s", liveName, pid, why))
    onUpdate(string.format("refusing to kill %s: %s", liveName, why), true)
    return
  end
  local availBefore = lastMetrics.availPct or 0
  local totalGB = lastMetrics.totalGB or 0
  M.logSnapshot(string.format("kill-term:%s(%d)", liveName, pid))
  onUpdate(string.format("terminating %s\u{2026}", liveName), false)
  sh(string.format("/bin/kill -TERM %d 2>/dev/null", pid))
  hs.timer.doAfter(k.escalateSec, guard("kill-escalate", function()
    if pidAlive(pid) then
      local again = probePid(pid)
      if again and procs.friendlyName(again.comm) == liveName then
        M.logSnapshot(string.format("kill-kill9:%s(%d)", liveName, pid))
        onUpdate(string.format("%s ignored TERM, sending KILL", liveName), false)
        sh(string.format("/bin/kill -KILL %d 2>/dev/null", pid))
      end
    end
    hs.timer.doAfter(k.verifySec + k.settleSec, guard("kill-verify", function()
      local gone = not pidAlive(pid)
      local m = readMetrics()
      local reclaimedGB = math.max(0, (m.availPct - availBefore) / 100 * totalGB)
      if gone then
        if frozen[pid] then frozen[pid] = nil; saveFrozen() end
        M.logSnapshot(string.format("kill-done:%s(%d)-reclaimed=%.1fGB", liveName, pid, reclaimedGB))
        onUpdate(string.format("%s terminated \u{00B7} reclaimed ~%.1f GB", liveName, reclaimedGB), true)
      else
        M.logSnapshot(string.format("kill-failed:%s(%d)-still-present", liveName, pid))
        onUpdate(string.format("%s is still present (zombie or unkillable); use Activity Monitor", liveName), true)
      end
    end))
  end))
end

-- Silence alerts for one process for the standard window.
function M.ignore(pid, name)
  ignoredUntil[pid .. "|" .. name] = hs.timer.secondsSinceEpoch() + core.cfg.cool.ignoreSec
  M.logSnapshot(string.format("ignore:%s(%d)", name, pid))
  if lastOffender and lastOffender.pid == pid then
    lastOffender = nil
    titleSnap.offenderName, titleSnap.offenderGB = nil, nil
  end
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
  frozenReconcile()               -- SIGSTOPped processes survive reloads
  renderTitleNow()
  pollTimer = hs.timer.doEvery(core.cfg.pollSec, guard("tick", tick))
  tick()                          -- immediate first sample
  return M
end

function M.stop()
  if pollTimer then pollTimer:stop(); pollTimer = nil end
  if flashTimer then flashTimer:stop(); flashTimer = nil end
  if sampleTask then pcall(function() sampleTask:terminate() end); sampleTask = nil end
  stopTopStream()
  flashState = nil
  if menu then menu:delete(); menu = nil end
end

-- Field diagnostics, for `hs -c "print(hs.inspect(memwatch.debug()))"`.
function M.debug()
  local now = hs.timer.secondsSinceEpoch()
  local tracked = 0
  for _ in pairs(tracker.procs) do tracked = tracked + 1 end
  return {
    state          = smState.state,
    kern           = lastKern,
    rates          = { swapOut = lastRates.swapOut, comp = lastRates.comp },
    streamAlive    = topTask ~= nil,
    topCacheAgeSec = topCache.at > 0 and math.floor(now - topCache.at) or -1,
    sampleAgeSec   = lastSampleAt > 0 and math.floor(now - lastSampleAt) or -1,
    tracked        = tracked,
    runs           = #lastRuns,
    ranked         = #lastRanked,
    offender       = lastOffender and string.format("%s(%d)%s", lastOffender.name,
                       lastOffender.pid, lastOffender.kind and "/" .. lastOffender.kind or "") or nil,
    watch          = titleSnap.watchName,
    unattended     = core.resolveUnattended(core.cfg),
    frozenCount    = (function() local n = 0; for _ in pairs(frozen) do n = n + 1 end; return n end)(),
    protectedPids  = (function()
                       local t = {}
                       for pid in pairs(protectedPids) do t[#t + 1] = pid end
                       table.sort(t)
                       return t
                     end)(),
    lfm            = { enabled = lfm.cfg.enabled, ready = lfmServerReady,
                       offline = lfmOffline, pid = lfmServerPid, port = lfmServerPort,
                       cached = (function() local n = 0; for _ in pairs(verdictCache) do n = n + 1 end; return n end)() },
  }
end

-- One-line current state, for `hs -c "memwatch.status()"`.
function M.status()
  local m = lastMetrics
  local off = lastOffender
    and string.format(" offender=%s(%d)", lastOffender.name, lastOffender.pid) or ""
  local watch = titleSnap.watchName
    and string.format(" watch=%s", titleSnap.watchName) or ""
  return string.format(
    "state=%s kern=%d swapout=%.0fpg/s comprate=%.0fpg/s avail=%.0f%% swap=%.1fGB compressor=%.1fGB%s%s",
    smState.state, lastKern, lastRates.swapOut, lastRates.comp,
    m.availPct, m.swapGB, m.compGB, off, watch)
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
    lastOffender = { pid = 99999, name = "FakeProc", weightMB = 22 * 1024,
                     slopeMBmin = 12000, kind = "extreme" }
    notifyCrit(lastMetrics)
    -- Clicking Force Quit here is safe: pid 99999 probes as already exited.
    raiseHud(lastOffender, "Memory CRITICAL (self-test)")
  end
  hs.timer.doAfter(dur, guard("test-resume", function()
    M.hideHud()
    lastOffender = nil
    smState = core.newSMState(hs.timer.secondsSinceEpoch())
    titleSnap = {}
    pollTimer = hs.timer.doEvery(core.cfg.pollSec, guard("tick", tick))
    tick()                                                -- revert to the real state
  end))
  return string.format("memwatch.test(%s) running for %ds (live sampling paused)", state, dur)
end

-- Full alert-surface demo with a synthetic runaway: red title, HUD, and
-- notification, no real process involved (the kill probe reports it already
-- exited). Usage: hs -c "memwatch.simulate()"
function M.simulate(seconds)
  local dur = tonumber(seconds) or 20
  if pollTimer then pollTimer:stop(); pollTimer = nil end
  smState.state = "critical"
  smState.since = hs.timer.secondsSinceEpoch()
  local fake = { pid = 99999, name = "SimRunaway", weightMB = 22 * 1024,
                 slopeMBmin = 12000, kind = "extreme" }
  lastOffender = fake
  titleSnap = { offenderName = fake.name, offenderGB = fake.weightMB / 1024, causeTag = "SWAP" }
  applyFlash("critical")
  if not flashTimer then renderTitleNow() end
  raiseHud(fake, "Runaway process (simulation)")
  hs.timer.doAfter(dur, guard("simulate-end", function()
    M.hideHud()
    lastOffender = nil
    smState = core.newSMState(hs.timer.secondsSinceEpoch())
    titleSnap = {}
    pollTimer = hs.timer.doEvery(core.cfg.pollSec, guard("tick", tick))
    tick()
  end))
  return string.format("memwatch.simulate running for %ds (live sampling paused)", dur)
end

-- Toggle the LFM adjudicator from the menu or the CLI; persists to the
-- local config so the choice survives reloads.
function M.setLfmEnabled(on)
  lfm.cfg.enabled = on == true
  saveLocalConfig()
  M.logSnapshot("lfm-" .. (lfm.cfg.enabled and "enabled" or "disabled"))
  return lfm.cfg.enabled
end

applyLocalConfig()  -- operator overrides land before the first tick
_G.memwatch = M  -- expose for the hs CLI
M.start()
return M

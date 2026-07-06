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
local unattendedFiredFor = {} -- [pid] = epoch of the last unattended adjudication
local unattendedWaitStreak = {} -- [pid] = consecutive model-wait outcomes at grace expiry
local lfmServerTask  = nil    -- hs.task handle for llama-server
local lfmServerPid   = nil
local lfmServerPort  = nil
local lfmServerReady = false
local lfmSpawnedAt   = nil    -- epoch of the current spawn (fast-crash detection)
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
local lfmTick
local gcUnattendedState
local offenderIsForeground
local probePid

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
  local invalidMode = false
  if type(conf.unattended) == "string" then
    if core.UNATTENDED_MODES[conf.unattended] then
      core.cfg.unattended = conf.unattended
    else
      invalidMode = true
      logError("local-config", "unknown unattended mode '" .. conf.unattended
        .. "'; failing closed to off and ignoring autoKill from this config")
      core.cfg.unattended = "off"
    end
  end
  -- Fail closed: an invalid explicit mode disarms the legacy autoKill shim
  -- too, so a typo'd config can never leave autonomous kill armed via the
  -- back door ({"unattended":"disabled","autoKill":true} -> off, not kill).
  if type(conf.autoKill) == "boolean" and not invalidMode then
    core.cfg.autoKill = conf.autoKill
  elseif invalidMode then
    core.cfg.autoKill = false
  end
  -- How long the HUD may go unanswered before the unattended action fires.
  -- Exposed because an operator running unattended=freeze may want a faster
  -- (or slower) hand-off than the 60s default.
  if type(conf.unattendedGraceSec) == "number" and conf.unattendedGraceSec >= 5 then
    core.cfg.cool.autoKillGraceSec = conf.unattendedGraceSec
  end
  if type(conf.lfm) == "table" then
    for k, v in pairs(conf.lfm) do
      if lfm.cfg[k] ~= nil and type(v) == type(lfm.cfg[k]) then lfm.cfg[k] = v end
    end
  end
end

local function saveLocalConfig()
  -- MERGE into the existing file, never clobber it: the menu LFM toggle
  -- writes only enabled + a few keys, but an operator may have set
  -- autoKill, unattendedGraceSec, timeoutSec, maxServerMB, spawnMinAvailPct,
  -- ctx, threads, etc. by hand. Read what is there, overlay the fields this
  -- toggle owns, and preserve every other key.
  local conf = {}
  local rf = io.open(LOCAL_CONFIG_PATH, "r")
  if rf then
    local existing = lfm.jsonDecode(rf:read("a"))
    rf:close()
    if type(existing) == "table" then conf = existing end
  end
  conf.unattended = core.cfg.unattended
  if type(conf.lfm) ~= "table" then conf.lfm = {} end
  conf.lfm.enabled = lfm.cfg.enabled
  conf.lfm.model = lfm.cfg.model
  conf.lfm.resident = lfm.cfg.resident
  conf.lfm.promptVariant = lfm.cfg.promptVariant
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
        end, { weightMB = target.weightMB, expectedLstart = target.lstart })
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
        end, { expectedLstart = target.lstart })
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
  -- Capture the offender's start time at raise, so a Freeze/Force Quit click
  -- seconds later binds identity and cannot signal a pid reused meanwhile.
  if offender and offender.pid and not offender.lstart then
    local probed = probePid(offender.pid)
    if probed then offender.lstart = probed.lstart end
  end
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
  items[#items + 1] = { title = "Open value report",
    fn = function() M.report() end }
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
    -- Re-arm semantics (live-drill finding): a WAIT outcome must not consume
    -- the per-offender latch forever, or one low-confidence model wait
    -- disables unattended coverage while the crisis continues. Each
    -- adjudication stamps the time; another full grace window must pass
    -- before the same offender is adjudicated again.
    local mode = core.resolveUnattended(core.cfg)
    if mode ~= "off" and offender and offender.kind == "extreme"
       and hud and hud:isShowing() and not hudInteracted and not hudHold
       and (now - hudShownAt) >= core.cfg.cool.autoKillGraceSec
       and (now - (unattendedFiredFor[offender.pid] or 0)) >= core.cfg.cool.autoKillGraceSec then
      unattendedFiredFor[offender.pid] = now
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
        -- Bind the offender's start time NOW so the autonomous signal (and
        -- its TERM->KILL escalation seconds later) can never act on a pid
        -- reused since this decision. Autonomous action is where a wrong
        -- target destroys work, so identity is bound most strictly here.
        local bound = probePid(offender.pid)
        local lstart = bound and bound.lstart or nil
        if action == "terminate" then
          M.killPid(offender.pid, offender.name, narrate, { expectedLstart = lstart })
        else
          M.freezePid(offender.pid, offender.name, narrate,
            { weightMB = offender.weightMB, expectedLstart = lstart })
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
  -- GC the recycled-pid unattended state BEFORE alertSurfaces consumes it:
  -- if a pid left the runaway set (old process gone) its streak/fired stamp
  -- must be cleared before this tick's unattended decision can read it, or a
  -- recycled pid could inherit stale state for one tick.
  gcUnattendedState()
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

  -- LFM adjudicator lifecycle: spawn/retire/self-police/advisory. Async
  -- everywhere; a disabled feature makes this a single boolean check.
  -- (Unattended-state GC runs earlier in the tick, before alertSurfaces.)
  lfmTick(state, now, interesting)

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
-- cannot fake; the frozen ledger persists it across reloads. Forward-declared
-- at the top: the HUD raise and the unattended path (both earlier in the
-- file) capture identity through it.
probePid = function(pid)
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
  -- Bind start time when the caller captured one at selection, so a pid
  -- reused between selection and this call is refused (same-name reuse).
  local proc, twhy = resolveSignalTarget(pid, expectedName, opts.expectedLstart)
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
  -- Record the ledger entry BEFORE the SIGSTOP, not after the verify: a
  -- reload in the verify window would otherwise leave a SIGSTOPped process
  -- with no ledger row (an orphan reconcile cannot find). Persisting first
  -- means a reload finds it and frozenReconcile re-validates (still stopped
  -- -> kept; failed to stop -> dropped). The verify below downgrades a
  -- process that never entered state T.
  frozen[pid] = {
    pid = pid, name = proc.liveName, lstart = proc.lstart,
    weightMB = opts.weightMB or 0,
    frozenAt = hs.timer.secondsSinceEpoch(),
  }
  saveFrozen()
  sh(string.format("/bin/kill -STOP %d 2>/dev/null", pid))
  hs.timer.doAfter(0.5, guard("freeze-verify", function()
    -- Re-probe IDENTITY after the signal, not just the stop state: if the
    -- pid was recycled between the pre-signal probe and the SIGSTOP, we
    -- would have stopped the WRONG (new) process. If it stopped but its
    -- identity no longer matches, CONTINUE it (undo our SIGSTOP) and drop
    -- the ledger entry - never strand a bystander stopped.
    local reprobe = resolveSignalTarget(pid, proc.liveName, proc.lstart)
    if not reprobe then
      sh(string.format("/bin/kill -CONT %d 2>/dev/null", pid))
      frozen[pid] = nil
      saveFrozen()
      M.logSnapshot(string.format("freeze-abort:%s(%d)-identity-changed", proc.liveName, pid))
      onUpdate(string.format("%s changed identity mid-freeze; released, no freeze", proc.liveName), true)
    elseif pidState(pid) == "T" then
      M.logSnapshot(string.format("freeze-done:%s(%d)", proc.liveName, pid))
      onUpdate(string.format(
        "%s frozen \u{00B7} memory is NOT released until it is resumed or quit", proc.liveName), true)
    else
      frozen[pid] = nil
      saveFrozen()
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

-- The model-free deterministic policy: the mode is the action (kill ->
-- terminate, freeze -> freeze), but a foreground offender is never
-- terminated autonomously even here (capped to freeze), mirroring the LFM
-- rail so the deterministic path is no more aggressive than the adjudicated
-- one. The extreme-only gate lives upstream in alertSurfaces.
local function deterministicAction(mode, foreground)
  if mode == "kill" and not foreground then return "terminate" end
  return "freeze"
end

-- Choose the unattended action. A fresh model verdict is refined through
-- the deterministic rails within the mode ceiling; no verdict means the
-- deterministic policy acts exactly as the legacy autoKill did (the mode is
-- the action, extreme-only, policy-gated inside the signal path).
resolveUnattendedAction = function(mode, offender)
  -- The foreground termination rail must fire in the LIVE path, not only in
  -- the advisory snapshot: lastOffender never carries a foreground flag, so
  -- compute it here against the frontmost app before applyVerdict.
  local foreground = offenderIsForeground(offender)
  local e = consumeVerdict(offender)
  if e then
    local proc = probePid(offender.pid)
    local allowed = false
    if proc then
      allowed = core.killAllowed(proc, ownUid, selfPid, nil, protectedPids)
    end
    local eff, rails = lfm.applyVerdict(e.verdict, mode, allowed, {
      offenderKind = offender.kind,
      offenderForeground = foreground,
    })
    -- Wait-deferral bound (a rail in the TIME dimension, bake-off finding):
    -- a model wait DEFERS the deterministic policy, protecting a
    -- false-positive extreme (a build burst resolves within a window or
    -- two), but an inert or over-conservative model must not capture the
    -- decision forever while a true runaway grinds the machine down. After
    -- three consecutive model-wait outcomes on the same offender at grace
    -- expiry, the deterministic policy proceeds.
    if eff == "wait" then
      local streak = (unattendedWaitStreak[offender.pid] or 0) + 1
      unattendedWaitStreak[offender.pid] = streak
      if streak >= 3 then
        -- The model's wait rationale is SUPERSEDED here, so do not attach it
        -- to the deterministic action (it would mislabel the report card).
        local action = deterministicAction(mode, foreground)
        local drails = { "deterministic", "wait-deferral-exhausted" }
        return action, "deterministic-fallback", nil, drails,
          { model = lfm.cfg.model, deferrals = streak,
            supersededModelAction = "wait" }
      end
    else
      unattendedWaitStreak[offender.pid] = 0
    end
    return eff, "lfm", e.verdict.rationale, rails,
      { model = lfm.cfg.model, snapshotHash = e.snapshotHash, confidence = e.verdict.confidence }
  end
  return deterministicAction(mode, foreground), "deterministic-fallback", nil, { "deterministic" }, nil
end

------------------------------------------------------------------------------
-- LFM server lifecycle
--
-- The adjudicator is an ENHANCEMENT the decision path consults through the
-- async verdict cache; nothing here ever blocks a tick. Spawn happens at
-- ELEVATED onset only (never during critical, never below the availability
-- floor), on an ephemeral port with a per-spawn api-key file, at reduced
-- QoS. Any timeout or self-police trip retires the server through one
-- discipline (TERM, wait for exit AND port release, else KILL) and latches
-- the adjudicator offline until the next elevated tick.
------------------------------------------------------------------------------

local LFM_KEY_PATH = os.getenv("HOME") .. "/projects/memwatch/eval/tmp/lfm-api-key"
local LFM_PIDFILE  = os.getenv("HOME") .. "/projects/memwatch/eval/tmp/lfm-server.pid"
local lfmApiKey = nil
local lfmBinPath = nil

local function resolveLlamaServer()
  if lfmBinPath then return lfmBinPath end
  local brewPrefix = sh("/opt/homebrew/bin/brew --prefix llama.cpp 2>/dev/null"):gsub("%s+$", "")
  local candidates = {
    brewPrefix ~= "" and (brewPrefix .. "/bin/llama-server") or nil,
    "/opt/homebrew/bin/llama-server",
    "/usr/local/bin/llama-server",
    sh("command -v llama-server 2>/dev/null"):gsub("%s+$", ""),
  }
  for _, p in ipairs(candidates) do
    if p ~= "" and sh(string.format("test -x %q && echo yes", p)):match("yes") then
      lfmBinPath = p
      return p
    end
  end
  return nil
end

local function portFree(port)
  return sh(string.format("/usr/sbin/lsof -nP -iTCP:%d -sTCP:LISTEN -t 2>/dev/null", port)) == ""
end

local function listenerPid(port)
  return tonumber(sh(string.format("/usr/sbin/lsof -nP -iTCP:%d -sTCP:LISTEN -t 2>/dev/null", port)):match("%d+"))
end

-- One retire discipline for every exit path (calm, timeout, self-police,
-- stop): TERM, wait up to 5s for BOTH process exit and port release, else
-- KILL. Clears all server state; the offline latch is the caller's call.
-- Before /health passes, the tracked pid is the taskpolicy task and the
-- real listener may be a child, so retire targets BOTH the tracked pid AND
-- whatever is actually bound to the port, and only declares success once the
-- port is free (not merely the tracked pid gone), so a pre-health child can
-- never be orphaned still holding the port.
local function retireLfmServer(reason)
  local pid, port = lfmServerPid, lfmServerPort
  lfmServerReady = false
  lfmServerPid, lfmServerPort = nil, nil
  lfmSpawnedAt = nil  -- a deliberate retire must not trip the fast-crash latch
  os.remove(LFM_PIDFILE)  -- a cleanly retired server is not a crash orphan
  lfmInFlight = nil
  if lfmServerTask then pcall(function() lfmServerTask:terminate() end) end
  lfmServerTask = nil
  protectedPids = { [selfPid] = true }
  if not pid then return end
  M.logSnapshot(string.format("lfm-retire:%s:pid=%d", reason or "?", pid))
  -- Signal the tracked pid AND the actual port listener (may be a child),
  -- but only signal the listener if it is CONFIRMED ours: our tracked pid,
  -- or an llama-server serving OUR model dir. In the narrow window after our
  -- server died, an unrelated process could bind the port; never kill it.
  local function listenerIsOurs(owner)
    if not owner then return false end
    if owner == pid then return true end
    local info = sh(string.format("/bin/ps -p %d -o comm=,args= 2>/dev/null", owner))
    local comm = info:match("^(%S+)")
    return comm ~= nil and comm:match("([^/]+)$") == "llama-server"
      and info:find("projects/memwatch/models/", 1, true) ~= nil
  end
  local function signalTargets(sig)
    if pid then sh(string.format("/bin/kill -%s %d 2>/dev/null", sig, pid)) end
    if port then
      local owner = listenerPid(port)
      if owner and owner ~= pid and listenerIsOurs(owner) then
        sh(string.format("/bin/kill -%s %d 2>/dev/null", sig, owner))
      end
    end
  end
  signalTargets("TERM")
  local deadline = hs.timer.secondsSinceEpoch() + 5
  hs.timer.doUntil(
    function()
      -- Success requires the tracked pid gone AND our hold on the port
      -- released: the port counts as released if it is free OR now held by
      -- a process that is NOT ours (an unrelated squatter must not keep our
      -- retire waiting, and we already refuse to signal it above).
      local portReleased = (not port) or portFree(port) or not listenerIsOurs(listenerPid(port))
      local gone = not pidAlive(pid) and portReleased
      if gone then return true end
      if hs.timer.secondsSinceEpoch() > deadline then
        signalTargets("KILL")
        return hs.timer.secondsSinceEpoch() > deadline + 3
      end
      return false
    end,
    guard("lfm-retire-wait", function() end),
    1)
end

local function spawnLfmServer()
  local bin = resolveLlamaServer()
  if not bin then
    M.logSnapshot("lfm-spawn-skip:no-llama-server-binary")
    lfmOffline = true
    return
  end
  -- The model name comes from a runtime control file (memwatch-local.json),
  -- so validate it as a PLAIN .gguf filename before it ever reaches a shell
  -- or the server argv: no path separators, no shell metacharacters, no
  -- traversal. A name that does not match is refused, not interpolated.
  local model = lfm.cfg.model
  if type(model) ~= "string" or not model:match("^[%w%.%-_]+%.gguf$") then
    M.logSnapshot("lfm-spawn-skip:invalid-model-name:" .. tostring(model))
    lfmOffline = true
    return
  end
  local modelPath = os.getenv("HOME") .. "/projects/memwatch/models/" .. model
  if not sh(string.format("test -f %q && echo yes", modelPath)):match("yes") then
    M.logSnapshot("lfm-spawn-skip:model-missing:" .. model)
    lfmOffline = true
    return
  end
  -- Ephemeral port, availability-checked; per-spawn key in a 0600 file.
  local port
  for _ = 1, 8 do
    local candidate = math.random(49152, 65151)
    if portFree(candidate) then port = candidate; break end
  end
  if not port then
    M.logSnapshot("lfm-spawn-skip:no-free-port")
    return
  end
  lfmApiKey = sh("/usr/bin/openssl rand -hex 16"):gsub("%s+$", "")
  -- Create the dir at normal perms (a restrictive umask on the mkdir would
  -- drop the dir's execute bit and make the subsequent key write fail on a
  -- fresh clone), then write the key file itself 0600 and VERIFY it landed;
  -- if it did not, do not launch a server with a key file that is not there.
  local tmpDir = os.getenv("HOME") .. "/projects/memwatch/eval/tmp"
  sh(string.format("mkdir -p %q && (umask 177 && printf '%%s' %q > %q)",
    tmpDir, lfmApiKey, LFM_KEY_PATH))
  if not sh(string.format("test -s %q && echo yes", LFM_KEY_PATH)):match("yes") then
    M.logSnapshot("lfm-spawn-skip:api-key-write-failed")
    lfmApiKey = nil
    return
  end
  lfmServerPort = port
  lfmServerReady = false
  lfmSpawnedAt = hs.timer.secondsSinceEpoch()
  local spawnAt = lfmSpawnedAt
  -- taskpolicy -c utility keeps inference threads out of the crisis's way;
  -- the drain callback exists because llama-server logs continuously and an
  -- undrained pipe deadlocks at 64KB.
  lfmServerTask = hs.task.new("/usr/sbin/taskpolicy",
    guard("lfm-server-exit", function(code)
      M.logSnapshot(string.format("lfm-server-exit:code=%s", tostring(code)))
      lfmServerTask = nil
      lfmServerReady = false
      lfmServerPid, lfmServerPort = nil, nil
      protectedPids = { [selfPid] = true }
      -- A FAST crash (died within a few seconds of spawn, before it was ever
      -- ready) latches the adjudicator offline: otherwise the next elevated
      -- tick respawns it and a crash-looping binary thrashes load/exec cycles
      -- through the pressure episode. A clean retire nils lfmSpawnedAt first,
      -- so this only fires on an unexpected early exit.
      if lfmSpawnedAt == spawnAt
         and (hs.timer.secondsSinceEpoch() - spawnAt) < 10 then
        lfmOffline = true
        M.logSnapshot("lfm-fast-crash:latched-offline")
      end
    end),
    function() return true end,
    { "-c", "utility", bin,
      "-m", modelPath, "--host", "127.0.0.1", "--port", tostring(port),
      "-c", tostring(lfm.cfg.ctx), "-np", "1", "-t", tostring(lfm.cfg.threads),
      "-ngl", "0", "--api-key-file", LFM_KEY_PATH })
  if not (lfmServerTask and lfmServerTask:start()) then
    M.logSnapshot("lfm-spawn-failed:task-start")
    lfmServerTask = nil
    return
  end
  lfmServerPid = lfmServerTask:pid()
  -- Protect the adjudicator from the FIRST tick, not only once /health
  -- passes: model load can take seconds, during which the server process
  -- exists and could otherwise appear in the ranked/offender lists and pass
  -- killAllowed. Guard the task pid now; the health check below refines the
  -- set to the verified listener owner (and its taskpolicy parent).
  protectedPids = { [selfPid] = true, [lfmServerPid] = true }
  -- Record the spawned pid + start time so a crash-orphan sweep on the next
  -- start kills exactly OUR server, never a user's manual benchmark.
  do
    local probed = probePid(lfmServerPid)
    local rec = lfm.jsonEncode({ pid = lfmServerPid, lstart = probed and probed.lstart or nil })
    if rec then
      local pf = io.open(LFM_PIDFILE, "w")
      if pf then pf:write(rec, "\n"); pf:close() end
    end
  end
  M.logSnapshot(string.format("lfm-spawn:pid=%d:port=%d:avail=%d%%",
    lfmServerPid, port, math.floor(lastMetrics.availPct or 0)))
  -- Health poll to ready, with the listener-ownership check: the pid bound
  -- to our port must be our child (or its direct descendant via taskpolicy).
  local healthDeadline = hs.timer.secondsSinceEpoch() + 60
  hs.timer.doUntil(
    function()
      if not lfmServerTask then return true end -- died; exit callback logged it
      if hs.timer.secondsSinceEpoch() > healthDeadline then
        M.logSnapshot("lfm-health-timeout")
        retireLfmServer("health-timeout")
        lfmOffline = true
        return true
      end
      local body = sh(string.format(
        "curl -s -m 2 http://127.0.0.1:%d/health 2>/dev/null", port))
      if body:find('"ok"', 1, true) then
        local owner = listenerPid(port)
        local expected = lfmServerTask and lfmServerTask:pid()
        local ownerOk = owner ~= nil and expected ~= nil
          and (owner == expected
               or sh(string.format("/bin/ps -o ppid= -p %d 2>/dev/null", owner)):match("%d+") == tostring(expected))
        if not ownerOk then
          M.logSnapshot(string.format("lfm-listener-mismatch:owner=%s", tostring(owner)))
          retireLfmServer("listener-mismatch")
          lfmOffline = true
          return true
        end
        -- Protect BOTH the listener owner and the launched task pid (the
        -- taskpolicy parent), so neither the wrapper nor the server is ever
        -- signalable during the run.
        protectedPids = { [selfPid] = true, [owner] = true }
        if expected then protectedPids[expected] = true end
        lfmServerPid = owner
        lfmServerReady = true
        M.logSnapshot(string.format("lfm-ready:%.1fs:pid=%d",
          hs.timer.secondsSinceEpoch() - lfmSpawnedAt, owner))
        return true
      end
      return false
    end,
    guard("lfm-health-poll", function() end),
    1)
end

-- Is this offender the user's frontmost app? A name match against the
-- frontmost application (no pid involved). Used both to tag the snapshot
-- and to feed the foreground termination rail in the live unattended path.
-- Forward-declared at the top: resolveUnattendedAction (defined earlier)
-- calls this, so a bare `local function` here would bind that call to a nil
-- global (the split-scope class the scanner guards, now extended to catch
-- `local function` too).
offenderIsForeground = function(offender)
  if not offender or not offender.pid then return "unknown" end
  local frontName, frontPid = nil, nil
  pcall(function()
    local app = hs.application.frontmostApplication()
    frontName = app and app:name() or nil
    frontPid = app and app:pid() or nil
  end)
  -- Fail closed: if the frontmost app cannot be determined, we cannot prove
  -- the offender is a background process, so return "unknown" (the caller
  -- treats unknown like foreground for the autonomous-terminate cap).
  if not frontName and not frontPid then return "unknown" end
  -- Direct name match (the app itself is the offender).
  if offender.name and frontName
     and (offender.name == frontName or offender.name:find(frontName, 1, true)) then
    return true
  end
  -- Process-tree match: the offender is a descendant of the frontmost app
  -- (an unsaved REPL/build/tab running UNDER the frontmost terminal, IDE, or
  -- browser). Walk ppid up to a bounded depth.
  if frontPid then
    local pid = offender.pid
    for _ = 1, 12 do
      if pid == frontPid then return true end
      local ppid = tonumber(sh(string.format("/bin/ps -o ppid= -p %d 2>/dev/null", pid)):match("%d+"))
      if not ppid or ppid <= 1 then break end
      pid = ppid
    end
  end
  return false
end

-- Assemble the model-facing snapshot from what the tick already knows. The
-- serializer strips pids structurally; foreground is a name match against
-- the frontmost app (no pid involved).
local function buildLfmSnapshot(offender)
  local frontName = nil
  pcall(function()
    local app = hs.application.frontmostApplication()
    frontName = app and app:name() or nil
  end)
  local function withForeground(p)
    if not p then return nil end
    return {
      name = p.name, kind = p.kind, weightMB = p.weightMB,
      slopeMBmin = p.slopeMBmin, ageSec = p.ageSec,
      foreground = (frontName ~= nil and p.name ~= nil
        and (p.name == frontName or p.name:find(frontName, 1, true) ~= nil)) or nil,
    }
  end
  local frozenCount = 0
  for _ in pairs(frozen) do frozenCount = frozenCount + 1 end
  local runaways = {}
  for i = 1, math.min(#lastRuns, 5) do runaways[i] = withForeground(lastRuns[i]) end
  return {
    state = smState.state, kern = lastKern,
    availPct = lastMetrics.availPct, swapGB = lastMetrics.swapGB,
    compressorGB = lastMetrics.compGB,
    swapoutRate = lastRates.swapOut, compRate = lastRates.comp,
    frozenCount = frozenCount,
    offender = withForeground(offender),
    runaways = runaways,
  }, (withForeground(offender) or {}).foreground
end

-- Dispatch one async adjudication request for the bound offender. Replies
-- land in the per-pid verdict cache; the nonce discards anything late or
-- stale; the unified timeout policy retires the server and latches offline.
local function dispatchAdjudication(offender, why)
  if not (lfmServerReady and lfmServerPort and not lfmInFlight) then return end
  local proc = probePid(offender.pid)
  if not proc then return end
  local snap, foreground = buildLfmSnapshot(offender)
  local user, serr = lfm.serializeSnapshot(snap)
  if not user then
    M.logSnapshot("lfm-serialize-error:" .. tostring(serr))
    return
  end
  local body = lfm.buildRequestBody(lfm.buildSystemPrompt({}), user, {})
  if not body then return end
  lfmReqNonce = lfmReqNonce + 1
  local nonce = lfmReqNonce
  local hash = lfm.snapshotHash(user)
  local ident = { name = procs.friendlyName(proc.comm), lstart = proc.lstart }
  local pid = offender.pid
  local sentAt = hs.timer.secondsSinceEpoch()
  lfmInFlight = { nonce = nonce, pid = pid, hash = hash, at = sentAt }
  M.logSnapshot(string.format("lfm-dispatch:%s:%s(%d):nonce=%d", why, ident.name, pid, nonce))
  hs.http.asyncPost(
    string.format("http://127.0.0.1:%d/v1/chat/completions", lfmServerPort),
    body,
    { ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. (lfmApiKey or "") },
    guard("lfm-reply", function(status, respBody)
      if not lfmInFlight or lfmInFlight.nonce ~= nonce then
        M.logSnapshot(string.format("lfm-reply-discard:stale-nonce=%d", nonce))
        return
      end
      lfmInFlight = nil
      if status ~= 200 then
        M.logSnapshot(string.format("lfm-reply-error:http=%s", tostring(status)))
        return
      end
      local raw, perr = lfm.parseResponse(respBody or "")
      local verdict = raw and lfm.validateVerdict(raw) or nil
      if not verdict then
        M.logSnapshot("lfm-reply-invalid:" .. tostring(perr or "validation"))
        return
      end
      local latencyMs = math.floor((hs.timer.secondsSinceEpoch() - sentAt) * 1000)
      verdictCache[pid] = {
        verdict = verdict, snapshotHash = hash, reqNonce = nonce,
        at = hs.timer.secondsSinceEpoch(), ident = ident,
      }
      M.logSnapshot(string.format("lfm-verdict:%s(%d):%s:conf=%.2f:%dms",
        ident.name, pid, verdict.action, verdict.confidence, latencyMs))
      writeDecisionOutcome(
        { name = ident.name, kind = offender.kind, pid = pid,
          weightMB = offender.weightMB, slopeMBmin = offender.slopeMBmin,
          foreground = foreground },
        verdict.action, "lfm-advisory", verdict.rationale, nil,
        { model = lfm.cfg.model, snapshotHash = hash,
          confidence = verdict.confidence, latencyMs = latencyMs })
    end))
  -- Unified timeout policy: any request still in flight at the watchdog
  -- retires the server (reclaiming its CPU for the crisis) and latches the
  -- adjudicator offline until the next elevated tick.
  hs.timer.doAfter(lfm.cfg.timeoutSec, guard("lfm-timeout", function()
    if lfmInFlight and lfmInFlight.nonce == nonce then
      M.logSnapshot(string.format("lfm-timeout:nonce=%d:%.0fs", nonce, lfm.cfg.timeoutSec))
      lfmInFlight = nil
      retireLfmServer("timeout")
      lfmOffline = true
    end
  end))
end

-- Per-tick lifecycle: spawn discipline, retire-on-calm, the self-police
-- circuit, advisory dispatch, and cache hygiene. Called from tick(); never
-- blocks; every fork here happens at elevated or calmer.
lfmTick = function(state, now, interesting)
  if not lfm.cfg.enabled then
    if lfmServerTask then retireLfmServer("disabled") end
    return
  end
  -- The offline latch clears only on CALM recovery (state == ok), never
  -- merely on elevated: a model that timed out or was self-policed during a
  -- storm must stay out for the REST of that pressure episode, or a still-
  -- elevated tick would clear the latch and respawn, thrashing the model's
  -- page-ins through the same crisis it degraded in. Re-arm happens at the
  -- next elevated onset AFTER things have gone quiet.
  if lfmOffline and state == "ok" then lfmOffline = false end

  local running = lfmServerTask ~= nil

  -- Self-police circuit (independent of adjudication): the server's own
  -- footprint is measured the SAME way memwatch ranks every process - RSS
  -- PLUS compressed pages - not RSS alone. The kernel compresses an
  -- allocator's pages in real time (the RSS-vs-CMPRS lesson this tool was
  -- built on), so an RSS-only cap would miss a server whose weight has been
  -- compressed away. Over budget -> retire + offline latch + loud notice.
  if running and lfmServerPid then
    for _, p in ipairs(lastPsList) do
      if p.pid == lfmServerPid then
        local cmprsMB = (topCache.map and topCache.map[lfmServerPid]) or 0
        local footprintMB = (p.rssMB or 0) + cmprsMB
        if footprintMB > lfm.cfg.maxServerMB then
        M.logSnapshot(string.format("lfm-self-police:footprint=%dMB(rss=%d+cmprs=%d)>cap=%dMB",
          math.floor(footprintMB), math.floor(p.rssMB or 0), math.floor(cmprsMB), lfm.cfg.maxServerMB))
        hs.notify.new({ title = "memwatch: adjudicator over budget",
          informativeText = string.format(
            "llama-server hit %d MB (cap %d); killed and latched offline.",
            math.floor(footprintMB), lfm.cfg.maxServerMB),
          withdrawAfter = 0 }):send()
        retireLfmServer("self-police")
        lfmOffline = true
        return
        end
      end
    end
  end

  -- Spawn discipline: elevated onset only (resident mode may also spawn at
  -- ok), above the availability floor, never critical, never while latched.
  if not running and not lfmOffline
     and state ~= "critical"
     and (lfm.cfg.resident or state == "elevated")
     and (lastMetrics.availPct or 0) >= lfm.cfg.spawnMinAvailPct then
    spawnLfmServer()
  end

  -- Retire on calm (resident servers stay).
  if running and not lfm.cfg.resident then
    if state == "ok" and #lastRuns == 0 then
      lfmCalmSince = lfmCalmSince or now
      if (now - lfmCalmSince) > lfm.cfg.retireCalmSec then
        retireLfmServer("calm")
        lfmCalmSince = nil
      end
    else
      lfmCalmSince = nil
    end
  end

  -- Advisory dispatch: a warm server adjudicates the current offender on
  -- the advisory cadence, and immediately at critical when nothing fresh is
  -- cached (the grace-expiry consumer needs a verdict to consume).
  if lfmServerReady and interesting and lastOffender then
    local cached = verdictCache[lastOffender.pid]
    local fresh = cached and (now - (cached.at or 0)) <= lfm.cfg.verdictFreshSec
    local due = (now - lfmLastAdvisoryAt) >= lfm.cfg.advisoryIntervalSec
    if (lfm.cfg.advisory and due) or (state == "critical" and not fresh and not lfmInFlight) then
      lfmLastAdvisoryAt = now
      dispatchAdjudication(lastOffender, state == "critical" and "critical" or "advisory")
    end
  end

  -- Cache hygiene: drop entries for pids that are gone or stale beyond use.
  for pid, e in pairs(verdictCache) do
    if (now - (e.at or 0)) > (lfm.cfg.verdictFreshSec * 2) then
      verdictCache[pid] = nil
    end
  end
end

-- Drop per-offender unattended state (fired stamp, wait streak) for any pid
-- that is not a currently-tracked runaway, so a recycled pid cannot inherit
-- a prior process's streak or fired stamp and trigger a premature action.
-- The signal path also re-validates identity, but this keeps the DECISION
-- from ever consuming stale streak state. Runs every tick regardless of LFM.
gcUnattendedState = function()
  local liveRun = {}
  for _, r in ipairs(lastRuns) do liveRun[r.pid] = true end
  for pid in pairs(unattendedWaitStreak) do
    if not liveRun[pid] then unattendedWaitStreak[pid] = nil end
  end
  for pid in pairs(unattendedFiredFor) do
    if not liveRun[pid] then unattendedFiredFor[pid] = nil end
  end
end

-- One-click kill: re-validate identity first (pid-reuse guard), check the
-- pure policy, SIGTERM, escalate to SIGKILL after cfg.kill.escalateSec if the
-- target is still alive (re-validated again), then verify death and report
-- how much memory actually came back. onUpdate(text, done) drives whichever
-- surface initiated the kill.
function M.killPid(pid, expectedName, onUpdate, opts)
  onUpdate = onUpdate or alertUpdate
  opts = opts or {}
  local k = core.cfg.kill
  local frozenEntry = frozen[pid]
  -- Bind identity by start time when the caller captured one at selection
  -- (the frozen ledger, or an offender/HUD snapshot), so a pid reused
  -- between selection and this call is refused. Same-name pid reuse is
  -- exactly the bystander-kill class this tool was scarred by.
  local expectLstart = opts.expectedLstart or (frozenEntry and frozenEntry.lstart) or nil
  local proc, twhy = resolveSignalTarget(pid, expectedName, expectLstart)
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
  -- A SIGSTOPped process cannot handle SIGTERM until it is continued, so a
  -- TERM to a frozen target would just pend and force the full escalation
  -- wait before SIGKILL. Continue it first so the graceful signal can land.
  if frozenEntry or pidState(pid) == "T" then
    sh(string.format("/bin/kill -CONT %d 2>/dev/null", pid))
  end
  M.logSnapshot(string.format("kill-term:%s(%d)", liveName, pid))
  onUpdate(string.format("terminating %s\u{2026}", liveName), false)
  sh(string.format("/bin/kill -TERM %d 2>/dev/null", pid))
  hs.timer.doAfter(k.escalateSec, guard("kill-escalate", function()
    if pidAlive(pid) then
      -- Re-validate FULL identity (name AND the start time bound above)
      -- before SIGKILL: between TERM and this escalation the original may
      -- have exited and the pid been reused by another same-name process;
      -- name alone would not catch that, start time does.
      local again = resolveSignalTarget(pid, liveName, proc.lstart)
      if again then
        M.logSnapshot(string.format("kill-kill9:%s(%d)", liveName, pid))
        onUpdate(string.format("%s ignored TERM, sending KILL", liveName), false)
        sh(string.format("/bin/kill -KILL %d 2>/dev/null", pid))
      else
        M.logSnapshot(string.format("kill-escalate-abort:%d-identity-changed", pid))
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
  -- Orphan sweep: a hard Hammerspoon crash can leave OUR previous session's
  -- llama-server running with no owner. Only ever kill a server WE spawned:
  -- each spawn records its pid + start time to a pidfile, and this sweep
  -- kills exactly that pid IFF it is still alive AND its identity matches AND
  -- it is an llama-server serving our model dir. This never touches a user's
  -- own manual benchmark using the same model, and it only runs at all when
  -- the LFM feature is enabled.
  if lfm.cfg.enabled then
    local pf = io.open(LFM_PIDFILE, "r")
    if pf then
      local rec = lfm.jsonDecode(pf:read("a")); pf:close()
      if type(rec) == "table" and type(rec.pid) == "number" then
        local info = sh(string.format("/bin/ps -p %d -o lstart=,comm=,args= 2>/dev/null", rec.pid))
        local comm = info:match("%d%s+(%S+)") or info:match("^%s*%a+%s+%a+%s+%d+%s+[%d:]+%s+%d+%s+(%S+)")
        if info:find("projects/memwatch/models/", 1, true)
           and info:find("llama-server", 1, true)
           and (not rec.lstart or info:find(rec.lstart, 1, true)) then
          sh(string.format("/bin/kill -KILL %d 2>/dev/null", rec.pid))
          M.logSnapshot("lfm-orphan-sweep:pid=" .. rec.pid)
        end
      end
    end
    os.remove(LFM_PIDFILE)
  end
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
  if lfmServerTask then retireLfmServer("stop") end
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

-- Render the value report from the local ledgers and open it.
function M.report(public)
  local ok, reportMod = pcall(require, "memwatch_report")
  if not ok then return "report module unavailable" end
  local home = os.getenv("HOME") .. "/projects/memwatch/"
  os.execute("mkdir -p " .. home .. "reports")
  local out, err = reportMod.generate({
    ledger = home .. "memwatch-lfm.jsonl",
    log = home .. "memwatch.log",
    league = home .. "eval/results/league.json",
    out = home .. "reports/report.html",
  }, {
    public = public == true,
    generatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  })
  if not out then return "report failed: " .. tostring(err) end
  sh(string.format("/usr/bin/open %q", out))
  return "report opened: " .. out
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

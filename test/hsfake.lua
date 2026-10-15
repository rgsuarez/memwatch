-- hsfake.lua: a fake Hammerspoon world for driving lua/memwatch.lua under
-- standalone Lua, so the alert glue's behavior (not just its source text)
-- can be tested. It provides a virtual clock with one-shot, repeating and
-- polling timers; a fake process table that answers the exact ps and kill
-- shapes the glue issues; a sampler task that reports that table; and a
-- canvas, notifications, a menu bar and alerts that record what a person
-- at the machine would see.
--
-- Only what memwatch.lua touches is modeled. A command the fake does not
-- recognize returns "" (the glue treats that as "no answer") and is kept
-- in W.unknown for inspection.

local F = {}

local MEM_BYTES = 36 * 1024 ^ 3
local PAGE = 16384

function F.new()
  local W = { now = 1000.0, timers = {}, nextTimer = 0, procs = {}, kern = 1, availPct = 45,
              swapUsedMB = 0, sigs = {}, notifs = {}, alerts = {}, exec = {}, unknown = {},
              probeFails = false, activation = nil, hud = nil, menu = nil,
              etimeColumn = false }

  -- ---- virtual clock and timers ----------------------------------------
  local Timer = {}
  Timer.__index = Timer
  function Timer:stop() self.stopped = true; return self end
  function Timer:running() return not self.stopped end
  local function addTimer(kind, delay, interval, fn, pred)
    W.nextTimer = W.nextTimer + 1
    local t = setmetatable({ kind = kind, at = W.now + delay, interval = interval, fn = fn,
                             pred = pred, id = W.nextTimer }, Timer)
    W.timers[#W.timers + 1] = t
    return t
  end
  W.addTimer = addTimer

  -- Run every due timer in time order up to now + dt.
  function W.run(dt)
    local stop = W.now + dt
    while true do
      local best
      for _, t in ipairs(W.timers) do
        if not t.stopped and t.at <= stop and (not best or t.at < best.at
            or (t.at == best.at and t.id < best.id)) then
          best = t
        end
      end
      if not best then break end
      if best.at > W.now then W.now = best.at end
      if best.kind == "after" then
        best.stopped = true
        best.fn(best)
      elseif best.kind == "every" then
        best.at = best.at + best.interval
        best.fn(best)
      else -- until: the predicate runs first; true ends the poller
        best.at = best.at + best.interval
        if best.pred() then best.stopped = true else best.fn(best) end
      end
    end
    W.now = stop
  end

  function W.liveTimers(kind)
    local n = 0
    for _, t in ipairs(W.timers) do
      if not t.stopped and (kind == nil or t.kind == kind) then n = n + 1 end
    end
    return n
  end

  -- ---- processes ---------------------------------------------------------
  local nextStart = 0
  local function startStamp()
    nextStart = nextStart + 1
    return string.format("Mon Oct 12 10:%02d:%02d 2026", (nextStart // 60) % 60, nextStart % 60)
  end
  function W.addProc(pid, name, rssMB, extra)
    local p = { pid = pid, uid = 501, comm = "/usr/local/bin/" .. name, rssKB = math.floor(rssMB * 1024),
                lstart = startStamp(), state = "S", bornAt = W.now }
    for k, v in pairs(extra or {}) do p[k] = v end
    W.procs[pid] = p
    return p
  end
  -- A same-name process taking over a pid that just exited.
  function W.reusePid(pid, name, rssMB)
    W.procs[pid] = nil
    return W.addProc(pid, name, rssMB)
  end
  -- Grow a process by mbPerSec while it runs (a stopped process holds still).
  function W.grow(pid, mbPerSec)
    return addTimer("every", 1, 1, function()
      local p = W.procs[pid]
      if p and p.state == "S" then p.rssKB = p.rssKB + math.floor(mbPerSec * 1024) end
    end)
  end

  local function etime(p)
    local s = math.max(0, math.floor(W.now - p.bornAt)) + 120
    return string.format("%02d:%02d", s // 60, s % 60)
  end
  local function samplerBlob()
    local rows = { tostring(W.kern),
      string.format("total = 4096.00M  used = %.2fM  free = 1024.00M  (encrypted)", W.swapUsedMB),
      W.etimeColumn and "  PID   UID    RSS ELAPSED COMM" or "  PID   UID    RSS COMM" }
    local pids = {}
    for pid in pairs(W.procs) do pids[#pids + 1] = pid end
    table.sort(pids)
    for _, pid in ipairs(pids) do
      local p = W.procs[pid]
      if W.etimeColumn then
        rows[#rows + 1] = string.format("%5d %5d %6d %s %s", pid, p.uid, p.rssKB, etime(p), p.comm)
      else
        rows[#rows + 1] = string.format("%5d %5d %6d %s", pid, p.uid, p.rssKB, p.comm)
      end
    end
    return table.concat(rows, "\n") .. "\n"
  end

  local function exec(cmd)
    W.exec[#W.exec + 1] = cmd
    if cmd:find("^/usr/bin/id %-u") then return "501\n" end
    local pid = cmd:match("^/bin/ps %-p (%d+) %-o uid=,lstart=,comm=")
    if pid then
      local p = W.procs[tonumber(pid)]
      if not p or W.probeFails then return "" end
      return string.format("  %d %s %s\n", p.uid, p.lstart, p.comm)
    end
    pid = cmd:match("^/bin/ps %-p (%d+) %-o pid=")
    if pid then return W.procs[tonumber(pid)] and ("  " .. pid .. "\n") or "" end
    pid = cmd:match("^/bin/ps %-p (%d+) %-o state=")
    if pid then local p = W.procs[tonumber(pid)]; return p and (p.state .. "\n") or "" end
    if cmd:find("^/bin/ps %-o ppid= %-p %d+") then return "1\n" end
    local sig, kp = cmd:match("^/bin/kill %-(%u+) (%d+)")
    if sig then
      kp = tonumber(kp)
      W.sigs[#W.sigs + 1] = { t = W.now, sig = sig, pid = kp }
      local p = W.procs[kp]
      if p then
        if sig == "STOP" then p.state = "T"
        elseif sig == "CONT" then p.state = "S"
        elseif sig == "TERM" and p.state ~= "T" then W.procs[kp] = nil
        elseif sig == "KILL" then W.procs[kp] = nil end
      end
      return ""
    end
    W.unknown[#W.unknown + 1] = cmd
    return ""
  end

  function W.signalsTo(pid)
    local out = {}
    for _, s in ipairs(W.sigs) do if s.pid == pid then out[#out + 1] = s.sig end end
    return table.concat(out, ",")
  end

  -- ---- canvas, notifications, menu ----------------------------------------
  local Canvas = {}
  Canvas.__index = Canvas
  for _, m in ipairs({ "level", "behaviorAsLabels", "clickActivating", "canvasMouseEvents", "frame" }) do
    Canvas[m] = function(self) return self end
  end
  function Canvas:mouseCallback(fn) self._mouse = fn; return self end
  function Canvas:show() self._showing = true; return self end
  function Canvas:hide() self._showing = false; return self end
  function Canvas:isShowing() return self._showing == true end
  function Canvas:delete() self._showing = false end

  function W.hudShowing() return W.hud ~= nil and W.hud:isShowing() end
  function W.hudBody() return W.hud and W.hud[3] and W.hud[3].text or "" end
  function W.hudTitle() return W.hud and W.hud[2] and W.hud[2].text or "" end
  function W.click(id) assert(W.hud and W.hud._mouse, "no HUD"); W.hud._mouse(W.hud, "mouseUp", id) end

  local Notif = {}
  Notif.__index = Notif
  function Notif:send()
    self.sentAt = W.now
    W.notifs[#W.notifs + 1] = self
    local wa = self.attrs.withdrawAfter
    if wa and wa > 0 then addTimer("after", wa, nil, function() self.withdrawn = true end) end
    return self
  end
  function Notif:withdraw() self.withdrawn = true; return self end
  function Notif:activationType() return W.activation end

  local CRIT_TITLE = "Memory pressure: CRITICAL"
  function W.liveBanners()
    local out = {}
    for _, n in ipairs(W.notifs) do
      if not n.withdrawn and n.attrs.title == CRIT_TITLE then out[#out + 1] = n end
    end
    return out
  end
  function W.bannerPosts()
    local n = 0
    for _, x in ipairs(W.notifs) do if x.attrs.title == CRIT_TITLE then n = n + 1 end end
    return n
  end
  function W.notices(titlePrefix)
    local out = {}
    for _, n in ipairs(W.notifs) do
      if (n.attrs.title or ""):sub(1, #titlePrefix) == titlePrefix then out[#out + 1] = n end
    end
    return out
  end
  function W.clickBanner(n)
    W.activation = 2
    if n.fn then n.fn(n) end
    W.activation = nil
  end

  -- ---- the hs table ---------------------------------------------------------
  local hs = {
    execute = function(cmd) return exec(cmd), true end,
    processInfo = { processID = 777 },
    timer = {
      secondsSinceEpoch = function() return W.now end,
      doAfter = function(sec, fn) return addTimer("after", sec, nil, fn) end,
      doEvery = function(iv, fn) return addTimer("every", iv, iv, fn) end,
      doUntil = function(pred, action, iv) return addTimer("until", iv or 1, iv or 1, action, pred) end,
    },
    host = { vmStat = function()
      local total = MEM_BYTES // PAGE
      return { pageSize = PAGE, memSize = MEM_BYTES, pagesFree = math.floor(total * W.availPct / 100),
               pagesSpeculative = 0, pagesPurgeable = 0, fileBackedPages = 0, uncompressedPages = 0,
               swapOuts = 0, pagesCompressed = 0, pageOuts = 0 }
    end },
    task = { new = function(path, exitCb, streamCb)
      local t = { path = path }
      function t:start()
        if path == "/bin/sh" then
          addTimer("after", W.samplerDelay or 0.05, nil, function()
            if streamCb then streamCb(t, samplerBlob()) end
            exitCb(0, "", "")
          end)
        end
        return t
      end
      function t:terminate() end
      function t:isRunning() return false end
      function t:pid() return 9999 end
      return t
    end },
    canvas = { new = function()
      local c = setmetatable({ _showing = false }, Canvas)
      W.hud = c
      return c
    end, windowLevels = { overlay = 1 } },
    notify = { new = function(a, b)
      local fn, attrs = nil, a
      if type(a) == "function" then fn, attrs = a, b end
      return setmetatable({ fn = fn, attrs = attrs or {} }, Notif)
    end, activationTypes = { actionButtonClicked = 2, contentsClicked = 1 } },
    menubar = { new = function()
      local m = {}
      function m:setMenu(fn) self._fn = fn end
      function m:setTitle(x) self._title = x end
      function m:delete() end
      W.menu = m
      return m
    end },
    styledtext = { new = function(text) return text end },
    screen = { mainScreen = function()
      return { fullFrame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
    end },
    application = { launchOrFocus = function() end, frontmostApplication = function() return nil end },
    alert = { show = function(text) W.alerts[#W.alerts + 1] = { t = W.now, text = text } end },
    http = { asyncPost = function() end },
    fs = { dir = function() return function() return nil end end },
  }
  W.hs = hs

  -- Menu items as a person would see them (the builder runs on open).
  function W.menuItems() return W.menu and W.menu._fn and W.menu._fn() or {} end
  function W.menuItem(prefix)
    for _, it in ipairs(W.menuItems()) do
      if type(it.title) == "string" and it.title:sub(1, #prefix) == prefix then return it end
    end
  end
  return W
end

-- Load a fresh copy of memwatch.lua into world W, with HOME pointed at a
-- private scratch tree (config, ledgers and logs land there). localConfig,
-- when given, is written as memwatch-local.json before the load.
function F.load(W, localConfig)
  local mp = assert(io.popen("mktemp -d"))
  local home = mp:read("l")
  mp:close()
  assert(home and home:match("^/"), "mktemp -d failed")
  os.execute("mkdir -p '" .. home .. "/projects/memwatch'")
  W.home = home
  if localConfig then
    local f = assert(io.open(home .. "/projects/memwatch/memwatch-local.json", "w"))
    f:write(localConfig)
    f:close()
  end
  for _, m in ipairs({ "memwatch_core", "memwatch_procs", "memwatch_lfm", "memwatch_report",
                       "memwatch_observe" }) do
    package.loaded[m] = nil
  end
  local realGetenv = F.realGetenv or os.getenv
  F.realGetenv = realGetenv
  os.getenv = function(k) if k == "HOME" then return home end return realGetenv(k) end
  os.time = function(t) if t then return F.realTime(t) end return math.floor(W.now) end
  _G.hs = W.hs
  local chunk = assert(loadfile("lua/memwatch.lua"))
  local mw = chunk()
  return mw
end
F.realTime = os.time

function F.cleanup(W)
  if W.home and W.home:match("^/") then os.execute("rm -rf '" .. W.home .. "'") end
end

return F

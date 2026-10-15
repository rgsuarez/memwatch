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
local SELF_PID = 777   -- Hammerspoon's own pid in the fake
local PAGE = 16384

function F.new()
  local W = { now = 1000.0, timers = {}, nextTimer = 0, procs = {}, kern = 1, availPct = 45,
              swapUsedMB = 0, sigs = {}, notifs = {}, alerts = {}, exec = {}, unknown = {},
              probeFails = false, activation = nil, hud = nil, menu = nil,
              etimeColumn = true }   -- the sampler reports ps etime (process age)

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

  function W.releaseStalled()
    W.timersStall = false
    for _, t in ipairs(W.stalled or {}) do
      if not t.stopped then t.at = W.now + (t.stalledDelay or 0) end
    end
    W.stalled = {}
  end

  function W.liveTimers(kind)
    local n = 0
    for _, t in ipairs(W.timers) do
      if not t.stopped and (kind == nil or t.kind == kind) then n = n + 1 end
    end
    return n
  end

  -- ---- processes ---------------------------------------------------------
  -- A process's start time as ps prints it (local time), consistent with
  -- the etime the sampler reports for it (every fake process is reported
  -- 120 s older than its birth, so identity windows can decide). Both are
  -- on the wall clock, as the kernel keeps them: the start is the wall time
  -- at birth, and etime is the wall clock now minus it, so a wall-clock
  -- step moves etime and launch times together and the start stays put.
  local function wallNow() return W.now + (W.wallOffset or 0) end
  local function startStamp(bornWall)
    return os.date("%a %b %e %H:%M:%S %Y", math.floor(bornWall) - 120)
  end
  function W.addProc(pid, name, rssMB, extra)
    local p = { pid = pid, uid = 501, comm = "/usr/local/bin/" .. name, rssKB = math.floor(rssMB * 1024),
                lstart = startStamp(wallNow()), state = "S", bornAt = W.now, bornWall = wallNow() }
    for k, v in pairs(extra or {}) do p[k] = v end
    W.procs[pid] = p
    return p
  end
  -- Hammerspoon's own row in the sampler's table (not a fake process the
  -- scenarios drive: it never grows, and memwatch never signals it).
  W.selfProc = { pid = SELF_PID, uid = 501, comm = "/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon",
                 rssKB = 300 * 1024, state = "S", bornAt = W.now - 86400, bornWall = W.now - 86400 }
  -- A same-name process taking over a pid that just exited.
  function W.reusePid(pid, name, rssMB)
    W.procs[pid] = nil
    return W.addProc(pid, name, rssMB)
  end
  -- Grow a process by mbPerSec while it runs (a stopped process holds still).
  function W.grow(pid, mbPerSec)
    local t = addTimer("every", 1, 1, function()
      local p = W.procs[pid]
      if p and p.state == "S" then p.rssKB = p.rssKB + math.floor(mbPerSec * 1024) end
    end)
    t.world = true   -- the process's own behavior: a Hammerspoon reload does not stop it
    return t
  end

  local function etime(p)
    local s = math.max(0, math.floor(wallNow() - p.bornWall) + 120)
    return string.format("%02d:%02d", s // 60, s % 60)
  end
  local function samplerBlob()
    local rows = { tostring(W.kern),
      string.format("total = 4096.00M  used = %.2fM  free = 1024.00M  (encrypted)", W.swapUsedMB),
      W.etimeColumn and "  PID   UID    RSS ELAPSED COMM" or "  PID   UID    RSS COMM" }
    local pids = {}
    for pid in pairs(W.procs) do pids[#pids + 1] = pid end
    -- Hammerspoon itself is in every real table (memwatch's positive
    -- control for a whole table).
    if not W.procs[SELF_PID] then pids[#pids + 1] = SELF_PID end
    table.sort(pids)
    for _, pid in ipairs(pids) do
      local p = W.procs[pid] or (pid == SELF_PID and W.selfProc)
      -- samplerOmit: rows a cut-off (partial) table is missing.
      if W.samplerOmit and W.samplerOmit[pid] then goto continue end
      if W.etimeColumn then
        rows[#rows + 1] = string.format("%5d %5d %6d %s %s", pid, p.uid, p.rssKB, etime(p), p.comm)
      else
        rows[#rows + 1] = string.format("%5d %5d %6d %s", pid, p.uid, p.rssKB, p.comm)
      end
      ::continue::
    end
    return table.concat(rows, "\n") .. "\n"
  end

  local function exec(cmd)
    W.exec[#W.exec + 1] = cmd
    if cmd:find("^/usr/bin/id %-u") then return "501\n" end
    -- The identity probe: one row per live pid in the list, memwatch's own
    -- pid included (the positive control). probeFails models a fork that
    -- runs but answers nothing: no rows at all, control row included.
    local list = cmd:match("^/bin/ps %-p ([%d,]+) %-o pid=,uid=,state=,lstart=,comm=")
    if list then
      if W.probeFails then return "" end
      -- probeFailsOnce: the next n probes fail (a fork that fails now and then).
      if (W.probeFailsOnce or 0) > 0 then
        W.probeFailsOnce = W.probeFailsOnce - 1
        return ""
      end
      -- takeOverBeforeProbe: that pid's process exits and a same-name one
      -- takes the pid just before this probe runs (one shot).
      local tk = W.takeOverBeforeProbe
      if tk and W.procs[tk] and ("," .. list .. ","):find("," .. tk .. ",", 1, true) then
        W.takeOverBeforeProbe = nil
        local old = W.procs[tk]
        W.reusePid(tk, (old.comm:match("([^/]+)$") or "proc"), old.rssKB / 1024)
      end
      -- vanishBeforeProbe: that process exits just before this probe runs
      -- (one shot).
      if W.vanishBeforeProbe and W.procs[W.vanishBeforeProbe] then
        W.procs[W.vanishBeforeProbe], W.vanishBeforeProbe = nil, nil
      end
      -- probeScript: per-probe outcomes in order ("ok" or "fail"), consumed
      -- one per probe, so a sequence of answers and failures can be staged.
      if W.probeScript and #W.probeScript > 0 then
        if table.remove(W.probeScript, 1) == "fail" then return "" end
      end
      local rows, seen, order = {}, {}, {}
      for ps in list:gmatch("%d+") do order[#order + 1] = tonumber(ps) end
      table.sort(order)                -- ps lists processes in pid order
      for _, pid in ipairs(order) do
        if not seen[pid] then
          seen[pid] = true
          local p = W.procs[pid]
          if pid == SELF_PID then
            rows[#rows + 1] = string.format("%5d %5d Ss   Mon Oct 12 09:00:00 2026 %s", pid, 501,
              "/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon")
          elseif p then
            rows[#rows + 1] = string.format("%5d %5d %-4s %s %s", pid, p.uid, p.state, p.lstart, p.comm)
          end
        end
      end
      -- vanishAfterProbe: that process exits right after this probe saw it
      -- (between an engine's identity check and its signal).
      if W.vanishAfterProbe and W.procs[W.vanishAfterProbe] then
        W.procs[W.vanishAfterProbe], W.vanishAfterProbe = nil, nil
      end
      -- reuseAfterProbe: that process exits right after this probe saw it,
      -- and a same-name process takes the pid, so the signal that follows
      -- reaches the newcomer (one shot).
      -- (A table { pid = n, extra = { ... } } gives the newcomer traits.)
      local ra = W.reuseAfterProbe
      local raPid = type(ra) == "table" and ra.pid or ra
      if raPid and W.procs[raPid] then
        W.reuseAfterProbe = nil
        local old = W.procs[raPid]
        local nu = W.reusePid(raPid, (old.comm:match("([^/]+)$") or "proc"), old.rssKB / 1024)
        for k, v in pairs(type(ra) == "table" and ra.extra or {}) do nu[k] = v end
      end
      return table.concat(rows, "\n") .. "\n"
    end
    if cmd:find("^/bin/ps %-o ppid= %-p %d+") then return "1\n" end
    local sig, kp = cmd:match("^/bin/kill %-(%u+) (%d+)")
    if sig then
      kp = tonumber(kp)
      W.sigs[#W.sigs + 1] = { t = W.now, sig = sig, pid = kp }
      if W.onSignal then W.onSignal(sig, kp) end
      local p = W.procs[kp]
      if p then
        -- ignoreTerm: a process that survives TERM; unkillable: one that
        -- survives KILL too (a zombie, or stuck in the kernel); unstoppable:
        -- one a STOP does not stop (it never reaches state T). stopDelay
        -- models a STOP that takes effect a moment later (a process in a
        -- syscall stops when it returns to user space).
        if sig == "STOP" then
          if not p.unstoppable then
            if W.stopDelay then
              -- The kernel applies the STOP whatever memwatch does meanwhile.
              addTimer("after", W.stopDelay, nil, function()
                if W.procs[kp] == p then p.state = "T" end
              end).world = true
            else
              p.state = "T"
            end
          end
        elseif sig == "CONT" then p.state = "S"
        elseif sig == "TERM" and p.state ~= "T" and not p.ignoreTerm then W.procs[kp] = nil
        elseif sig == "KILL" and not p.unkillable then W.procs[kp] = nil end
        return ""
      end
      return "", false   -- kill(1) on a pid nothing holds exits 1 (ESRCH)
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
  -- send() returns a handle the way Hammerspoon does: a userdata, not the
  -- notification table (a closed temp file given a metatable of its own),
  -- so glue that tests a handle's type is caught here as it would be live.
  function Notif:send()
    self.sentAt = W.now
    W.notifs[#W.notifs + 1] = self
    local wa = self.attrs.withdrawAfter
    if wa and wa > 0 then addTimer("after", wa, nil, function() self.withdrawn = true end) end
    -- A real userdata, as Hammerspoon's handle is, from a file that needs
    -- no write (a closed handle is still userdata): /dev/null, else a file
    -- in the world's own scratch home, else a system temp file. With none,
    -- the notification itself stands in (it has the same two methods).
    local ud = io.open("/dev/null", "r")
      or (W.home and io.open(W.home .. "/notif-handle", "a"))
      or io.tmpfile()
    if not ud then return self end
    ud:close()
    local n = self
    debug.setmetatable(ud, { __index = {
      withdraw = function() n.withdrawn = true; return ud end,
      activationType = function() return W.activation end,
    } })
    return ud
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
    -- forkRaises models io.popen itself failing (hs.execute then raises);
    -- killRaises fails only the signal sends, after the probes succeeded.
    -- probeSignaled models a ps killed mid-reply: its partial output, and
    -- hs.execute's status saying a signal ended it.
    execute = function(cmd)
      -- sendFails = { TERM = true, ... } fails only those signals' sends.
      local sig = cmd:match("^/bin/kill %-(%u+)")
      if (W.forkRaises and cmd:find("^/bin/")) or (W.killRaises and cmd:find("^/bin/kill"))
         or (sig and W.sendFails and W.sendFails[sig]) then
        error("fork: Resource temporarily unavailable")
      end
      local out, exited0 = exec(cmd)
      if W.probeSignaled and cmd:find("^/bin/ps %-p") then
        return out:sub(1, math.max(0, math.floor(#out / 2))), nil, "signal", 9
      end
      if exited0 == false then return out, nil, "exit", 1 end
      return out, true, "exit", 0
    end,
    processInfo = { processID = SELF_PID },
    timer = {
      -- wallOffset: the wall clock stepped (NTP at wake, a VM resume);
      -- the run loop's own timers are unaffected.
      secondsSinceEpoch = function() return W.now + (W.wallOffset or 0) end,
      -- The monotonic clock (nanoseconds since boot): wall-clock steps never
      -- move it.
      absoluteTime = function() return math.floor(W.now * 1e9) end,
      -- timersStall: a one-shot callback that never gets to run (a run loop
      -- stalled past it), so a narrative waiting on it never finishes.
      -- timerLag: one-shots run that much late (a run loop blocked in a
      -- probe during a storm), so a follow-up or an outcome arrives after later
      -- evidence or after a deadline. A timer stalled this way can be released
      -- later (W.releaseStalled): it then runs its remaining delay from that
      -- moment, as a run loop that unblocks does.
      doAfter = function(sec, fn)
        if W.timersStall then
          local t = addTimer("after", math.huge, nil, fn)
          t.stalledDelay = sec
          W.stalled = W.stalled or {}
          W.stalled[#W.stalled + 1] = t
          return t
        end
        return addTimer("after", sec + (W.timerLag or 0), nil, fn)
      end,
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
        -- psStarved: the sampler fork starts but never reports (the watchdog
        -- relaunches it; a relaunch after psStarved clears reports again).
        if path == "/bin/sh" and not W.psStarved then
          -- ps reads the table when it runs, at launch; a starved callback
          -- delivers that reading late (samplerDelay), as a real storm does.
          -- samplersLive / samplersMax count the sampler forks memwatch has
          -- neither seen finish nor terminated: overlap means two ps at once.
          local blob = samplerBlob()
          t.sampler = true
          W.samplersLive = (W.samplersLive or 0) + 1
          W.samplersMax = math.max(W.samplersMax or 0, W.samplersLive)
          t.delivery = addTimer("after", W.samplerDelay or 0.05, nil, function()
            if t.done then return end
            t.done = true
            W.samplersLive = W.samplersLive - 1
            if streamCb then streamCb(t, blob) end
            exitCb(W.samplerExit or 0, "", "")   -- nonzero: ps failed or was cut off mid-table
          end)
        end
        -- The streaming top: with topEmits set, one block every 5 s naming
        -- each process the way top does (truncated at 16 characters).
        if path == "/usr/bin/top" then
          t.timer = addTimer("every", 5, 5, function()
            if not W.topEmits or not streamCb then return end
            local rows = { "  PID COMMAND          MEM    CMPRS" }
            local pids = {}
            for pid in pairs(W.procs) do pids[#pids + 1] = pid end
            table.sort(pids)
            for _, pid in ipairs(pids) do
              local p = W.procs[pid]
              local name = (p.comm:match("([^/]+)$") or p.comm):sub(1, 16)
              rows[#rows + 1] = string.format("%5d %-16s %dM %dM", pid, name,
                math.floor(p.rssKB / 1024), 0)
            end
            streamCb(t, table.concat(rows, "\n") .. "\n")
          end)
        end
        return t
      end
      function t:terminate()
        if t.timer then t.timer:stop() end
        -- A terminated sampler stops counting as running. With
        -- terminateCallsBack it also reports at once, as SIGTERM ends it:
        -- exit 15, its table lost.
        if t.sampler and not t.done then
          t.done = true
          W.samplersLive = W.samplersLive - 1
          if W.terminateCallsBack then
            if t.delivery then t.delivery:stop() end
            addTimer("after", 0.05, nil, function() exitCb(15, "", "") end)
          end
        end
      end
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
    -- frontmost: { name, pid } of the frontmost app (nil: undeterminable,
    -- which the unattended policy treats as foreground).
    application = { launchOrFocus = function() end, frontmostApplication = function()
      local f = W.frontmost
      if not f then return nil end
      return { name = function() return f.name end, pid = function() return f.pid end }
    end },
    alert = { show = function(text) W.alerts[#W.alerts + 1] = { t = W.now, text = text } end },
    -- Every POST is recorded; with httpReply(url, body) -> status, body set,
    -- it is answered after httpDelay (default 0.2 s).
    http = { asyncPost = function(url, body, headers, cb)
      W.httpPosts = W.httpPosts or {}
      W.httpPosts[#W.httpPosts + 1] = { url = url, body = body, at = W.now }
      if W.httpReply and cb then
        addTimer("after", W.httpDelay or 0.2, nil, function() cb(W.httpReply(url, body)) end)
      end
    end },
    -- W.jetsam: { [name] = modification epoch } of kernel jetsam reports.
    fs = {
      dir = function()
        local names = {}
        for n in pairs(W.jetsam or {}) do names[#names + 1] = n end
        local i = 0
        return function() i = i + 1; return names[i] end
      end,
      attributes = function(path, key)
        local m = (W.jetsam or {})[path:match("[^/]+$")]
        if m then
          if key == "modification" then return m end
          return { modification = m }
        end
        -- Any other path is a real file in the scratch home: it exists when
        -- renaming it onto itself succeeds (a stat, needing no read access).
        if key == nil and os.rename(path, path) then return { mode = "file" } end
        return nil
      end,
    },
  }
  W.hs = hs

  -- A Hammerspoon reload: every timer and canvas of the old Lua state dies
  -- with it (persisted files and posted notifications survive).
  function W.reloadState()
    for _, t in ipairs(W.timers) do
      if not t.world then t.stopped = true end   -- the world's own timers carry on
    end
    if W.hud then W.hud._showing = false end
    W.hud, W.menu = nil, nil
  end

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
-- The scratch root: HSFAKE_ROOT when set, else the system temp dir, else a
-- directory under the working tree (for sandboxes that deny /tmp writes).
local function scratchDir()
  local tries = {}
  local root = os.getenv("HSFAKE_ROOT")
  if root and root ~= "" then tries[#tries + 1] = "mktemp -d '" .. root .. "/hsfake.XXXXXX'" end
  tries[#tries + 1] = "mktemp -d 2>/dev/null"
  tries[#tries + 1] = "mktemp -d \"$PWD/.hsfake.XXXXXX\" 2>/dev/null"
  for _, cmd in ipairs(tries) do
    local mp = io.popen(cmd)
    local dir = mp and mp:read("l")
    if mp then mp:close() end
    if dir and dir:match("^/") then return dir end
  end
  error("no writable scratch directory (set HSFAKE_ROOT)")
end

-- opts.keepHome reloads into the world's existing home (a Hammerspoon
-- reload: the config, the frozen ledger and the logs survive).
function F.load(W, localConfig, opts)
  local home = (opts and opts.keepHome and W.home) or scratchDir()
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

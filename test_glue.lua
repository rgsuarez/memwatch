-- test_glue.lua: behavioral tests of the alert-episode glue in
-- lua/memwatch.lua, run against a fake Hammerspoon world (test/hsfake.lua)
-- with a virtual clock. Each scenario loads a fresh memwatch.lua and drives
-- it the way a pressure episode and an operator would, then checks what was
-- signaled and what a person would have seen. Run from the repo root:
--   lua test_glue.lua
package.path = "lua/?.lua;test/?.lua;" .. package.path
local F = require("hsfake")

local fails = 0
local function check(name, got, want)
  if got == want then
    print("ok    " .. name)
  else
    print(string.format("FAIL  %-60s got=%s want=%s", name, tostring(got), tostring(want)))
    fails = fails + 1
  end
end

local UNATTENDED_FREEZE = '{"unattended":"freeze"}'
local UNATTENDED_KILL = '{"unattended":"kill"}'

-- Run a scenario in a fresh world; fn(W, mw) does the driving.
local function scenario(name, localConfig, fn)
  local W = F.new()
  local ok, err = pcall(function()
    local mw = F.load(W, localConfig)
    fn(W, mw)
  end)
  if not ok then
    print("FAIL  " .. name .. " raised: " .. tostring(err))
    fails = fails + 1
  end
  -- Every command the glue issued is one the fake models: an unmodeled one
  -- reads as an empty answer, which would let a scenario pass on nothing.
  if #W.unknown > 0 then
    print("FAIL  " .. name .. " issued unmodeled commands: " .. table.concat(W.unknown, " | "):sub(1, 240))
    fails = fails + 1
  end
  pcall(function() if _G.memwatch then _G.memwatch.stop() end end)
  F.cleanup(W)
end

-- Run until pred() holds or maxSec passes; returns whether it held.
local function runUntil(W, maxSec, pred)
  local stop = W.now + maxSec
  while W.now < stop do
    if pred() then return true end
    W.run(1)
  end
  return pred()
end

local function bodyNames(W, name) return W.hudBody():find(name, 1, true) ~= nil end

-- Does memwatch.log (in the scenario's scratch home) contain this text?
local function logHas(W, text)
  local f = io.open(W.home .. "/projects/memwatch/memwatch.log", "r")
  if not f then return false end
  local all = f:read("a")
  f:close()
  return all:find(text, 1, true) ~= nil
end

-- A runaway the detector tags extreme within a few samples.
local function leaker(W, pid, name, rate)
  W.addProc(pid, name or "leaker", 2000)
  W.grow(pid, rate or 220)
end

-- ---- banner: a named offender gets its banner without a gap ----
scenario("banner follows the named offender", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  check("banner: an episode raises the HUD", runUntil(W, 30, function() return W.hudShowing() end), true)
  runUntil(W, 30, function() return bodyNames(W, "leaker") end)
  W.run(6)
  local live = W.liveBanners()
  check("banner: one live banner once the offender is named", #live, 1)
  check("banner: it names the offender", live[1] and (live[1].attrs.subTitle or ""):find("leaker", 1, true) ~= nil, true)
  check("banner: its Force Quit is offered once identity is bound",
    live[1] and live[1].attrs.hasActionButton, true)
  W.run(200)
  check("banner: still exactly one banner after the cooldown", #W.liveBanners(), 1)
end)

-- ---- banner: an unbound banner gains its action once identity binds ----
scenario("banner upgrades when identity binds", nil, function(W, mw)
  leaker(W, 4242)
  W.run(12)
  W.probeFails = true
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(6)
  local live = W.liveBanners()
  check("bind: with probes failing the banner offers no Force Quit",
    live[1] ~= nil and live[1].attrs.hasActionButton ~= true, true)
  local records = mw.debug().bannerRecords
  W.probeFails = false
  W.run(40)
  live = W.liveBanners()
  check("bind: once probes recover the banner offers Force Quit",
    live[1] ~= nil and live[1].attrs.hasActionButton == true, true)
  check("bind: still one live banner", #live, 1)
  check("bind: the upgrade adds no second history record", mw.debug().bannerRecords, records)
end)

-- ---- identity: a refusal keeps a banner bound to the pid's new process ----
-- A Force Quit built while a process was unbound is clicked after another
-- process, under another name, took its pid and earned a bound banner.
scenario("a refusal keeps another process's banner", nil, function(W)
  leaker(W, 4242, "nodeA")
  W.run(12)
  W.probeFails = true
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "nodeA") end)
  W.run(6)
  local stale = W.menuItem("Force Quit nodeA")
  check("refusal: the offender item was built unbound", stale ~= nil and stale.fn ~= nil, true)
  W.reusePid(4242, "nodeB", 2000)
  W.grow(4242, 220)
  W.probeFails = false
  local function nodeBBanner()
    local live = W.liveBanners()
    return #live == 1 and (live[1].attrs.subTitle or ""):find("nodeB", 1, true) ~= nil
      and live[1].attrs.hasActionButton == true
  end
  check("refusal: nodeB earns a bound banner", runUntil(W, 400, nodeBBanner), true)
  stale.fn()
  W.run(1)
  check("refusal: the stale click signals nothing", W.signalsTo(4242), "")
  check("refusal: nodeB's banner survives a refusal naming nodeA", nodeBBanner(), true)
end)

-- ---- names: a top-born truncated name and its full ps name are one process ----
-- With the ps sampler starved, only the streaming top feeds the tracker, and
-- top truncates names at 16 characters. When ps recovers it fills in the
-- full name. An ignore made on the truncated name must hold, and the bound
-- identity must carry over without another probe.
local LONG = "Google Chrome Helper (Renderer)"
local function topOnlyEpisode(W, mw)
  -- Critical (the kernel level rides the ps sample) with the stream up,
  -- then ps starves and the process is born: only top has seen it.
  W.kern = 4
  runUntil(W, 60, function() return mw.debug().state == "critical" and mw.debug().streamAlive end)
  W.run(1)
  W.psStarved, W.topEmits = true, true
  W.addProc(4242, LONG, 2000)
  W.grow(4242, 220)
  return runUntil(W, 120, function() return bodyNames(W, LONG:sub(1, 16) .. " (pid") end)
end
local function probesOf(W, pid, from)
  local n = 0
  for i = from or 1, #W.exec do
    local list = W.exec[i]:match("^/bin/ps %-p ([%d,]+) %-o pid=")
    if list and ("," .. list .. ","):find("," .. pid .. ",", 1, true) then n = n + 1 end
  end
  return n
end

scenario("an ignore holds across the name ps fills in", nil, function(W, mw)
  check("names: the HUD names the truncated top name", topOnlyEpisode(W, mw), true)
  W.run(6)
  W.click("ignore")
  check("names: the ignore takes the HUD down", W.hudShowing(), false)
  W.psStarved = false
  runUntil(W, 120, function() return not W.hudShowing() and false end)
  local reraised = runUntil(W, 400, function() return bodyNames(W, "Google Chrome") end)
  check("names: the ignored process does not come back once ps names it in full", reraised, false)
end)

scenario("a refreshed full name keeps the bound identity", nil, function(W, mw)
  check("names: the HUD names the truncated top name", topOnlyEpisode(W, mw), true)
  W.run(20)
  local from = #W.exec + 1
  W.psStarved = false
  check("names: ps fills in the full name", runUntil(W, 120, function() return bodyNames(W, LONG) end), true)
  W.run(10)
  check("names: no second probe for the same process", probesOf(W, 4242, from), 0)
end)

-- ---- answers: a frozen mark yields to a newcomer on its pid ----
-- A frozen process dies and a same-name process takes its pid and runs
-- away. Its ledger entry is a phantom until the sweep can prove it (60 s,
-- or never while probes fail); growth since the freeze proves it sooner.
local function frozenThenReused(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node") end)
  W.run(5)
  W.click("freeze")
  W.run(6)
  local frozenState = W.procs[4242] and W.procs[4242].state
  W.reusePid(4242, "node", 2000)
  W.grow(4242, 220)
  return frozenState
end

scenario("a phantom frozen entry does not hide a newcomer", nil, function(W)
  check("phantom: the runaway is frozen", frozenThenReused(W), "T")
  W.probeFails = true   -- the sweep keeps an entry it cannot verify
  check("phantom: the newcomer is surfaced while probes fail",
    runUntil(W, 90, function() return W.hudShowing() and bodyNames(W, "node (pid 4242)") end), true)
end)

scenario("a freeze of the newcomer on a phantom's pid freezes it", nil, function(W)
  check("phantom: the runaway is frozen", frozenThenReused(W), "T")
  W.run(2)
  local row = W.menuItem("node")
  local freeze = row and row.menu and row.menu[1]
  check("phantom: the menu offers the newcomer's Freeze", freeze ~= nil and freeze.fn ~= nil, true)
  freeze.fn()
  W.run(2)
  check("phantom: the newcomer is stopped, not reported already frozen", W.procs[4242].state, "T")
end)

-- ---- answers: a freeze not yet verified does not answer the next click ----
scenario("an unverified freeze does not answer the next click as frozen", nil, function(W)
  leaker(W, 4242, "node")
  W.procs[4242].unstoppable = true
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node") end)
  W.run(5)
  -- The STOP goes out (and does nothing); the verifier's probe then fails.
  W.onSignal = function(sig) if sig == "STOP" then W.probeFails = true end end
  W.click("freeze")
  W.run(1)
  W.onSignal, W.probeFails = nil, false
  W.run(5)
  check("pending: the alert stands after an unverified freeze", W.hudShowing(), true)
  W.click("freeze")
  W.run(6)
  check("pending: a second click does not answer it as frozen", W.hudShowing(), true)
  check("pending: the process still runs", W.procs[4242].state, "S")
end)

-- ---- identity: an unbound HUD refuses instead of signaling by name ----
scenario("unbound HUD actions refuse", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.probeFails = true
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.click("kill")
  W.run(10)
  check("unbound: Force Quit sends nothing", W.signalsTo(4242), "")
  W.click("freeze")
  W.run(3)
  check("unbound: Freeze sends nothing", W.signalsTo(4242), "")
  W.probeFails = false
  W.run(40)
  if not W.hudShowing() then runUntil(W, 90, function() return W.hudShowing() end) end
  W.click("kill")
  W.run(10)
  check("unbound: after binding, Force Quit acts", W.signalsTo(4242):find("TERM", 1, true) ~= nil, true)
end)

-- ---- identity: a same-name pid reuse is refused, then re-surfaced ----
scenario("pid reuse is refused", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node") end)
  W.run(5)
  W.reusePid(4242, "node", 9000)
  W.grow(4242, 220)
  W.click("kill")
  W.run(10)
  check("reuse: the newcomer is not signaled from the old binding", W.signalsTo(4242), "")
end)

-- ---- grace: a handoff to a different offender restarts the grace ----
scenario("a retarget gets its own grace", UNATTENDED_FREEZE, function(W)
  leaker(W, 4242, "first")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "first") end)
  W.run(45)
  -- A much faster, larger process takes over as the offender.
  W.procs[4242].state = "T"   -- the first one stops growing (held still)
  W.addProc(5151, "second", 6000)
  W.grow(5151, 900)
  runUntil(W, 30, function() return bodyNames(W, "second") end)
  local namedAt = W.now
  W.run(30)
  check("grace: the new offender is not frozen within its own grace", W.signalsTo(5151), "")
  W.run(50)
  check("grace: it is frozen after its own grace",
    W.signalsTo(5151):find("STOP", 1, true) ~= nil, true)
  check("grace: (named at least 59 s before the freeze)", (W.sigs[#W.sigs].t - namedAt) >= 59, true)
end)

-- ---- answers: a HUD freeze is the operator's answer for the episode ----
scenario("a HUD freeze is final for the episode", UNATTENDED_KILL, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(10)
  W.click("freeze")
  W.run(5)
  check("answer: the click froze it", W.signalsTo(4242), "STOP")
  W.run(300)
  check("answer: memwatch never terminates the process the operator froze", W.signalsTo(4242), "STOP")
  check("answer: no unattended receipt follows", #W.notices("memwatch unattended"), 0)
end)

-- ---- answers: closing the HUD is "not now" ----
scenario("close snoozes", UNATTENDED_FREEZE, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(10)
  local closedAt = W.now
  W.click("close")
  W.run(30)
  check("snooze: the HUD stays down during the snooze", W.hudShowing(), false)
  check("snooze: nothing is signaled during the snooze", W.signalsTo(4242), "")
  runUntil(W, 60, function() return W.hudShowing() end)
  check("snooze: the HUD returns after the raise cooldown", W.hudShowing(), true)
  check("snooze: (not before the cooldown)", W.now - closedAt >= 59, true)
  local backAt = W.now
  W.run(50)
  check("snooze: the returned alert gets a fresh grace", W.signalsTo(4242), "")
  W.run(20)
  check("snooze: an unanswered return is acted on", W.signalsTo(4242), "STOP")
  check("snooze: (only after its own grace)", (W.sigs[#W.sigs].t - backAt) >= 59, true)
end)

-- ---- answers: closing a quiet hog does not hide its escalation ----
scenario("an escalation preempts the snooze", nil, function(W)
  W.addProc(4242, "bigvm", 12000)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "bigvm") end)
  W.click("close")
  W.run(10)
  check("escalate: closed", W.hudShowing(), false)
  W.grow(4242, 250)
  check("escalate: the HUD returns as soon as the hog becomes a runaway",
    runUntil(W, 40, function() return W.hudShowing() end), true)
end)

-- ---- answers: Ignore keeps the process off the alert surfaces ----
scenario("ignore holds", nil, function(W)
  W.addProc(4242, "bigvm", 12000)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "bigvm") end)
  W.click("ignore")
  W.run(5)
  local shownAgain = runUntil(W, 150, function() return W.hudShowing() and bodyNames(W, "bigvm") end)
  check("ignore: the ignored process never returns to the HUD", shownAgain, false)
  local named = false
  for _, b in ipairs(W.liveBanners()) do
    if (b.attrs.subTitle or ""):find("bigvm", 1, true) then named = true end
  end
  check("ignore: no live banner names it", named, false)
end)

-- ---- unattended: no action without a bound identity ----
scenario("unattended needs identity", UNATTENDED_FREEZE, function(W)
  leaker(W, 4242)
  W.run(12)
  W.probeFails = true
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(80)
  check("identity: no unattended signal while identity cannot be bound", W.signalsTo(4242), "")
  W.probeFails = false
  local recoveredAt = W.now
  check("identity: once it binds, the unattended freeze lands",
    runUntil(W, 100, function() return W.signalsTo(4242) ~= "" end) and W.signalsTo(4242), "STOP")
  -- (round 5) Grace earned while unbound does not carry over to the bound
  -- process: the pid could hold a newcomer by then. A full grace from the
  -- bind (within one bind retry of recovery).
  check("identity: after a full grace of its own, none carried over from while unbound",
    W.sigs[#W.sigs] ~= nil and W.sigs[#W.sigs].t - recoveredAt >= 59, true)
end)

-- (round 5) While probes fail, an unbound runaway accrues grace; it exits
-- and a same-name process takes its pid. When probes recover and the HUD
-- binds the newcomer, none of that grace is its.
scenario("unbound grace does not pass to a newcomer on the pid", UNATTENDED_FREEZE, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.probeFails = true
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.run(50)                         -- about 50 s of grace accrues while unbound
  W.reusePid(4242, "node", 2000)
  W.grow(4242, 220)
  W.probeFails = false
  local recoveredAt = W.now
  runUntil(W, 120, function() return W.signalsTo(4242) ~= "" end)
  check("unbound-grace: the newcomer is frozen in the end", W.signalsTo(4242), "STOP")
  check("unbound-grace: only after a full grace of its own",
    W.sigs[#W.sigs] ~= nil and W.sigs[#W.sigs].t - recoveredAt >= 59, true)
end)

-- (round 5) An operator answer given while unbound (here, opening
-- Activity Monitor) does not stand a bound newcomer on the pid down.
scenario("an unbound answer does not stand a newcomer down", UNATTENDED_FREEZE, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.probeFails = true
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.click("monitor")
  W.run(5)
  W.reusePid(4242, "node", 2000)
  W.grow(4242, 220)
  W.probeFails = false
  check("unbound-answer: the newcomer is acted on once its own grace passes",
    runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end) and W.signalsTo(4242), "STOP")
end)

-- (round 5) Two helpers whose names share their first 15 characters are
-- different processes: an ignore of one never hides the other on its pid.
scenario("an ignore names one process, not a name prefix", nil, function(W)
  W.addProc(4242, "Chrome Helper (GPU)", 2000)
  W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "Chrome Helper (GPU) (pid") end)
  W.click("ignore")
  W.run(3)
  W.reusePid(4242, "Chrome Helper (Renderer)", 2000)
  W.grow(4242, 220)
  check("prefix: the other helper on the pid is alerted",
    runUntil(W, 90, function() return W.hudShowing() and bodyNames(W, "Chrome Helper (Renderer) (pid") end), true)
end)

-- ---- self-test surfaces never signal a real process ----
scenario("self-test is inert", nil, function(W, mw)
  W.addProc(99999, "something-real", 300)
  W.run(6)
  mw.test("critical", 20)
  W.run(2)
  check("selftest: the HUD shows the synthetic offender", W.hudShowing() and bodyNames(W, "FakeProc"), true)
  W.click("kill")
  check("selftest: a button says nothing was signaled", W.hudBody(), "Self-test: nothing was signaled.")
  W.run(8)
  W.click("freeze")
  W.run(3)
  check("selftest: the HUD's buttons signal nothing", W.signalsTo(99999), "")
  local live = W.liveBanners()
  check("selftest: one banner is up", #live, 1)
  check("selftest: and it offers no Force Quit", live[1] ~= nil and live[1].attrs.hasActionButton ~= true, true)
end)

-- ---- lifecycle: overlapping self-tests leave one poller; stop clears ----
scenario("overlapping diagnostics", nil, function(W, mw)
  W.run(6)
  mw.test("critical", 10)
  W.run(3)
  mw.simulate(5)
  W.run(20)
  local pollers = 0
  for _, t in ipairs(W.timers) do
    if not t.stopped and t.kind == "every" and t.interval == 5 then pollers = pollers + 1 end
  end
  check("lifecycle: exactly one poll timer after both resume", pollers, 1)
  mw.test("critical", 30)
  W.run(2)
  mw.stop()
  W.run(40)
  check("lifecycle: stop leaves no HUD", W.hudShowing(), false)
  check("lifecycle: stop leaves no banner", #W.liveBanners(), 0)
  local live = 0
  for _, t in ipairs(W.timers) do
    if not t.stopped and t.kind == "every" and t.interval == 5 then live = live + 1 end
  end
  check("lifecycle: and no poll timer", live, 0)
end)

-- ---- config: an undecodable local config is never rewritten ----
scenario("corrupt config survives a toggle", '{"unattended":"off","remoteServer":', function(W, mw)
  local path = W.home .. "/projects/memwatch/memwatch-local.json"
  mw.setAlertsEnabled(false)
  local f = assert(io.open(path, "r"))
  local txt = f:read("a")
  f:close()
  check("config: a file that does not decode is left as it was", txt, '{"unattended":"off","remoteServer":')
end)

-- ---- mute: the degraded page still reaches the operator ----
scenario("degraded page ignores the mute", '{"alerts":false}', function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  W.run(10)
  W.samplerDelay = 1e6   -- the sampler fork starves
  W.run(80)
  check("mute: the degraded-during-pressure notice is posted", #W.notices("memwatch degraded") >= 1, true)
end)

-- ---- identity: recovering probes do not license a name-only click ----
scenario("unbound click after recovery refuses first", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.probeFails = true
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.probeFails = false
  W.click("kill")                 -- before any retry could have bound it
  W.run(1)
  check("recover: the first click after recovery signals nothing", W.signalsTo(4242), "")
  check("recover: it binds and says so", W.hudBody():find("Click again", 1, true) ~= nil, true)
  W.click("kill")
  W.run(10)
  check("recover: the second click acts on the bound process", W.signalsTo(4242), "TERM")
end)

-- ---- identity: after a reuse refusal the newcomer is a new alert ----
scenario("reuse refusal re-surfaces the newcomer", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node") end)
  W.run(5)
  W.reusePid(4242, "node", 9000)
  W.grow(4242, 220)
  W.click("kill")
  W.run(6)
  check("resurface: the click on the old binding is refused", W.signalsTo(4242), "")
  check("resurface: the newcomer is surfaced again",
    runUntil(W, 20, function() return W.hudShowing() and bodyNames(W, "node") end), true)
  W.click("kill")
  W.run(10)
  check("resurface: and can be acted on under its own identity", W.signalsTo(4242), "TERM")
end)

-- ---- grace: a handoff while the first alert is up and unanswered ----
scenario("a visible handoff restarts the grace", UNATTENDED_FREEZE, function(W)
  leaker(W, 4242, "first")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "first") end)
  W.run(30)                          -- half of the first offender's grace
  W.procs[4242] = nil                -- it exits on its own
  W.addProc(5151, "second", 6000)
  W.grow(5151, 900)
  runUntil(W, 30, function() return bodyNames(W, "second") end)
  check("handoff: the HUD stayed up across the handoff", W.hudShowing(), true)
  local namedAt = W.now
  W.run(40)
  check("handoff: the new offender is not frozen on the old grace", W.signalsTo(5151), "")
  W.run(40)
  check("handoff: it is frozen on its own grace", W.signalsTo(5151), "STOP")
  check("handoff: (a full grace after it was named)", (W.sigs[#W.sigs].t - namedAt) >= 59, true)
end)

-- ---- answers: memwatch's own freeze is final too ----
scenario("an unattended freeze is final", UNATTENDED_FREEZE, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  runUntil(W, 90, function() return W.signalsTo(4242) ~= "" end)
  check("final: the unattended freeze landed", W.signalsTo(4242), "STOP")
  W.run(240)
  check("final: no second action on the frozen process", W.signalsTo(4242), "STOP")
  check("final: exactly one unattended receipt", #W.notices("memwatch unattended"), 1)
end)

-- ---- mute: a muted episode still arms, and acts only on a bound identity ----
scenario("a muted episode arms", '{"unattended":"freeze","alerts":false}', function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  W.run(30)
  check("muted: no HUD is shown", W.hudShowing(), false)
  check("muted: no banner is posted", #W.liveBanners(), 0)
  runUntil(W, 90, function() return W.signalsTo(4242) ~= "" end)
  check("muted: the unattended freeze still lands", W.signalsTo(4242), "STOP")
  W.run(2)                          -- the receipt follows the verified result
  check("muted: its receipt still notifies", #W.notices("memwatch unattended freeze"), 1)
end)

-- ---- banner: a generic banner upgrades the moment an offender is named ----
scenario("generic banner upgrades without a gap", nil, function(W)
  W.kern = 4
  W.run(12)
  check("generic: a generic banner is up while no offender is named", #W.liveBanners(), 1)
  leaker(W, 4242)
  local named = runUntil(W, 40, function()
    local b = W.liveBanners()[1]
    return b ~= nil and (b.attrs.subTitle or ""):find("leaker", 1, true) ~= nil
  end)
  check("generic: replaced by the named banner without waiting out the cooldown", named, true)
  check("generic: never two banners at once", #W.liveBanners(), 1)
end)

-- ---- menu: the offender's Force Quit never signals by name alone ----
scenario("menu offender quit binds or refuses", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.probeFails = true
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  local item = W.menuItem("Force Quit leaker")
  check("menu: the offender's Force Quit is listed", item ~= nil, true)
  if item then item.fn() end
  W.run(10)
  check("menu: with identity unverifiable it signals nothing", W.signalsTo(4242), "")
  check("menu: and says why", W.alerts[#W.alerts] ~= nil and W.alerts[#W.alerts].text:find("can't verify", 1, true) ~= nil, true)
  W.probeFails = false
  item = W.menuItem("Force Quit leaker")
  if item then item.fn() end
  W.run(10)
  check("menu: once it can bind, it acts on that identity", W.signalsTo(4242), "TERM")
end)

-- ---- probes: a probe that cannot run is never read as an exit ----
-- (round-3 P1) An already-bound offender, then ps stops answering: the
-- click must not send anything, and must not record the process as
-- answered, so it acts once the probes come back.
scenario("a failed probe at the click is not an exit", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(5)                          -- bound at the raise
  W.probeFails = true
  W.click("freeze")
  W.run(8)
  check("probe-fail: Freeze sends nothing it cannot verify", W.signalsTo(4242), "")
  check("probe-fail: the alert stands, still up", W.hudShowing(), true)
  W.click("kill")
  W.run(30)
  check("probe-fail: Force Quit sends nothing either", W.signalsTo(4242), "")
  check("probe-fail: the alert is still up", W.hudShowing(), true)
  W.probeFails = false
  W.run(5)
  W.click("freeze")
  W.run(3)
  check("probe-fail: once probes answer, the same alert acts", W.signalsTo(4242), "STOP")
end)

scenario("a raising fork is not an exit", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(5)
  W.forkRaises = true
  W.click("freeze")
  W.run(8)
  W.forkRaises = false
  check("fork-raise: nothing was signaled", W.signalsTo(4242), "")
  check("fork-raise: the alert stands", W.hudShowing(), true)
  W.click("freeze")
  W.run(3)
  check("fork-raise: the retry acts", W.signalsTo(4242), "STOP")
end)

scenario("unattended survives a failed probe", UNATTENDED_FREEZE, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(5)                          -- bound
  W.probeFails = true
  W.run(80)                         -- grace expires while ps cannot answer
  check("unattended-probe: nothing is signaled unverified", W.signalsTo(4242), "")
  W.probeFails = false
  check("unattended-probe: it acts once the probe answers",
    runUntil(W, 90, function() return W.signalsTo(4242) ~= "" end) and W.signalsTo(4242), "STOP")
end)

-- ---- probes: a TERM sent, then the verify cannot run ----
scenario("kill escalation never signals an unverified pid", nil, function(W)
  W.addProc(4242, "stubborn", 2000, { ignoreTerm = true })
  W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "stubborn") end)
  W.run(5)
  W.click("kill")
  W.run(0.5)
  check("escalate: TERM went out", W.signalsTo(4242), "TERM")
  W.probeFails = true
  W.run(20)
  check("escalate: no KILL to a pid it cannot verify", W.signalsTo(4242), "TERM")
  W.probeFails = false
  W.run(5)
  W.click("kill")
  W.run(20)
  check("escalate: with probes back, the retry escalates", W.signalsTo(4242), "TERM,TERM,KILL")
end)

-- ---- frozen ledger: a probe that cannot run never strands a frozen process ----
scenario("resume keeps the entry when it cannot verify", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(5)
  W.click("freeze")
  W.run(5)
  check("strand: frozen", W.procs[4242].state, "T")
  W.probeFails = true
  local row = W.menuItem("   leaker")
  local resume = row and row.menu and row.menu[1]
  check("strand: the frozen row offers Resume", resume ~= nil and resume.title:find("Resume", 1, true) ~= nil, true)
  if resume then resume.fn() end
  W.run(3)
  check("strand: Resume sends nothing it cannot verify", W.signalsTo(4242), "STOP")
  check("strand: the process is still listed as frozen", W.menuItem("   leaker") ~= nil, true)
  W.probeFails = false
  row = W.menuItem("   leaker")
  resume = row and row.menu and row.menu[1]
  if resume then resume.fn() end
  W.run(3)
  check("strand: once probes answer, Resume continues it", W.signalsTo(4242), "STOP,CONT")
  check("strand: and it is running again", W.procs[4242].state, "S")
end)

scenario("a reload keeps a frozen process it cannot verify", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(5)
  W.click("freeze")
  W.run(5)
  W.reloadState()
  W.probeFails = true
  F.load(W, nil, { keepHome = true })
  W.run(3)
  check("reload: the unverifiable entry stays in the menu", W.menuItem("   leaker") ~= nil, true)
  W.probeFails = false
  W.kern = 1
  W.availPct = 45
  W.run(130)                        -- calm: the sweep re-checks it
  check("reload: the sweep keeps it once verified frozen", W.menuItem("   leaker") ~= nil, true)
end)

-- ---- outcomes: an unattended receipt says what happened, when it happened ----
-- (round 3) A same-name process took the pid under an inherited binding:
-- the attempt is refused as stale, so no "freeze" receipt, and the
-- newcomer is a new alert with its own grace.
scenario("an unattended action refused as stale posts no receipt", '{"unattended":"freeze","alerts":false}', function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  W.run(40)                         -- muted, armed, bound
  W.reusePid(4242, "leaker", 9000)
  W.grow(4242, 220)
  local refused = runUntil(W, 40, function() return logHas(W, "answered:rebind:leaker(4242):stale") end)
  check("receipt: the stale attempt is refused and rebinds", refused, true)
  local refusedAt = W.now
  check("receipt: nothing signaled to the newcomer on the old binding", W.signalsTo(4242), "")
  check("receipt: and no receipt claims a freeze", #W.notices("memwatch unattended freeze"), 0)
  runUntil(W, 90, function() return W.signalsTo(4242) ~= "" end)
  W.run(2)
  check("receipt: the newcomer is frozen on its own identity", W.signalsTo(4242), "STOP")
  check("receipt: (a full grace after the refusal)", W.sigs[#W.sigs].t - refusedAt >= 59, true)
  check("receipt: exactly one receipt, for the freeze that happened", #W.notices("memwatch unattended freeze"), 1)
end)

-- (round 4) The policy gate refuses another user's process: nothing is
-- signaled, and nothing is announced.
scenario("an unattended action the policy refuses posts no receipt", UNATTENDED_FREEZE, function(W)
  W.addProc(4242, "rootleak", 2000, { uid = 0 })
  W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  local refused = runUntil(W, 120, function() return logHas(W, "freeze-refuse:rootleak(4242)") end)
  check("policy: the unattended freeze is refused", refused, true)
  W.run(10)
  check("policy: nothing was signaled", W.signalsTo(4242), "")
  check("policy: and no receipt claims anything", #W.notices("memwatch unattended"), 0)
end)

-- (round 4) An unattended action whose result never arrives (its verifier
-- never got to run) still owes a receipt: a STOP went out, and the muted
-- operator is told so at the hold deadline.
scenario("an unattended action with no result still posts a receipt", '{"unattended":"freeze","alerts":false}', function(W)
  W.onSignal = function(sig) if sig == "STOP" then W.timersStall = true end end
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 120, function() return W.signalsTo(4242) ~= "" end)
  W.onSignal, W.timersStall = nil, false
  check("no-result: the STOP went out", W.signalsTo(4242), "STOP")
  check("no-result: nothing is announced before the deadline", #W.notices("memwatch unattended"), 0)
  W.run(50)
  local n = W.notices("memwatch unattended freeze")
  check("no-result: one receipt at the deadline, though alerts are muted", #n, 1)
  check("no-result: it says the result never came back",
    n[1] ~= nil and (n[1].attrs.informativeText or ""):find("never came back", 1, true) ~= nil, true)
end)

-- (round 3) A freeze that did not stop the process is a snooze, not a
-- handled answer, even when the settle window cannot probe; and memwatch
-- does not keep retrying a signal that already failed on that process.
scenario("a survivor is snoozed, not handled", nil, function(W)
  W.addProc(4242, "wedged", 2000, { unstoppable = true })
  W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "wedged") end)
  W.run(5)
  W.click("freeze")
  W.run(1)
  check("survivor: it did not stop", W.hudBody():find("did not stop", 1, true) ~= nil, true)
  W.probeFails = true
  W.run(8)
  W.probeFails = false
  check("survivor: the alert came down as a snooze", W.hudShowing(), false)
  check("survivor: and comes back after the cooldown",
    runUntil(W, 70, function() return W.hudShowing() and bodyNames(W, "wedged") end), true)
end)

scenario("unattended does not retry a failed freeze", UNATTENDED_FREEZE, function(W)
  W.addProc(4242, "wedged", 2000, { unstoppable = true })
  W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "wedged") end)
  runUntil(W, 90, function() return W.signalsTo(4242) ~= "" end)
  W.run(2)
  check("retry: the unattended freeze was tried", W.signalsTo(4242), "STOP")
  check("retry: its receipt says it did not stop",
    (W.notices("memwatch unattended freeze")[1] or { attrs = {} }).attrs.informativeText ~= nil
    and W.notices("memwatch unattended freeze")[1].attrs.informativeText:find("did not stop", 1, true) ~= nil, true)
  W.run(400)
  check("retry: it is never tried again on the same process", W.signalsTo(4242), "STOP")
end)

-- ---- answers: by the process's own state, not a note in a list ----
scenario("resume makes a frozen process alertable again", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(5)
  W.click("freeze")
  W.run(8)
  check("resume-answer: frozen, and the alert is down", W.hudShowing(), false)
  local row = W.menuItem("   leaker")
  local resume = row and row.menu and row.menu[1]
  if resume then resume.fn() end
  W.run(2)
  check("resume-answer: resumed", W.procs[4242].state, "S")
  check("resume-answer: a resumed runaway is alerted again",
    runUntil(W, 90, function() return W.hudShowing() and bodyNames(W, "leaker") end), true)
end)

scenario("a killed process does not haunt the HUD", nil, function(W)
  leaker(W, 4242)
  W.addProc(5151, "bigvm", 9000)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(5)
  W.click("kill")
  W.run(12)
  check("ghost: the leaker is gone", W.procs[4242] == nil, true)
  -- (the narrative text names it until the settle; a raise names "pid 4242")
  local haunted = runUntil(W, 40, function() return W.hudShowing() and bodyNames(W, "leaker (pid 4242)") end)
  check("ghost: the HUD never comes back for the dead process", haunted, false)
  check("ghost: the next process is alerted instead", W.hudShowing() and bodyNames(W, "bigvm"), true)
end)

-- ---- answers: a raise never names a process its bind proved gone ----
-- With the ps sampler starved, the last assessment's offender outlives the
-- process. The raise's bind proves it gone; the alert rises unnamed.
scenario("a raise never names a process its bind proved gone", nil, function(W)
  leaker(W, 4242, "ghost")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "ghost (pid") end)
  W.run(5)
  W.click("close")                      -- snoozed: back after the raise cooldown
  W.psStarved = true
  W.run(6)
  W.procs[4242] = nil                   -- it exits; no sample will say so
  local named = runUntil(W, 90, function() return W.hudShowing() and bodyNames(W, "ghost (pid") end)
  check("gone: the HUD never names the exited process", named, false)
  check("gone: the alert still rises, unnamed", W.hudShowing() and bodyNames(W, "No single offender"), true)
end)

-- (round 3) A banner posted before its identity bound, upgraded in place,
-- then a same-name process reuses the pid: the newcomer must get its own
-- banner once the cooldown allows, not be taken for the one announced.
scenario("banner history follows the bound identity", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.probeFails = true
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node") end)
  W.run(6)
  W.probeFails = false
  W.run(30)
  local b = W.liveBanners()[1]
  check("history: the banner bound in place", b ~= nil and b.attrs.hasActionButton == true, true)
  W.reusePid(4242, "node", 9000)
  W.grow(4242, 220)
  W.click("kill")                   -- the stale binding is refused and rebinds
  W.run(10)
  check("history: nothing was signaled on the stale binding", W.signalsTo(4242), "")
  local fresh = runUntil(W, 240, function()
    local live = W.liveBanners()
    return #live == 1 and live[1] ~= b and live[1].attrs.hasActionButton == true
  end)
  check("history: the newcomer gets its own banner", fresh, true)
end)

-- (round 3) Ignore lasts as long as the button says, for whoever holds
-- the pid afterwards too; it is not a permanent answer for the episode.
scenario("ignore lasts its window", nil, function(W)
  W.addProc(4242, "bigvm", 12000)
  W.run(12)
  W.probeFails = true               -- ignored before its identity could bind
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "bigvm") end)
  W.click("ignore")
  W.run(5)
  W.probeFails = false
  local early = runUntil(W, 1700, function() return W.hudShowing() and bodyNames(W, "bigvm") end)
  check("ignore-window: hidden while the ignore lasts", early, false)
  check("ignore-window: alerted again once the 30 minutes are up",
    runUntil(W, 200, function() return W.hudShowing() and bodyNames(W, "bigvm") end), true)
end)

-- (round 3) A frozen process dies (memory pressure can kill a stopped
-- process) and a same-name process takes its pid: the phantom ledger entry
-- must not hide the newcomer for the rest of the episode.
scenario("a dead frozen process does not hide its pid's newcomer", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node") end)
  W.run(5)
  W.click("freeze")
  W.run(8)
  W.reusePid(4242, "node", 3000)    -- the frozen one died; a newcomer runs away
  W.grow(4242, 300)
  check("phantom: the newcomer is alerted while pressure lasts",
    runUntil(W, 150, function() return W.hudShowing() and bodyNames(W, "node") end), true)
end)

-- ---- grace: per process, from when it heads the alert as extreme ----
-- (round 3 P1) A generic alert that later names an extreme offender must
-- not act on it the moment it is named.
scenario("a generic alert's first offender gets a full grace", UNATTENDED_FREEZE, function(W)
  W.kern = 4
  W.run(70)                         -- a generic HUD, up past a grace window
  check("generic-grace: a generic HUD is up", W.hudShowing(), true)
  leaker(W, 4242)
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  local namedAt = W.now
  W.run(40)
  check("generic-grace: not acted on right after it is named", W.signalsTo(4242), "")
  runUntil(W, 60, function() return W.signalsTo(4242) ~= "" end)
  check("generic-grace: acted on after its own grace", W.signalsTo(4242), "STOP")
  check("generic-grace: (at least a grace after it was named)", W.sigs[#W.sigs].t - namedAt >= 59, true)
end)

-- A hog shown for minutes that turns into a runaway gets a full grace as
-- a runaway: its time as a quiet hog does not count.
scenario("a hog that escalates gets a full grace", UNATTENDED_FREEZE, function(W)
  W.addProc(4242, "bigvm", 12000)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "bigvm") end)
  W.run(90)
  W.grow(4242, 250)
  runUntil(W, 40, function() return bodyNames(W, "MB/min") end)
  local extremeAt = W.now
  W.run(40)
  check("hog-grace: not acted on right after it escalates", W.signalsTo(4242), "")
  runUntil(W, 60, function() return W.signalsTo(4242) ~= "" end)
  check("hog-grace: acted on after a grace as a runaway", W.signalsTo(4242), "STOP")
  check("hog-grace: (at least a grace after it escalated)", W.sigs[#W.sigs].t - extremeAt >= 55, true)
end)

-- (round 3 P1) Two runaways trading the top spot each keep their own clock:
-- the alternation must not starve unattended action.
scenario("alternating offenders each get acted on", UNATTENDED_FREEZE, function(W)
  W.addProc(4242, "alpha", 2000)
  W.addProc(5151, "beta", 2000)
  local fast = 4242
  W.addTimer("every", 1, 1, function()
    for _, pid in ipairs({ 4242, 5151 }) do
      local p = W.procs[pid]
      if p and p.state == "S" then p.rssKB = p.rssKB + math.floor(((pid == fast) and 400 or 150) * 1024) end
    end
  end)
  W.addTimer("every", 20, 20, function() fast = (fast == 4242) and 5151 or 4242 end)
  W.run(12)
  W.kern = 4
  local both = runUntil(W, 400, function()
    return W.signalsTo(4242):find("STOP", 1, true) ~= nil and W.signalsTo(5151):find("STOP", 1, true) ~= nil
  end)
  check("flap: both alternating runaways are frozen in the end", both, true)
  check("flap: (the HUD retargeted between them)", logHas(W, "hud-retarget:alpha") and logHas(W, "hud-retarget:beta"), true)
end)

-- (round 3 P1) A click that did nothing (an unbound refusal) is not an
-- answer: unattended still acts once the identity binds.
scenario("a refused click does not disarm unattended", UNATTENDED_FREEZE, function(W)
  leaker(W, 4242)
  W.run(12)
  W.probeFails = true
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.click("kill")
  W.run(2)
  check("refused-click: the unbound click refused", W.hudBody():find("Can't verify", 1, true) ~= nil, true)
  W.probeFails = false
  check("refused-click: unattended still freezes once it binds",
    runUntil(W, 120, function() return W.signalsTo(4242) ~= "" end) and W.signalsTo(4242), "STOP")
end)

-- (round 4) An action whose probe failed before any signal (unverified)
-- left the process untouched, so it is no answer: once probes recover,
-- unattended still acts. Each surface: the HUD, the banner, a menu row;
-- and a click whose outcome never came back lapses at the hold deadline.
local function armedEpisode(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  return runUntil(W, 40, function() return bodyNames(W, "leaker (pid") end)
end
local function freezesWithin(W, sec)
  return runUntil(W, sec, function() return W.signalsTo(4242) ~= "" end) and W.signalsTo(4242)
end

scenario("an unverified HUD click does not disarm unattended", UNATTENDED_FREEZE, function(W)
  check("unverified-hud: the alert names the runaway", armedEpisode(W), true)
  W.run(5)
  W.probeFails = true
  W.click("freeze")
  W.run(6)
  check("unverified-hud: nothing was signaled", W.signalsTo(4242), "")
  W.probeFails = false
  check("unverified-hud: unattended freezes once probes recover", freezesWithin(W, 120), "STOP")
end)

scenario("an unverified banner click does not disarm unattended", UNATTENDED_FREEZE, function(W)
  check("unverified-banner: the alert names the runaway", armedEpisode(W), true)
  W.run(8)
  local b = W.liveBanners()[1]
  check("unverified-banner: the banner offers Force Quit", b ~= nil and b.attrs.hasActionButton == true, true)
  W.probeFails = true
  if b then W.clickBanner(b) end
  W.run(3)
  check("unverified-banner: nothing was signaled", W.signalsTo(4242), "")
  W.probeFails = false
  check("unverified-banner: unattended freezes once probes recover", freezesWithin(W, 120), "STOP")
end)

scenario("an unverified menu click does not disarm unattended", UNATTENDED_FREEZE, function(W)
  check("unverified-menu: the alert names the runaway", armedEpisode(W), true)
  W.run(5)
  local row = W.menuItem("leaker")
  local freeze = row and row.menu and row.menu[1]
  check("unverified-menu: the row offers Freeze", freeze ~= nil and freeze.disabled == nil, true)
  W.probeFails = true
  if freeze then freeze.fn() end
  W.run(3)
  check("unverified-menu: nothing was signaled", W.signalsTo(4242), "")
  W.probeFails = false
  check("unverified-menu: unattended freezes once probes recover", freezesWithin(W, 120), "STOP")
end)

scenario("a click whose signal went out still answers", UNATTENDED_FREEZE, function(W)
  W.addProc(4242, "leaker", 2000, { unstoppable = true })
  W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker (pid") end)
  W.run(5)
  -- The STOP goes out (and does nothing); its verifier's probe fails.
  W.onSignal = function(sig) if sig == "STOP" then W.probeFails = true end end
  W.click("freeze")
  W.run(1)
  W.onSignal, W.probeFails = nil, false
  W.run(120)
  check("answered: the operator's STOP is the only signal", W.signalsTo(4242), "STOP")
end)

scenario("a click whose outcome never came back lapses", UNATTENDED_FREEZE, function(W)
  check("lapse: the alert names the runaway", armedEpisode(W), true)
  W.run(5)
  W.killRaises = true               -- the TERM send itself fails
  W.click("kill")
  W.run(2)
  W.killRaises = false
  check("lapse: unattended freezes after the hold deadline", freezesWithin(W, 150), "STOP")
end)

-- (round 3) A banner Force Quit is the operator's answer: unattended does
-- not act on that process during the operator's TERM escalation.
scenario("a banner Force Quit stands unattended down", UNATTENDED_FREEZE, function(W)
  W.addProc(4242, "stubborn", 2000, { ignoreTerm = true })
  W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "stubborn") end)
  W.run(57)                         -- the TERM escalation overlaps the grace expiry
  local b = W.liveBanners()[1]
  check("banner-answer: the banner offers Force Quit", b ~= nil and b.attrs.hasActionButton == true, true)
  if b then W.clickBanner(b) end
  W.run(30)
  check("banner-answer: the operator's kill ran, and memwatch never froze it", W.signalsTo(4242), "TERM,KILL")
end)

-- ---- identity: a refusal on any surface rebinds every surface ----
-- (round 3) The menu finds the HUD's binding stale while the HUD is up: the
-- HUD rebinds to the process now holding the pid, so the next click acts
-- instead of refusing forever.
scenario("a menu refusal rebinds the visible HUD", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node") end)
  W.run(5)
  W.reusePid(4242, "node", 9000)
  W.grow(4242, 220)
  local item = W.menuItem("Force Quit node")
  if item then item.fn() end
  W.run(1)
  check("menu-rebind: the stale binding is refused", W.signalsTo(4242), "")
  check("menu-rebind: the visible HUD rebinds to the newcomer",
    runUntil(W, 15, function() return logHas(W, "hud-rebind:node(4242)") end), true)
  check("menu-rebind: the HUD is still up", W.hudShowing(), true)
  item = W.menuItem("Force Quit node")
  if item then item.fn() end
  W.run(10)
  check("menu-rebind: the next click acts on the newcomer", W.signalsTo(4242), "TERM")
end)

scenario("a banner refusal withdraws the stale banner", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node") end)
  W.run(6)
  local b = W.liveBanners()[1]
  check("banner-rebind: a bound banner is up", b ~= nil and b.attrs.hasActionButton == true, true)
  W.reusePid(4242, "node", 9000)
  W.grow(4242, 220)
  if b then W.clickBanner(b) end
  W.run(1)
  check("banner-rebind: nothing signaled on the stale identity", W.signalsTo(4242), "")
  check("banner-rebind: the stale banner is withdrawn", b ~= nil and b.withdrawn == true, true)
  check("banner-rebind: the HUD rebinds", runUntil(W, 15, function() return logHas(W, "hud-rebind:node(4242)") end), true)
end)

-- (round 3) A menu process row binds when the menu opens: a pid reused
-- between opening the menu and clicking is refused, and a row that cannot
-- be verified offers no action.
scenario("menu rows act only on the identity bound at open", nil, function(W)
  W.addProc(4242, "node", 6000)
  W.run(12)
  local function row(items)
    for _, it in ipairs(items) do
      if type(it.title) == "string" and it.title:find("(pid 4242)", 1, true) and it.menu then return it end
    end
  end
  local r = row(W.menuItems())
  check("rows: the process row is listed", r ~= nil, true)
  W.reusePid(4242, "node", 6000)
  if r then r.menu[2].fn() end
  W.run(10)
  check("rows: Force Quit refuses a pid reused after the menu opened", W.signalsTo(4242), "")
  if r then r.menu[1].fn() end
  W.run(3)
  check("rows: so does Freeze", W.signalsTo(4242), "")
  W.probeFails = true
  r = row(W.menuItems())
  check("rows: an unverifiable row offers no Force Quit", r ~= nil and r.menu[2].disabled == true, true)
  check("rows: and no Freeze", r ~= nil and r.menu[1].disabled == true, true)
  W.probeFails = false
  r = row(W.menuItems())
  if r then r.menu[2].fn() end
  W.run(10)
  check("rows: a row bound to the live process acts", W.signalsTo(4242), "TERM")
end)

-- ---- lifecycle: the run's end is the episode's end ----
-- (round 3) A restart in a sustained critical episode starts a fresh one:
-- the banner comes back with the HUD, past the old history and cooldown.
scenario("a restart starts a fresh episode", nil, function(W, mw)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(6)
  local before = W.liveBanners()[1]
  check("restart: a banner is up before the restart", before ~= nil, true)
  mw.start()
  W.run(1)
  check("restart: stop withdrew it", before ~= nil and before.withdrawn == true, true)
  check("restart: the restarted run raises the HUD again",
    runUntil(W, 30, function() return W.hudShowing() and bodyNames(W, "leaker") end), true)
  check("restart: and posts the banner again", runUntil(W, 30, function() return #W.liveBanners() == 1 end), true)
end)

-- (round 3) An action narrative from before a restart must not hide or
-- answer the restarted run's alert when it ends.
scenario("a narrative from a stopped run touches nothing", nil, function(W, mw)
  W.addProc(4242, "wedged", 2000, { ignoreTerm = true, unkillable = true })
  W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "wedged") end)
  W.run(5)
  W.click("kill")
  W.run(2)
  mw.start()                        -- restart mid-narrative
  runUntil(W, 30, function() return W.hudShowing() and bodyNames(W, "wedged (pid") end)
  W.run(25)                         -- the old kill fails and its narrative ends
  check("narrative: the restarted run's HUD is still up", W.hudShowing(), true)
  check("narrative: and still names the process", bodyNames(W, "wedged (pid 4242)"), true)
end)

-- (round 3 P1) A simulation during a real alert must not leave the real
-- banner's Force Quit up behind the synthetic HUD.
scenario("a simulation withdraws a real banner", nil, function(W, mw)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(6)
  local b = W.liveBanners()[1]
  check("simulate: a real, actionable banner is up", b ~= nil and b.attrs.hasActionButton == true, true)
  mw.simulate(5)
  W.run(1)
  check("simulate: the real banner is withdrawn", b ~= nil and b.withdrawn == true, true)
end)

-- ---- surfaces: the degraded page lasts as long as the condition ----
-- (round 3) A 30-second page every 300 s reached an absent operator about
-- one time in ten. It now stays up, as one page, and goes on recovery.
scenario("the degraded page stays until recovery", '{"alerts":false}', function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  W.run(10)
  W.samplerDelay = 1e6              -- the sampler fork starves
  runUntil(W, 80, function() return #W.notices("memwatch degraded") >= 1 end)
  W.run(240)
  local live = 0
  for _, n in ipairs(W.notices("memwatch degraded")) do if not n.withdrawn then live = live + 1 end end
  check("degraded: exactly one page is up minutes later", live, 1)
  W.samplerDelay = 0.05
  for _, t in ipairs(W.timers) do        -- deliver the starved sample now
    if not t.stopped and t.kind == "after" and t.at > W.now + 1e5 then t.at = W.now + 0.05 end
  end
  W.run(30)
  live = 0
  for _, n in ipairs(W.notices("memwatch degraded")) do if not n.withdrawn then live = live + 1 end end
  check("degraded: the page goes once the sampler recovers", live, 0)
end)

scenario("a toggle that cannot be saved says so", '{"unattended":"off","remoteServer":', function(W, mw)
  mw.setAlertsEnabled(false)
  local said = false
  for _, a in ipairs(W.alerts) do if a.text:find("couldn't save", 1, true) then said = true end end
  check("toggle: the operator is told the setting lasts only until reload", said, true)
end)

-- ---- runs: a menu action's outcome belongs to the run that started it ----
-- (round 4) The action finishes on its verified identity after a restart,
-- but its outcome no longer routes to the alert: the new run's alert for
-- the same process stays up.
scenario("an earlier run's menu action leaves the new run's alert alone", nil, function(W, mw)
  W.addProc(4242, "wedged", 2000, { unkillable = true, ignoreTerm = true })
  W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "wedged (pid") end)
  W.run(5)
  local row = W.menuItem("wedged")
  local forceQuit = row and row.menu and row.menu[2]
  check("runs: the row offers Force Quit", forceQuit ~= nil and forceQuit.disabled == nil, true)
  forceQuit.fn()                    -- TERM now; KILL and the verdict seconds later
  W.run(1)
  mw.stop()
  mw.start()
  check("runs: the new run raises its own alert",
    runUntil(W, 10, function() return W.hudShowing() and bodyNames(W, "wedged (pid") end), true)
  W.run(20)
  check("runs: the earlier action still finished on its identity", W.signalsTo(4242), "TERM,KILL")
  check("runs: its outcome did not take the new run's alert down", W.hudShowing(), true)
end)

-- (round 4) A menu action the process survives answers the HUD naming it
-- the way the HUD's own action would: snoozed, back after the cooldown.
scenario("a menu Force Quit the process survives snoozes its HUD", nil, function(W)
  W.addProc(4242, "wedged", 2000, { unkillable = true, ignoreTerm = true })
  W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "wedged (pid") end)
  W.run(5)
  local row = W.menuItem("wedged")
  row.menu[2].fn()
  W.run(20)
  check("survived: the HUD naming it is snoozed", W.hudShowing(), false)
  check("survived: and comes back after the cooldown",
    runUntil(W, 90, function() return W.hudShowing() and bodyNames(W, "wedged (pid") end), true)
end)

-- (round 4) A diagnostic at any level is a run boundary: an elevated
-- self-test during a real critical episode ends that episode, so its banner
-- and history do not outlive the run that posted them.
scenario("an elevated self-test ends the live episode", nil, function(W, mw)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  check("elevated-test: the real episode has its banner",
    runUntil(W, 40, function() return #W.liveBanners() == 1 end), true)
  mw.test("elevated", 5)
  check("elevated-test: the live episode's banner is withdrawn", #W.liveBanners(), 0)
  check("elevated-test: and its history cleared", mw.debug().bannerRecords, 0)
  check("elevated-test: the real episode posts afresh after the test",
    runUntil(W, 60, function() return #W.liveBanners() == 1 end), true)
end)

-- (round 4) With the HUD closed, the menu's offender Force Quit acts on
-- the banner's binding, as the banner's own button would: a same-name
-- process that took the pid since is refused, and the refusal rebinds.
scenario("the menu offender acts on the banner's binding", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.run(6)
  local b = W.liveBanners()[1]
  check("menu-banner: the banner is bound", b ~= nil and b.attrs.hasActionButton == true, true)
  W.click("close")                  -- the HUD is down; the banner stays
  W.reusePid(4242, "node", 9000)
  W.grow(4242, 220)
  W.run(6)                          -- a sample: a fresh offender table, unbound
  local item = W.menuItem("Force Quit node")
  check("menu-banner: the offender item is offered", item ~= nil and item.fn ~= nil, true)
  item.fn()
  W.run(2)
  check("menu-banner: a pid reused since the banner bound is refused", W.signalsTo(4242), "")
  item = W.menuItem("Force Quit node")
  item.fn()
  W.run(10)
  check("menu-banner: once rebound, the next click acts", W.signalsTo(4242):find("TERM", 1, true) ~= nil, true)
end)

-- ---- the frozen ledger: each writer owns only its own entry ----
-- (round 5) A STOP that could not be sent leaves no ledger entry: nothing
-- to protect, and a pending one would swallow the retry.
scenario("a STOP that was never sent leaves no entry", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker (pid") end)
  W.run(5)
  W.killRaises = true               -- the STOP send fails
  W.click("freeze")
  W.killRaises, W.probeFails = false, true   -- and its verifier cannot probe
  W.run(1)
  W.probeFails = false
  W.run(5)
  check("unsent: no ledger entry is left", W.menuItem("   leaker"), nil)
  W.click("freeze")
  W.run(2)
  check("unsent: the retry sends its STOP", W.signalsTo(4242), "STOP")
end)

-- (round 5) A reload while a freeze is still being verified keeps its
-- entry: the STOP lands after the reload, and Resume must be there.
scenario("a reload keeps a freeze still being verified", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker (pid") end)
  W.run(5)
  W.stopDelay = 5                   -- the STOP lands 5 s after it is sent
  W.click("freeze")
  W.run(0.2)
  W.reloadState()
  F.load(W, nil, { keepHome = true })
  W.run(8)
  check("pending-reload: the process stopped after the reload", W.procs[4242].state, "T")
  check("pending-reload: and the menu still offers its Resume", W.menuItem("   leaker") ~= nil, true)
end)

-- (round 5) A resume's verifier, finding the pid taken over, drops only
-- the resumed process's entry, never a newer freeze of the pid's next
-- process.
scenario("a resume never drops a newer process's freeze", nil, function(W, mw)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.run(5)
  W.click("freeze")
  W.run(6)
  local row = W.menuItem("   node")
  local resume = row and row.menu and row.menu[1]
  check("resume-race: the frozen row offers Resume", resume ~= nil and resume.fn ~= nil, true)
  resume.fn()                       -- CONT now; its verifier in 0.5 s
  W.reusePid(4242, "node", 2000)    -- the resumed process exits; a newcomer takes the pid
  W.run(0.2)
  mw.freezePid(4242, "node")        -- and is frozen
  W.run(0.4)                        -- the resume verifier finds the pid taken over
  W.probeFails = true               -- and the newcomer's freeze verifier cannot probe
  W.run(0.5)
  W.probeFails = false
  check("resume-race: the newcomer is stopped", W.procs[4242].state, "T")
  check("resume-race: and keeps its ledger entry (Resume offered)", W.menuItem("   node") ~= nil, true)
end)

-- (round 5) A kill whose target exits while another process takes its
-- pid is "replaced": the newcomer is a new question, never marked gone.
scenario("a kill whose pid is taken over rebinds", nil, function(W)
  W.addProc(4242, "node", 2000, { ignoreTerm = true })
  W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.run(5)
  W.click("kill")                   -- TERM is ignored; the escalation waits 7 s
  W.run(2)
  W.reusePid(4242, "node", 2000)    -- it exits, and a newcomer takes the pid
  W.grow(4242, 220)
  W.run(20)
  check("replaced: the outcome is a rebind, not done", logHas(W, "answered:rebind:node(4242):replaced"), true)
  check("replaced: no KILL to the newcomer", W.signalsTo(4242), "TERM")
  check("replaced: the newcomer is alerted at once",
    runUntil(W, 6, function() return W.hudShowing() and bodyNames(W, "node (pid") end), true)
end)

-- (round 5) A frozen process continued for a Force Quit whose TERM cannot
-- be sent is stopped again: its ledger entry stays true.
scenario("a failed TERM after CONT stops the process again", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker (pid") end)
  W.run(5)
  W.click("freeze")
  W.run(6)
  local row = W.menuItem("   leaker")
  local fq = row and row.menu and row.menu[2]
  W.sendFails = { TERM = true }
  fq.fn()
  W.sendFails = nil
  W.run(2)
  check("re-stop: CONT then STOP went out, no TERM", W.signalsTo(4242), "STOP,CONT,STOP")
  check("re-stop: it is stopped again", W.procs[4242].state, "T")
  check("re-stop: its ledger entry stays", W.menuItem("   leaker") ~= nil, true)
end)

-- ---- narratives: a hold that never ends is released ----
-- A narrative whose next step never runs (the run loop stalls past its
-- escalation) ends without its last update. The alert must not stay
-- frozen in that hold.
scenario("a stuck narrative hold is released", nil, function(W)
  W.addProc(4242, "leaker", 2000, { ignoreTerm = true })
  W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(5)
  W.timersStall = true              -- the escalation after TERM never runs
  W.click("kill")
  W.timersStall = false
  W.run(5)
  check("hold: the narrative is stuck mid-action", W.hudBody():find("terminating", 1, true) ~= nil, true)
  check("hold: the alert comes back to live numbers after the deadline",
    runUntil(W, 60, function() return W.hudShowing() and bodyNames(W, "leaker (pid 4242)") end), true)
  W.click("kill")
  W.run(20)
  check("hold: and acts again", W.signalsTo(4242), "TERM,TERM,KILL")
end)

-- (round 4) A signal whose fork fails sent nothing: the action says so at
-- once and ends, instead of holding the alert until the deadline.
scenario("a signal that cannot be sent ends its narrative", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(5)
  W.killRaises = true               -- the probe answers; the kill itself cannot fork
  W.click("kill")
  W.killRaises = false
  W.run(1)
  check("send: the narrative says nothing was signaled",
    W.hudBody():find("couldn't send TERM", 1, true) ~= nil, true)
  check("send: the alert stands, back on live numbers well before the hold deadline",
    runUntil(W, 10, function() return W.hudShowing() and bodyNames(W, "leaker (pid 4242)") end), true)
  W.click("kill")
  W.run(10)
  check("send: and the next click acts", W.signalsTo(4242), "TERM")
end)

-- ---- round 4: interactions the design pass introduced ----
-- (round 4 P1) The sweep runs in every state now, in the same tick as an
-- unattended freeze. A STOP that takes effect a moment later must not
-- lose its ledger entry before its verifier runs.
scenario("a freeze being verified survives the sweep", UNATTENDED_FREEZE, function(W)
  W.stopDelay = 0.2
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  runUntil(W, 90, function() return W.signalsTo(4242) ~= "" end)
  W.run(3)
  check("pending: the process is stopped", W.procs[4242].state, "T")
  check("pending: and the ledger still holds it (Resume is offered)", W.menuItem("   leaker") ~= nil, true)
  W.kern = 1
  W.run(130)                        -- calm sweeps re-check it
  check("pending: still held after the sweeps", W.menuItem("   leaker") ~= nil, true)
end)

-- (round 4 P1) A same-name process reusing an earlier offender's pid gets
-- its own grace when the alert comes back to that pid, not the old one's.
scenario("a reused pid's newcomer gets its own grace", UNATTENDED_FREEZE, function(W)
  W.addProc(4242, "node", 2000)
  local fastA = W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid 4242)") end)
  W.run(45)                         -- most of node's grace
  W.addProc(5151, "bigger", 2000)   -- a faster runaway takes the alert
  W.grow(5151, 900)
  fastA:stop()
  runUntil(W, 30, function() return bodyNames(W, "bigger") end)
  W.procs[5151].state = "T"         -- held still by the operator elsewhere
  W.reusePid(4242, "node", 3000)    -- node exits; a same-name process takes its pid
  W.grow(4242, 1500)
  local back = runUntil(W, 60, function() return bodyNames(W, "node (pid 4242)") end)
  check("reuse-grace: the alert comes back to the pid", back, true)
  local backAt = W.now
  runUntil(W, 120, function() return W.signalsTo(4242) ~= "" end)
  check("reuse-grace: the newcomer is frozen in the end", W.signalsTo(4242), "STOP")
  check("reuse-grace: only after a grace of its own", W.sigs[#W.sigs].t - backAt >= 55, true)
end)

-- (round 4 P1) A STOP that went out but could not be verified changed a
-- process: the muted operator is told, truthfully, and how to check.
scenario("an unconfirmed unattended freeze is announced", '{"unattended":"freeze","alerts":false}', function(W)
  W.onSignal = function(sig) if sig == "STOP" then W.probeFails = true end end
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 90, function() return W.signalsTo(4242) ~= "" end)
  W.run(3)
  W.onSignal = nil
  local n = W.notices("memwatch unattended freeze")[1]
  check("unconfirmed: a receipt is posted though alerts are muted", n ~= nil, true)
  check("unconfirmed: it says the result is unverified",
    n ~= nil and (n.attrs.informativeText or ""):find("can't verify", 1, true) ~= nil, true)
  W.probeFails = false
end)

-- ---- round 5: what round 4 found ----
-- A ps killed mid-reply can leave the control row and a cut-off target
-- line: that proves nothing, so nothing is concluded or signaled.
scenario("a ps cut off by a signal is not an exit", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(5)
  W.probeSignaled = true
  W.click("freeze")
  W.run(8)
  W.probeSignaled = false
  check("cut-off: nothing was signaled", W.signalsTo(4242), "")
  check("cut-off: the alert stands", W.hudShowing() and bodyNames(W, "leaker"), true)
  W.click("freeze")
  W.run(3)
  check("cut-off: the retry acts", W.signalsTo(4242), "STOP")
end)

-- (round 4) An escalation probe that cannot run once is retried; a
-- survivor that never got its KILL is not reported as unkillable.
scenario("an unverifiable escalation is retried", nil, function(W)
  W.addProc(4242, "stubborn", 2000, { ignoreTerm = true })
  W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "stubborn") end)
  W.run(5)
  W.onSignal = function(sig)
    if sig == "TERM" then
      W.probeFails = true
      W.addTimer("after", 8, nil, function() W.probeFails = false end)
    end
  end
  W.click("kill")
  W.run(25)
  W.onSignal = nil
  check("escalate-retry: KILL went out once the probe answered", W.signalsTo(4242), "TERM,KILL")
  check("escalate-retry: and it is gone", W.procs[4242] == nil, true)
end)

-- (round 4) A kill's verify that finds a newer process at the pid must not
-- drop that process's own frozen-ledger entry.
scenario("a kill never drops a newer process's ledger entry", nil, function(W)
  W.addProc(4242, "node", 2000, { ignoreTerm = true })
  W.grow(4242, 220)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node") end)
  W.run(5)
  W.click("kill")                   -- TERM to the first node (it ignores TERM)
  W.run(2)
  W.reusePid(4242, "node", 1000)    -- it exits; a newer node takes the pid
  W.run(1)
  local r
  for _, it in ipairs(W.menuItems()) do
    if type(it.title) == "string" and it.title:find("(pid 4242)", 1, true) and it.menu then r = it end
  end
  if r then r.menu[1].fn() end      -- the operator freezes the newer node
  W.run(20)                         -- the first kill's escalate and verify run
  check("newer-ledger: the newer node is frozen", W.procs[4242] and W.procs[4242].state, "T")
  check("newer-ledger: and still listed under Frozen by memwatch", W.menuItem("   node") ~= nil, true)
end)

if fails == 0 then
  print("\nALL PASS")
else
  print("\n" .. fails .. " FAILED")
  os.exit(1)
end

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
  check("no-result: it says the result has not come back",
    n[1] ~= nil and (n[1].attrs.informativeText or ""):find("has not come back", 1, true) ~= nil, true)
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

-- (round 5) A kill that refuses (the process exited between the identity
-- check and the TERM) sent nothing, and nothing is claimed: no
-- "terminated" for an exit memwatch did not cause.
scenario("a TERM that kill refuses is not claimed", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker (pid") end)
  W.run(5)
  W.vanishAfterProbe = 4242         -- it exits right after the click's probe
  W.click("kill")
  W.run(1)
  check("refused-send: the narrative says nothing was signaled",
    W.hudBody():find("nothing was signaled", 1, true) ~= nil, true)
  W.run(20)                         -- past any escalation and verify
  check("refused-send: no termination is claimed", logHas(W, "kill-done:leaker(4242)"), false)
end)

-- ---- actions in flight ----
-- (round 5) A run loop that stalls past the hold deadline: the deadline
-- receipt goes out, but the action is still in flight, so no second action
-- starts on the process, and when the outcome arrives it replaces that
-- receipt: one live receipt for one action.
scenario("a late outcome replaces its deadline receipt", '{"unattended":"freeze","alerts":false}', function(W)
  W.onSignal = function(sig) if sig == "STOP" then W.timerLag = 70 end end
  leaker(W, 4242)
  W.run(12)
  W.kern = 4
  runUntil(W, 120, function() return W.signalsTo(4242) ~= "" end)
  W.onSignal, W.timerLag = nil, 0
  W.run(50)
  local function live()
    local out = {}
    for _, n in ipairs(W.notices("memwatch unattended")) do
      if not n.withdrawn then out[#out + 1] = n end
    end
    return out
  end
  check("late: the deadline receipt is up while the outcome is late", #live(), 1)
  W.run(40)                         -- the verifier finally runs
  local l = live()
  check("late: one live receipt in the end", #l, 1)
  check("late: and it is the real outcome",
    l[1] ~= nil and (l[1].attrs.informativeText or ""):find("frozen", 1, true) ~= nil, true)
  check("late: no second action while the first was in flight", W.signalsTo(4242), "STOP")
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

-- ---- round 6: the lifecycle rules (docs/alert-lifecycle.md) ----
-- A node frozen from the HUD and shown in the menu's frozen rows.
local function frozenNode(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.run(5)
  W.click("freeze")
  W.run(3)
  return W.procs[4242] and W.procs[4242].state
end
local function frozenRowAction(W, name, title)
  local row = W.menuItem("   " .. name)
  for _, it in ipairs(row and row.menu or {}) do
    if type(it.title) == "string" and it.title:find(title, 1, true) and it.fn then return it.fn end
  end
end
local function liveUnattendedReceipts(W)
  local out = {}
  for _, n in ipairs(W.notices("memwatch unattended")) do
    if not n.withdrawn then out[#out + 1] = n end
  end
  return out
end

-- Rule 1: the STOP that re-freezes a process whose quit could not be sent
-- is a new freeze, verified afresh: a same-name newcomer that took the pid
-- after the CONT is never stopped.
scenario("a quit whose TERM cannot be sent re-freezes only the process it verified", nil, function(W)
  check("refreeze: the node is frozen", frozenNode(W), "T")
  local quit = frozenRowAction(W, "node", "Force Quit")
  check("refreeze: the frozen row offers Force Quit", quit ~= nil, true)
  W.sendFails = { TERM = true }
  W.onSignal = function(sig) if sig == "CONT" then W.reusePid(4242, "node", 500) end end
  quit()
  W.onSignal = nil
  W.run(5)
  W.sendFails = nil
  check("refreeze: the newcomer on the pid keeps running", W.procs[4242] and W.procs[4242].state, "S")
  check("refreeze: and was never sent a STOP", W.signalsTo(4242), "STOP,CONT")
  check("refreeze: the old process's entry is gone", W.menuItem("   node"), nil)
end)

scenario("a quit whose TERM cannot be sent freezes the same process again", nil, function(W)
  check("refreeze-same: the node is frozen", frozenNode(W), "T")
  local quit = frozenRowAction(W, "node", "Force Quit")
  W.sendFails = { TERM = true }
  quit()
  W.run(5)
  W.sendFails = nil
  check("refreeze-same: the same node is stopped again (control)", W.procs[4242] and W.procs[4242].state, "T")
  check("refreeze-same: and still offered for Resume", frozenRowAction(W, "node", "Resume") ~= nil, true)
end)

-- Rules 1 and 2: that re-freeze is a pending entry like any freeze, so a
-- reload before its STOP lands keeps it, and Resume is still there.
scenario("a re-freeze survives a reload before its STOP lands", nil, function(W)
  W.stopDelay = 0.2
  check("refreeze-reload: the node is frozen", frozenNode(W), "T")
  local quit = frozenRowAction(W, "node", "Force Quit")
  W.sendFails, W.stopDelay = { TERM = true }, 5
  quit()
  W.run(0.2)
  W.reloadState()
  F.load(W, nil, { keepHome = true })
  W.sendFails = nil
  W.run(8)
  check("refreeze-reload: the node stopped after the reload", W.procs[4242] and W.procs[4242].state, "T")
  check("refreeze-reload: and the menu still offers its Resume", frozenRowAction(W, "node", "Resume") ~= nil, true)
end)

-- Rule 2: a freeze whose STOP could not be sent, interrupted by a reload
-- before its verifier ran, is not kept: the process runs, unhidden.
scenario("a freeze whose STOP was never sent is forgotten at reload", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.run(5)
  W.sendFails = { STOP = true }
  W.click("freeze")
  W.run(0.1)
  W.reloadState()
  F.load(W, nil, { keepHome = true })
  W.sendFails = nil
  W.run(3)
  check("unsent-reload: the process runs", W.procs[4242] and W.procs[4242].state, "S")
  check("unsent-reload: and is not listed as frozen", W.menuItem("   node"), nil)
end)

-- Rule 1: the CONT that undoes a STOP which reached the pid's next process
-- goes to a process seen stopped; if it cannot be sent, that process stays
-- in the ledger so it can be resumed.
scenario("a STOP that reached the pid's next process is undone", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.run(5)
  W.reuseAfterProbe = 4242          -- the newcomer takes the pid between the probe and the STOP
  W.click("freeze")
  W.run(3)
  check("abort: the newcomer was continued (control)", W.procs[4242] and W.procs[4242].state, "S")
end)

scenario("a newcomer left stopped by a failed undo stays resumable", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.run(5)
  W.reuseAfterProbe = 4242
  W.sendFails = { CONT = true }     -- the undo cannot be sent
  W.click("freeze")
  W.run(3)
  W.sendFails = nil
  check("abort-fail: the newcomer is still stopped", W.procs[4242] and W.procs[4242].state, "T")
  check("abort-fail: and the menu offers its Resume", frozenRowAction(W, "node", "Resume") ~= nil, true)
  check("abort-fail: the failure is logged", logHas(W, "freeze-abort-cont-failed:node(4242)"), true)
  local row = W.menuItem("   node")
  check("abort-fail: its size is unknown, never the size of the process the freeze meant",
    row ~= nil and row.title:find("size unknown", 1, true) ~= nil, true)
  local resume = frozenRowAction(W, "node", "Resume")
  if resume then resume() end
  W.run(2)
  check("abort-fail: Resume continues it", W.procs[4242] and W.procs[4242].state, "S")
end)

-- Rule 4: an unattended action whose narrative never finishes releases its
-- in-flight hold one hold window after its deadline receipt; until then no
-- second action starts.
scenario("an action that never finishes releases its hold after a backstop", UNATTENDED_KILL, function(W)
  W.frontmost = { name = "Terminal", pid = 760 }   -- another app is in front: terminate is allowed
  leaker(W, 4242, "node")
  W.procs[4242].ignoreTerm = true
  -- From the TERM on, one-shot timers stall: its escalation and verifier
  -- never run.
  W.onSignal = function(sig) if sig == "TERM" then W.timersStall = true end end
  W.run(12)
  W.kern = 4
  runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
  W.onSignal = nil
  check("backstop: the first action sent its TERM", W.signalsTo(4242), "TERM")
  W.run(80)
  check("backstop: no second action while in flight", W.signalsTo(4242), "TERM")
  W.run(160)
  W.timersStall = false
  check("backstop: the hold was released", logHas(W, "unattended-hold-released:terminate:node(4242)"), true)
  check("backstop: and the process could be acted on again", select(2, W.signalsTo(4242):gsub("TERM", "")) >= 2, true)
end)

-- The denied case in terminate mode (a freeze's pending entry would hide
-- the process anyway): one TERM while its narrative is slow.
scenario("no second terminate starts while the first is in flight", UNATTENDED_KILL, function(W)
  W.frontmost = { name = "Terminal", pid = 760 }   -- another app is in front: terminate is allowed
  leaker(W, 4242, "node")
  W.procs[4242].ignoreTerm = true
  W.onSignal = function(sig) if sig == "TERM" then W.timerLag = 400 end end
  W.run(12)
  W.kern = 4
  runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
  W.onSignal = nil
  W.run(80)
  W.timerLag = 0
  check("in-flight: one TERM while the first action is in flight", W.signalsTo(4242), "TERM")
end)

-- Rule 5: once the deadline receipt is up, any final outcome replaces it,
-- even one never announced on time (here the process exits before the late
-- verifier runs).
scenario("a late outcome that is not announced on time still replaces its receipt",
         '{"unattended":"freeze","alerts":false}', function(W)
  W.onSignal = function(sig) if sig == "STOP" then W.timerLag = 70 end end
  leaker(W, 4242, "node")
  W.procs[4242].unstoppable = true
  W.run(12)
  W.kern = 4
  runUntil(W, 120, function() return W.signalsTo(4242) ~= "" end)
  W.onSignal, W.timerLag = nil, 0
  W.run(50)
  check("late-other: the deadline receipt is up", #liveUnattendedReceipts(W), 1)
  W.procs[4242] = nil               -- it exits before the late verifier runs
  W.run(40)
  local l = liveUnattendedReceipts(W)
  check("late-other: one live receipt in the end", #l, 1)
  check("late-other: and it says what happened",
    l[1] ~= nil and (l[1].attrs.informativeText or ""):find("exited", 1, true) ~= nil, true)
end)

-- Rule 6: a HUD whose process was answered from another surface goes, even
-- when it never bound (its probe failed at the raise).
scenario("a HUD goes when its process is frozen from the menu, bound or not", nil, function(W, mw)
  leaker(W, 4242, "node")
  W.run(12)
  W.probeFails = true               -- the raise cannot bind
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node") end)
  W.probeFails = false
  W.run(1)
  local row = W.menuItem("node")   -- the menu binds its rows when it opens
  local freeze = row and row.menu and row.menu[1]
  check("retire: the menu offers the offender's Freeze", freeze ~= nil and freeze.fn ~= nil, true)
  if freeze then freeze.fn() end
  W.run(12)
  check("retire: the process is frozen", W.procs[4242] and W.procs[4242].state, "T")
  check("retire: and the HUD has gone", W.hudShowing(), false)
end)

-- Rule 7: a frozen mark never holds for a process with another name, and
-- a mark growth released stays released.
scenario("a frozen mark never hides a process with another name", nil, function(W)
  check("other-name: the node is frozen", frozenNode(W), "T")
  W.procs[4242] = nil
  -- A steady process takes the pid (state R: running, and in the fake only
  -- S grows), so no growth can reveal it: only its name can.
  W.addProc(4242, "python", 1000, { state = "R" })
  W.probeFails = true               -- the sweep cannot prove the mark stale
  local shown = runUntil(W, 120, function() return W.hudShowing() and bodyNames(W, "python") end)
  W.probeFails = false
  check("other-name: the newcomer is named while probes fail", shown, true)
end)

scenario("a mark that growth released stays released", nil, function(W)
  check("released: the node is frozen", frozenNode(W), "T")
  W.reusePid(4242, "node", 2000)
  local g = W.grow(4242, 220)
  W.probeFails = true
  local shown = runUntil(W, 120, function() return W.hudShowing() and bodyNames(W, "node (pid 4242)") end)
  check("released: the climbing newcomer is surfaced", shown, true)
  g:stop()                          -- it plateaus (state R: running, and in
  W.procs[4242].state = "R"         -- the fake only S grows)
  W.run(30)
  W.probeFails = false
  check("released: a plateau does not hide it again", W.hudShowing() and bodyNames(W, "node (pid 4242)"), true)
end)

-- Rule 2: an entry an older version wrote without a start time is dropped
-- at reload and named in a notice: nothing ties it to the process it froze
-- (a step across the reload shows nowhere, so its freeze stamp cannot be
-- dated against this clock), and nothing is ever signaled through it.
-- frozenAtOffset: when the old entry says it was frozen, relative to the
-- process's own start (positive: after it started).
-- opts.lstart: the start time the process shows from then on; opts.probeScript:
-- the probes' outcomes during the reload.
local function legacyEntryWorld(W, state, frozenAtOffset, probeFails, opts)
  leaker(W, 4242, "node")
  W.procs[4242].state = state
  W.run(6)
  -- Dated from the fake's own start stamp read with hand-written fields,
  -- never through the parser under test.
  local mm, ss = W.procs[4242].lstart:match("^Mon Oct 12 10:(%d+):(%d+) 2026$")
  local started = os.time({ year = 2026, month = 10, day = 12, hour = 10, min = tonumber(mm), sec = tonumber(ss) })
  local f = assert(io.open(W.home .. "/projects/memwatch/memwatch-frozen.json", "w"))
  f:write(string.format('[{"pid":4242,"name":"node","weightMB":0,"frozenAt":%d}]\n',
    started + (frozenAtOffset or 60)))
  f:close()
  if opts and opts.lstart then W.procs[4242].lstart = opts.lstart end
  if opts and opts.wallOffset then W.wallOffset = opts.wallOffset end
  W.reloadState()
  W.probeFails = probeFails
  W.probeScript = opts and opts.probeScript
  F.load(W, nil, { keepHome = true })
  W.run(3)
  W.probeFails, W.probeScript = false, nil
end
for _, case in ipairs({
  { how = "stopped, frozen after it started", state = "T", offset = 60 },
  { how = "stopped, frozen before it started", state = "T", offset = -60 },
  { how = "stopped, in the freeze's own second", state = "T", offset = 0 },
  { how = "running", state = "S", offset = 60 },
  { how = "unprobed", state = "T", offset = 60, probeFails = true },
}) do
  scenario("an old entry without a start time is dropped and named (" .. case.how .. ")", nil, function(W)
    legacyEntryWorld(W, case.state, case.offset, case.probeFails)
    check("legacy (" .. case.how .. "): not listed as frozen", W.menuItem("   node"), nil)
    check("legacy (" .. case.how .. "): the drop is logged", logHas(W, "frozen-reconcile-drop:node(4242):no-start-time"), true)
    check("legacy (" .. case.how .. "): the notice names it",
      #W.notices("memwatch: dropped "), 1)
    check("legacy (" .. case.how .. "): nothing was signaled", W.signalsTo(4242), "")
  end)
end
-- Many old entries: the notice says how many, and each is its own log line.
scenario("many old entries without a start time are counted in one notice", nil, function(W)
  leaker(W, 4242, "node")
  W.run(6)
  local rows = {}
  for i = 1, 12 do
    rows[#rows + 1] = string.format('{"pid":%d,"name":"some-long-program-name-%02d","weightMB":0,"frozenAt":%d}',
      5000 + i, i, math.floor(W.now) - 60)
  end
  local f = assert(io.open(W.home .. "/projects/memwatch/memwatch-frozen.json", "w"))
  f:write("[" .. table.concat(rows, ",") .. "]\n")
  f:close()
  W.reloadState()
  F.load(W, nil, { keepHome = true })
  W.run(3)
  local notes = W.notices("memwatch: dropped 12 old frozen entries")
  check("legacy-many: one notice, with the count", #notes, 1)
  local sub = notes[1] and notes[1].attrs.subTitle or ""
  check("legacy-many: the names are cut to fit, and say how many", sub:find("(12 in all)", 1, true) ~= nil, true)
  local logged = 0
  for i = 1, 12 do
    if logHas(W, string.format("frozen-reconcile-drop:some-long-program-name-%02d(%d):no-start-time", i, 5000 + i)) then
      logged = logged + 1
    end
  end
  check("legacy-many: each drop is its own log line", logged, 12)
end)
-- (round 11) An entry an earlier build bound by name at a reload carries a
-- start time, but not one recorded at its STOP: it is dropped and named too.
scenario("an entry an earlier build bound by name is dropped and named", nil, function(W)
  leaker(W, 4242, "node")
  W.procs[4242].state = "T"
  W.run(6)
  local f = assert(io.open(W.home .. "/projects/memwatch/memwatch-frozen.json", "w"))
  f:write(string.format('[{"pid":4242,"name":"node","lstart":"%s","weightMB":0,"frozenAt":%d,"adopted":true}]\n',
    W.procs[4242].lstart, math.floor(W.now) - 30))
  f:close()
  W.reloadState()
  F.load(W, nil, { keepHome = true })
  W.run(3)
  check("adopted: not listed as frozen", W.menuItem("   node"), nil)
  check("adopted: the drop is logged as bound by name", logHas(W, "frozen-reconcile-drop:node(4242):bound-by-name"), true)
  check("adopted: the notice names it", #W.notices("memwatch: dropped "), 1)
  check("adopted: nothing was signaled", W.signalsTo(4242), "")
end)
scenario("an entry with a start time is kept at reload (control)", nil, function(W)
  leaker(W, 4242, "node")
  W.procs[4242].state = "T"
  W.run(6)
  local f = assert(io.open(W.home .. "/projects/memwatch/memwatch-frozen.json", "w"))
  f:write(string.format('[{"pid":4242,"name":"node","lstart":"%s","weightMB":0,"frozenAt":%d}]\n',
    W.procs[4242].lstart, math.floor(W.now) - 30))
  f:close()
  W.reloadState()
  F.load(W, nil, { keepHome = true })
  W.run(3)
  check("legacy-control: kept, with its Resume", frozenRowAction(W, "node", "Resume") ~= nil, true)
  check("legacy-control: nothing named", #W.notices("memwatch: dropped "), 0)
end)

-- ---- round 7 ----
-- Rule 1: the undo is decided from the verifier's own probe row, so a later
-- probe failing cannot strand the newcomer the STOP reached.
scenario("the undo of a STOP that reached a newcomer needs no second probe", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.run(5)
  W.reuseAfterProbe = 4242
  W.probeScript = { "ok", "ok", "fail", "fail", "fail" }   -- the freeze's probe and the verifier's answer; later ones fail
  W.click("freeze")
  W.run(3)
  W.probeScript = nil
  check("undo: the newcomer was continued", W.procs[4242] and W.procs[4242].state, "S")
  check("undo: STOP then CONT", W.signalsTo(4242), "STOP,CONT")
end)

scenario("the undo goes only to a newcomer seen stopped", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.run(5)
  W.reuseAfterProbe = { pid = 4242, extra = { unstoppable = true } }   -- the STOP does nothing to it
  W.click("freeze")
  W.run(3)
  check("seen-stopped: a newcomer that never stopped gets no CONT", W.signalsTo(4242), "STOP")
end)

-- Rule 4: an action released by the backstop never escalates over the
-- newer action that took the process.
scenario("a released action's late escalation never overrides a newer action", UNATTENDED_KILL, function(W)
  W.frontmost = { name = "Terminal", pid = 760 }
  leaker(W, 4242, "node")
  W.procs[4242].ignoreTerm = true
  W.onSignal = function(sig) if sig == "TERM" then W.timersStall = true end end
  W.run(12)
  W.kern = 4
  runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
  W.onSignal = nil
  -- The process comes to the front: the next action is capped to a freeze.
  W.frontmost = { name = "node", pid = 4242 }
  runUntil(W, 300, function() return W.signalsTo(4242):find("STOP", 1, true) ~= nil end)
  check("supersede: the newer action froze it", W.signalsTo(4242), "TERM,STOP")
  W.releaseStalled()                -- the first action's escalation finally runs
  W.run(30)
  check("supersede: the first action sent no KILL over it", W.signalsTo(4242):find("KILL", 1, true), nil)
  check("supersede: the process stays frozen", W.procs[4242] and W.procs[4242].state, "T")
  check("supersede: the skipped escalation is logged", logHas(W, "kill-escalate-superseded:node(4242)"), true)
  check("supersede: the first action's late outcome does not write over the HUD",
    W.hudBody():find("ignored TERM", 1, true), nil)
  local said = false
  for _, n in ipairs(W.notices("memwatch unattended terminate")) do
    if (n.attrs.informativeText or ""):find("KILL withheld, released after its result did not come back", 1, true) then said = true end
  end
  check("supersede: its receipt says the KILL was withheld, and why", said, true)
end)

-- Rule 6: a freeze its own verifier could not confirm stops counting as
-- pending when its window ends; the stopped process is then answered and
-- the HUD goes (probes answering again).
scenario("an unconfirmed freeze retires the HUD when its window ends", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.run(5)
  W.onSignal = function(sig) if sig == "STOP" then W.probeFails = true end end
  W.click("freeze")
  W.run(1)
  W.onSignal, W.probeFails = nil, false
  check("unconfirmed: the process is stopped", W.procs[4242] and W.procs[4242].state, "T")
  local gone = runUntil(W, 150, function() return not W.hudShowing() end)
  check("unconfirmed: the HUD goes once the window has ended", gone, true)
end)

-- With probes failing throughout, the sweep cannot settle it; the freeze
-- stops counting as pending when its window ends, and a stopped process
-- (no growth) is then answered.
scenario("a freeze past its window no longer holds the HUD as pending", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.run(5)
  W.onSignal = function(sig) if sig == "STOP" then W.probeFails = true end end
  W.click("freeze")
  W.onSignal = nil
  W.run(10)
  check("expiry: still pending inside its window, the HUD stands", W.hudShowing(), true)
  local gone = runUntil(W, 60, function() return not W.hudShowing() end)
  W.probeFails = false
  check("expiry: after the window the stopped process is answered", gone, true)
end)

-- Rule 2: a freeze whose STOP never went out is never adopted at a reload,
-- even after its window, and even if something else has stopped it.
scenario("an entry whose STOP never went out is dropped at any later reload", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.run(5)
  W.sendFails = { STOP = true }
  W.click("freeze")
  W.run(0.1)
  W.reloadState()                   -- memwatch dies before the verifier runs
  W.sendFails = nil
  W.procs[4242].state = "T"         -- something else stops the process
  W.run(60)                         -- past the freeze's pending window
  F.load(W, nil, { keepHome = true })
  W.run(3)
  check("never-sent: not listed as frozen by memwatch", W.menuItem("   node"), nil)
end)

-- The nested re-freeze's own outcomes, named for the right process.
scenario("a re-freeze that cannot verify says the process may be running", nil, function(W)
  check("refreeze-unverified: the node is frozen", frozenNode(W), "T")
  local quit = frozenRowAction(W, "node", "Force Quit")
  W.sendFails = { TERM = true }
  W.onSignal = function(sig) if sig == "CONT" then W.probeFailsOnce = 1 end end
  local before = #W.alerts
  quit()
  W.onSignal = nil
  W.run(3)
  W.sendFails = nil
  local said = false
  for i = before + 1, #W.alerts do
    if W.alerts[i].text:find("can't verify it now; it was continued and may be running", 1, true) then said = true end
  end
  check("refreeze-unverified: the alert says it may be running", said, true)
end)

scenario("a re-freeze that finds the process gone drops its entry", nil, function(W)
  check("refreeze-exited: the node is frozen", frozenNode(W), "T")
  local quit = frozenRowAction(W, "node", "Force Quit")
  W.sendFails = { TERM = true }
  W.onSignal = function(sig) if sig == "CONT" then W.vanishBeforeProbe = 4242 end end   -- it exits once continued
  quit()
  W.onSignal = nil
  -- At once, before any sweep could have pruned it.
  check("refreeze-exited: its entry is gone at once", W.menuItem("   node"), nil)
  W.run(3)
  W.sendFails = nil
  check("refreeze-exited: and the alert says it exited",
    W.alerts[#W.alerts] ~= nil and W.alerts[#W.alerts].text:find("couldn't send TERM to node; node already exited", 1, true) ~= nil, true)
end)

-- A wall clock stepped back between two unattended attempts on the same
-- process never holds the second off for the length of the step.
scenario("a clock stepped back never holds the next unattended attempt off", UNATTENDED_FREEZE, function(W)
  leaker(W, 4242, "node")
  W.procs[4242].unstoppable = true  -- every freeze fails to take, so it is attempted again
  W.onSignal = function(sig) if sig == "STOP" then W.probeFails = true end end   -- and is unconfirmed
  W.run(12)
  W.kern = 4
  runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
  W.onSignal = nil
  W.run(1)
  W.probeFails = false
  local first = W.now
  W.wallOffset = -120               -- the clock steps back right after the first attempt
  local again = runUntil(W, 100, function() return select(2, W.signalsTo(4242):gsub("STOP", "")) >= 2 end)
  check("clock-step: the next attempt comes within its grace window, not the step's length", again, true)
  check("clock-step: and well before the clock catches up", W.now - first < 100, true)
end)

-- Rule 8: the grace keeps the length it had left. A step back half-way
-- through it moves its stamp with the rest, so the next attempt comes when
-- the grace would have ended, not a whole grace after the step.
scenario("a clock stepped back mid-grace keeps what the grace had left", UNATTENDED_FREEZE, function(W)
  leaker(W, 4242, "node")
  W.procs[4242].unstoppable = true
  W.onSignal = function(sig) if sig == "STOP" then W.probeFails = true end end
  W.run(12)
  W.kern = 4
  runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
  local first = W.now
  W.onSignal = nil
  W.run(1)
  W.probeFails = false
  local grace = 60                    -- the default unattended grace (memwatch_core cfg.cool.autoKillGraceSec)
  W.run(grace / 2)                    -- half-way through the grace
  W.wallOffset = -120
  local again = runUntil(W, grace * 2, function() return select(2, W.signalsTo(4242):gsub("STOP", "")) >= 2 end)
  check("grace-left: the next attempt comes", again, true)
  check("grace-left: when the grace would have ended (" .. math.floor(W.now - first) .. " s), not a whole grace after the step",
    W.now - first <= grace + 8, true)
end)

-- A HUD hold whose narrative never finishes is still released one hold
-- window after the action, whatever the wall clock did meanwhile.
scenario("a clock stepped back never lengthens a stuck hold", nil, function(W)
  leaker(W, 4242, "node")
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
  W.run(5)
  W.onSignal = function(sig) if sig == "STOP" then W.timersStall = true end end   -- its verifier never runs
  W.click("freeze")
  W.onSignal = nil
  W.run(2)
  W.wallOffset = -120
  local released = runUntil(W, 60, function() return logHas(W, "hud-hold-expired") end)
  W.timersStall = false
  check("stuck hold: released within a hold window of the action", released, true)
end)

-- ---- round 8 ----
-- Did any alert, or the HUD, say this?
do
  local function said(W, text)
    if W.hudBody():find(text, 1, true) then return true end
    for _, a in ipairs(W.alerts) do if a.text:find(text, 1, true) then return true end end
    return false
  end
  local function receiptSays(W, title, text)
    for _, n in ipairs(W.notices(title)) do
      if (n.attrs.informativeText or ""):find(text, 1, true) then return true end
    end
    return false
  end
  local function ledgerFrozenAt(W)
    local f = io.open(W.home .. "/projects/memwatch/memwatch-frozen.json", "r")
    local raw = f and f:read("a") or ""
    if f then f:close() end
    local n = 0
    for _ in raw:gmatch('"pid"') do n = n + 1 end
    return tonumber(raw:match('"frozenAt":([%d%.]+)')), n
  end

  -- Rule 2: a STOP that could not be sent leaves no entry, at once, and a
  -- process someone else stopped is never offered for Resume.
  scenario("a STOP that could not be sent leaves no entry, even on a process stopped by another", nil, function(W)
    leaker(W, 4242, "node")
    W.run(12)
    W.kern = 4
    runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
    W.run(5)
    W.sendFails = { STOP = true }
    W.click("freeze")
    check("unsent: no entry at once", W.menuItem("   node"), nil)
    W.procs[4242].state = "T"       -- something else stops it before the verifier runs
    W.sendFails = nil
    W.run(3)
    check("unsent: still none after the verifier", W.menuItem("   node"), nil)
    check("unsent: it says the process is stopped, but not by memwatch", said(W, "it is stopped, but not by memwatch"), true)
    check("unsent: nothing was signaled", W.signalsTo(4242), "")
  end)

  -- A STOP that could not be sent, to a process that then exited or whose
  -- pid changed hands, says nothing was signaled, never that it released one.
  for _, case in ipairs({
    { how = "exited", knob = "vanishAfterProbe", text = "couldn't send STOP to node; it has exited" },
    { how = "taken over", knob = "reuseAfterProbe",
      text = "couldn't send STOP to node; pid 4242 now holds another process, which was not signaled" },
  }) do
    scenario("an unsent STOP on a process " .. case.how .. " mid-freeze says nothing was signaled", nil, function(W)
      leaker(W, 4242, "node")
      W.run(12)
      W.kern = 4
      runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
      W.run(5)
      W.sendFails = { STOP = true }
      W[case.knob] = 4242
      W.click("freeze")
      W.run(3)
      W.sendFails = nil
      check("unsent-" .. case.how .. ": it says so", said(W, case.text), true)
      check("unsent-" .. case.how .. ": never that it released anything", said(W, "released, no freeze"), false)
      check("unsent-" .. case.how .. ": nothing was signaled", W.signalsTo(4242), "")
    end)
  end

  -- The reload drops a ledger entry whose STOP never went out (a ledger
  -- written by an earlier build of this change).
  scenario("a ledger entry whose STOP never went out is dropped at reload", nil, function(W)
    leaker(W, 4242, "node")
    W.procs[4242].state = "T"
    W.run(6)
    local f = assert(io.open(W.home .. "/projects/memwatch/memwatch-frozen.json", "w"))
    f:write(string.format('[{"pid":4242,"name":"node","lstart":"%s","weightMB":0,"frozenAt":%d,"stopSent":false}]\n',
      W.procs[4242].lstart, math.floor(W.now)))
    f:close()
    W.reloadState()
    F.load(W, nil, { keepHome = true })
    W.run(3)
    check("unsent-ledger: not listed as frozen", W.menuItem("   node"), nil)
    check("unsent-ledger: the drop is logged", logHas(W, "frozen-reconcile-drop:node(4242):stop-never-sent"), true)
  end)

  -- Rule 3: a released freeze's late verifier never writes over (or drops)
  -- the entry a newer freeze of the same process wrote.
  scenario("a released freeze's late verifier never undoes a newer freeze", UNATTENDED_FREEZE, function(W, mw)
    leaker(W, 4242, "node")
    W.onSignal = function(sig) if sig == "STOP" then W.timersStall = true; W.onSignal = nil end end
    W.run(12)
    W.kern = 4
    runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
    W.run(0.1)
    W.timersStall = false           -- only what that tick scheduled stays stalled: the first verifier
    check("late-verify: the first freeze stopped it", W.procs[4242] and W.procs[4242].state, "T")
    local released = runUntil(W, 200, function() return logHas(W, "unattended-hold-released:freeze:node(4242)") end)
    check("late-verify: the backstop released the first freeze", released, true)
    W.procs[4242].state = "S"       -- resumed by someone else
    local newerAt = W.now
    mw.freezePid(4242, "node", nil, { expectedLstart = W.procs[4242].lstart, weightMB = 2500 })
    W.run(2)
    check("late-verify: the newer freeze holds it", W.procs[4242] and W.procs[4242].state, "T")
    local at1 = ledgerFrozenAt(W)
    check("late-verify: the ledger holds the newer freeze", at1 ~= nil and at1 >= newerAt - 0.01, true)
    W.releaseStalled()              -- the first freeze's verifier finally runs
    W.run(3)
    local at2, n2 = ledgerFrozenAt(W)
    check("late-verify: the newer freeze's entry is not written over", at2 ~= nil and at2 >= newerAt - 0.01, true)
    check("late-verify: one entry", n2, 1)
    check("late-verify: and it is still resumable", frozenRowAction(W, "node", "Resume") ~= nil, true)
  end)

  -- Rule 4: a superseded kill whose probes cannot answer neither retries
  -- nor claims a failed send.
  scenario("a superseded kill with probes failing retries nothing and says what it did", UNATTENDED_KILL, function(W)
    W.frontmost = { name = "Terminal", pid = 760 }
    leaker(W, 4242, "node")
    W.procs[4242].ignoreTerm = true
    W.onSignal = function(sig) if sig == "TERM" then W.timersStall = true end end
    W.run(12)
    W.kern = 4
    runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
    W.onSignal = nil
    W.frontmost = { name = "node", pid = 4242 }
    runUntil(W, 300, function() return W.signalsTo(4242):find("STOP", 1, true) ~= nil end)
    W.probeFails = true
    W.releaseStalled()
    W.run(30)
    W.probeFails = false
    check("superseded-unknown: no KILL", W.signalsTo(4242):find("KILL", 1, true), nil)
    check("superseded-unknown: the skip is logged", logHas(W, "kill-escalate-superseded:node(4242)"), true)
    check("superseded-unknown: no retry", logHas(W, "kill-escalate-retry:node(4242)"), false)
    check("superseded-unknown: no probe for it after the skip", logHas(W, "kill-unverified:node(4242)"), false)
    check("superseded-unknown: no claim that a KILL could not be sent",
      receiptSays(W, "memwatch unattended terminate", "could not send it KILL"), false)
    check("superseded-unknown: its receipt says the KILL was withheld, and why",
      receiptSays(W, "memwatch unattended terminate", "KILL withheld, released after its result did not come back"), true)
  end)

  -- Rule 4: an operator's answer supersedes memwatch's own kill in flight.
  for _, case in ipairs({
    { how = "the HUD's Freeze", act = function(W) W.click("freeze") end, want = "TERM,STOP", state = "T" },
    { how = "the HUD's Ignore", act = function(W) W.click("ignore") end, want = "TERM", state = "S" },
    { how = "the menu's Ignore", act = function(W)
        local it = W.menuItem("Ignore node")
        if it then it.fn() end
      end, want = "TERM", state = "S" },
    { how = "the process row's Ignore", act = function(W)
        local row = W.menuItem("node ")
        for _, it in ipairs(row and row.menu or {}) do
          if it.title == "Ignore for 30 min" and it.fn then it.fn() end
        end
      end, want = "TERM", state = "S" },
    -- The menu opened while probes failed: the row has no start time, and
    -- its Ignore still vetoes memwatch's own KILL.
    { how = "the process row's Ignore, unbound", act = function(W)
        W.probeFails = true
        local row = W.menuItem("node ")
        W.probeFails = false
        for _, it in ipairs(row and row.menu or {}) do
          if it.title == "Ignore for 30 min" and it.fn then it.fn() end
        end
      end, want = "TERM", state = "S" },
  }) do
    scenario(case.how .. " supersedes memwatch's own kill in flight", UNATTENDED_KILL, function(W)
      W.frontmost = { name = "Terminal", pid = 760 }
      leaker(W, 4242, "node")
      W.procs[4242].ignoreTerm = true
      W.run(12)
      W.kern = 4
      runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
      W.run(1)
      case.act(W)
      W.run(30)
      check("operator-supersede (" .. case.how .. "): no KILL over the answer", W.signalsTo(4242), case.want)
      check("operator-supersede (" .. case.how .. "): the process is as the operator left it",
        W.procs[4242] and W.procs[4242].state, case.state)
      check("operator-supersede (" .. case.how .. "): logged",
        logHas(W, "unattended-superseded-by-operator:node(4242)"), true)
      check("operator-supersede (" .. case.how .. "): the receipt says the operator answered it",
        receiptSays(W, "memwatch unattended terminate", "KILL withheld, the operator answered it"), true)
    end)
  end

  -- Rule 5: an unattended freeze whose STOP went out is announced even when
  -- its process then exits.
  scenario("an unattended freeze whose process exits after the STOP still leaves a receipt", UNATTENDED_FREEZE, function(W)
    leaker(W, 4242, "node")
    W.onSignal = function(sig) if sig == "STOP" then W.vanishBeforeProbe = 4242; W.onSignal = nil end end
    W.run(12)
    W.kern = 4
    runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
    W.run(5)
    check("receipt-exit: the receipt says it exited during the freeze",
      receiptSays(W, "memwatch unattended freeze", "exited during the freeze"), true)
  end)

  -- Rule 5: an unattended terminate continued a stopped process, could not
  -- send its TERM, and found it gone when it went to stop it again: a signal
  -- went out, so it is announced, in the re-freeze's own words.
  scenario("an unattended terminate whose re-freeze finds the process gone still leaves a receipt", UNATTENDED_KILL, function(W)
    W.frontmost = { name = "Terminal", pid = 760 }
    leaker(W, 4242, "node")
    W.run(12)
    W.kern = 4
    runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
    W.procs[4242].state = "T"       -- stopped by something else; memwatch must continue it for a TERM
    W.sendFails = { TERM = true }
    W.onSignal = function(sig) if sig == "CONT" then W.vanishBeforeProbe = 4242; W.onSignal = nil end end
    local acted = runUntil(W, 200, function() return W.signalsTo(4242):find("CONT", 1, true) ~= nil end)
    W.run(5)
    W.sendFails, W.onSignal = nil, nil
    check("refreeze-receipt: the unattended terminate acted", acted, true)
    check("refreeze-receipt: the receipt says what the re-freeze found",
      receiptSays(W, "memwatch unattended terminate", "couldn't send TERM to node; node already exited"), true)
  end)

  -- Rule 1: a re-freeze whose STOP reached a newcomer, and was undone, says
  -- so in its own words (never that nothing was signaled).
  scenario("a re-freeze that undoes its STOP on a newcomer says so", nil, function(W)
    check("refreeze-takeover: the node is frozen", frozenNode(W), "T")
    local quit = frozenRowAction(W, "node", "Force Quit")
    W.sendFails = { TERM = true }
    W.onSignal = function(sig) if sig == "CONT" then W.reuseAfterProbe = 4242; W.onSignal = nil end end
    local before = #W.sigs
    quit()
    W.run(3)
    W.sendFails = nil
    local seq = {}
    for i = before + 1, #W.sigs do if W.sigs[i].pid == 4242 then seq[#seq + 1] = W.sigs[i].sig end end
    check("refreeze-takeover: CONT, then the re-freeze's STOP and its undo", table.concat(seq, ","), "CONT,STOP,CONT")
    check("refreeze-takeover: the newcomer runs", W.procs[4242] and W.procs[4242].state, "S")
    check("refreeze-takeover: it says the newcomer was released", said(W, "changed identity mid-freeze; released"), true)
    check("refreeze-takeover: never that nothing was signaled", said(W, "which was not signaled"), false)
  end)

  -- ---- round 9: the lifecycle model's design pass ----
  -- Rule 8: a callback that stamps between a step back and the next tick is
  -- shifted once, at its own read, never again at the tick.
  scenario("a callback between a step back and the tick is shifted once", nil, function(W, mw)
    leaker(W, 4242, "node")
    W.kern = 2
    W.samplerDelay = 3              -- the sampler replies 3 s after the tick that launched it
    W.run(20)                       -- the tick at 1020 has launched a sampler
    W.wallOffset = -120             -- the wall clock steps back before that reply lands
    W.run(5.5)                      -- the reply at 1023, then the tick at 1025
    local age = mw.debug().sampleAgeSec
    check("step-gap: the sample is fresh", age ~= nil and age >= 0 and age <= 6, true)
    check("step-gap: no stale-sampler line", logHas(W, "sampler-stale"), false)
    check("step-gap: no degraded page", #W.notices("memwatch degraded during pressure"), 0)
    check("step-gap: the step was seen once", logHas(W, "clock-stepped-back:120s"), true)
  end)

  -- The step that counts is more than clockStepSec (2 s); less is time noise.
  for _, case in ipairs({ { step = -1.9, seen = false }, { step = -2.1, seen = true } }) do
    scenario("a wall step of " .. case.step .. " s is " .. (case.seen and "" or "not ") .. "a step", nil, function(W)
      W.run(11)
      W.wallOffset = case.step
      W.run(6)
      check("step-threshold " .. case.step .. ": " .. (case.seen and "seen" or "ignored"),
        logHas(W, "clock-stepped-back"), case.seen)
    end)
  end

  -- Without the monotonic clock steps cannot be seen: memwatch says so.
  scenario("a missing monotonic clock is said once at start", nil, function(W)
    check("mono-missing: nothing said while it exists (control)", logHas(W, "clock-mono-unavailable"), false)
    W.hs.timer.absoluteTime = nil
    W.reloadState()
    F.load(W, nil, { keepHome = true })
    W.run(1)
    check("mono-missing: said at start", logHas(W, "clock-mono-unavailable:wall-only-step-detection"), true)
    -- A wall clock that runs backwards between two reads still shows.
    W.run(11)
    W.wallOffset = -120
    W.run(6)
    check("mono-missing: a step back that runs the wall backwards is still seen", logHas(W, "clock-stepped-back"), true)
  end)

  -- Rule 4: a frozen row's Resume or Force Quit is the operator's answer: it
  -- vetoes memwatch's own kill in flight on that process. A Resume leaves the
  -- process a candidate (it is meant to run); a Force Quit carries on as the
  -- operator's own kill.
  local function staleFrozenUnderKill(W)
    W.frontmost = { name = "Terminal", pid = 760 }
    leaker(W, 4242, "node")
    W.procs[4242].ignoreTerm = true
    W.procs[4242].state = "T"
    W.run(6)
    local f = assert(io.open(W.home .. "/projects/memwatch/memwatch-frozen.json", "w"))
    f:write(string.format('[{"pid":4242,"name":"node","lstart":"%s","weightMB":0,"frozenAt":%d,"stopSent":true}]\n',
      W.procs[4242].lstart, math.floor(W.now)))
    f:close()
    W.reloadState()
    -- A short grace, so memwatch's own kill comes inside the sweep's minute,
    -- while the stale entry is still listed.
    F.load(W, '{"unattended":"kill","unattendedGraceSec":5}', { keepHome = true })
    W.run(3)
    local listed = frozenRowAction(W, "node", "Resume") ~= nil
    W.procs[4242].state = "S"       -- resumed outside memwatch: it grows, and runs away
    W.kern = 4
    local termed = runUntil(W, 55, function() return W.signalsTo(4242):find("TERM", 1, true) ~= nil end)
    return listed and termed
  end
  scenario("a frozen row's Resume vetoes memwatch's own kill in flight", nil, function(W)
    check("frozen-veto: memwatch's own kill sent its TERM to a listed process", staleFrozenUnderKill(W), true)
    local resume = frozenRowAction(W, "node", "Resume")
    check("frozen-veto: the row still offers Resume", resume ~= nil, true)
    if resume then resume() end
    W.run(8)                        -- past that kill's escalation, 7 s after its TERM
    check("frozen-veto: no KILL over the Resume", W.signalsTo(4242):find("KILL", 1, true), nil)
    check("frozen-veto: the process runs", W.procs[4242] and W.procs[4242].state, "S")
    check("frozen-veto: that kill's escalation was withheld",
      logHas(W, "kill-escalate-superseded:node(4242):operator"), true)
    check("frozen-veto: the receipt says the operator answered it",
      receiptSays(W, "memwatch unattended terminate", "KILL withheld, the operator answered it"), true)
    -- Still running away, it is a candidate again: memwatch may act anew.
    local again = runUntil(W, 200, function()
      local _, n = W.signalsTo(4242):gsub("TERM", "")
      return n >= 2
    end)
    check("frozen-veto: a resumed process is a candidate again", again, true)
  end)
  scenario("a frozen row's Force Quit takes over memwatch's own kill", nil, function(W)
    check("frozen-quit: memwatch's own kill sent its TERM to a listed process", staleFrozenUnderKill(W), true)
    local quit = frozenRowAction(W, "node", "Force Quit")
    check("frozen-quit: the row offers Force Quit", quit ~= nil, true)
    if quit then quit() end
    W.run(30)
    check("frozen-quit: memwatch's own KILL was withheld",
      logHas(W, "kill-escalate-superseded:node(4242):operator"), true)
    check("frozen-quit: the operator's quit carried on to its KILL", W.procs[4242], nil)
  end)

  -- Rule 1: a quit while the freeze it acts on is still pending, whose TERM
  -- cannot be sent, re-freezes the process: the old entry goes first.
  scenario("a quit while its freeze is still pending re-freezes the process", nil, function(W)
    leaker(W, 4242, "node")
    W.run(12)
    W.kern = 4
    runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
    W.run(5)
    W.click("freeze")
    local quit = frozenRowAction(W, "node", "Force Quit")   -- before the freeze's verifier runs
    check("pending-quit: the pending freeze offers Force Quit", quit ~= nil, true)
    W.sendFails = { TERM = true }
    if quit then quit() end
    W.run(3)
    W.sendFails = nil
    check("pending-quit: STOP, the quit's CONT, then the re-freeze's STOP", W.signalsTo(4242), "STOP,CONT,STOP")
    check("pending-quit: stopped again", W.procs[4242] and W.procs[4242].state, "T")
    check("pending-quit: and resumable", frozenRowAction(W, "node", "Resume") ~= nil, true)
  end)

  -- Rule 8: a pending window persisted ahead of now (a step back across a
  -- reload) lasts at most one window more.
  scenario("a persisted pending window ahead of now lasts one window at most", nil, function(W)
    leaker(W, 4242, "node")
    W.run(6)
    local f = assert(io.open(W.home .. "/projects/memwatch/memwatch-frozen.json", "w"))
    f:write(string.format('[{"pid":4242,"name":"node","lstart":"%s","weightMB":0,"frozenAt":%d,"pendingUntil":%d,"stopSent":true}]\n',
      W.procs[4242].lstart, math.floor(W.now), math.floor(W.now) + 3600))
    f:close()
    W.reloadState()
    F.load(W, nil, { keepHome = true })
    W.run(3)
    check("pending-clamp: kept while pending", W.menuItem("   node") ~= nil, true)
    local gone = runUntil(W, 150, function() return W.menuItem("   node") == nil end)
    check("pending-clamp: a running process is dropped once the window has ended", gone, true)
    check("pending-clamp: by the sweep, as resumed outside memwatch",
      logHas(W, "frozen-prune:node(4242):resumed-externally"), true)
  end)

  -- Rule 8: so does a freeze stamp persisted ahead of now: it reads as
  -- frozen from now, never a negative time frozen.
  scenario("a persisted freeze stamp ahead of now reads as now", nil, function(W)
    leaker(W, 4242, "node")
    W.procs[4242].state = "T"
    W.run(6)
    local f = assert(io.open(W.home .. "/projects/memwatch/memwatch-frozen.json", "w"))
    f:write(string.format('[{"pid":4242,"name":"node","lstart":"%s","weightMB":0,"frozenAt":%d,"stopSent":true}]\n',
      W.procs[4242].lstart, math.floor(W.now) + 3600))
    f:close()
    W.reloadState()
    F.load(W, nil, { keepHome = true })
    W.run(3)
    local row = W.menuItem("   node")
    check("future-frozen: kept", row ~= nil, true)
    check("future-frozen: never a negative time frozen", row ~= nil and row.title:find("%-%d+ min") == nil, true)
    local g = io.open(W.home .. "/projects/memwatch/memwatch-frozen.json", "r")
    local raw = g and g:read("a") or ""
    if g then g:close() end
    local at = tonumber(raw:match('"frozenAt":(%-?[%d%.]+)'))
    check("future-frozen: the stamp is now, not an hour ahead", at ~= nil and at <= W.now + 1, true)
  end)

  -- Rule 3: a freeze still owns its entry after an in-process restart's
  -- reconcile rebuilt it, so its undo still reaches the newcomer it stopped.
  scenario("a freeze's verifier keeps its entry across an in-process restart", nil, function(W, mw)
    leaker(W, 4242, "node")
    W.run(12)
    W.kern = 4
    runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
    W.run(5)
    W.reuseAfterProbe = 4242          -- a newcomer takes the pid between the probe and the STOP
    W.click("freeze")
    W.probeFails = true               -- the restart's reconcile cannot check the entry, so keeps it
    mw.start()
    W.probeFails = false
    W.run(3)                          -- the freeze's own verifier runs
    check("restart-own: the newcomer the STOP reached was continued", W.procs[4242] and W.procs[4242].state, "S")
    check("restart-own: STOP, then its undo", W.signalsTo(4242), "STOP,CONT")
  end)

  -- Rule 3 with rule 8: a verifier settles its freeze's entry where the
  -- slot holds it (rebuilt by a restart's reconcile, then shifted by a step
  -- back), never by putting back the unshifted copy it captured.
  scenario("a verifier settles the rebuilt entry, shifted, not its own copy", nil, function(W, mw)
    leaker(W, 4242, "node")
    W.run(12)
    W.kern = 4
    runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
    W.run(5)
    local clickedAt = W.now
    W.click("freeze")
    W.probeFails = true               -- the restart's reconcile cannot check the entry, so keeps it
    mw.start()
    W.probeFails = false
    W.wallOffset = -120               -- a step back, read before the freeze's own verifier runs
    mw.debug()
    W.run(3)
    local f = io.open(W.home .. "/projects/memwatch/memwatch-frozen.json", "r")
    local raw = f and f:read("a") or ""
    if f then f:close() end
    local at = tonumber(raw:match('"frozenAt":(%-?[%d%.]+)'))
    check("rebuilt-settle: frozen and listed", W.menuItem("   node") ~= nil, true)
    check("rebuilt-settle: the entry kept the step's shift (" .. tostring(at and math.floor(at - clickedAt)) .. " s)",
      at ~= nil and math.abs((at - clickedAt) + 120) <= 2, true)
  end)

  -- Rule 4: an operator's answer frees the HUD from memwatch's own action:
  -- once the operator's quit has answered the process, the alert goes.
  scenario("an operator's quit during memwatch's own kill lets the alert retire", UNATTENDED_KILL, function(W)
    W.frontmost = { name = "Terminal", pid = 760 }
    leaker(W, 4242, "node")
    W.procs[4242].ignoreTerm = true
    W.run(12)
    W.kern = 4
    runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
    W.run(1)
    local quit = W.menuItem("Force Quit node")
    check("hold-release: the menu offers Force Quit", quit ~= nil and quit.fn ~= nil, true)
    if quit then quit.fn() end
    local gone = runUntil(W, 20, function() return W.procs[4242] == nil end)
    check("hold-release: the operator's quit ended the process", gone, true)
    local retired = runUntil(W, 8, function() return not W.hudShowing() end)
    check("hold-release: the alert retires at once, not after memwatch's hold", retired, true)
  end)

  -- Rule 4: a click that signals nothing is no answer: its veto is withdrawn
  -- and memwatch's own kill carries on.
  -- The click's answer settles when its outcome arrives, not when the HUD
  -- comes down, so it holds however close to memwatch's escalation the
  -- click lands (here 1 s and 5 s after the TERM).
  -- 1 s after the TERM, and 2 s before memwatch's escalation (escalateSec
  -- after it): the case the HUD's 4 s settle used to lose.
  local escalateSec = require("memwatch_core").cfg.kill.escalateSec
  for _, after in ipairs({ 1, escalateSec - 2 }) do
    scenario("a click that signals nothing does not veto memwatch's own kill (" .. after .. " s)", UNATTENDED_KILL, function(W)
      W.frontmost = { name = "Terminal", pid = 760 }
      leaker(W, 4242, "node")
      W.procs[4242].ignoreTerm = true
      W.run(12)
      W.kern = 4
      runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
      W.run(after)
      W.probeFailsOnce = 1              -- the click's own probe fails: nothing is signaled
      W.click("kill")
      W.run(30)
      check("no-veto (" .. after .. " s): memwatch's KILL still went out", W.signalsTo(4242), "TERM,KILL")
      check("no-veto (" .. after .. " s): the veto was withdrawn", logHas(W, "unattended-veto-withdrawn:node(4242)"), true)
      check("no-veto (" .. after .. " s): no receipt claims the operator answered it",
        receiptSays(W, "memwatch unattended terminate", "KILL withheld, the operator answered it"), false)
    end)
  end

  -- Rule 4: each click holds its own veto. A second click that signals
  -- nothing gives up only its own: the first click's freeze still stands
  -- memwatch's KILL down.
  scenario("a failed second click does not withdraw the first click's veto", UNATTENDED_KILL, function(W)
    W.frontmost = { name = "Terminal", pid = 760 }
    leaker(W, 4242, "node")
    W.procs[4242].ignoreTerm = true
    W.run(12)
    W.kern = 4
    runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
    W.run(1)
    W.click("freeze")                   -- click 1: its STOP goes out, its outcome is on the way
    local row = W.menuItem("node ")
    local again
    for _, it in ipairs(row and row.menu or {}) do
      if it.title == "Freeze node" then again = it end
    end
    check("two-clicks: the row offers Freeze", again ~= nil, true)
    W.probeFailsOnce = 1                -- click 2's own probe fails: it signals nothing
    if again then again.fn() end
    W.run(30)
    check("two-clicks: no KILL over the operator's freeze", W.signalsTo(4242), "TERM,STOP")
    check("two-clicks: the process stays frozen", W.procs[4242] and W.procs[4242].state, "T")
    check("two-clicks: the veto was never withdrawn", logHas(W, "unattended-veto-withdrawn:node(4242)"), false)
  end)
  -- Rule 3: a resume's verifier owns only the entry it resumed. A newer
  -- freeze of the same process (its STOP still on the way when the resume
  -- is checked) keeps its own entry, so the process stays resumable.
  scenario("a resume's check never drops a newer freeze of the same process", nil, function(W)
    W.frontmost = { name = "Terminal", pid = 760 }
    leaker(W, 4242, "node")
    W.run(12)
    W.kern = 4
    runUntil(W, 40, function() return bodyNames(W, "node") end)
    W.run(10)
    W.click("freeze")
    runUntil(W, 20, function() return frozenRowAction(W, "node", "Resume") ~= nil end)
    W.run(5)
    -- The resume's check comes 0.5 s after its CONT; the newer freeze, 0.3 s
    -- after the resume, lands its STOP 0.3 s after sending it: after the
    -- resume's check, before the freeze's own.
    W.stopDelay = 0.3
    local resume = frozenRowAction(W, "node", "Resume")
    check("resume-newer: frozen and resumable", resume ~= nil, true)
    if resume then resume() end
    W.run(0.3)
    local row = W.menuItem("node ")
    local freeze
    for _, it in ipairs(row and row.menu or {}) do
      if it.title == "Freeze node" then freeze = it end
    end
    check("resume-newer: the row offers Freeze", freeze ~= nil, true)
    if freeze then freeze.fn() end      -- a newer freeze, before the resume's check
    W.run(0.3)                          -- the resume's check has run
    W.probeFailsOnce = 1                -- the newer freeze's own check cannot answer
    W.run(15)
    W.stopDelay = nil
    check("resume-newer: frozen again", W.procs[4242] and W.procs[4242].state, "T")
    check("resume-newer: and still resumable", frozenRowAction(W, "node", "Resume") ~= nil, true)
  end)

  -- (round 11) The writes that keep an answer's veto standing, each pinned:
  -- a click that did something holds for good; so does an answer that needs
  -- no signal engine; and a later answer on an action already vetoed is a
  -- holder too, so an earlier click's late "nothing done" leaves it standing.
  local function termOut(W)          -- memwatch's own TERM is out; the node ignores it
    W.frontmost = { name = "Terminal", pid = 760 }
    leaker(W, 4242, "node")
    W.procs[4242].ignoreTerm = true
    W.run(12)
    W.kern = 4
    runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
  end
  local function rowItem(W, title)
    local row = W.menuItem("node ")
    for _, it in ipairs(row and row.menu or {}) do
      if it.title == title then return it end
    end
  end
  scenario("a Freeze that worked keeps its veto against a later click that signals nothing", UNATTENDED_KILL, function(W)
    termOut(W)
    W.run(1)
    W.click("freeze")
    W.run(2)
    local quit = frozenRowAction(W, "node", "Force Quit")
    check("final-veto freeze: the frozen row offers Force Quit (control)", quit ~= nil, true)
    W.probeFailsOnce = 1
    if quit then quit() end
    W.run(30)
    check("final-veto freeze: no KILL over the operator's freeze", W.signalsTo(4242), "TERM,STOP")
  end)
  scenario("closing the alert keeps its veto against a later click that signals nothing", UNATTENDED_KILL, function(W)
    termOut(W)
    W.run(1)
    local quit = rowItem(W, "Force Quit node")
    check("final-veto close: the process row offers Force Quit (control)", quit ~= nil and quit.disabled ~= true, true)
    W.click("close")
    W.probeFailsOnce = 1
    if quit then quit.fn() end
    W.run(30)
    check("final-veto close: no KILL after the operator closed the alert", W.signalsTo(4242), "TERM")
  end)
  scenario("a later working click holds the veto when an earlier one gives up after the fact", UNATTENDED_KILL, function(W)
    termOut(W)
    local freezeB = rowItem(W, "Freeze node")
    check("final-veto late: the process row offers Freeze (control)", freezeB ~= nil and freezeB.disabled ~= true, true)
    W.sendFails = { STOP = true }
    W.click("freeze")                 -- click A: its STOP cannot be sent; it gives up 0.5 s later
    W.sendFails = nil
    W.run(0.1)
    if freezeB then freezeB.fn() end  -- click B: a working freeze
    W.run(30)
    check("final-veto late: click A gave up (control)", logHas(W, "freeze-skip:node(4242)-stopped-by-another"), true)
    check("final-veto late: no KILL over the operator's freeze", W.signalsTo(4242), "TERM,STOP")
  end)
  -- (round 11) A click settles whatever run its outcome lands in: a click
  -- that did nothing, whose outcome lands after an in-process restart, still
  -- gives up the veto it held against the earlier run's action.
  scenario("a click that did nothing gives up its veto across a restart", UNATTENDED_KILL, function(W, mw)
    termOut(W)
    W.run(1)
    W.sendFails = { STOP = true }
    W.click("freeze")                 -- its STOP cannot be sent; it says so 0.5 s later
    W.sendFails = nil
    mw.start()                        -- an in-process restart before that outcome lands
    W.run(30)
    check("restart-settle: the click gave up its veto after the restart",
      logHas(W, "unattended-veto-withdrawn:node(4242)"), true)
    check("restart-settle: memwatch's own KILL still went out", W.signalsTo(4242):find("KILL", 1, true) ~= nil, true)
  end)

  -- The other order: a Force Quit that signals nothing, then a Freeze that
  -- works, both before the HUD comes down. The failed click's outcome never
  -- undoes the freeze's veto.
  scenario("a failed click before a working one does not undo its veto", UNATTENDED_KILL, function(W)
    W.frontmost = { name = "Terminal", pid = 760 }
    leaker(W, 4242, "node")
    W.procs[4242].ignoreTerm = true
    W.run(12)
    W.kern = 4
    runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
    W.run(1)
    W.probeFailsOnce = 1                -- click 1: Force Quit, its probe fails
    W.click("kill")
    local row = W.menuItem("node ")
    local freeze
    for _, it in ipairs(row and row.menu or {}) do
      if it.title == "Freeze node" then freeze = it end
    end
    check("failed-first: the row offers Freeze", freeze ~= nil, true)
    if freeze then freeze.fn() end      -- click 2: Freeze, it works
    W.run(30)
    check("failed-first: no KILL over the operator's freeze", W.signalsTo(4242), "TERM,STOP")
    check("failed-first: the process stays frozen", W.procs[4242] and W.procs[4242].state, "T")
  end)

  -- Rule 5: a superseded action still owes its receipt: one whose result
  -- never comes back is announced at its deadline.
  scenario("a superseded action whose result never comes back still leaves a receipt", UNATTENDED_FREEZE, function(W)
    leaker(W, 4242, "node")
    W.onSignal = function(sig) if sig == "STOP" then W.timersStall = true; W.onSignal = nil end end
    W.run(12)
    W.kern = 4
    runUntil(W, 150, function() return W.signalsTo(4242) ~= "" end)
    W.run(0.1)
    W.timersStall = false             -- only the freeze's verifier stays stalled
    W.click("monitor")                -- the operator answers it
    W.run(120)
    check("superseded-receipt: the late receipt was posted",
      receiptSays(W, "memwatch unattended freeze", "result has not come back"), true)
  end)

  -- Rule 8: a step in the middle of a tick is taken out when the tick ends.
  -- The tick holds a reading from before the step, so a read later in the
  -- same tick that shifted every stamp at once would leave the tick
  -- comparing its old reading with shifted stamps (a fresh sample would read
  -- as minutes stale).
  scenario("a step in the middle of a tick is taken out when it ends", UNATTENDED_FREEZE, function(W)
    W.frontmost = { name = "Terminal", pid = 760 }
    leaker(W, 4242, "node")
    W.run(12)
    W.kern = 4
    runUntil(W, 60, function() return W.hudShowing() end)
    W.run(3)
    W.onVmStat = function() W.wallOffset = -120; W.onVmStat = nil end
    W.run(4)
    check("mid-tick: the step was seen", logHas(W, "clock-stepped-back:120s"), true)
    check("mid-tick: a fresh sample never reads as stale", logHas(W, "sampler-stale"), false)
    W.run(30)
    check("mid-tick: nor later", logHas(W, "sampler-stale"), false)
    check("mid-tick: the shift ran without error", logHas(W, "error:clock-shift"), false)
  end)

  -- Rule 8: a callback that throws while holding a step still ends its
  -- frame: the step is applied once, and the next step is applied too (the
  -- frame did not leak).
  scenario("a callback that throws while holding a step still applies it", nil, function(W, mw)
    leaker(W, 4242)
    W.run(12)
    W.kern = 4
    runUntil(W, 40, function() return bodyNames(W, "leaker") end)
    W.run(5)
    local row = W.menuItem("leaker ")
    local freeze
    for _, it in ipairs(row and row.menu or {}) do
      if type(it.title) == "string" and it.title:find("^Freeze") then freeze = it end
    end
    check("frame-error: the row offers Freeze (control)", freeze ~= nil, true)
    W.onAlert = function()
      W.onAlert = nil
      W.wallOffset = -120
      mw.debug()                       -- a read inside the verifier's frame sees the step: it is held
      error("thrown inside the verifier")
    end
    if freeze then freeze.fn() end
    W.run(2)                          -- its verifier shows the outcome: the throw lands there
    check("frame-error: the verifier's error was logged", logHas(W, "error:freeze-verify"), true)
    check("frame-error: the held step was applied when the frame ended", logHas(W, "clock-stepped-back:120s"), true)
    W.wallOffset = -240                -- a second step: applied too, so no frame leaked
    W.run(6)
    local f = io.open(W.home .. "/projects/memwatch/memwatch.log", "r")
    local all = f and f:read("a") or ""
    if f then f:close() end
    local _, n = all:gsub("clock%-stepped%-back:120s", "")
    check("frame-error: the next step was applied as well (" .. n .. ")", n, 2)
  end)

  -- Rule 8: a forward step (a sleep) is no step back: nothing shifts.
  scenario("a forward wall step shifts nothing", nil, function(W)
    W.run(11)
    W.wallOffset = 120
    W.run(6)
    check("forward-step: no step back is seen", logHas(W, "clock-stepped-back"), false)
  end)

  -- Rule 8: the shifted ledger is written out, so a reload reads it shifted.
  scenario("a pending freeze's shifted window is written out", nil, function(W)
    leaker(W, 4242, "node")
    W.run(12)
    W.kern = 4
    runUntil(W, 40, function() return bodyNames(W, "node (pid") end)
    W.run(5)
    W.onSignal = function(sig) if sig == "STOP" then W.timersStall = true; W.onSignal = nil end end
    W.click("freeze")
    W.run(0.1)
    W.timersStall = false
    local function persisted()
      local f = io.open(W.home .. "/projects/memwatch/memwatch-frozen.json", "r")
      local raw = f and f:read("a") or ""
      if f then f:close() end
      return tonumber(raw:match('"pendingUntil":([%d%.]+)'))
    end
    local before = persisted()
    W.wallOffset = -120
    W.run(6)
    local after = persisted()
    check("persist-shift: the pending window was written before", before ~= nil, true)
    check("persist-shift: and is written shifted after the step", after ~= nil and before ~= nil and after <= before - 115, true)
  end)

  -- A quit whose CONT and TERM both could not be sent signaled nothing.
  scenario("a quit whose CONT and TERM cannot be sent says nothing was signaled", nil, function(W)
    check("unsent-quit: the node is frozen", frozenNode(W), "T")
    local quit = frozenRowAction(W, "node", "Force Quit")
    W.sendFails = { CONT = true, TERM = true }
    if quit then quit() end
    W.run(3)
    W.sendFails = nil
    check("unsent-quit: it says nothing was signaled", said(W, "couldn't send TERM to node; nothing was signaled"), true)
    check("unsent-quit: the node stays frozen", W.procs[4242] and W.procs[4242].state, "T")
    check("unsent-quit: and listed", frozenRowAction(W, "node", "Resume") ~= nil, true)
  end)

  -- The fake's notification handles need no temp file.
  local realTmpfile = io.tmpfile
  io.tmpfile = function() return nil end
  scenario("notification handles need no temp file", nil, function(W)
    local h = hs.notify.new({ title = "handle probe" }):send()
    check("handles: a userdata, as Hammerspoon's is", type(h), "userdata")
    h:withdraw()
    check("handles: withdraw reaches the notification", W.notifs[#W.notifs].withdrawn, true)
  end)
  io.tmpfile = realTmpfile
end

if fails == 0 then
  print("\nALL PASS")
else
  print("\n" .. fails .. " FAILED")
  os.exit(1)
end

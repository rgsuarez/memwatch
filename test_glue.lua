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
scenario("banner upgrades when identity binds", nil, function(W)
  leaker(W, 4242)
  W.run(12)
  W.probeFails = true
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, "leaker") end)
  W.run(6)
  local live = W.liveBanners()
  check("bind: with probes failing the banner offers no Force Quit",
    live[1] ~= nil and live[1].attrs.hasActionButton ~= true, true)
  W.probeFails = false
  W.run(40)
  live = W.liveBanners()
  check("bind: once probes recover the banner offers Force Quit",
    live[1] ~= nil and live[1].attrs.hasActionButton == true, true)
  check("bind: still one live banner", #live, 1)
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
  check("identity: once it binds, the unattended freeze lands",
    runUntil(W, 40, function() return W.signalsTo(4242) ~= "" end) and W.signalsTo(4242), "STOP")
end)

-- ---- self-test surfaces never signal a real process ----
scenario("self-test is inert", nil, function(W, mw)
  W.addProc(99999, "something-real", 300)
  W.run(6)
  mw.test("critical", 20)
  W.run(2)
  W.click("kill")
  W.run(8)
  W.click("freeze")
  W.run(3)
  check("selftest: the HUD's buttons signal nothing", W.signalsTo(99999), "")
  for _, b in ipairs(W.liveBanners()) do
    check("selftest: the banner offers no Force Quit", b.attrs.hasActionButton == true, false)
  end
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
-- the attempt is refused, so no "freeze" receipt, and the newcomer is a new
-- alert with its own grace.
scenario("a refused unattended action posts no receipt", '{"unattended":"freeze","alerts":false}', function(W)
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

if fails == 0 then
  print("\nALL PASS")
else
  print("\n" .. fails .. " FAILED")
  os.exit(1)
end

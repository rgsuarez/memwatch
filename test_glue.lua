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
  -- Wait for the runaway reading (the first sample can name it as the hog).
  runUntil(W, 40, function() return bodyNames(W, "leaker") and bodyNames(W, "MB/min") end)
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

-- ---- observation ledger: what was faced, and what became of it ----
local function ledgerRows(W)
  local lfm = require("memwatch_lfm")
  local rows = {}
  local f = io.open(W.home .. "/projects/memwatch/memwatch-observe.jsonl", "r")
  if not f then return rows end
  for line in f:lines() do
    local r = lfm.jsonDecode(line)
    if r then rows[#rows + 1] = r end
  end
  f:close()
  return rows
end
local function decisionRow(W, pid)
  for _, r in ipairs(ledgerRows(W)) do
    if r.point == "decision" and r.pid == pid then return r end
  end
end
local function followups(W, seq)
  local out = {}
  for _, r in ipairs(ledgerRows(W)) do
    if r.followup_for == seq then out[#out + 1] = r end
  end
  table.sort(out, function(a, b) return (a.horizonSec or 0) < (b.horizonSec or 0) end)
  return out
end
-- Drive one leaker to its grace-expiry decision point; returns its row.
local function toDecision(W, pid, name)
  leaker(W, pid, name)
  W.run(12)
  W.kern = 4
  runUntil(W, 40, function() return bodyNames(W, name or "leaker") end)
  runUntil(W, 90, function() return decisionRow(W, pid) ~= nil end)
  return decisionRow(W, pid)
end

scenario("ledger: a decision point and its follow-ups", nil, function(W)
  local row = toDecision(W, 4242)
  check("ledger: a decision row is written at grace expiry", row ~= nil, true)
  if not row then return end
  check("ledger: with unattended off nothing would have fired", row.wouldAct, "none")
  check("ledger: the freeze-ceiling counterfactual is freeze", row.wouldActAtFreeze, "freeze")
  check("ledger: the exact model input rides along", type(row.snapshot), "string")
  check("ledger: the model input carries no pid", row.snapshot:find('"pid"', 1, true), nil)
  W.run(190)
  local fu = followups(W, row.seq)
  check("ledger: three follow-ups", #fu, 3)
  check("ledger: the process is still alive at +60", fu[1] and fu[1].fate, "alive")
  check("ledger: nobody touched it", fu[3] and fu[3].operatorActionsSince, 0)
  check("ledger: memwatch sent it nothing", fu[3] and fu[3].memwatchSignalSince, nil)
  check("ledger: the peak since the observation only grows",
    fu[3] ~= nil and fu[1] ~= nil and fu[3].peakSinceMB >= fu[1].peakSinceMB, true)
end)

scenario("ledger: an operator's quit is recorded as such", nil, function(W)
  local row = toDecision(W, 4242)
  if not row then check("ledger quit: decision row", false, true); return end
  W.click("kill")
  W.run(190)
  local fu = followups(W, row.seq)
  local last = fu[#fu]
  check("ledger quit: the process is recorded as exited", last and last.fate, "exited")
  check("ledger quit: an operator action is counted", last ~= nil and (last.operatorActionsSince or 0) >= 1, true)
  check("ledger quit: memwatch's own TERM is recorded", last and last.memwatchSignalSince, "terminate")
end)

scenario("ledger: memwatch's freeze is recorded as such", UNATTENDED_FREEZE, function(W)
  local row = toDecision(W, 4242)
  if not row then check("ledger freeze: decision row", false, true); return end
  check("ledger freeze: the live mode would have frozen", row.wouldAct, "freeze")
  W.run(190)
  local fu = followups(W, row.seq)
  local last = fu[#fu]
  check("ledger freeze: the process is recorded as frozen", last and last.fate, "frozen")
  check("ledger freeze: memwatch's STOP is recorded", last and last.memwatchSignalSince, "freeze")
  check("ledger freeze: the frozen ledger agrees", last and last.frozenLedger, true)
  check("ledger freeze: no operator action", last and last.operatorActionsSince, 0)
end)

scenario("ledger: a partial process table proves nothing", nil, function(W)
  local row = toDecision(W, 4242)
  if not row then check("ledger partial: decision row", false, true); return end
  W.samplerExit = 1
  W.run(65)
  local fu = followups(W, row.seq)
  check("ledger partial: absence from a partial table is unknown, not exited",
    fu[1] and fu[1].fate, "unknown")
  check("ledger partial: and says why", fu[1] and fu[1].fateDetail, "incomplete-sample")
end)

scenario("ledger: a late sampler delivery is not a pid reuse", nil, function(W)
  local row = toDecision(W, 4242)
  if not row then check("ledger stall: decision row", false, true); return end
  W.samplerDelay = 40
  W.run(190)
  local reused = false
  for _, r in ipairs(followups(W, row.seq)) do
    if r.fateDetail == "pid-reused" then reused = true end
  end
  check("ledger stall: a 40 s delivery stall never reads as a reused pid", reused, false)
end)

scenario("ledger: a pid taken over by another process", nil, function(W)
  local row = toDecision(W, 4242)
  if not row then check("ledger reuse: decision row", false, true); return end
  W.reusePid(4242, "somethingelse", 500)
  W.run(70)
  local fu = followups(W, row.seq)
  check("ledger reuse: the observed process is recorded as exited", fu[1] and fu[1].fate, "exited")
  check("ledger reuse: with the pid reuse named", fu[1] and fu[1].fateDetail, "pid-reused")
end)

if fails == 0 then
  print("\nALL PASS")
else
  print("\n" .. fails .. " FAILED")
  os.exit(1)
end

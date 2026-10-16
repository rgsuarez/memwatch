-- gen-episodes.lua: simulate decision EPISODES for the discrimination oracle.
--
-- The 74-scenario corpus (gen-scenarios.lua) cannot reward judgment: every
-- hog is gold wait and freeze is acceptable on every extreme, so the rule
-- "extreme -> freeze" outscores every model ever benchmarked. The decision a
-- model actually owns in production is narrower and harder: at grace expiry
-- on an offender the detector has tagged kind=extreme, under the freeze
-- ceiling, FREEZE (it is a runaway that will exhaust the machine) or WAIT (it
-- is a self-limiting burst or a bystander that will resolve on its own).
--
-- An episode follows ONE such offender from grace expiry (t = 0) through its
-- later decision points, each where production re-arms (the first open tick
-- a grace window or more after the last), exactly as production would
-- re-adjudicate it. A seeded trajectory model drives the offender's
-- footprint: its base (the template's w0); the climb at its peak rate
-- (peak0) on which the detector first tags it extreme, the alert's onset,
-- a grace window before t = 0; growth through that window (graceRate, by
-- default the first phase's rate); then the template's phases from t = 0
-- and hold / exit / release. The machine's availability follows (avail0 is
-- its value at t = 0), and the labels fall out of the trajectory
-- mechanically and exactly, with no time grid between a label and its
-- trajectory:
--
--   runaway       the trajectory exhausts the machine (availability <= the
--                 exhaustion floor) at or before it resolves, or it is a
--                 hold that settles at or below the starvation line, read
--                 as the snapshot reports availability (whole percent,
--                 floored). A plateau that releases within the deferral
--                 bound is not starving: it resolves on its own
--   ttxSec        seconds from t = 0 to exhaustion (runaways); a starving
--                 plateau is given the deferral bound (it must be frozen by
--                 then)
--   resolvesBySec seconds until the offender exits, releases, or stops
--                 growing (non-runaways)
--   class         runaway | savable (resolves within the deferral bound
--                 without exhausting) | late (resolves after it; excluded
--                 from the wrongful-freeze count)
--
-- Decision points exist only where production would make one: the process
-- is alive, availability is above the exhaustion floor, and PRODUCTION's
-- unattended gate (memwatch_core) is open: the alert, raised when the
-- pressure state machine went critical on the offender, unanswered for its
-- grace window, with the offender extreme at its head by PRODUCTION's
-- tracker (memwatch_procs, fed one ps row per 5 s sampler tick). The
-- tracker's latch, its 55 s ring and its two qualifying routes therefore
-- decide when an offender stops being eligible, as they do live.
-- Each step carries the full model-input snapshot: the offender as the
-- tracker reports it (weight, rising-tail slope, peak, age) and the state
-- machine's state.
--
-- Usage (from the repo root):
--   lua eval/gen-episodes.lua --templates eval/episode-templates.lua \
--       --split dev --seed 1 --per-template 8 --out eval/episodes/dev
-- A set decides gate G7 only with enough runaways: 59 at zero misses, 93 at
-- one (the one-sided Clopper-Pearson bound); 8 per template gives the
-- public dev templates 88. A sealed set is generated the same way from
-- templates kept OUTSIDE this repository, so its templates never become
-- public or training material.

package.path = "lua/?.lua;" .. package.path
local lfm = require("memwatch_lfm")
local procs = require("memwatch_procs")
local core = require("memwatch_core")

local M = {}

M.cfg = {
  totalMB         = 36864,  -- the deployment machine's RAM
  exhaustPct      = 5,      -- availability at which the machine is lost
  starvePct       = 8,      -- a plateau holding the machine at or below this starves it
  decisionsMax    = 3,      -- grace expiry and two re-arms (the floor acts by the third)
  deferralSec     = lfm.cfg.maxDeferSec, -- the deterministic floor fires here (production's default)
  horizonSec      = 180,
  tickSec         = core.cfg.pollSec,    -- the sampler's cadence
  leadSec         = 60,     -- base-footprint history before the climb
  graceSec        = core.cfg.cool.autoKillGraceSec, -- the alert's unanswered window
  exposureStepMax = 15,     -- production's EXPOSURE_STEP_MAX (a stalled tick's most grace; inert on a 5 s grid)
  settleSec       = 10,     -- below critical this long ends the alert, as in production
  maxFill         = 0.90,   -- the offender's physical footprint plus what is available, of the machine
}

-- Deterministic PRNG (xorshift32), identical across Lua 5.4 and 5.5 so a
-- (template, seed) pair always yields the same episode.
function M.rng(seed)
  local s = (seed * 2654435761 + 1013904223) % 4294967296
  if s == 0 then s = 2463534242 end
  local r = {}
  function r.next()
    s = s ~ ((s << 13) & 0xFFFFFFFF)
    s = s ~ (s >> 17)
    s = s ~ ((s << 5) & 0xFFFFFFFF)
    s = s & 0xFFFFFFFF
    return s / 4294967296
  end
  function r.range(lo, hi) return lo + (hi - lo) * r.next() end
  function r.pick(t) return t[1 + math.floor(r.next() * #t) % #t] end
  return r
end

local function sampleRange(r, v)
  if type(v) == "table" then return r.range(v[1], v[2]) end
  return v
end

-- Sample one parameter vector from a template. w0 is the base footprint
-- before the climb that qualified the offender (see prepare); avail0 is the
-- availability at t = 0, after it.
function M.sample(tpl, r)
  local p = {
    name = r.pick(tpl.names),
    foreground = tpl.foreground == true,
    avail0 = sampleRange(r, tpl.avail0),
    w0 = sampleRange(r, tpl.w0),
    age0 = math.floor(sampleRange(r, tpl.age0)),
    peak0 = sampleRange(r, tpl.peak0 or 0),     -- the climb's rate before the alert, MB/min
    frozenCount = tpl.frozenCount or 0,
    -- How much of the growth the kernel absorbs by compression before it
    -- costs availability (1 = incompressible data, 2-3 = typical heaps).
    compress = sampleRange(r, tpl.compress or 1.5),
    phases = {},
    after = tpl.after or "hold",
  }
  local t = 0
  for _, ph in ipairs(tpl.phases or {}) do
    local dur = sampleRange(r, ph.dur)
    local rate = sampleRange(r, ph.rate)
    p.phases[#p.phases + 1] = { from = t, to = t + dur, rate = rate }
    t = t + dur
  end
  p.growthEnd = t
  if p.after == "exit" or p.after == "release" then
    p.releaseAt = math.max(p.growthEnd, sampleRange(r, tpl.releaseAt))
  end
  -- Growth through the alert's grace window, before t = 0: the template's
  -- own (graceRate, MB/s), else the trajectory's first phase continuing.
  if tpl.graceRate ~= nil then p.graceRate = sampleRange(r, tpl.graceRate) end
  return p
end

local PID = 4242
local OWN_UID = 501
-- Template names macOS runs under another user (as observed: mds_stores
-- under its own service user, backupd and mds as root, WindowServer under
-- its own). Production's policy gate (core.killAllowed: same uid only)
-- never freezes them, so no decision of a candidate's changes their fate.
local SYSTEM_OWNED = { mds_stores = 308, mds = 0, backupd = 0, ["backupd-helper"] = 0, logd = 0, WindowServer = 88 }
function M.ownerOf(name) return SYSTEM_OWNED[procs.friendlyName(name)] or OWN_UID end

-- Footprint at time t (MB). Before t = 0: the base, then the climb at the
-- template's peak rate on which the detector first tags the offender
-- extreme, ending at the alert's onset (onsetAt, a grace window before
-- t = 0), then growth at graceRate through the grace window. From t = 0:
-- the template's phases. A release gives the whole burst back (the base);
-- an exit leaves nothing.
function M.weightAt(p, t)
  if p.releaseAt and t >= p.releaseAt then
    return (p.after == "exit") and 0 or p.w0
  end
  if t < 0 then
    local cStart = p.onsetAt - p.climbSec
    if t <= cStart then return p.w0 end
    if t <= p.onsetAt then return p.w0 + p.climbRate * (t - cStart) end
    return p.wOn + p.graceRate * (t - p.onsetAt)
  end
  local w = p.wAt0
  for _, ph in ipairs(p.phases) do
    if t > ph.from then w = w + ph.rate * (math.min(t, ph.to) - ph.from) end
  end
  return w
end

local function fracOf(p, cfg) return 100 / cfg.totalMB / math.max(1, p.compress or 1) end

-- Availability at time t (percent): avail0 at t = 0, less what the
-- offender's footprint has grown since (net of compression).
function M.availAt(p, t, cfg)
  cfg = cfg or M.cfg
  return p.avail0 - (M.weightAt(p, t) - p.wAt0) * fracOf(p, cfg)
end

-- Sampler ticks from first to last (multiples of tickSec), feeding the
-- PRODUCTION tracker (memwatch_procs) one ps row per tick while the process
-- exists, and the production pressure state machine (memwatch_core) the
-- same tick's signals. The alert runs as production runs it: it rises (its
-- grace starting over) when the state goes critical with the process alive
-- to head it, as a runaway or, once its latch lapses, as the hog fallback,
-- and it ends only once the state has settled below critical for
-- settleSec. Grace accrues, interval by interval and only while critical,
-- while the offender heads the alert as extreme (a stalled interval counts
-- at most exposureStepMax). The PRODUCTION unattended gate
-- (core.unattendedGate), asked only while critical as production asks it,
-- says whether the tick could act. Returns ticks[t] = { alive, w, avail,
-- run (the tracker's runaway row for the offender, or nil), state, kern,
-- rates, exposureSec, gate }, plus the first tick the alert's head was
-- extreme (onset).
local function pressureOf(avail, slopeMBmin)
  local pressure = (20 - avail) / 20
  if pressure < 0 then pressure = 0 end
  -- Swap-out runs while there is pressure or growth; a machine with room
  -- and nothing growing goes quiet, so its state machine can calm.
  local swapBase = (pressure > 0 or slopeMBmin > 0) and 200 or 0
  return avail <= 10 and 4 or 2,
    { swapOut = math.floor(swapBase + pressure * 2200 + slopeMBmin / 8),
      comp = math.floor(500 + pressure * 4800 + slopeMBmin / 3) }, pressure
end

-- One tick of the alert, as production runs it (pure). st: { active,
-- exposureSec, prevT, headed, belowSince }. While critical: the alert rises
-- (grace starting over) when the process is alive to head it, and grace
-- accrues over the last interval if the offender headed it as extreme
-- (a stalled interval counts at most exposureStepMax). Below critical: no
-- grace accrues, and the alert ends once the state has stayed below for
-- settleSec. Returns st.
function M.alertStep(st, t, critical, alive, extreme, cfg)
  cfg = cfg or M.cfg
  if critical then
    st.belowSince = nil
    if not st.active and alive then st.active, st.exposureSec, st.prevT, st.headed = true, 0, nil, false end
    if st.headed and st.prevT then
      st.exposureSec = st.exposureSec + math.min(math.max(t - st.prevT, 0), cfg.exposureStepMax)
    end
    st.prevT = t
    st.headed = (st.active and alive and extreme) or false
  else
    st.prevT, st.headed = nil, false
    st.belowSince = st.belowSince or t
    if st.active and (t - st.belowSince) >= cfg.settleSec then st.active = false end
  end
  return st
end

function M.track(p, cfg, first, last)
  cfg = cfg or M.cfg
  local tr = procs.newTracker()
  local sm = core.newSMState(first)
  local ticks = {}
  local born = -p.age0
  -- On the sampler's grid, from the later of the first tick and the birth.
  local t0 = math.floor(math.max(first, born) / cfg.tickSec) * cfg.tickSec
  if t0 < born then t0 = t0 + cfg.tickSec end
  local alert, onset = { active = false, exposureSec = 0 }, nil
  for t = t0, last, cfg.tickSec do
    local alive = not (p.after == "exit" and p.releaseAt and t >= p.releaseAt)
    local w = M.weightAt(p, t)
    local rows = {}
    if alive then
      rows[1] = { pid = PID, uid = M.ownerOf(p.name), comm = p.name, rssMB = w, etimeSec = p.age0 + t }
    end
    procs.update(tr, rows, t, nil)
    local avail = M.availAt(p, t, cfg)
    local run
    for _, r in ipairs(procs.runaways(tr, t, sm.state, cfg.totalMB, t)) do
      if r.pid == PID then run = r end
    end
    local kern, rates, pressure = pressureOf(avail, run and run.slopeMBmin or 0)
    local sig = core.signals({ availPct = avail }, rates, kern, run ~= nil and run.kind == "extreme")
    core.smStep(sm, sig, t)
    local critical = sm.state == "critical"
    M.alertStep(alert, t, critical, alive, run ~= nil and run.kind == "extreme", cfg)
    if alert.headed and onset == nil then onset = t end
    local gate = "closed"
    if critical then
      gate = core.unattendedGate({
        kind = run and run.kind or (alive and "hog") or nil, alertActive = alert.active, hudHold = false,
        sameAsHud = alive, answered = false, interacted = false, final = false, bound = true,
        exposureSec = alert.exposureSec, graceSec = cfg.graceSec,
      })
    end
    ticks[t] = { t = t, alive = alive, w = w, avail = avail, run = run, state = sm.state,
                 kern = kern, rates = rates, pressure = pressure, exposureSec = alert.exposureSec, gate = gate }
  end
  return ticks, onset
end

-- The climb the detector qualified the offender on: at the template's peak
-- rate, the shortest whole number of ticks after which the production
-- tracker reads kind=extreme at the climb's last sample (the net route can
-- qualify a fast climb before the streak route's four rises), so the tag
-- first lands on that sample. nil when no climb that fits the ring does.
function M.climbFor(p, cfg)
  cfg = cfg or M.cfg
  local rate = (p.peak0 or 0) / 60
  if rate <= 0 then return nil end
  local maxSec = (procs.cfg.windowSamples - 1) * cfg.tickSec
  for sec = cfg.tickSec, maxSec, cfg.tickSec do
    local q = { w0 = p.w0, climbRate = rate, climbSec = sec, onsetAt = 0, graceRate = 0,
                wOn = p.w0 + rate * sec, wAt0 = p.w0 + rate * sec, avail0 = 50, compress = 1,
                phases = {}, age0 = sec + cfg.leadSec, after = "hold" }
    local ticks = M.track(q, cfg, -(sec + cfg.leadSec), 0)
    local k = ticks[0]
    if k and k.run and k.run.kind == "extreme" then return sec end
  end
  return nil
end

-- Derived fields, idempotent: the climb, the alert's onset a grace window
-- before t = 0, the growth through that window, and the footprint at t = 0.
function M.prepare(p, cfg)
  cfg = cfg or M.cfg
  if p.wAt0 then return p end
  p.climbRate = (p.peak0 or 0) / 60
  p.climbSec = M.climbFor(p, cfg)
  assert(p.climbSec, "no climb at peak0 " .. tostring(p.peak0) .. " MB/min qualifies kind=extreme")
  p.onsetAt = -cfg.graceSec
  if p.graceRate == nil then p.graceRate = p.phases[1] and p.phases[1].rate or 0 end
  -- The process lived through the grace window, the climb, and two quiet
  -- ticks before it (the ring the climb was measured against).
  assert(p.age0 >= cfg.graceSec + p.climbSec + 2 * cfg.tickSec,
    "the process is younger than its history: age0 " .. tostring(p.age0) .. " < grace "
      .. cfg.graceSec .. " + climb " .. p.climbSec .. " + two ticks")
  p.wOn = p.w0 + p.climbRate * p.climbSec
  p.wAt0 = p.wOn + p.graceRate * cfg.graceSec
  -- The history must fit the machine. The offender's weight is its logical
  -- footprint (resident plus compressed bytes, as production measures it),
  -- which compression lets exceed the machine; what must fit is the
  -- physical part: the footprint net of compression plus what is available.
  -- That sum is the same at every moment of a trajectory (what the offender
  -- takes, availability loses), so one check covers the whole history.
  local fill = M.fill(p, cfg)
  assert(fill <= cfg.maxFill, string.format(
    "the history needs %.0f%% of the machine (its footprint net of compression plus what is available; over %.0f%%)",
    fill * 100, cfg.maxFill * 100))
  return p
end

-- The share of the machine a trajectory needs: the offender's physical
-- footprint (net of compression) plus the available memory, constant over
-- the trajectory.
function M.fill(p, cfg)
  cfg = cfg or M.cfg
  return p.avail0 / 100 + p.wAt0 / (math.max(1, p.compress or 1) * cfg.totalMB)
end

-- The first time at or after t = 0 that availability reaches the
-- exhaustion floor while the offender still holds its growth, exactly
-- (growth is piecewise linear), or nil within the horizon.
local function exhaustAt(p, cfg)
  local needMB = (p.avail0 - cfg.exhaustPct) / fracOf(p, cfg)
  if needMB <= 0 then return 0 end
  local limit = math.min(cfg.horizonSec, p.releaseAt or math.huge)
  local grown = 0
  for _, ph in ipairs(p.phases) do
    if ph.from >= limit then break end
    local span = math.min(ph.to, limit) - ph.from
    if ph.rate > 0 and grown + ph.rate * span >= needMB then
      return ph.from + (needMB - grown) / ph.rate
    end
    grown = grown + ph.rate * span
  end
  return nil
end
M.exhaustAt = exhaustAt

-- Whether exhaustion comes first: at or before a hold resolves (a hold
-- crossing as its growth ends settles at the floor, starving anyway), but
-- strictly before a release or exit, which gives the memory back at that
-- instant. exhaustAt only looks while the offender holds its growth.
function M.exhaustsFirst(ttx, resolve, releases)
  if ttx == nil then return false end
  if releases then return ttx < resolve end
  return ttx <= resolve
end

-- The decision points, as production re-arms them: the first at grace
-- expiry (t = 0); each later one at the first tick a grace window or more
-- after the last at which the gate is open, the process alive and the
-- machine above the floor; at most decisionsMax. An offender the gate does
-- not admit at t = 0 is no episode: production's first decision would come
-- at some later open tick, off the time this episode is measured from.
function M.decisionTimes(ticks, cfg)
  cfg = cfg or M.cfg
  local function eligible(k) return k ~= nil and k.alive and k.gate == "open" and k.avail > cfg.exhaustPct end
  if not eligible(ticks[0]) then return {} end
  local times, t = { 0 }, cfg.graceSec
  while #times < cfg.decisionsMax and t <= cfg.horizonSec do
    if eligible(ticks[t]) then
      times[#times + 1] = t
      t = t + cfg.graceSec
    else
      t = t + cfg.tickSec
    end
  end
  return times
end

-- Simulate the trajectory and derive labels, exactly: no time grid stands
-- between a label and the trajectory it describes.
function M.simulate(p, cfg)
  cfg = cfg or M.cfg
  M.prepare(p, cfg)
  local ttx = exhaustAt(p, cfg)
  -- Resolution: exit/release time, else the end of growth for a hold.
  local resolve = p.releaseAt or p.growthEnd
  -- A hold that settles at or below the starvation line starves the
  -- machine for good. The line is read as the snapshot reports
  -- availability (whole percent, floored), so a plateau the model sees at
  -- the line is labeled at the line. A plateau that releases within the
  -- deferral bound is not starving: it resolves, and freezing it would only
  -- keep it from releasing.
  local plateau = (p.releaseAt == nil) and M.availAt(p, p.growthEnd, cfg) or nil
  local starving = plateau ~= nil and math.floor(plateau) <= cfg.starvePct
  local runaway = M.exhaustsFirst(ttx, resolve, p.releaseAt ~= nil) or starving
  local class
  if runaway then
    class = "runaway"
    if ttx == nil then ttx = cfg.deferralSec end
  elseif resolve <= cfg.deferralSec then
    class = "savable"
  else
    class = "late"
  end
  return { ttxSec = runaway and ttx or nil, resolvesBySec = (not runaway) and resolve or nil,
           runaway = runaway, class = class, plateauPct = plateau }
end

-- The model-input snapshot at a decision tick: the offender as the
-- production tracker reports it (kind, weight, rising-tail slope, peak,
-- age), the production state machine's state, and pressure fields
-- correlated with availability so the numbers read like a real machine.
local function snapshotAt(p, k)
  local run = k.run
  local offender = {
    name = p.name, kind = run.kind,
    weightMB = math.floor(run.weightMB), slopeMBmin = math.floor(run.slopeMBmin),
    peakSlopeMBmin = math.floor(run.peakSlopeMBmin),
    ageSec = run.ageSec, foreground = p.foreground or nil,
  }
  return {
    state = k.state,
    kern = k.kern,
    availPct = math.floor(k.avail),
    swapGB = math.floor((6 + k.pressure * 10) * 10) / 10,
    compressorGB = math.floor((24 + k.pressure * 8) * 10) / 10,
    swapoutRate = k.rates.swapOut,
    compRate = k.rates.comp,
    frozenCount = p.frozenCount,
    offender = offender,
    runaways = lfm.jsonArray({ { name = p.name, kind = offender.kind, weightMB = offender.weightMB,
                                 slopeMBmin = offender.slopeMBmin, peakSlopeMBmin = offender.peakSlopeMBmin,
                                 ageSec = offender.ageSec } }),
  }
end

-- A template's own stream: seeded by the id's content (FNV-1a), so two
-- templates never share draws.
local function idHash(s)
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end
  return h
end
M.idHash = idHash

-- Build one episode from a template and a seed. Decision points are where
-- production makes one: the process is alive, the production unattended
-- gate is open (the alert unanswered for its grace window, the offender
-- extreme at its head), and the machine is above the exhaustion floor.
function M.episode(tpl, seed, split, cfg)
  cfg = cfg or M.cfg
  local r = M.rng((seed * 7919 + idHash(tpl.id)) % 4294967296)
  local p = M.sample(tpl, r)
  local sim = M.simulate(p, cfg)
  local first = p.onsetAt - p.climbSec - cfg.leadSec
  local ticks, onset = M.track(p, cfg, first, cfg.horizonSec)
  -- The construction's invariant: the climb first qualifies the offender at
  -- its last sample, so the alert rises exactly a grace window before t = 0.
  assert(onset == p.onsetAt, "the alert rose at " .. tostring(onset) .. ", not at " .. p.onsetAt)
  local steps = lfm.jsonArray({})
  -- An offender production's policy gate refuses (another user's process,
  -- or a denylisted name) is never frozen, whatever a candidate says: no
  -- episode.
  local allowed = core.killAllowed({ pid = PID, uid = M.ownerOf(p.name), comm = p.name }, OWN_UID, 1)
  for _, t in ipairs(allowed and M.decisionTimes(ticks, cfg) or {}) do
    steps[#steps + 1] = { t = t, snapshot = snapshotAt(p, ticks[t]) }
  end
  return {
    id = string.format("%s-%s-s%d", split, tpl.id, seed),
    template = tpl.id, split = split, family = tpl.family,
    intendedClass = tpl.class,
    labels = {
      class = sim.class, runaway = sim.runaway,
      ttxSec = sim.ttxSec, resolvesBySec = sim.resolvesBySec,
      source = "simulator", rationale = tpl.rationale,
    },
    params = { avail0 = math.floor(p.avail0 * 10) / 10, w0 = math.floor(p.w0),
               wAt0 = math.floor(p.wAt0), climbSec = p.climbSec,
               age0 = p.age0, after = p.after, growthEnd = math.floor(p.growthEnd * 10) / 10,
               releaseAt = p.releaseAt and math.floor(p.releaseAt * 10) / 10 or nil },
    steps = steps,
  }
end

-- CLI
local function parseArgs(argv)
  local a = { split = "dev", seed = 1, per = 4 }
  local i = 1
  while i <= #argv do
    local k = argv[i]
    if k == "--templates" then a.templates = argv[i + 1]; i = i + 2
    elseif k == "--split" then a.split = argv[i + 1]; i = i + 2
    elseif k == "--seed" then a.seed = tonumber(argv[i + 1]); i = i + 2
    elseif k == "--per-template" then a.per = tonumber(argv[i + 1]); i = i + 2
    elseif k == "--out" then a.out = argv[i + 1]; i = i + 2
    else error("unknown argument " .. tostring(k)) end
  end
  return a
end

function M.main(argv)
  local a = parseArgs(argv)
  assert(a.templates and a.out, "usage: --templates <file> --out <dir> [--split s --seed n --per-template k]")
  local templates = dofile(a.templates)
  os.execute("mkdir -p '" .. a.out:gsub("'", "") .. "'")
  local counts = { runaway = 0, savable = 0, late = 0 }
  local n, noStep = 0, 0
  for _, tpl in ipairs(templates) do
    if tpl.split == nil or tpl.split == a.split then
      for k = 1, a.per do
        local ep = M.episode(tpl, a.seed * 1000 + k, a.split)
        if #ep.steps == 0 then
          noStep = noStep + 1   -- no decision point would ever exist; not an episode
        else
          local enc = assert(lfm.jsonEncode(ep))
          local f = assert(io.open(a.out .. "/" .. ep.id .. ".json", "w"))
          f:write(enc, "\n")
          f:close()
          counts[ep.labels.class] = counts[ep.labels.class] + 1
          n = n + 1
        end
      end
    end
  end
  print(string.format("wrote %d episodes to %s (runaway %d, savable %d, late %d; %d samples had no decision point)",
    n, a.out, counts.runaway, counts.savable, counts.late, noStep))
end

if arg and arg[0] and arg[0]:match("gen%-episodes%.lua$") then
  M.main(arg)
end

return M

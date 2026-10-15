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
-- An episode follows ONE such offender from grace expiry (t = 0) through the
-- later decision points at t = 60 and t = 120, exactly as production would
-- re-adjudicate it. A seeded trajectory model (the offender's growth phases,
-- then hold / exit / release) drives the machine's availability, and the
-- labels fall out of the simulation mechanically:
--
--   runaway       the trajectory exhausts the machine (availability <= the
--                 exhaustion floor) before it resolves, or it plateaus while
--                 holding the machine at or below the starvation line
--   ttxSec        seconds from t = 0 to exhaustion (runaways); a starving
--                 plateau is given the deferral bound (it must be frozen by
--                 then, and the deterministic floor guarantees it is)
--   resolvesBySec seconds until the offender exits, releases, or stops
--                 growing (non-runaways)
--   class         runaway | savable (resolves within the deferral bound
--                 without exhausting) | late (resolves after it; excluded
--                 from the wrongful-freeze count, the deterministic floor
--                 catches it regardless)
--
-- Decision points exist only where production would make one: the process
-- is alive, availability is above the exhaustion floor, and the detector
-- still reads kind=extreme (its latch runs 120 s past the last qualifying
-- growth sample). Each step carries the full model-input snapshot.
--
-- Usage (from the repo root):
--   lua eval/gen-episodes.lua --templates eval/episode-templates.lua \
--       --split dev --seed 1 --per-template 4 --out eval/episodes/dev
-- A sealed set is generated the same way from templates kept OUTSIDE this
-- repository, so its templates never become public or training material.

package.path = "lua/?.lua;" .. package.path
local lfm = require("memwatch_lfm")

local M = {}

M.cfg = {
  totalMB         = 36864,  -- the deployment machine's RAM
  exhaustPct      = 5,      -- availability at which the machine is lost
  starvePct       = 8,      -- a plateau holding the machine at or below this starves it
  decisionTimes   = { 0, 60, 120 },
  deferralSec     = 120,    -- maxDeferSec: the deterministic floor fires here
  horizonSec      = 180,
  latchSec        = 120,    -- the detector's extreme latch
  extremeRateMBs  = 150,    -- 9000 MB/min streak route
  extremeNetMB    = 6000,   -- +6 GB across the 60 s window route
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

-- Sample one parameter vector from a template.
function M.sample(tpl, r)
  local p = {
    name = r.pick(tpl.names),
    foreground = tpl.foreground == true,
    avail0 = sampleRange(r, tpl.avail0),
    w0 = sampleRange(r, tpl.w0),
    age0 = math.floor(sampleRange(r, tpl.age0)),
    peak0 = sampleRange(r, tpl.peak0 or 0),     -- MB/min peak observed before t = 0
    stoppedBefore = sampleRange(r, tpl.stoppedBefore or 0), -- s before t = 0 growth last qualified
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
  return p
end

-- Offender weight at time t (MB) and its growth rate (MB/s), from params.
local function rateAt(p, t)
  for _, ph in ipairs(p.phases) do
    if t >= ph.from and t < ph.to then return ph.rate end
  end
  return 0
end

local function weightAt(p, t)
  local w = p.w0
  for _, ph in ipairs(p.phases) do
    if t > ph.from then
      w = w + ph.rate * (math.min(t, ph.to) - ph.from)
    end
  end
  return w
end

-- Simulate the whole trajectory at 1 s resolution and derive labels.
function M.simulate(p, cfg)
  cfg = cfg or M.cfg
  local frac = 100 / cfg.totalMB / math.max(1, p.compress or 1)
  local tl = {}
  local ttx = nil
  local lastQualify = -p.stoppedBefore
  local peak = p.peak0
  local exited = false
  for t = 0, cfg.horizonSec do
    local rate = rateAt(p, t)
    local w = weightAt(p, t)
    local released = (p.releaseAt ~= nil) and t >= p.releaseAt
    local avail = p.avail0 - (w - p.w0) * frac
    if released then
      avail = p.avail0  -- the burst's memory comes back (exit or release)
      exited = exited or (p.after == "exit")
    end
    if not released then
      local back = t >= 60 and weightAt(p, t - 60) or nil
      if rate >= cfg.extremeRateMBs or (back and (w - back) >= cfg.extremeNetMB) then
        lastQualify = t
      end
      if rate * 60 > peak then peak = rate * 60 end
    end
    tl[t] = { w = w, rate = released and 0 or rate, avail = avail, alive = not (released and p.after == "exit"),
              released = released, kindExtreme = (t - lastQualify) < cfg.latchSec, peak = peak }
    if ttx == nil and avail <= cfg.exhaustPct and not released then ttx = t end
  end
  -- Resolution: exit/release time, else the end of growth for a hold.
  local resolve
  if p.releaseAt then
    resolve = p.releaseAt
  else
    resolve = p.growthEnd
  end
  local holdAvail = tl[math.min(cfg.horizonSec, math.max(0, math.floor(resolve)))].avail
  local starving = (p.releaseAt == nil) and holdAvail <= cfg.starvePct
  local runaway = (ttx ~= nil and ttx < resolve) or starving
  local class
  if runaway then
    class = "runaway"
    if ttx == nil then ttx = cfg.deferralSec end
  elseif resolve <= cfg.deferralSec then
    class = "savable"
  else
    class = "late"
  end
  return { timeline = tl, ttxSec = runaway and ttx or nil, resolvesBySec = (not runaway) and resolve or nil,
           runaway = runaway, class = class }
end

-- Correlated pressure fields so the numbers read like a real machine.
local function snapshotAt(p, step, sim, t)
  local avail = step.avail
  local pressure = (20 - avail) / 20
  if pressure < 0 then pressure = 0 end
  local slopeMBmin = math.floor(step.rate * 60)
  local offender = {
    name = p.name, kind = step.kindExtreme and "extreme" or "hog",
    weightMB = math.floor(step.w), slopeMBmin = slopeMBmin,
    peakSlopeMBmin = math.floor(step.peak),
    ageSec = p.age0 + t, foreground = p.foreground or nil,
  }
  return {
    state = avail <= 12 and "critical" or "elevated",
    kern = avail <= 10 and 4 or 2,
    availPct = math.floor(avail),
    swapGB = math.floor((6 + pressure * 10) * 10) / 10,
    compressorGB = math.floor((24 + pressure * 8) * 10) / 10,
    swapoutRate = math.floor(200 + pressure * 2200 + slopeMBmin / 8),
    compRate = math.floor(500 + pressure * 4800 + slopeMBmin / 3),
    frozenCount = p.frozenCount,
    offender = offender,
    runaways = lfm.jsonArray({ { name = p.name, kind = offender.kind, weightMB = offender.weightMB,
                                 slopeMBmin = slopeMBmin, peakSlopeMBmin = offender.peakSlopeMBmin,
                                 ageSec = offender.ageSec } }),
  }
end

-- Build one episode from a template and a seed.
function M.episode(tpl, seed, split, cfg)
  cfg = cfg or M.cfg
  local r = M.rng(seed * 7919 + (#tpl.id * 131))
  local p = M.sample(tpl, r)
  local sim = M.simulate(p, cfg)
  local steps = lfm.jsonArray({})
  for _, t in ipairs(cfg.decisionTimes) do
    local st = sim.timeline[t]
    if st and st.alive and st.kindExtreme and st.avail > cfg.exhaustPct then
      steps[#steps + 1] = { t = t, snapshot = snapshotAt(p, st, sim, t) }
    end
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
               age0 = p.age0, after = p.after, growthEnd = math.floor(p.growthEnd),
               releaseAt = p.releaseAt and math.floor(p.releaseAt) or nil },
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

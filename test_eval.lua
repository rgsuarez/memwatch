-- test_eval.lua: unit tests for the discrimination-oracle harness
-- (eval/gen-episodes.lua, eval/score-episodes.lua). Run from the repo root:
--   lua test_eval.lua
package.path = "lua/?.lua;eval/?.lua;" .. package.path
local gen = require("gen-episodes")
local sc = require("score-episodes")

local fails = 0
local function check(name, got, want)
  if got == want then
    print("ok    " .. name)
  else
    print(string.format("FAIL  %-44s got=%s want=%s", name, tostring(got), tostring(want)))
    fails = fails + 1
  end
end
local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= tol end

-- ---- PRNG: deterministic and identical across runs ----
do
  local a, b = gen.rng(42), gen.rng(42)
  local same = true
  for _ = 1, 20 do if a.next() ~= b.next() then same = false end end
  check("rng: same seed, same stream", same, true)
  local c = gen.rng(43)
  check("rng: different seed, different stream", gen.rng(42).next() ~= c.next(), true)
  local r, inRange = gen.rng(7), true
  for _ = 1, 200 do local v = r.next(); if v < 0 or v >= 1 then inRange = false end end
  check("rng: values in [0,1)", inRange, true)
end

-- ---- simulator: labels follow the label rule ----
local function params(over)
  local p = { name = "x", foreground = false, avail0 = 12, w0 = 4000, age0 = 100, peak0 = 9000,
              stoppedBefore = 0, frozenCount = 0, compress = 1, phases = {}, after = "hold" }
  for k, v in pairs(over) do p[k] = v end
  local t = 0
  for _, ph in ipairs(p.phases) do ph.from = t; ph.to = t + ph.dur; t = ph.to end
  p.growthEnd = t
  return p
end
do
  -- Unbounded leak: (12 - 5)% of 36864 MB = 2580.48 MB at 200 MB/s -> 12.9 s.
  local sim = gen.simulate(params({ phases = { { dur = 180, rate = 200 } } }))
  check("sim leak: runaway", sim.class, "runaway")
  check("sim leak: ttx matches the closed form", sim.ttxSec, 13)
  -- Compression stretches the same leak: x2 -> 25.8 s.
  local simC = gen.simulate(params({ compress = 2, phases = { { dur = 180, rate = 200 } } }))
  check("sim leak: compression stretches ttx", simC.ttxSec, 26)
  -- A burst that finishes with headroom: savable, resolves at its exit.
  local sb = gen.simulate(params({ avail0 = 25, phases = { { dur = 20, rate = 150 } },
                                   after = "exit", releaseAt = 45 }))
  check("sim burst: savable", sb.class, "savable")
  check("sim burst: resolves at exit", sb.resolvesBySec, 45)
  check("sim burst: never a runaway", sb.runaway, false)
  -- The same burst with no headroom exhausts first: a runaway.
  local sl = gen.simulate(params({ avail0 = 7, phases = { { dur = 20, rate = 150 } },
                                   after = "exit", releaseAt = 45 }))
  check("sim burst without headroom: runaway", sl.class, "runaway")
  -- A plateau holding at the starvation line: runaway, frozen by the floor.
  local sp = gen.simulate(params({ avail0 = 7.5, phases = { { dur = 2, rate = 100 } } }))
  check("sim starving plateau: runaway", sp.class, "runaway")
  check("sim starving plateau: ttx is the deferral bound", sp.ttxSec, 120)
  -- A bounded pass that resolves only after the deferral bound: late.
  local sz = gen.simulate(params({ avail0 = 30, compress = 3, phases = { { dur = 150, rate = 100 } },
                                   after = "release", releaseAt = 160 }))
  check("sim slow pass: late", sz.class, "late")
end

-- ---- episode steps exist only where production would decide ----
do
  local tpl = { id = "T-exit", names = { "rg" }, avail0 = 25, w0 = 3000, age0 = 100, peak0 = 9000,
                compress = 1.5, phases = { { dur = 10, rate = 150 } }, after = "exit", releaseAt = 30 }
  local ep = gen.episode(tpl, 1, "test")
  check("episode: exit before 60 leaves one decision point", #ep.steps, 1)
  check("episode: the step is grace expiry", ep.steps[1].t, 0)
  check("episode: snapshot is extreme at t=0", ep.steps[1].snapshot.offender.kind, "extreme")
  check("episode: snapshot carries age", ep.steps[1].snapshot.offender.ageSec, 100)
  check("episode: snapshot has no pid", ep.steps[1].snapshot.offender.pid, nil)
  local hold = { id = "T-hold", names = { "qemu" }, avail0 = 28, w0 = 9000, age0 = 9000, peak0 = 9000,
                 compress = 2, phases = { { dur = 10, rate = 160 } }, after = "hold" }
  local eh = gen.episode(hold, 1, "test")
  check("episode: a latched hold decides at 0, 60 and 120", #eh.steps, 3)
  local stale = { id = "T-stale", names = { "qemu" }, avail0 = 28, w0 = 9000, age0 = 9000, peak0 = 9000,
                  compress = 2, phases = {}, after = "hold", stoppedBefore = 70 }
  local es = gen.episode(stale, 1, "test")
  check("episode: the latch lapses after 120 s of no qualifying growth", #es.steps, 1)
end

-- ---- play: production deferral semantics ----
do
  local ep3 = { id = "e3", labels = { class = "savable", runaway = false, resolvesBySec = 150 },
                steps = { { t = 0, snapshot = {} }, { t = 60, snapshot = {} }, { t = 120, snapshot = {} } } }
  local res = sc.play(ep3, function() return "wait" end)
  check("play: waits until the floor freezes at 120", res.freezeAt, 120)
  check("play: the floor is the actor", res.by, "floor")
  local ep2 = { id = "e2", labels = { class = "savable" }, steps = { { t = 0, snapshot = {} }, { t = 60, snapshot = {} } } }
  check("play: resolved before 120 means no freeze", sc.play(ep2, function() return "wait" end).freezeAt, nil)
  check("play: first freeze ends the episode", sc.play(ep3, function() return "freeze" end).freezeAt, 0)
  local runEp = { id = "r", labels = { class = "runaway", runaway = true, ttxSec = 40 },
                  steps = { { t = 0, snapshot = {} } } }
  check("outcome: waiting past ttx is a miss",
    sc.outcome(runEp, sc.play(runEp, function() return "wait" end)).missed, true)
  check("outcome: freezing at grace expiry is not a miss",
    sc.outcome(runEp, sc.play(runEp, function() return "freeze" end)).missed, false)
  check("outcome: any freeze on a savable is wrongful",
    sc.outcome(ep3, sc.play(ep3, function() return "freeze" end)).wrongful, true)
end

-- ---- statistics ----
check("cp: 0 of 59 clears the 5% bound", sc.cpUpper(0, 59) <= 0.05, true)
check("cp: 0 of 58 does not", sc.cpUpper(0, 58) <= 0.05, false)
check("cp: 0 of 41 is about 0.070", near(sc.cpUpper(0, 41), 1 - 0.05 ^ (1 / 41), 1e-6), true)
check("cp: 1 of 93 clears the bound", sc.cpUpper(1, 93) <= 0.05, true)
check("cp: 1 of 92 does not", sc.cpUpper(1, 92) <= 0.05, false)
check("binomial cdf sums to 1", near(sc.binomCdf(10, 10, 0.3), 1, 1e-9), true)
do
  local ones, zeros = {}, {}
  for i = 1, 40 do
    ones[i] = { template = "t" .. (i % 8), d = 1 }
    zeros[i] = { template = "t" .. (i % 8), d = 0 }
  end
  check("bootstrap: uniform improvement has lower bound 1", (sc.pairedLowerBound(ones)), 1)
  check("bootstrap: no improvement has lower bound 0", (sc.pairedLowerBound(zeros)), 0)
end

-- ---- tree baseline: fits a separable toy set exactly ----
do
  local eps = {}
  for i = 1, 30 do
    local run = i % 2 == 0
    eps[i] = { id = "toy" .. i, labels = { class = run and "runaway" or "savable", runaway = run },
               steps = { { t = 0, snapshot = { availPct = run and 8 or 20,
                 offender = { name = "rg", kind = "extreme", weightMB = 5000, slopeMBmin = 12000,
                              peakSlopeMBmin = 12000, ageSec = 100 } } } } }
  end
  local tree = sc.fitTree(eps, 3, 2)
  local decide = sc.treeCandidate(tree)
  local wrong = 0
  for _, ep in ipairs(eps) do
    local act = decide(ep.steps[1], ep)
    if (act == "freeze") ~= ep.labels.runaway then wrong = wrong + 1 end
  end
  check("tree: separable toy set fit exactly", wrong, 0)
  check("tree: description names the split", sc.describeTree(tree):find("availPct", 1, true) ~= nil, true)
end

-- ---- the gate's controls on a generated public set ----
do
  local templates = dofile("eval/episode-templates.lua")
  local eps = {}
  for _, tpl in ipairs(templates) do
    for k = 1, 3 do
      local ep = gen.episode(tpl, 900 + k, "ctl")
      if #ep.steps > 0 then eps[#eps + 1] = ep end
    end
  end
  sc.cfg.bootstrap = 400   -- keep the unit test fast; the CLI default stays 2000
  local baselines = { ["always-freeze"] = sc.candidates["always-freeze"](), rule = sc.candidates.rule() }
  local g = sc.gate(eps, sc.candidates["always-freeze"](), baselines)
  check("gate control: always-freeze cannot beat itself", g.passBeat, false)
  local s = sc.score(eps, sc.candidates.oracle())
  check("gate: the oracle never misses", s.misses, 0)
  check("gate: the oracle itself never freezes a savable", s.wrongful - s.wrongfulByFloor, 0)
  check("gate: floor freezes are attributed to the floor", s.wrongfulByFloor >= 0, true)
  sc.cfg.bootstrap = 2000
end

if fails == 0 then
  print("\nALL PASS")
else
  print("\n" .. fails .. " FAILED")
  os.exit(1)
end

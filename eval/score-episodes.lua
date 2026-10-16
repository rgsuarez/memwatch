-- score-episodes.lua: score decision candidates on simulated episodes and
-- apply the discrimination gate (G7).
--
-- A candidate is played through each episode the way production defers:
-- at each decision point (grace expiry, then each re-arm) it says freeze or
-- wait; the first freeze ends the episode; a wait defers, but once the
-- deferral bound has elapsed since the first wait the deterministic floor
-- supersedes a wait with its freeze. As in production, the candidate is
-- asked first, so a freeze it makes itself is its own, never the floor's.
-- Outcomes, from the simulator's labels:
--
--   missed runaway   a runaway whose first freeze lands after ttxSec (or never)
--   wrongful freeze  any freeze on a savable episode (it would have resolved)
--   late episodes    excluded from both (the floor catches them regardless)
--
-- G7 passes when the miss rate's one-sided 95% Clopper-Pearson upper bound
-- is at most 5% AND the candidate's wrongful-freeze rate beats the best
-- deterministic baseline that itself meets the miss bound: the one-sided
-- 95% lower bound of the paired improvement, bootstrapped by template, must
-- be above zero. Calibration (G8) is reported as a diagnostic only.
--
-- Usage (from the repo root):
--   lua eval/score-episodes.lua gate --dir <episodes> --fit-dir <dev episodes> \
--       --candidate <name> [--out result.json]
--   lua eval/score-episodes.lua controls --dir <episodes> --fit-dir <dev episodes>
--   lua eval/score-episodes.lua tau --dir <dev episodes> --decisions <rows.jsonl> [--key <key.json>]
--   gate also takes --prevalence <weights.json> ({ category = count } from field
--   decisions) for a field-weighted diagnostic beside the pre-registered gate.
-- Candidates: always-freeze | never-act | rule | ttx | tree | oracle | noisy-oracle |
--   decisions (recorded model decisions, --decisions <rows.jsonl> [--key] --tau <x>).
--   ttx and tree are the baselines as fit on --fit-dir (the ttx horizon fit
--   there), the same functions the gate compares against.

package.path = "lua/?.lua;eval/?.lua;" .. package.path
local lfm = require("memwatch_lfm")

local M = {}

M.cfg = {
  deferralSec  = 120,
  missBound    = 0.05,
  confidence   = 0.95,
  bootstrap    = 2000,
  bootSeed     = 20261015,
  noisyFlip    = 0.10,
  powerShare   = 0.50,   -- the power control's share of the oracle's improvement
  powerTarget  = 0.80,
  ruleMinAvail = 12,   -- the category rule waits only with at least this much headroom
  totalMB      = 36864, -- the deployment machine, for the time-to-exhaustion baseline
  floorPct     = 5,     -- exhaustion, as the labels define it
  starvePct    = 8,     -- the starvation line, as the labels define it
  -- the time-to-exhaustion baseline freezes when exhaustion is projected
  -- sooner than its horizon, fit on dev (fitTtx); this is the default when
  -- no horizon meets the miss bound there: the next decision point
  ttxHorizonSec = 60,
}

------------------------------------------------------------------------------
-- deterministic PRNG (xorshift32), shared semantics with gen-episodes.lua
------------------------------------------------------------------------------
local function rng(seed)
  local s = (seed * 2654435761 + 1013904223) % 4294967296
  if s == 0 then s = 2463534242 end
  return function()
    s = s ~ ((s << 13) & 0xFFFFFFFF)
    s = s ~ (s >> 17)
    s = s ~ ((s << 5) & 0xFFFFFFFF)
    s = s & 0xFFFFFFFF
    return s / 4294967296
  end
end
M.rng = rng

------------------------------------------------------------------------------
-- play one episode
------------------------------------------------------------------------------

-- decide(step, ep) -> "freeze" | "wait", pFreeze (optional number)
function M.play(ep, decide, cfg)
  cfg = cfg or M.cfg
  local firstWaitT = nil
  local trace = {}
  for _, st in ipairs(ep.steps) do
    local act, p = decide(st, ep)
    if act == "freeze" then
      trace[#trace + 1] = { t = st.t, act = act, p = p }
      return { freezeAt = st.t, by = "candidate", trace = trace }
    end
    -- The deterministic floor: once the deferral bound has elapsed since the
    -- first wait, a wait is superseded by the freeze. cfg.floorMaxAvailPct
    -- (unset = always) is the proposed contract variant: the floor fires
    -- only while headroom is at or below that level, and otherwise the
    -- candidate keeps deciding.
    local floorDue = firstWaitT and (st.t - firstWaitT) >= cfg.deferralSec
    if floorDue and cfg.floorMaxAvailPct
       and (st.snapshot and st.snapshot.availPct or 0) > cfg.floorMaxAvailPct then
      floorDue = false
    end
    if floorDue then
      trace[#trace + 1] = { t = st.t, act = "freeze", by = "floor", p = p }
      return { freezeAt = st.t, by = "floor", trace = trace }
    end
    trace[#trace + 1] = { t = st.t, act = act, p = p }
    firstWaitT = firstWaitT or st.t
  end
  return { freezeAt = nil, by = nil, trace = trace }
end

function M.outcome(ep, res)
  local L = ep.labels
  if L.class == "runaway" then
    local missed = res.freezeAt == nil or res.freezeAt > (L.ttxSec or 0)
    return { class = "runaway", missed = missed, wrongful = false }
  elseif L.class == "savable" then
    return { class = "savable", missed = false, wrongful = res.freezeAt ~= nil }
  end
  return { class = "late", missed = false, wrongful = false }
end

------------------------------------------------------------------------------
-- statistics
------------------------------------------------------------------------------

-- P(X <= k) for X ~ Binomial(n, p), computed in log space.
local function lgamma(x)
  -- Lanczos approximation (g = 7), accurate to ~1e-15 for x > 0.
  local c = { 0.99999999999980993, 676.5203681218851, -1259.1392167224028,
              771.32342877765313, -176.61502916214059, 12.507343278686905,
              -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7 }
  if x < 0.5 then return math.log(math.pi / math.abs(math.sin(math.pi * x))) - lgamma(1 - x) end
  x = x - 1
  local a = c[1]
  local t = x + 7.5
  for i = 1, 8 do a = a + c[i + 1] / (x + i) end
  return 0.5 * math.log(2 * math.pi) + (x + 0.5) * math.log(t) - t + math.log(a)
end

local function binomCdf(k, n, p)
  if p <= 0 then return 1 end
  if p >= 1 then return (k >= n) and 1 or 0 end
  local s = 0
  for i = 0, k do
    local lc = lgamma(n + 1) - lgamma(i + 1) - lgamma(n - i + 1)
    s = s + math.exp(lc + i * math.log(p) + (n - i) * math.log(1 - p))
  end
  return math.min(1, s)
end
M.binomCdf = binomCdf

-- One-sided upper Clopper-Pearson bound for k events in n trials.
function M.cpUpper(k, n, conf)
  conf = conf or M.cfg.confidence
  if n == 0 then return 1 end
  if k >= n then return 1 end
  local alpha = 1 - conf
  local lo, hi = k / n, 1
  for _ = 1, 100 do
    local mid = (lo + hi) / 2
    if binomCdf(k, n, mid) > alpha then lo = mid else hi = mid end
  end
  return hi
end

-- Paired improvement d_i = baseline_wrongful_i - candidate_wrongful_i over
-- savable episodes; one-sided lower bound by a bootstrap that resamples
-- TEMPLATES (jittered copies of one template are not independent).
function M.pairedLowerBound(pairs, cfg)
  cfg = cfg or M.cfg
  local byTpl, tpls = {}, {}
  for _, pr in ipairs(pairs) do
    if not byTpl[pr.template] then byTpl[pr.template] = {}; tpls[#tpls + 1] = pr.template end
    table.insert(byTpl[pr.template], pr.d)
  end
  table.sort(tpls)
  if #tpls == 0 then return nil, 0 end
  local function meanOf(sample)
    local s, n = 0, 0
    for _, t in ipairs(sample) do
      for _, d in ipairs(byTpl[t]) do s = s + d; n = n + 1 end
    end
    return n > 0 and s / n or 0
  end
  local point = meanOf(tpls)
  local r = rng(cfg.bootSeed)
  local stats = {}
  for b = 1, cfg.bootstrap do
    local sample = {}
    for i = 1, #tpls do sample[i] = tpls[1 + math.floor(r() * #tpls) % #tpls] end
    stats[b] = meanOf(sample)
  end
  table.sort(stats)
  local idx = math.max(1, math.floor((1 - cfg.confidence) * cfg.bootstrap))
  return stats[idx], point
end

------------------------------------------------------------------------------
-- candidates
------------------------------------------------------------------------------

local SELF_LIMITING = {
  ["search-tool"] = true, ["build-tool"] = true, ["package-manager"] = true,
  system = true, media = true, editor = true, vm = true, ["model-server"] = true,
  database = true,
}

local function catOf(st)
  local off = st and st.snapshot and st.snapshot.offender
  return off and lfm.categorize(off.name, nil) or "unknown"
end

-- Feature vector for the tree baseline (everything a model would see).
function M.features(st)
  local o = st.snapshot.offender
  local peak = (o.peakSlopeMBmin and o.peakSlopeMBmin > 0) and o.peakSlopeMBmin or 1
  return {
    availPct = st.snapshot.availPct or 0,
    slopeMBmin = o.slopeMBmin or 0,
    peakSlopeMBmin = o.peakSlopeMBmin or 0,
    slopeRatio = (o.slopeMBmin or 0) / peak,
    weightMB = o.weightMB or 0,
    ageSec = o.ageSec or 0,
    stepT = st.t,
    foreground = o.foreground and 1 or 0,
    category = catOf(st),
  }
end

M.candidates = {}

M.candidates["always-freeze"] = function() return function() return "freeze", 1 end end

M.candidates["never-act"] = function() return function() return "wait", 0 end end

-- The best obvious deterministic rule: wait on a self-limiting category with
-- headroom while it is not still growing at full tilt; freeze otherwise.
M.candidates["rule"] = function()
  return function(st)
    local f = M.features(st)
    if SELF_LIMITING[f.category] and f.availPct >= M.cfg.ruleMinAvail then
      if st.t == 0 or f.slopeRatio < 0.5 then return "wait", 0.2 end
    end
    return "freeze", 0.9
  end
end

-- A physics baseline with nothing fitted: project the time until the
-- machine reaches the exhaustion floor at the offender's current growth,
-- and freeze when that comes sooner than the horizon (the deferral bound
-- plus a decision step), or when a plateaued process holds the machine at
-- the starvation line. Unlike the tree it learns nothing from templates, so
-- it cannot borrow the headroom ranges a template designer happened to use.
function M.ttxSec(st, cfg)
  cfg = cfg or M.cfg
  local f = M.features(st)
  local room = (f.availPct - cfg.floorPct) / 100 * cfg.totalMB
  if room <= 0 then return 0 end
  if f.slopeMBmin <= 0 then return math.huge end
  return room / f.slopeMBmin * 60
end
M.candidates["ttx"] = function(horizonSec)
  local horizon = horizonSec or M.cfg.ttxHorizonSec
  return function(st)
    local f = M.features(st)
    if f.availPct <= M.cfg.starvePct then return "freeze", 0.95 end
    local ttx = M.ttxSec(st)
    if ttx <= horizon then return "freeze", 0.9 end
    return "wait", 0.2
  end
end

-- The ttx baseline's horizon, fit on dev like the tree: the fewest wrongful
-- freezes among the horizons (0 to 180 s, by 5) that meet the miss bound
-- there, ties to the longer, more cautious one. At grace expiry every
-- offender already grows at the extreme rate, so any horizon near a minute
-- freezes nearly everything; fitting is what makes this baseline more than
-- always-freeze. No horizon meets the bound: the default.
function M.fitTtx(fitEpisodes, cfg)
  cfg = cfg or M.cfg
  local best, bestWrongful = nil, nil
  for h = 0, 180, 5 do
    local s = M.score(fitEpisodes, M.candidates.ttx(h), cfg)
    if s.missUpper <= cfg.missBound and (bestWrongful == nil or s.wrongful <= bestWrongful) then
      best, bestWrongful = h, s.wrongful
    end
  end
  return best or cfg.ttxHorizonSec
end

M.candidates["oracle"] = function()
  return function(_, ep) return ep.labels.runaway and "freeze" or "wait", ep.labels.runaway and 1 or 0 end
end

-- The gate's power control: a candidate halfway (by default) between the
-- best baseline and the label oracle. Per episode, chosen deterministically
-- from its id and the seed, it decides like the oracle with probability
-- `share` and like the baseline otherwise, so its true improvement over that
-- baseline is `share` of the oracle's. The gate is adequately powered when
-- such a candidate passes in at least powerTarget of the seeds. (A label
-- oracle with flipped labels is no power control: flipping a runaway's label
-- makes it miss, so it fails the miss bound by construction.)
function M.mixedOracle(baseline, share, seed)
  local oracle = M.candidates["oracle"]()
  return function(st, ep)
    local h = tonumber(lfm.snapshotHash(ep.id .. ":mix:" .. tostring(seed)), 16) or 0
    if (h % 100000) / 100000 < share then return oracle(st, ep) end
    return baseline(st, ep)
  end
end

-- A label-reading oracle with a fixed fraction of episodes flipped
-- (deterministic per episode id): a robustness diagnostic, not the power
-- control (see mixedOracle).
function M.noisyOracle(flip, seed)
  return function(_, ep)
    local h = tonumber(lfm.snapshotHash(ep.id .. ":" .. tostring(seed)), 16) or 0
    local u = (h % 100000) / 100000
    local truth = ep.labels.runaway
    if u < flip then truth = not truth end
    return truth and "freeze" or "wait", truth and 1 or 0
  end
end

-- Recorded model decisions replayed through the production wait rail:
-- decisions[episodeId][t] = { action, pWait }. A model's wait defers only
-- when lfm.waitHonored passes at tauWait, exactly as the live rail decides:
-- a wait recorded with no probability (a chat verdict, whose confidence is
-- self-reported) is never honored, at any threshold. A step with no
-- recorded decision gets the deterministic freeze. tauWait = 0 honors every
-- wait that carries a probability. The score is 1 - P(wait) (with no
-- probability, the recorded action: 0 for a wait, 1 for a freeze).
function M.decisionsCandidate(decisions, tauWait)
  return function(st, ep)
    local d = decisions[ep.id] and decisions[ep.id][st.t]
    if not d then return "freeze", 1 end
    local p = type(d.pWait) == "number" and d.pWait or nil
    local score = p and (1 - p) or (d.action == "wait" and 0 or 1)
    if lfm.waitHonored({ action = d.action, pWait = p }, tauWait) then return "wait", score end
    return "freeze", score
  end
end

-- Load recorded decisions from JSONL rows { episode, t, action, pWait }.
-- With a key file (an independent judge's opaque ids), rows are
-- { qid, action, p_runaway } and the key maps each qid to its episode and
-- step; P(wait) is 1 - p_runaway. Returns the decisions, the row count, and
-- how many rows carry no probability (their waits are never honored).
function M.loadDecisions(path, keyPath)
  local key = nil
  if keyPath then
    local kf = assert(io.open(keyPath, "r"))
    key = assert(lfm.jsonDecode(kf:read("a"))).rows
    kf:close()
  end
  local out, n, noP = {}, 0, 0
  for line in io.lines(path) do
    if line:match("%S") then
      local r = assert(lfm.jsonDecode(line), "bad decisions row")
      local ep, t, pWait = r.episode, r.t, r.pWait
      if key then
        local k = assert(key[r.qid], "decision for an unknown qid")
        ep, t = k.episode, k.t
        pWait = type(r.p_runaway) == "number" and (1 - r.p_runaway) or nil
      end
      assert(r.action == "freeze" or r.action == "wait", "decision action must be freeze or wait")
      out[ep] = out[ep] or {}
      out[ep][t] = { action = r.action, pWait = pWait }
      n = n + 1
      if type(pWait) ~= "number" then noP = noP + 1 end
    end
  end
  return out, n, noP
end

-- The tau sweep on dev: score the replayed decisions at each threshold and
-- pick the one with the fewest wrongful freezes among those meeting the miss
-- bound. If none meets it (an underpowered set), the fewest misses wins and
-- the result says so. Choose on dev, freeze, then score held-out once.
function M.chooseTau(episodes, decisions, grid, cfg)
  cfg = cfg or M.cfg
  local rows, best = {}, nil
  for _, tau in ipairs(grid) do
    local s = M.score(episodes, M.decisionsCandidate(decisions, tau), cfg)
    local r = { tau = tau, misses = s.misses, missUpper = s.missUpper, wrongful = s.wrongful,
                wrongfulRate = s.wrongfulRate, meets = s.missUpper <= cfg.missBound }
    rows[#rows + 1] = r
    -- Ties go to the stricter threshold: it costs no wrongful freezes here
    -- and can only catch more runaways.
    local better = best == nil
      or (r.meets and not best.meets)
      or (r.meets == best.meets and r.meets and (r.wrongful < best.wrongful
          or (r.wrongful == best.wrongful and r.tau > best.tau)))
      or (r.meets == best.meets and not r.meets and (r.misses < best.misses
          or (r.misses == best.misses and r.tau > best.tau)))
    if better then best = r end
  end
  return best, rows
end

------------------------------------------------------------------------------
-- depth-limited decision tree (CART, Gini), fit on dev steps
------------------------------------------------------------------------------

local NUMERIC = { "availPct", "slopeMBmin", "peakSlopeMBmin", "slopeRatio", "weightMB", "ageSec", "stepT", "foreground" }

local function gini(rows)
  local n, pos = #rows, 0
  for _, r in ipairs(rows) do pos = pos + r.y end
  if n == 0 then return 0 end
  local p = pos / n
  return 2 * p * (1 - p)
end

local function leaf(rows)
  local pos = 0
  for _, r in ipairs(rows) do pos = pos + r.y end
  return { leaf = true, pFreeze = (#rows > 0) and pos / #rows or 1, n = #rows }
end

local function bestSplit(rows)
  local base = gini(rows)
  local best = nil
  local n = #rows
  local function consider(test, desc)
    local l, r = {}, {}
    for _, row in ipairs(rows) do
      if test(row.f) then l[#l + 1] = row else r[#r + 1] = row end
    end
    if #l == 0 or #r == 0 then return end
    local g = (#l / n) * gini(l) + (#r / n) * gini(r)
    if base - g > 1e-9 and (best == nil or g < best.g) then
      best = { g = g, test = test, desc = desc, l = l, r = r }
    end
  end
  for _, key in ipairs(NUMERIC) do
    local vals, seen = {}, {}
    for _, row in ipairs(rows) do
      local v = row.f[key]
      if not seen[v] then seen[v] = true; vals[#vals + 1] = v end
    end
    table.sort(vals)
    for i = 1, #vals - 1 do
      local thr = (vals[i] + vals[i + 1]) / 2
      consider(function(f) return f[key] <= thr end, { key = key, op = "<=", thr = thr })
    end
  end
  local cats = {}
  for _, row in ipairs(rows) do cats[row.f.category] = true end
  for c in pairs(cats) do
    consider(function(f) return f.category == c end, { key = "category", op = "==", val = c })
  end
  return best
end

local function grow(rows, depth, maxDepth, minLeaf)
  if depth >= maxDepth or #rows < 2 * minLeaf or gini(rows) == 0 then return leaf(rows) end
  local s = bestSplit(rows)
  if not s or #s.l < minLeaf or #s.r < minLeaf then return leaf(rows) end
  return { desc = s.desc, yes = grow(s.l, depth + 1, maxDepth, minLeaf),
           no = grow(s.r, depth + 1, maxDepth, minLeaf) }
end

local function evalTree(node, f)
  while not node.leaf do
    local d = node.desc
    local yes
    if d.op == "==" then yes = (f[d.key] == d.val) else yes = (f[d.key] <= d.thr) end
    node = yes and node.yes or node.no
  end
  return node.pFreeze
end

-- Training rows: every decision point of every runaway (target freeze) and
-- savable (target wait) episode; late episodes carry no target.
function M.fitTree(episodes, maxDepth, minLeaf)
  local rows = {}
  for _, ep in ipairs(episodes) do
    if ep.labels.class ~= "late" then
      for _, st in ipairs(ep.steps) do
        rows[#rows + 1] = { f = M.features(st), y = ep.labels.runaway and 1 or 0 }
      end
    end
  end
  return grow(rows, 0, maxDepth or 3, minLeaf or 5)
end

function M.describeTree(node, indent)
  indent = indent or ""
  if node.leaf then
    return string.format("%s-> %s (pFreeze %.2f, n=%d)\n", indent,
      node.pFreeze >= 0.5 and "freeze" or "wait", node.pFreeze, node.n)
  end
  local d = node.desc
  local q = d.op == "==" and string.format("%s == %q", d.key, d.val)
    or string.format("%s <= %.4g", d.key, d.thr)
  return string.format("%sif %s:\n", indent, q) .. M.describeTree(node.yes, indent .. "  ")
    .. string.format("%selse:\n", indent) .. M.describeTree(node.no, indent .. "  ")
end

function M.treeCandidate(tree)
  return function(st)
    local p = evalTree(tree, M.features(st))
    return p >= 0.5 and "freeze" or "wait", p
  end
end

------------------------------------------------------------------------------
-- scoring and the gate
------------------------------------------------------------------------------

function M.loadDir(dir)
  local eps = {}
  local p = io.popen("ls '" .. dir:gsub("'", "") .. "'")
  for name in p:lines() do
    if name:match("%.json$") then
      local f = assert(io.open(dir .. "/" .. name, "r"))
      eps[#eps + 1] = assert(lfm.jsonDecode(f:read("a")))
      f:close()
    end
  end
  p:close()
  table.sort(eps, function(a, b) return a.id < b.id end)
  return eps
end

function M.score(episodes, decide, cfg)
  cfg = cfg or M.cfg
  -- wrongfulByFloor: savables frozen by the deterministic floor rather than
  -- the candidate (a bystander still latched extreme at the deferral bound);
  -- no candidate can prevent those, so they cancel in a paired comparison.
  local s = { nRunaway = 0, nSavable = 0, nLate = 0, misses = 0, wrongful = 0,
              wrongfulByFloor = 0, perEpisode = {}, perFamily = {}, perCategory = {} }
  for _, ep in ipairs(episodes) do
    local res = M.play(ep, decide, cfg)
    local o = M.outcome(ep, res)
    local fam = s.perFamily[ep.family] or { runaway = 0, savable = 0, misses = 0, wrongful = 0 }
    s.perFamily[ep.family] = fam
    -- The category the model sees (production categorizer over the name).
    local cname = ep.steps[1] and catOf(ep.steps[1]) or "unknown"
    local cat = s.perCategory[cname] or { runaway = 0, savable = 0, misses = 0, wrongful = 0 }
    s.perCategory[cname] = cat
    if o.class == "runaway" then
      s.nRunaway = s.nRunaway + 1; fam.runaway = fam.runaway + 1; cat.runaway = cat.runaway + 1
      if o.missed then s.misses = s.misses + 1; fam.misses = fam.misses + 1; cat.misses = cat.misses + 1 end
    elseif o.class == "savable" then
      s.nSavable = s.nSavable + 1; fam.savable = fam.savable + 1; cat.savable = cat.savable + 1
      if o.wrongful then
        s.wrongful = s.wrongful + 1; fam.wrongful = fam.wrongful + 1; cat.wrongful = cat.wrongful + 1
        if res.by == "floor" then s.wrongfulByFloor = s.wrongfulByFloor + 1 end
      end
    else
      s.nLate = s.nLate + 1
    end
    s.perEpisode[ep.id] = { template = ep.template, class = o.class, freezeAt = res.freezeAt,
                            by = res.by, missed = o.missed, wrongful = o.wrongful }
  end
  s.missRate = s.nRunaway > 0 and s.misses / s.nRunaway or 0
  s.missUpper = M.cpUpper(s.misses, s.nRunaway, cfg.confidence)
  s.wrongfulRate = s.nSavable > 0 and s.wrongful / s.nSavable or 0
  return s
end

-- A diagnostic, not the gate: miss and wrongful-freeze rates re-weighted by
-- how often each category actually reaches a decision point in the field
-- (weights = { [category] = count }). The held-out set balances categories
-- on purpose, so its raw rates say little about the processes a deployment
-- meets most. Categories with weight but no episodes of a class are left out
-- of that class's average and listed in `uncovered`.
function M.prevalenceWeighted(s, weights)
  local out = { missRate = nil, wrongfulRate = nil, uncovered = {} }
  local mW, mSum, wW, wSum = 0, 0, 0, 0
  for cname, w in pairs(weights or {}) do
    local c = s.perCategory[cname]
    if c and c.runaway > 0 then mW = mW + w; mSum = mSum + w * (c.misses / c.runaway) end
    if c and c.savable > 0 then wW = wW + w; wSum = wSum + w * (c.wrongful / c.savable) end
    if not c or c.runaway == 0 or c.savable == 0 then out.uncovered[#out.uncovered + 1] = cname end
  end
  table.sort(out.uncovered)
  if mW > 0 then out.missRate = mSum / mW end
  if wW > 0 then out.wrongfulRate = wSum / wW end
  return out
end

-- Paired comparison of two scored runs over the same savable episodes.
function M.compare(cand, base, cfg)
  local prs = {}
  for id, ce in pairs(cand.perEpisode) do
    local be = base.perEpisode[id]
    if ce.class == "savable" and be then
      prs[#prs + 1] = { template = ce.template, d = (be.wrongful and 1 or 0) - (ce.wrongful and 1 or 0) }
    end
  end
  return M.pairedLowerBound(prs, cfg)
end

function M.gate(episodes, candDecide, baselines, cfg)
  cfg = cfg or M.cfg
  local cand = M.score(episodes, candDecide, cfg)
  local best, bestName = nil, nil
  local baseScores = {}
  -- The fewest wrongful freezes among the baselines meeting the miss bound;
  -- ties go to fewer misses, then to the first name. The choice never
  -- depends on a table's iteration order.
  local names = {}
  for name in pairs(baselines) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local b = M.score(episodes, baselines[name], cfg)
    baseScores[name] = b
    if b.missUpper <= cfg.missBound and (best == nil or b.wrongfulRate < best.wrongfulRate
        or (b.wrongfulRate == best.wrongfulRate and b.misses < best.misses)) then
      best, bestName = b, name
    end
  end
  local lower, point = nil, nil
  if best then lower, point = M.compare(cand, best, cfg) end
  local passMiss = cand.missUpper <= cfg.missBound
  local passBeat = (lower ~= nil) and lower > 0
  return {
    candidate = cand, bestBaseline = bestName, baselines = baseScores,
    improvementLower = lower, improvementPoint = point,
    passMiss = passMiss, passBeat = passBeat, pass = passMiss and passBeat,
  }
end

------------------------------------------------------------------------------
-- CLI
------------------------------------------------------------------------------

local function parse(argv)
  local a = { cmd = argv[1] }
  local i = 2
  while i <= #argv do
    local k, v = argv[i], argv[i + 1]
    if k == "--dir" then a.dir = v elseif k == "--fit-dir" then a.fitDir = v
    elseif k == "--candidate" then a.candidate = v elseif k == "--out" then a.out = v
    elseif k == "--tree-depth" then a.depth = tonumber(v)
    elseif k == "--decisions" then a.decisions = v elseif k == "--key" then a.key = v
    elseif k == "--tau" then a.tau = tonumber(v)
    elseif k == "--prevalence" then a.prevalence = v
    else error("unknown argument " .. tostring(k)) end
    i = i + 2
  end
  return a
end

local function summary(name, s)
  return string.format("%-16s runaway %3d  misses %3d (rate %.3f, upper95 %.3f)  savable %3d  wrongful %3d (rate %.3f; %d by the floor)  late %d",
    name, s.nRunaway, s.misses, s.missRate, s.missUpper, s.nSavable, s.wrongful, s.wrongfulRate,
    s.wrongfulByFloor, s.nLate)
end

-- The deterministic baselines, the fitted ones fit on fitEpisodes (dev).
-- Returns them, the tree, and the ttx horizon.
function M.baselineSet(fitEpisodes, depth)
  local tree = M.fitTree(fitEpisodes, depth or 3, 5)
  local horizon = M.fitTtx(fitEpisodes)
  return {
    ["always-freeze"] = M.candidates["always-freeze"](),
    ["rule"] = M.candidates["rule"](),
    ["ttx"] = M.candidates["ttx"](horizon),
    ["tree"] = M.treeCandidate(tree),
  }, tree, horizon
end

-- The power control: a candidate a share of the way from the best baseline
-- to the oracle (mixed by episode), gated on trials seeds. Returns how many
-- passed.
function M.powerControl(eps, baselines, bestName, trials, cfg)
  cfg = cfg or M.cfg
  local passes = 0
  for seed = 1, trials do
    local mix = M.mixedOracle(baselines[bestName], cfg.powerShare, seed)
    if M.gate(eps, mix, baselines, cfg).pass then passes = passes + 1 end
  end
  return passes
end

-- A note for rows that carry no probability: the rail never honors their
-- waits, so their candidate freezes there at every threshold.
local function noProbabilityNote(n, noP)
  if noP == 0 then return nil end
  if noP == n then
    return string.format("note: none of the %d rows carries a probability; the wait rail honors none of their waits, so no threshold changes the outcome", n)
  end
  return string.format("note: %d of %d rows carry no probability; the wait rail never honors their waits", noP, n)
end

local function sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

-- A directory's physical path (symlinks and relative spellings resolved),
-- or nil when it does not exist.
function M.realDir(dir)
  local p = io.popen("cd '" .. tostring(dir):gsub("'", "'\\''") .. "' 2>/dev/null && pwd -P")
  local out = p and p:read("l")
  if p then p:close() end
  return out
end

-- The decide function a gate run scores: a fitted baseline by its fitted
-- self (tree, ttx), recorded decisions through the rail, or a candidate.
function M.resolveCandidate(name, baselines, a)
  a = a or {}
  if name == "noisy-oracle" then return M.noisyOracle(M.cfg.noisyFlip, 1) end
  if name == "tree" or name == "ttx" then return baselines[name] end
  if name == "decisions" then
    assert(a.decisions, "--decisions is required for the decisions candidate")
    assert(a.tau, "--tau is required for the decisions candidate (choose it on dev)")
    local decisions, n, noP = M.loadDecisions(a.decisions, a.key)
    local note = noProbabilityNote(n, noP)
    if note then print(note) end
    return M.decisionsCandidate(decisions, a.tau)
  end
  if M.candidates[name] then return M.candidates[name]() end
  error("unknown candidate " .. name)
end

-- Returns the exit status: 0, or 1 when the gate fails or a control does.
function M.main(argv)
  local status = 0
  local a = parse(argv)
  assert(a.dir, "--dir is required")
  local eps = M.loadDir(a.dir)
  -- The tree baseline is fit on another split, never on the episodes it is
  -- scored on: a gate or a control run must name it, and it must not be the
  -- evaluated directory under another spelling.
  if a.cmd == "gate" or a.cmd == "controls" then
    assert(a.fitDir, "--fit-dir is required (the dev split the tree is fit on)")
    local fitReal = assert(M.realDir(a.fitDir), "--fit-dir does not exist")
    assert(fitReal ~= M.realDir(a.dir), "--fit-dir is the evaluated directory; fit the tree on another split")
  end
  local fitEps = a.fitDir and M.loadDir(a.fitDir) or eps
  -- A split with no runaway or no savable episode fits nothing: the tree
  -- would be one leaf and the ttx horizon its default, weakening the gate.
  if a.cmd == "gate" or a.cmd == "controls" then
    local has = {}
    for _, ep in ipairs(fitEps) do has[ep.labels and ep.labels.class or "?"] = true end
    assert(has.runaway and has.savable,
      "--fit-dir has no runaway or no savable episode; the baselines cannot be fit on it")
    -- Another directory holding the same episodes (a copy, or the same
    -- templates and seeds regenerated under another split label) is the
    -- same split: episodes are compared by what they hold, not by id.
    local function content(ep)
      return lfm.jsonEncode({ template = ep.template, labels = ep.labels, steps = ep.steps })
    end
    local scored = {}
    for _, ep in ipairs(eps) do scored[content(ep)] = ep.id end
    for _, ep in ipairs(fitEps) do
      local twin = scored[content(ep)]
      assert(not twin, "--fit-dir holds " .. tostring(ep.id) .. ", the same episode as " .. tostring(twin)
        .. " in the evaluated set")
    end
  end
  local baselines, tree, horizon = M.baselineSet(fitEps, a.depth)
  if a.cmd == "gate" then
    local name = a.candidate or "oracle"
    local decide = M.resolveCandidate(name, baselines, a)
    local g = M.gate(eps, decide, baselines)
    for _, bn in ipairs(sortedKeys(g.baselines)) do print(summary("base:" .. bn, g.baselines[bn])) end
    print(summary("cand:" .. name, g.candidate))
    if a.prevalence then
      local pf = assert(io.open(a.prevalence, "r"))
      local weights = assert(lfm.jsonDecode(pf:read("a")), "bad --prevalence file")
      pf:close()
      local rows = { { "cand:" .. name, g.candidate } }
      for _, bn in ipairs(sortedKeys(g.baselines)) do rows[#rows + 1] = { "base:" .. bn, g.baselines[bn] } end
      for _, r in ipairs(rows) do
        local pw = M.prevalenceWeighted(r[2], weights)
        print(string.format("%-16s field-weighted: miss %s  wrongful %s%s", r[1],
          pw.missRate and string.format("%.3f", pw.missRate) or "n/a",
          pw.wrongfulRate and string.format("%.3f", pw.wrongfulRate) or "n/a",
          #pw.uncovered > 0 and ("  (not covered: " .. table.concat(pw.uncovered, ",") .. ")") or ""))
      end
    end
    print(string.format("best baseline: %s  paired improvement point %.3f lower95 %s  ->  G7 %s",
      tostring(g.bestBaseline), g.improvementPoint or 0, g.improvementLower and string.format("%.3f", g.improvementLower) or "n/a",
      g.pass and "PASS" or "FAIL"))
    status = g.pass and 0 or 1
    print("tree baseline (fit on " .. (a.fitDir or a.dir) .. "):\n" .. M.describeTree(tree, "  "))
    print(string.format("ttx baseline horizon (fit on the same split): %d s", horizon))
    if a.out then
      local f = assert(io.open(a.out, "w"))
      f:write(assert(lfm.jsonEncode({ candidate = name, pass = g.pass, passMiss = g.passMiss, passBeat = g.passBeat,
        bestBaseline = g.bestBaseline, improvementLower = g.improvementLower, improvementPoint = g.improvementPoint,
        missUpper = g.candidate.missUpper, missRate = g.candidate.missRate, wrongfulRate = g.candidate.wrongfulRate,
        nRunaway = g.candidate.nRunaway, nSavable = g.candidate.nSavable, nLate = g.candidate.nLate })), "\n")
      f:close()
    end
  elseif a.cmd == "tau" then
    assert(a.decisions, "--decisions is required")
    local decisions, n, noP = M.loadDecisions(a.decisions, a.key)
    local note = noProbabilityNote(n, noP)
    if note then print(note) end
    local grid = { 0, 0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95, 0.98, 0.99, 1.01 }
    local best, rows = M.chooseTau(eps, decisions, grid)
    for _, r in ipairs(rows) do
      print(string.format("tau %.2f  misses %3d (upper95 %.3f)  wrongful %3d (rate %.3f)  %s", r.tau, r.misses,
        r.missUpper, r.wrongful, r.wrongfulRate, r.meets and "meets bound" or "misses bound"))
    end
    print(string.format("chosen tau %.2f (%s)", best.tau, best.meets and "fewest wrongful within the miss bound"
      or "no threshold meets the miss bound on this set; fewest misses"))
  elseif a.cmd == "controls" then
    local gF = M.gate(eps, M.candidates["always-freeze"](), baselines)
    local gO = M.gate(eps, M.candidates["oracle"](), baselines)
    print(string.format("control always-freeze must FAIL: %s", gF.pass and "FAILED (gate passed it)" or "ok (failed)"))
    print(string.format("control oracle must PASS: %s", gO.pass and "ok (passed)" or "FAILED (gate failed it)"))
    if gF.pass or not gO.pass then status = 1 end
    -- An undecidable set (no baseline meets the miss bound: too few
    -- runaways, 59 at zero misses) or an underpowered one fails the run.
    if not gO.bestBaseline then
      print("power: no baseline meets the miss bound on this set; the gate compares against nothing (UNDECIDABLE)")
      status = 1
    else
      local trials = 50
      local passes = M.powerControl(eps, baselines, gO.bestBaseline, trials)
      local powered = (passes / trials) >= M.cfg.powerTarget
      print(string.format("power: a candidate %.0f%% of the way from %s to the oracle passed %d/%d seeds (target >= %.0f%%): %s",
        M.cfg.powerShare * 100, gO.bestBaseline, passes, trials, M.cfg.powerTarget * 100,
        powered and "ok" or "UNDERPOWERED"))
      if not powered then status = 1 end
    end
  else
    error("usage: score-episodes.lua gate|controls|tau --dir <episodes> [--fit-dir <dev>] [--candidate <name>]")
  end
  return status
end

if arg and arg[0] and arg[0]:match("score%-episodes%.lua$") then
  os.exit(M.main(arg))
end

return M

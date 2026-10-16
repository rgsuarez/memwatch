-- score-episodes.lua: score decision candidates on simulated episodes and
-- apply the discrimination gate (G7).
--
-- A candidate is played through each episode the way production defers:
-- at each decision point (grace expiry, then each re-arm) it says freeze or
-- wait; the first freeze ends the episode; a wait defers, and once the
-- deferral bound has elapsed since the first wait, production's floor
-- decides (lfm.floorActs): it freezes at or below its headroom threshold,
-- on headroom it cannot read, or at its hold cap, at a decision point or on
-- any open tick after a held wait; otherwise the wait holds. A wait still
-- held when the episode ends is no freeze. As in production, the candidate
-- is asked first, so a freeze it makes itself is its own, never the
-- floor's.
-- Outcomes, from the simulator's labels:
--
--   missed runaway   a runaway whose first freeze lands after ttxSec (or never)
--   wrongful freeze  any freeze on a savable episode (it would have resolved)
--   late episodes    excluded from both: they resolve on their own, but only
--                    after the deferral bound, so neither answer is clearly
--                    right (a starving plateau is a runaway, never late)
--
-- G7 passes when the miss rate's one-sided 95% Clopper-Pearson upper bound
-- is at most 5% AND the candidate's wrongful-freeze rate beats the best
-- deterministic baseline that itself meets the miss bound: the one-sided
-- 95% lower bound of the paired improvement, bootstrapped by template, must
-- be above zero.
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
local core = require("memwatch_core")

local M = {}

M.cfg = {
  deferralSec  = lfm.cfg.maxDeferSec,   -- production's deferral bound (its default)
  -- production's deferral floor past the bound (lfm.floorActs): the headroom
  -- it acts at or below (0 acts at the bound), the hold cap, and the grace
  -- window its every-tick check runs within after a held wait
  floorAvailPct = lfm.cfg.floorAvailPct,
  maxHoldSec   = lfm.cfg.maxHoldSec,
  graceSec     = core.cfg.cool.autoKillGraceSec,
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
  -- sooner than its horizon, fit on dev (fitTtx); this is the horizon of an
  -- unfitted ttx candidate: the next decision point
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

-- Production's deferral floor (lfm.floorActs), the one function the live
-- step asks: past the bound it acts at or below floorAvailPct of headroom,
-- on headroom it cannot read, or once maxHoldSec has run since the first
-- wait; otherwise the wait holds. Returns why it acts, or nil.
local function floorWhy(firstAt, avail, now, cfg)
  return lfm.floorActs({ firstAt = firstAt }, { availKnown = avail ~= nil, availPct = avail }, now,
    { floorAvailPct = cfg.floorAvailPct or M.cfg.floorAvailPct, maxHoldSec = cfg.maxHoldSec or M.cfg.maxHoldSec })
end

-- decide(step, ep) -> "freeze" | "wait", pFreeze (optional number)
-- The candidate is asked at each decision point, and production's floor
-- decides as production's does: at a decision point past the bound, on the
-- headroom of that tick; and, once a wait is held past the bound, on every
-- open tick after it until the next decision point (within a grace window
-- of the held decision), reading each tick's raw headroom from the
-- episode's floorTicks. An episode without them is read on its decision
-- points alone, from each step's snapshot.
function M.play(ep, decide, cfg)
  cfg = cfg or M.cfg
  -- A partial cfg (a test's) takes the scorer's defaults for what it leaves out.
  local bound, grace = cfg.deferralSec or M.cfg.deferralSec, cfg.graceSec or M.cfg.graceSec
  local firstWaitT, seq, heldAt = nil, nil, nil
  local trace = {}
  local byT = {}
  for _, k in ipairs(ep.floorTicks or {}) do byT[k.t] = k end
  local function headroomAt(st)
    local k = byT[st.t]
    if k then return k.avail end
    return st.snapshot and st.snapshot.availPct or nil
  end
  local function floorTick(untilT)
    if heldAt == nil then return nil end
    local stop = math.min(untilT, heldAt + grace)
    for _, k in ipairs(ep.floorTicks or {}) do
      if k.t > heldAt and k.t < stop and k.open == true then
        local why = floorWhy(firstWaitT, k.avail, k.t, cfg)
        if why then return k.t, why end
      end
    end
    return nil
  end
  local function floorFreeze(t, why, p)
    trace[#trace + 1] = { t = t, act = "freeze", by = "floor", why = why, p = p }
    return { freezeAt = t, by = "floor", why = why, trace = trace }
  end
  for i, st in ipairs(ep.steps) do
    local ft, fwhy = floorTick(st.t)
    if ft then return floorFreeze(ft, fwhy) end
    heldAt = nil
    -- A decision under a new alert starts a new sequence, as production's
    -- episode reset does once an alert settles: the deferral starts over.
    if i > 1 and st.alertSeq ~= seq then firstWaitT = nil end
    seq = st.alertSeq
    local act, p = decide(st, ep)
    if act == "freeze" then
      trace[#trace + 1] = { t = st.t, act = act, p = p }
      return { freezeAt = st.t, by = "candidate", trace = trace }
    end
    -- A wait, folded into the deferral as production's step folds it: the
    -- bound runs from the first wait (this one, if it is the first).
    firstWaitT = firstWaitT or st.t
    if (st.t - firstWaitT) >= bound then
      local why = floorWhy(firstWaitT, headroomAt(st), st.t, cfg)
      if why then return floorFreeze(st.t, why, p) end
      heldAt = st.t
    end
    trace[#trace + 1] = { t = st.t, act = act, p = p }
  end
  local ft, fwhy = floorTick(math.huge)
  if ft then return floorFreeze(ft, fwhy) end
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
-- always-freeze. A fit split too small to certify the bound at any horizon
-- (fewer runaways than a zero-miss bound needs) is fit on its misses: the
-- fewest, then the fewest wrongful freezes, never a fixed default that
-- would quietly weaken the comparator. Returns the horizon, and whether it
-- met the bound.
function M.fitTtx(fitEpisodes, cfg)
  cfg = cfg or M.cfg
  local best, key = nil, nil
  for h = 0, 180, 5 do
    local s = M.score(fitEpisodes, M.candidates.ttx(h), cfg)
    local k = (s.missUpper <= cfg.missBound) and { 0, 0, s.wrongful } or { 1, s.misses, s.wrongful }
    if key == nil or k[1] < key[1]
       or (k[1] == key[1] and (k[2] < key[2] or (k[2] == key[2] and k[3] <= key[3]))) then
      best, key = h, k
    end
  end
  return best, key[1] == 0
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

-- Recorded model decisions replayed through the proposed wait rail
-- (lfm.waitHonored), the contract a model would be wired under before it
-- may defer anything live: decisions[episodeId][t] = { action, pWait }. A
-- model's wait defers only when the rail passes at tauWait, and a wait
-- recorded with no probability (a chat verdict, whose confidence is
-- self-reported) is never honored, at any threshold. The live path does
-- not consult the rail yet: it defers on any model wait, through
-- applyVerdict and the deferral bound, so this replay scores the stricter,
-- proposed contract. A step with no
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
  local out, n, noP, invalid = {}, 0, 0, 0
  -- One run per file: the rows a runner writes say what asked them and
  -- which run wrote them, and rows from two runs (two models, or two
  -- partial runs of one) would score as one candidate no output names.
  local origin
  for line in io.lines(path) do
    if line:match("%S") then
      local r = assert(lfm.jsonDecode(line), "bad decisions row")
      local ep, t, pWait = r.episode, r.t, r.pWait
      local hash = r.snapshotHash
      if key then
        local k = assert(key[r.qid], "decision for an unknown qid")
        -- A key carries each step's snapshot hash, as a runner's row does. A
        -- row that carries its own is evidence of what it answered, so the
        -- key never overwrites it: the two must agree, and the key's fills
        -- in only for a row that has none.
        ep, t = k.episode, k.t
        if hash ~= nil and k.snapshotHash ~= nil and hash ~= k.snapshotHash then
          error(string.format("row %s carries snapshot %s but the key gives %s for its step: the rows and the key"
            .. " were made from different episodes; rebuild the key, or record the rows again, from the episodes scored",
            tostring(r.qid), tostring(hash), tostring(k.snapshotHash)), 0)
        end
        hash = hash or k.snapshotHash
        pWait = type(r.p_runaway) == "number" and (1 - r.p_runaway) or nil
      end
      assert(r.action == "freeze" or r.action == "wait", "decision action must be freeze or wait")
      local who = string.format("%s/%s/%s/%s/%s", tostring(r.variant), tostring(r.api), tostring(r.model),
        tostring(r.label), tostring(r.run))
      origin = origin or who
      if who ~= origin then
        error("the decisions come from more than one run (" .. origin .. " and " .. who .. "); score one run's rows", 0)
      end
      out[ep] = out[ep] or {}
      if out[ep][t] then
        -- Through a key, a step can repeat because the key maps two qids to
        -- it: the key's defect, not the rows'.
        local why = key and ": a qid repeats in the rows, or the key maps two qids to that step"
          or "; score one run's rows"
        error(string.format("the decision for %s at %s s appears twice%s", tostring(ep), tostring(t), why), 0)
      end
      out[ep][t] = { action = r.action, pWait = pWait, hash = hash }
      n = n + 1
      if type(pWait) ~= "number" then noP = noP + 1 end
      if r.valid == false then invalid = invalid + 1 end
    end
  end
  return out, n, noP, invalid
end

-- The hash a recorded decision carries of the input it answered: the
-- step's snapshot as the episode file holds it. The runner computes the
-- same (eval/bakeoff.lua, episodes mode); the end-to-end test pins that the
-- two agree.
function M.stepHash(st)
  return lfm.snapshotHash(assert(lfm.jsonEncode(st.snapshot or {})))
end

-- Do the recorded decisions answer these episodes' inputs? Episode ids are
-- the same for every regeneration of a split, so a decisions file recorded
-- before the generator changed still covers a new one by id. Returns how
-- many decision points' rows were recorded on another snapshot, and how
-- many carry no hash to check.
function M.contentCheck(episodes, decisions)
  local mismatched, unchecked = 0, 0
  for _, ep in ipairs(episodes) do
    for _, st in ipairs(ep.steps) do
      local d = decisions[ep.id] and decisions[ep.id][st.t]
      if d then
        if d.hash == nil then unchecked = unchecked + 1
        elseif d.hash ~= M.stepHash(st) then mismatched = mismatched + 1 end
      end
    end
  end
  return mismatched, unchecked
end

-- How many of the episodes' decision points carry no recorded decision
-- (scored as the deterministic freeze, so a short or mismatched file makes
-- a model look like always-freeze there). Returns missing, total.
function M.coverage(episodes, decisions)
  local missing, total = 0, 0
  for _, ep in ipairs(episodes) do
    for _, st in ipairs(ep.steps) do
      total = total + 1
      if not (decisions[ep.id] and decisions[ep.id][st.t]) then missing = missing + 1 end
    end
  end
  return missing, total
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
  -- Categories in sorted order: of equally good splits the first is kept,
  -- so the tree never depends on a table's iteration order.
  local seenCat, cats = {}, {}
  for _, row in ipairs(rows) do
    if not seenCat[row.f.category] then seenCat[row.f.category] = true; cats[#cats + 1] = row.f.category end
  end
  table.sort(cats)
  for _, c in ipairs(cats) do
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

-- An episode's identity, for the duplicate and overlap checks: its inputs
-- (each step's time and snapshot) and its outcome labels. The inputs alone,
-- so a field a later generator adds to a step (alertSeq, say) cannot make an
-- older copy of the same episode look new.
function M.fingerprint(ep)
  local L = ep.labels or {}
  local inputs = {}
  for i, st in ipairs(ep.steps or {}) do inputs[i] = { t = st.t, snapshot = st.snapshot } end
  return lfm.jsonEncode({ steps = lfm.jsonArray(inputs), class = L.class, runaway = L.runaway,
                          ttxSec = L.ttxSec, resolvesBySec = L.resolvesBySec })
end

-- Everything the replay reads from an episode: each step's time and
-- snapshot, whether it starts a new alert, the floor's ticks, and the outcome
-- labels. Two episodes alike in all of it are the same trajectory, whatever
-- their ids or the template they are filed under (a copy relabeled to another
-- template would otherwise count as another bootstrap group); two that differ
-- in any of it can score apart (the same snapshots over different raw
-- headroom, say), so a split may hold both. The replay reads an alert only as
-- a change from the step before (M.play), so the identity holds that change,
-- not the alert's number: a copy with its alerts renumbered is the same
-- episode.
function M.replayPrint(ep)
  local L = ep.labels or {}
  local steps = {}
  for i, st in ipairs(ep.steps or {}) do
    local prev = ep.steps[i - 1]
    steps[i] = { t = st.t, newAlert = i > 1 and st.alertSeq ~= prev.alertSeq, snapshot = st.snapshot }
  end
  return lfm.jsonEncode({ steps = lfm.jsonArray(steps), floorTicks = lfm.jsonArray(ep.floorTicks or {}),
                          class = L.class, runaway = L.runaway, ttxSec = L.ttxSec, resolvesBySec = L.resolvesBySec })
end

-- Every episode in a directory, each once: a copied file (the same episode
-- under another file name or id) would be scored twice, counting toward the
-- decisive size and the miss bound, so a directory holding one is refused.
-- Within a split, the same episode is the same id or the same replay inputs
-- (M.replayPrint); across splits the overlap check reads the coarser
-- M.fingerprint, which fails safe.
function M.loadDir(dir)
  local eps = {}
  local byId, byPrint = {}, {}
  local p = io.popen("ls '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
  for name in p:lines() do
    if name:match("%.json$") then
      local f = assert(io.open(dir .. "/" .. name, "r"))
      local ep = assert(lfm.jsonDecode(f:read("a")))
      f:close()
      -- Every episode carries its id (the generator writes one): rows, keys
      -- and the sort all read it.
      if type(ep.id) ~= "string" or ep.id == "" then
        p:close()
        error(string.format("%s/%s carries no episode id (ids are non-empty strings)", dir, name), 0)
      end
      local fp = M.replayPrint(ep)
      local first = byId[ep.id] or byPrint[fp]
      if first then
        p:close()
        error(string.format("%s holds the same episode twice (%s and %s): score each episode once", dir, first, name), 0)
      end
      byId[ep.id] = name
      byPrint[fp] = name
      eps[#eps + 1] = ep
    end
  end
  p:close()
  table.sort(eps, function(a, b) return a.id < b.id end)
  return eps
end

function M.score(episodes, decide, cfg)
  cfg = cfg or M.cfg
  -- wrongfulByFloor: savables frozen by the deferral floor rather than the
  -- candidate (a bystander still latched extreme past the bound with its
  -- headroom at or below the floor's threshold); a candidate's wait cannot
  -- prevent those, and freezing earlier is wrongful too, so they cancel in a
  -- paired comparison.
  local s = { nRunaway = 0, nSavable = 0, nLate = 0, misses = 0, wrongful = 0,
              wrongfulByFloor = 0, perEpisode = {}, perFamily = {}, perCategory = {} }
  for _, ep in ipairs(episodes) do
    local res = M.play(ep, decide, cfg)
    local o = M.outcome(ep, res)
    local fam = s.perFamily[ep.family or "unknown"] or { runaway = 0, savable = 0, misses = 0, wrongful = 0 }
    s.perFamily[ep.family or "unknown"] = fam
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

-- The fewest runaways a set must hold for G7 to decide on it: enough that a
-- baseline missing one can still meet the miss bound, so the comparator is a
-- real rule rather than always-freeze by default (93 at the defaults). The
-- bound with one miss falls as the set grows, and sits above the bound with
-- none, so the search starts under the zero-miss size, doubles until a size
-- meets the bound, then bisects: a small bound costs a few dozen steps, not
-- one per runaway.
function M.decisiveRunaways(cfg)
  cfg = cfg or M.cfg
  local bound, conf = cfg.missBound, cfg.confidence
  assert(type(bound) == "number" and bound > 0 and bound < 1, "the miss bound must be between 0 and 1")
  assert(type(conf) == "number" and conf > 0 and conf < 1, "the confidence must be between 0 and 1")
  local function meets(n) return M.cpUpper(1, n, conf) <= bound end
  -- lo never meets the bound: under the zero-miss size (less two, for
  -- rounding) not even a set with no miss does. hi will.
  local lo = math.max(0, math.ceil(math.log(1 - conf) / math.log(1 - bound)) - 2)
  -- The doubling stops at the cap, which is tried itself: a bound only a
  -- larger set meets is refused, never answered past the cap.
  local cap = 1 << 24
  local hi = lo + 1
  while not meets(hi) do
    assert(hi < cap, "the miss bound is too small: no set of up to 2^24 runaways meets it with a miss")
    lo, hi = hi, math.min(hi * 2, cap)
  end
  while hi - lo > 1 do
    local mid = (lo + hi) // 2
    if meets(mid) then hi = mid else lo = mid end
  end
  return hi
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
  -- A set too small to let a one-miss baseline qualify decides nothing: it
  -- neither passes nor fails a candidate.
  local minRunaways = M.decisiveRunaways(cfg)
  local decisive = cand.nRunaway >= minRunaways
  return {
    candidate = cand, bestBaseline = bestName, baselines = baseScores,
    improvementLower = lower, improvementPoint = point,
    passMiss = passMiss, passBeat = passBeat, decisive = decisive, minRunaways = minRunaways,
    pass = decisive and passMiss and passBeat,
  }
end

------------------------------------------------------------------------------
-- CLI
------------------------------------------------------------------------------

local function parse(argv)
  local a = { cmd = argv[1] }
  local seen = {}
  local i = 2
  while i <= #argv do
    local k, v = argv[i], argv[i + 1]
    -- Every flag takes a value: one missing (the last argument, or another
    -- flag in its place) is refused, never read as unset. A flag given twice
    -- is refused too: which value was meant is not this script's to guess.
    if type(k) == "string" and k:match("^%-%-") and (v == nil or v:match("^%-%-")) then
      error(k .. " needs a value", 0)
    end
    if seen[k] then error(tostring(k) .. " given twice", 0) end
    seen[k] = true
    local function number(x) return assert(tonumber(x), k .. " must be a number, not " .. tostring(x)) end
    if k == "--dir" then a.dir = v elseif k == "--fit-dir" then a.fitDir = v
    elseif k == "--candidate" then a.candidate = v elseif k == "--out" then a.out = v
    elseif k == "--tree-depth" then
      a.depth = math.tointeger(number(v))
      assert(a.depth and a.depth >= 1, "--tree-depth must be a whole number of levels, 1 or more")
    elseif k == "--decisions" then a.decisions = v elseif k == "--key" then a.key = v
    elseif k == "--tau" then a.tau = number(v)
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
-- Returns them, the tree, the ttx horizon, and whether that horizon met the
-- miss bound on the fit split.
function M.baselineSet(fitEpisodes, depth)
  local tree = M.fitTree(fitEpisodes, depth or 3, 5)
  local horizon, certified = M.fitTtx(fitEpisodes)
  return {
    ["always-freeze"] = M.candidates["always-freeze"](),
    ["rule"] = M.candidates["rule"](),
    ["ttx"] = M.candidates["ttx"](horizon),
    ["tree"] = M.treeCandidate(tree),
  }, tree, horizon, certified
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

-- What a decisions file holds: rows the runner recorded as invalid replies
-- (each stands as the deterministic freeze) are noted. A decision point it
-- does not cover is refused: scored as the deterministic freeze it would
-- make a short, interrupted or mismatched file pass for a model (rows that
-- wait on the savables alone, say, pass with no runaway asked). So is a row
-- recorded on another snapshot, or with no snapshot hash to check.
local function decisionsNotes(episodes, decisions, n, invalid)
  if invalid > 0 then
    print(string.format("note: %d of %d rows are invalid replies, recorded as the deterministic freeze", invalid, n))
  end
  local missing, total = M.coverage(episodes, decisions)
  if missing > 0 then
    error(string.format("the decisions cover %d of %d decision points; record every one (a run that was "
      .. "interrupted, or rows from another episode set, cover fewer)", total - missing, total), 0)
  end
  local mismatched, unchecked = M.contentCheck(episodes, decisions)
  if mismatched > 0 then
    error(string.format("%d of %d decision points were recorded on another snapshot than the episode holds "
      .. "(the split was regenerated since, or another set shares its ids); record them again", mismatched, total), 0)
  end
  -- A row with no hash cannot be shown to answer this episode, so it does
  -- not decide a gate either: rows recorded before rows carried one, or a
  -- key that carries none, are recorded again (or the key rebuilt).
  if unchecked > 0 then
    error(string.format("%d of %d rows carry no snapshot hash, so the inputs they answered cannot be checked; "
      .. "record them again (a key file carries each step's snapshotHash)", unchecked, total), 0)
  end
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
  -- CDPATH unset: with it exported, cd can resolve a relative name to a
  -- directory elsewhere (and print it), so two spellings could compare
  -- equal or unequal for the wrong reason.
  local p = io.popen("CDPATH= cd -P -- '" .. tostring(dir):gsub("'", "'\\''") .. "' 2>/dev/null && pwd -P")
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
    local decisions, n, noP, invalid = M.loadDecisions(a.decisions, a.key)
    local note = noProbabilityNote(n, noP)
    if note then print(note) end
    if a.episodes then decisionsNotes(a.episodes, decisions, n, invalid) end
    return M.decisionsCandidate(decisions, a.tau)
  end
  if M.candidates[name] then return M.candidates[name]() end
  error("unknown candidate " .. name)
end

-- Episodes carry the deferral bound their labels were computed under; a
-- scorer playing the floor at another bound would score them by rules
-- they were not labeled by. (An episode file without it predates the
-- record and is not checked.)
function M.checkDeferral(episodes, cfg)
  cfg = cfg or M.cfg
  for _, ep in ipairs(episodes) do
    local d = ep.params and ep.params.deferralSec
    if d ~= nil and d ~= cfg.deferralSec then
      error(string.format("%s was labeled under a %s s deferral bound; this scorer plays the floor at %s s",
        tostring(ep.id), tostring(d), tostring(cfg.deferralSec)), 0)
    end
  end
end

-- Clear a result path before a run writes one: already absent is fine
-- (errno 2, no such file), but a path that cannot be cleared (permissions,
-- a directory) refuses the run, since an earlier result left there would
-- read as this run's.
function M.clearResult(path)
  local ok, err, code = os.remove(path)
  if not ok and code ~= 2 then
    error(string.format("cannot clear %s (%s): an earlier result left there would read as this run's",
      path, tostring(err)), 0)
  end
end

-- The CLI. Returns the exit status: 0 when the gate passes or the controls
-- hold, 1 when the gate fails or a control does, 2 when the set is too small
-- to decide (for the controls, or too weak to show the gate's power). A
-- refusal raises, and the script then exits 3, so a refusal is never read as
-- a verdict.
function M.main(argv)
  local status = 0
  local a = parse(argv)
  -- A gate's result file is this run's or nothing. One left at the path by an
  -- earlier run would read as this run's verdict if this one is refused or
  -- fails to write, so once the arguments parse, the path is cleared before
  -- anything else. (A command line that does not parse touches nothing.)
  if a.cmd == "gate" and a.out then M.clearResult(a.out) end
  assert(a.dir, "--dir is required")
  local eps = M.loadDir(a.dir)
  assert(#eps > 0, "no episodes in " .. a.dir)
  M.checkDeferral(eps)
  -- The tree baseline is fit on another split, never on the episodes it is
  -- scored on: a gate or a control run must name it, and it must not be the
  -- evaluated directory under another spelling.
  if a.cmd == "gate" or a.cmd == "controls" then
    assert(a.fitDir, "--fit-dir is required (the dev split the tree is fit on)")
    local fitReal = assert(M.realDir(a.fitDir), "--fit-dir does not exist")
    assert(fitReal ~= M.realDir(a.dir), "--fit-dir is the evaluated directory; fit the tree on another split")
  end
  local fitEps = a.fitDir and M.loadDir(a.fitDir) or eps
  M.checkDeferral(fitEps)
  -- A split with no runaway or no savable episode fits nothing: the tree
  -- would be one leaf and the ttx horizon its default, weakening the gate.
  if a.cmd == "gate" or a.cmd == "controls" then
    local has = {}
    for _, ep in ipairs(fitEps) do has[ep.labels and ep.labels.class or "?"] = true end
    assert(has.runaway and has.savable,
      "--fit-dir has no runaway or no savable episode; the baselines cannot be fit on it")
    -- Another directory holding the same episodes is the same split: a
    -- copy, the same templates and seeds regenerated under another split
    -- label, or a copy with only its descriptive fields edited. Episodes
    -- are compared by their inputs and outcome labels, and by id, which
    -- fails safe.
    -- (M.fingerprint: the inputs and the outcome labels.)
    local scored, scoredIds = {}, {}
    for _, ep in ipairs(eps) do scored[M.fingerprint(ep)] = ep.id; scoredIds[ep.id] = true end
    for _, ep in ipairs(fitEps) do
      local twin = scored[M.fingerprint(ep)]
      assert(not twin and not scoredIds[ep.id], "--fit-dir holds " .. tostring(ep.id) .. ", the same episode as "
        .. tostring(twin or ep.id) .. " in the evaluated set")
    end
  end
  local baselines, tree, horizon, certified = M.baselineSet(fitEps, a.depth)
  if a.cmd == "gate" then
    -- No default: the label-reading oracle is a control, never a candidate
    -- a gate run passes by omission.
    local name = assert(a.candidate, "--candidate is required")
    a.episodes = eps
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
      (not g.decisive) and "UNDECIDABLE" or g.pass and "PASS" or "FAIL"))
    if not g.decisive then
      print(string.format("this set holds %d runaways; G7 decides only on one with %d or more, so that a baseline"
        .. " missing one can be the comparator: generate more episodes per template", g.candidate.nRunaway, g.minRunaways))
    end
    -- 0 pass, 1 fail, 2 a set too small to decide.
    status = (not g.decisive) and 2 or g.pass and 0 or 1
    print("tree baseline (fit on " .. (a.fitDir or a.dir) .. "):\n" .. M.describeTree(tree, "  "))
    print(string.format("ttx baseline horizon (fit on the same split): %d s%s", horizon, certified and ""
      or " (no horizon can meet the miss bound on a split this small: fit on its fewest misses)"))
    if a.out then
      -- A result that did not reach the disk (a full volume) fails the run:
      -- the flush surfaces only at close, so both are checked. It is written
      -- whole beside the path, then renamed onto it, so a file at the path is
      -- always a whole result.
      local partial = a.out .. string.format(".partial-%08x", math.random(0, 0x7fffffff))
      local okW, errW = pcall(function()
        local f = assert(io.open(partial, "w"))
        assert(f:write(assert(lfm.jsonEncode({ candidate = name, pass = g.pass, passMiss = g.passMiss, passBeat = g.passBeat,
          bestBaseline = g.bestBaseline, improvementLower = g.improvementLower, improvementPoint = g.improvementPoint,
          missUpper = g.candidate.missUpper, missRate = g.candidate.missRate, wrongfulRate = g.candidate.wrongfulRate,
          nRunaway = g.candidate.nRunaway, nSavable = g.candidate.nSavable, nLate = g.candidate.nLate,
          decisive = g.decisive, minRunaways = g.minRunaways })), "\n"))
        assert(f:close())
        assert(os.rename(partial, a.out))
      end)
      if not okW then
        os.remove(partial)
        error(errW, 0)
      end
    end
  elseif a.cmd == "tau" then
    assert(a.decisions, "--decisions is required")
    local decisions, n, noP, invalid = M.loadDecisions(a.decisions, a.key)
    local note = noProbabilityNote(n, noP)
    if note then print(note) end
    decisionsNotes(eps, decisions, n, invalid)
    local grid = { 0, 0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95, 0.98, 0.99, 1.01 }
    local best, rows = M.chooseTau(eps, decisions, grid)
    for _, r in ipairs(rows) do
      print(string.format("tau %.2f  misses %3d (upper95 %.3f)  wrongful %3d (rate %.3f)  %s", r.tau, r.misses,
        r.missUpper, r.wrongful, r.wrongfulRate, r.meets and "meets bound" or "misses bound"))
    end
    print(string.format("chosen tau %.2f (%s)", best.tau, best.meets and "fewest wrongful within the miss bound"
      or "no threshold meets the miss bound on this set; fewest misses"))
  elseif a.cmd == "controls" then
    local gO = M.gate(eps, M.candidates["oracle"](), baselines)
    -- An undecidable set (too few runaways for a one-miss baseline to
    -- qualify, or no baseline meeting the bound) exits 2, as the gate does,
    -- and says so first: the gate passes nothing on it, so neither control is
    -- read.
    if not gO.decisive then
      print(string.format("UNDECIDABLE: this set holds %d runaways, under the %d G7 decides on, so the controls"
        .. " are not read: generate more episodes per template", gO.candidate.nRunaway, gO.minRunaways))
      status = 2
    elseif not gO.bestBaseline then
      print("UNDECIDABLE: no baseline meets the miss bound on this set, so the gate compares against nothing"
        .. " and the controls are not read")
      status = 2
    else
      local gF = M.gate(eps, M.candidates["always-freeze"](), baselines)
      print(string.format("control always-freeze must FAIL: %s", gF.pass and "FAILED (gate passed it)" or "ok (failed)"))
      print(string.format("control oracle must PASS: %s", gO.pass and "ok (passed)" or "FAILED (gate failed it)"))
      if gF.pass or not gO.pass then status = 1 end
      -- An underpowered set is too weak to show the gate works: exit 2, unless
      -- a control failed (1).
      local trials = 50
      local passes = M.powerControl(eps, baselines, gO.bestBaseline, trials)
      local powered = (passes / trials) >= M.cfg.powerTarget
      print(string.format("power: a candidate %.0f%% of the way from %s to the oracle passed %d/%d seeds (target >= %.0f%%): %s",
        M.cfg.powerShare * 100, gO.bestBaseline, passes, trials, M.cfg.powerTarget * 100,
        powered and "ok" or "UNDERPOWERED"))
      if not powered and status == 0 then status = 2 end
    end
  else
    error("usage: score-episodes.lua gate|controls|tau --dir <episodes> [--fit-dir <dev>] [--candidate <name>]")
  end
  return status
end

-- Run as a script, whatever the file is named (a symlink, a copy): the
-- chunk lua was asked to run is this one exactly when its source is the
-- script's path. Required or loaded by another script, it only exports.
local function isScript()
  return arg ~= nil and arg[0] ~= nil and debug.getinfo(1, "S").source == "@" .. arg[0]
end

if isScript() then
  -- A refusal (a bad flag, a set that cannot be read, decisions that do not
  -- answer these episodes) exits 3, never 1, which is a gate that failed.
  local ok, status = pcall(M.main, arg)
  if not ok then
    io.stderr:write("score-episodes: " .. tostring(status) .. "\n")
    os.exit(3)
  end
  os.exit(status)
end

return M

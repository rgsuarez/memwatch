-- memwatch_observe.lua: the pure half of the passive observation ledger.
--
-- The observation ledger (memwatch-observe.jsonl, local and gitignored)
-- records what memwatch saw at every moment an adjudicator would have been
-- consulted, whether or not one is enabled: the exact model-input snapshot,
-- the deterministic action that would have fired, and what actually became
-- of the process 60, 120 and 180 seconds later. It is the raw material for
-- an outcome-labeled evaluation set, so it runs with the adjudicator and
-- unattended actions both off.
--
-- Everything here is Hammerspoon-free (unit-tested under standalone Lua).
-- The glue owns timers, file IO and the live process tables, and it never
-- forks for an observation: fates come from the tick's existing ps sample
-- and memwatch's own frozen ledger, and exit-cause evidence from a directory
-- listing of the kernel's jetsam reports.

local M = {}

M.cfg = {
  intervalSec    = 45,              -- advisory-cadence row while elevated/critical
  horizons       = { 60, 120, 180 }, -- follow-up horizons, seconds
  maxBytes       = 4e6,             -- rotate the ledger past this size
  keep           = 3,               -- rotated generations kept (.1 .. .3)
  sampleFreshSec = 15,              -- ps data older than this cannot decide a fate
  reuseSlackSec  = 30,              -- start-time drift tolerated before a pid reads as reused
}

local function floorOrNil(v)
  return type(v) == "number" and math.floor(v) or nil
end

-- Build one observation row as a plain table (the glue encodes and appends
-- it). `snapshot` is the serialized model input exactly as an adjudicator
-- would receive it (pid-free by construction); the top-level `pid` is a
-- local join key for the follow-ups and must be stripped from any dataset
-- built from this ledger.
-- a: { at, seq, point = "advisory"|"decision"|"synthetic", synthetic,
--      state, kern, availPct, swapGB, compressorGB, swapoutRate, compRate,
--      runawayCount, mode, lfmEnabled, wouldAct, graceElapsedSec,
--      category, offender = {pid, name, kind, weightMB, slopeMBmin,
--      peakSlopeMBmin, ageSec, foreground}, snapshot, snapshotHash }
function M.row(a)
  local off = type(a.offender) == "table" and a.offender or {}
  return {
    at = a.at, seq = a.seq, point = a.point,
    synthetic = a.synthetic == true or nil,
    state = a.state, kern = a.kern,
    availPct = floorOrNil(a.availPct),
    swapGB = type(a.swapGB) == "number" and math.floor(a.swapGB * 10) / 10 or nil,
    compressorGB = type(a.compressorGB) == "number" and math.floor(a.compressorGB * 10) / 10 or nil,
    swapoutRate = floorOrNil(a.swapoutRate), compRate = floorOrNil(a.compRate),
    runawayCount = floorOrNil(a.runawayCount),
    mode = a.mode, lfmEnabled = a.lfmEnabled == true,
    wouldAct = a.wouldAct, graceElapsedSec = floorOrNil(a.graceElapsedSec),
    pid = floorOrNil(off.pid),
    offender = {
      name = off.name, category = a.category, kind = off.kind,
      weightMB = floorOrNil(off.weightMB), slopeMBmin = floorOrNil(off.slopeMBmin),
      peakSlopeMBmin = floorOrNil(off.peakSlopeMBmin), ageSec = floorOrNil(off.ageSec),
      foreground = off.foreground == true or nil,
    },
    snapshot = a.snapshot, snapshotHash = a.snapshotHash,
  }
end

-- What became of an observed process at a follow-up horizon, decided only
-- from data the tick already holds. Returns fate, detail.
--   frozen  : memwatch's own frozen ledger holds it (memwatch paused it)
--   unknown : the ps sample is too old to say anything (never guessed)
--   exited  : absent from a fresh ps sample, or its pid now belongs to a
--             process that started well after the observed one
--   alive   : present, same process
-- a: { frozen, sampleAgeSec, psRow, startedAt, psStartedAt }
function M.fate(a)
  if a.frozen then return "frozen", nil end
  if type(a.sampleAgeSec) ~= "number" or a.sampleAgeSec > M.cfg.sampleFreshSec then
    return "unknown", "stale-sample"
  end
  if not a.psRow then return "exited", nil end
  if type(a.startedAt) == "number" and type(a.psStartedAt) == "number"
     and (a.psStartedAt - a.startedAt) > M.cfg.reuseSlackSec then
    return "exited", "pid-reused"
  end
  return "alive", nil
end

-- The kernel writes one report per jetsam event, named with its LOCAL
-- timestamp: JetsamEvent-YYYY-MM-DD-HHMMSS.ips. Parse names into epochs;
-- anything that does not match is skipped, never counted.
function M.jetsamTimes(names)
  local out = {}
  for _, n in ipairs(names or {}) do
    local y, mo, d, h, mi, s = tostring(n):match(
      "^JetsamEvent%-(%d%d%d%d)%-(%d%d)%-(%d%d)%-(%d%d)(%d%d)(%d%d)")
    if y then
      out[#out + 1] = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                                hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
    end
  end
  return out
end

-- How many epochs fall inside [since, untilT].
function M.countSince(times, since, untilT)
  local n = 0
  for _, t in ipairs(times or {}) do
    if t >= since and t <= untilT then n = n + 1 end
  end
  return n
end

-- Largest value in a growth ring (the tracker's 60 s footprint window).
function M.ringMax(ring)
  local best = nil
  for _, s in ipairs(ring or {}) do
    if type(s.v) == "number" and (best == nil or s.v > best) then best = s.v end
  end
  return best
end

-- Rename steps that rotate `path` keeping `keep` generations, oldest first,
-- so no generation is overwritten before it has moved.
function M.rotationPlan(path, keep)
  local plan = {}
  for i = keep - 1, 1, -1 do
    plan[#plan + 1] = { path .. "." .. i, path .. "." .. (i + 1) }
  end
  plan[#plan + 1] = { path, path .. ".1" }
  return plan
end

return M

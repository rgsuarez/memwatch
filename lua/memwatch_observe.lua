-- memwatch_observe.lua: the pure half of the passive observation ledger.
--
-- The observation ledger (memwatch-observe.jsonl, local and gitignored)
-- records what memwatch saw at each grace-expiry decision point, and every
-- 45 s while pressure is up, whether or not an adjudicator is enabled: the
-- exact model-input snapshot, the action the deterministic policy fires
-- under the live mode with the freeze-ceiling counterfactual beside it, and
-- what actually became of the process 60, 120 and 180 seconds later. It is
-- the raw material for an outcome-labeled evaluation set, so it runs with
-- the adjudicator and unattended actions both off.
--
-- Two row fields are local join material, never model input: the top-level
-- pid, and offender.name, a sanitized basename kept only so categories can
-- be re-derived later. Neither may ever be fed to a model, and both must be
-- stripped from any dataset built from this ledger.
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
  clockSlackSec  = 1,               -- timestamp granularity allowed when comparing start windows
  maxLineBytes   = 60000,           -- a longer row drops its snapshot (the decoder rejects > 64 KB)
}

local function floorOrNil(v)
  return type(v) == "number" and math.floor(v) or nil
end

-- A raw process basename is attacker-controlled: it can carry control bytes
-- or invalid UTF-8, which make a malformed JSONL line for strict readers.
-- Keep ASCII letters, digits and . _ - + space, replace every other byte
-- with "?", and cap at 64 bytes. That makes the name safe to store, not safe
-- to show a model: instruction-like text survives, which is why the name is
-- never model input. The class is spelled as ASCII ranges rather than %w so
-- a locale change in the host process can never widen it. Returns nil for
-- anything that is not a string.
function M.sanitizeName(s)
  if type(s) ~= "string" then return nil end
  return (s:sub(1, 64):gsub("[^A-Za-z0-9%._%-%+ ]", "?"))
end

-- Build one observation row as a plain table (the glue encodes and appends
-- it). `snapshot` is the serialized model input exactly as an adjudicator
-- would receive it (pid-free by construction). The top-level `pid` is a
-- local join key for the follow-ups, and `offender.name` a sanitized
-- basename (sanitizeName) kept only to re-derive categories: neither may
-- ever be fed to a model, and both must be stripped from any dataset built
-- from this ledger. `wouldAct` is what the deterministic policy fires under
-- the live mode ("none" while it is off, and on every advisory row);
-- `wouldActAtFreeze`, present only at decision points, is the decision a
-- model would own at grace expiry under the freeze ceiling.
-- a: { at, seq, point = "advisory"|"decision"|"synthetic", synthetic,
--      state, kern, availPct, swapGB, compressorGB, swapoutRate, compRate,
--      runawayCount, mode, lfmEnabled, wouldAct, wouldActAtFreeze,
--      graceElapsedSec, category, offender = {pid, name, kind, weightMB,
--      slopeMBmin, peakSlopeMBmin, ageSec, foreground}, snapshot,
--      snapshotHash }
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
    wouldAct = a.wouldAct, wouldActAtFreeze = a.wouldActAtFreeze,
    graceElapsedSec = floorOrNil(a.graceElapsedSec),
    pid = floorOrNil(off.pid),
    offender = {
      name = M.sanitizeName(off.name), category = a.category, kind = off.kind,
      weightMB = floorOrNil(off.weightMB), slopeMBmin = floorOrNil(off.slopeMBmin),
      peakSlopeMBmin = floorOrNil(off.peakSlopeMBmin), ageSec = floorOrNil(off.ageSec),
      foreground = off.foreground == true or nil,
    },
    snapshot = a.snapshot, snapshotHash = a.snapshotHash,
  }
end

-- Encode a row as one ledger line under `cap` bytes when the snapshot is
-- what makes it large: the shared decoder rejects lines over 64 KB, so an
-- oversize row would be silently skipped by every reader. The snapshot is
-- dropped (its hash stays) and snapshotDropped marks the row; a row that is
-- oversize without a snapshot is returned as encoded. encode is
-- lfm.ledgerLine in the glue.
function M.boundLine(row, encode, cap)
  cap = cap or M.cfg.maxLineBytes
  local line = encode(row)
  if line and #line > cap and row.snapshot ~= nil then
    row.snapshot, row.snapshotDropped = nil, true
    line = encode(row)
  end
  return line
end

-- Identity of one pid across two samples, from their start windows (see
-- memwatch_procs.startWindow). A process has one true start, so two windows
-- of the same process always overlap: disjoint windows prove a different
-- process. Overlap proves the SAME process only when the first sighting was
-- older than the windows' combined width: a reused pid started after the
-- original was last seen alive, so at least the original's etime after the
-- original's start, and it can share a window only while that gap is
-- smaller than the uncertainty. Wide windows (callback stalls) therefore
-- yield unknown, never a false mismatch. Returns "same", "reused", "unknown".
function M.identity(w0, w1)
  if type(w0) ~= "table" or type(w1) ~= "table" then return "unknown" end
  local slack = M.cfg.clockSlackSec
  if w1.lo > w0.hi + slack or w0.lo > w1.hi + slack then return "reused" end
  local width = (w0.hi - w0.lo) + (w1.hi - w1.lo) + 2 * slack
  if type(w0.etimeSec) == "number" and w0.etimeSec >= width then return "same" end
  return "unknown"
end

-- The start window a tracker entry carries from its latest ps sighting
-- (procs.update), in the shape identity() compares; nil without one.
function M.startOf(e)
  if type(e) ~= "table" or type(e.startLo) ~= "number" then return nil end
  return { lo = e.startLo, hi = e.startHi, etimeSec = e.etimeSec }
end

-- The tracker entry for an observed pid, only when it is provably the
-- observed process: the same comm, and start windows identity() calls
-- "same". A reused pid's new process, or an identity that cannot be
-- decided, reads as absent, so a follow-up never takes weight or peak from
-- a different process.
function M.sameProcess(e, comm0, start0)
  if type(e) ~= "table" or comm0 == nil or e.comm ~= comm0 then return nil end
  if M.identity(start0, M.startOf(e)) ~= "same" then return nil end
  return e
end

-- What became of an observed process at a follow-up horizon, decided only
-- from data the tick already holds, and only from a fresh COMPLETE sample:
-- absence from a truncated table proves nothing. Returns fate, detail.
--   unknown : no fresh complete sample, or identity cannot be decided
--   exited  : absent from a fresh complete sample, or its pid now belongs to
--             a different process (detail "pid-reused")
--   frozen  : present, the same process, and memwatch's frozen ledger holds it
--   alive   : present, the same process
-- The frozen ledger never decides a fate by itself: an entry outlives a
-- frozen process killed meanwhile until the calm-only sweep removes it.
-- a: { sampleAgeSec, sampleComplete, psRow, comm0, start0, start1, frozen }
function M.fate(a)
  if type(a.sampleAgeSec) ~= "number" or a.sampleAgeSec > M.cfg.sampleFreshSec then
    return "unknown", "stale-sample"
  end
  if a.sampleComplete ~= true then return "unknown", "incomplete-sample" end
  if not a.psRow then return "exited", nil end
  if a.comm0 and a.psRow.comm and a.psRow.comm ~= a.comm0 then
    return "exited", "pid-reused"
  end
  local id = M.identity(a.start0, a.start1)
  if id == "reused" then return "exited", "pid-reused" end
  if id == "unknown" then return "unknown", "identity-uncertain" end
  if a.frozen then return "frozen", nil end
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
-- With `since`, only samples taken at or after it count: a peak since an
-- observation must not include the ring's older samples.
function M.ringMax(ring, since)
  local best = nil
  for _, s in ipairs(ring or {}) do
    if type(s.v) == "number" and (since == nil or (type(s.t) == "number" and s.t >= since))
       and (best == nil or s.v > best) then
      best = s.v
    end
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

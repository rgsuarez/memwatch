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
-- Keep ASCII letters, digits, . _ - + space and ( ) [ ] (helper names such
-- as "Code Helper (GPU)" carry their category in the parentheses), replace
-- every other byte with "?", and cap at 64 bytes. That makes the name safe
-- to store, not safe to show a model: instruction-like text survives, which
-- is why the name is never model input. The class is spelled as ASCII
-- ranges rather than %w so a locale change in the host process can never
-- widen it. Returns nil for anything that is not a string.
function M.sanitizeName(s)
  if type(s) ~= "string" then return nil end
  return (s:sub(1, 64):gsub("[^A-Za-z0-9%._%-%+ %(%)%[%]]", "?"))
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
-- model would own at grace expiry under the freeze ceiling. The foreground
-- flag is the fork-free name match (foregroundBasis "name"); the live
-- policy also walks the process tree and caps a terminate it cannot rule
-- out as foreground to a freeze, so under kill mode wouldAct can read
-- terminate where the live policy would freeze. `session` identifies the
-- load that wrote the row: (session, seq) is the join key.
-- a: { at, session, seq, point = "advisory"|"decision"|"synthetic", synthetic,
--      state, kern, availPct, swapGB, compressorGB, swapoutRate, compRate,
--      runawayCount, mode, lfmEnabled, wouldAct, wouldActAtFreeze,
--      graceElapsedSec, category, offender = {pid, name, kind, weightMB,
--      slopeMBmin, peakSlopeMBmin, ageSec, foreground}, snapshot,
--      snapshotHash }
function M.row(a)
  local off = type(a.offender) == "table" and a.offender or {}
  return {
    at = a.at, session = a.session, seq = a.seq, point = a.point,
    synthetic = a.synthetic == true or nil,
    state = a.state, kern = a.kern,
    availPct = floorOrNil(a.availPct),
    swapGB = type(a.swapGB) == "number" and math.floor(a.swapGB * 10) / 10 or nil,
    compressorGB = type(a.compressorGB) == "number" and math.floor(a.compressorGB * 10) / 10 or nil,
    swapoutRate = floorOrNil(a.swapoutRate), compRate = floorOrNil(a.compRate),
    runawayCount = floorOrNil(a.runawayCount),
    mode = a.mode, lfmEnabled = a.lfmEnabled == true,
    wouldAct = a.wouldAct, wouldActAtFreeze = a.wouldActAtFreeze,
    -- Under kill mode the deterministic action rests on the fork-free name
    -- match for foreground (see above): said at top level, so a filter on
    -- wouldAct cannot miss it.
    wouldActBasis = (a.mode == "kill" and a.wouldAct ~= nil and a.wouldAct ~= "none") and "name" or nil,
    graceElapsedSec = floorOrNil(a.graceElapsedSec),
    pid = floorOrNil(off.pid),
    offender = {
      name = M.sanitizeName(off.name), category = a.category, kind = off.kind,
      weightMB = floorOrNil(off.weightMB), slopeMBmin = floorOrNil(off.slopeMBmin),
      peakSlopeMBmin = floorOrNil(off.peakSlopeMBmin), ageSec = floorOrNil(off.ageSec),
      foreground = off.foreground == true or nil, foregroundBasis = "name",
    },
    snapshot = a.snapshot, snapshotHash = a.snapshotHash,
  }
end

-- Encode a row as one ledger line under `cap` bytes: the shared decoder
-- rejects lines over 64 KB, so an oversize row would be silently skipped by
-- every reader. The snapshot is dropped first (its hash stays) and
-- snapshotDropped marks the row; a row still over the cap is reduced to
-- its join keys and point, marked encodingDropped, so the observation is
-- never lost silently. encode is lfm.ledgerLine in the glue.
function M.boundLine(row, encode, cap)
  cap = cap or M.cfg.maxLineBytes
  local line = encode(row)
  if line and #line > cap and row.snapshot ~= nil then
    row.snapshot, row.snapshotDropped = nil, true
    line = encode(row)
  end
  if line and #line > cap then
    line = encode({ at = row.at, session = row.session, seq = row.seq, point = row.point,
                    pid = row.pid, encodingDropped = true })
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

-- Whether a tick is a would-be decision point that earns a decision row:
-- the ledger is on, the unattended gate (core.unattendedGate, the same one
-- the live unattended step asks) stands open for this tick's offender, and
-- this process has had no decision row within the last grace window
-- (sinceLastSec is nil when it has no live stamp; see liveStamp). The
-- unattended mode is deliberately not an input: the ledger records what an
-- adjudicator would face under every mode, including off, and a decision
-- row marks exactly the ticks where the live gate would act.
-- a: { enabled, gate ("open" | "unbound" | "closed"), sinceLastSec, graceSec }
function M.decisionDue(a)
  if type(a) ~= "table" or a.enabled ~= true or a.gate ~= "open" then return false end
  if type(a.graceSec) ~= "number" then return false end
  if type(a.sinceLastSec) == "number" and a.sinceLastSec < a.graceSec then return false end
  return true
end

-- A decision stamp ({ at, comm, start }) still holds for the process the
-- tracker now has under its pid unless that is provably a different
-- process: a different comm, or start windows identity() calls reused. So
-- a same-comm pid reuse within the grace window cannot suppress the new
-- process's decision row. An undecidable identity keeps the stamp, so at
-- worst a new process's row waits out one grace window. Returns the stamp
-- or nil.
function M.liveStamp(stamp, e)
  if type(stamp) ~= "table" then return nil end
  if type(e) ~= "table" then return stamp end
  if stamp.comm and e.comm and stamp.comm ~= e.comm then return nil end
  if M.identity(stamp.start, M.startOf(e)) == "reused" then return nil end
  return stamp
end

-- A process start time as ps prints it ("Mon Oct  5 10:00:01 2026", local
-- time) as an epoch; nil when it does not parse. Signal paths bind lstart,
-- the ledger compares start windows, and this joins the two. In the hour a
-- daylight-saving fold repeats, a local time is ambiguous by an hour: a
-- signal sent to a process started then can miss its observation (it is
-- left unrecorded, never attributed to another process).
local MONTHS = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
                 Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }
function M.lstartEpoch(s)
  if type(s) ~= "string" then return nil end
  local mon, d, h, mi, sec, y = s:match("^%a+%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+(%d+)$")
  if not mon or not MONTHS[mon] then return nil end
  return os.time({ year = tonumber(y), month = MONTHS[mon], day = tonumber(d),
                   hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec) })
end

-- Is a process with this start epoch (and comm) the observed one?
-- "different" when the comm differs or the epoch falls outside the
-- observation's start window. Inside the window it is "same" only when the
-- window could not also hold the pid's next process: that one starts after
-- the observed process was last seen alive, at least its etime after its
-- start, so it can fall inside only while the window is wider than that age
-- (a young process, or a stalled sample). Then, and whenever either side
-- lacks the data, "unknown". identity() draws the same line.
function M.matchStart(start0, comm0, epoch, comm)
  if comm0 and comm and comm0 ~= comm then return "different" end
  if type(start0) ~= "table" or type(epoch) ~= "number" then return "unknown" end
  local slack = M.cfg.clockSlackSec
  if epoch < start0.lo - slack or epoch > start0.hi + slack then return "different" end
  local width = (start0.hi - start0.lo) + 2 * slack
  if type(start0.etimeSec) == "number" and start0.etimeSec >= width then return "same" end
  return "unknown"
end

-- The evidence an observation keeps about its process, folded forward as
-- events arrive instead of read back from whatever the globals hold at the
-- follow-up: every ps sample (presence by acquisition time, weight and
-- peak, or proof it is gone), every memwatch signal and every operator
-- touch aimed at that same process. A follow-up reads only this record, so
-- a delivery stall, an expired tracker entry, a reused pid or an event from
-- before the observation cannot change what it reports.
-- a: { pid, comm0, start0, obsAt, weightMB }
function M.newEvidence(a)
  return { pid = a.pid, comm0 = a.comm0, start0 = a.start0, obsAt = a.obsAt,
           weight0 = a.weightMB, peakMB = a.weightMB, lastWeightMB = nil, seenAcq = nil,
           gone = nil, lastMiss = nil, samples = {}, signals = {},
           touches = 0, touchesUncertain = 0, touchLog = {} }
end

-- Fold one ps sample. s: { complete, row (the pid's row or nil), start1
-- (the row's start window), weightMB (the row's weight), launchedAt,
-- deliveredAt }. Presence counts from the sample's ACQUISITION bound (its
-- launch: ps read the table between launch and delivery), so a sample
-- delivered late is exactly as fresh as its launch says. A sample launched
-- before the observation says nothing about what followed it (a stalled
-- table can land after the observation and lack a process born since), so
-- it is ignored. A different process under the pid (another comm, or
-- disjoint start windows) proves the observed one gone, as does absence
-- from a complete table; absence from a partial table proves nothing. The
-- proof is dated by its delivery: the table was read by then.
function M.foldSample(ev, s)
  if ev.gone then return end
  if type(s.launchedAt) ~= "number" or s.launchedAt < ev.obsAt then
    ev.lastMiss = "pre-observation-sample"
    return
  end
  if s.row then
    local diff = (ev.comm0 and s.row.comm and s.row.comm ~= ev.comm0)
      or M.identity(ev.start0, s.start1) == "reused"
    if diff then
      ev.gone = { how = "pid-reused", at = s.deliveredAt }
      return
    end
    if M.identity(ev.start0, s.start1) ~= "same" then
      ev.lastMiss = "identity-uncertain"
      return
    end
    if ev.seenAcq == nil or s.launchedAt > ev.seenAcq then ev.seenAcq = s.launchedAt end
    if type(s.weightMB) == "number" then
      ev.lastWeightMB = s.weightMB
      if ev.peakMB == nil or s.weightMB > ev.peakMB then ev.peakMB = s.weightMB end
      ev.samples[#ev.samples + 1] = { at = s.launchedAt, weightMB = s.weightMB }
    end
    ev.lastMiss = nil
  elseif s.complete then
    ev.gone = { how = "exited", at = s.deliveredAt }
  else
    ev.lastMiss = "incomplete-sample"
  end
end

-- Fold one signal memwatch sent: sig { action, at, comm, startEpoch } for the
-- process it verified before signaling. Only a signal to this same process
-- counts; one whose process cannot be told apart is kept, marked uncertain.
function M.foldSignal(ev, sig)
  local m = M.matchStart(ev.start0, ev.comm0, sig.startEpoch, sig.comm)
  if m == "different" then return end
  ev.signals[#ev.signals + 1] = { action = sig.action, at = sig.at, uncertain = (m ~= "same") or nil }
end

-- Fold one operator touch aimed at this pid (t: { at, comm, startEpoch }
-- when known): a touch on a different process under the pid does not
-- count, and one whose process cannot be told apart counts apart, as
-- uncertain.
function M.foldTouch(ev, t)
  local m = M.matchStart(ev.start0, ev.comm0, t and t.startEpoch, t and t.comm)
  if m == "different" then return end
  local uncertain = m ~= "same"
  if uncertain then ev.touchesUncertain = ev.touchesUncertain + 1 else ev.touches = ev.touches + 1 end
  ev.touchLog[#ev.touchLog + 1] = { at = t and t.at, uncertain = uncertain or nil }
end

-- What became of the observed process by horizon instant t (the
-- observation time plus the horizon, never the moment a late timer ran),
-- from its evidence alone. Returns fate, detail.
--   exited  : proven gone by a sample delivered by t (detail "pid-reused"
--             when a different process holds the pid)
--   alive   : seen, as the same process, in a sample ACQUIRED within
--             sampleFreshSec of t, or after it (a process alive later was
--             alive at t)
--   frozen  : alive, and memwatch's frozen ledger holds this same process
--   unknown : no such evidence (detail: stale-sample, incomplete-sample,
--             identity-uncertain, or pre-observation-sample)
function M.fateAt(ev, t, frozenSame)
  if ev.gone and (ev.gone.at == nil or ev.gone.at <= t) then
    return "exited", (ev.gone.how == "pid-reused") and "pid-reused" or nil
  end
  if ev.seenAcq and ev.seenAcq >= t - M.cfg.sampleFreshSec then
    if frozenSame then return "frozen", nil end
    return "alive", nil
  end
  return "unknown", ev.lastMiss or "stale-sample"
end

-- The evidence as of horizon instant t: the weight of the last sighting
-- acquired by t, the peak since the observation through t, the last
-- memwatch signal sent by t (and how many), and the operator touches by t
-- (certain, and uncertain). A follow-up whose timer ran late reports the
-- horizon it names, not what happened after it.
function M.asOf(ev, t)
  local out = { weightMB = nil, peakMB = ev.weight0, signal = nil, signalCount = 0,
                touches = 0, touchesUncertain = 0 }
  for _, s in ipairs(ev.samples or {}) do
    if s.at <= t then
      out.weightMB = s.weightMB
      if out.peakMB == nil or s.weightMB > out.peakMB then out.peakMB = s.weightMB end
    end
  end
  for _, sig in ipairs(ev.signals or {}) do
    if sig.at == nil or sig.at <= t then out.signal, out.signalCount = sig, out.signalCount + 1 end
  end
  for _, tc in ipairs(ev.touchLog or {}) do
    if tc.at == nil or tc.at <= t then
      if tc.uncertain then out.touchesUncertain = out.touchesUncertain + 1 else out.touches = out.touches + 1 end
    end
  end
  return out
end

-- Does a frozen-ledger entry hold the observed process? From the entry's
-- bound start time against the observation's start window; nil when that
-- cannot be told.
function M.frozenMatches(entry, start0, comm0)
  if type(entry) ~= "table" then return false end
  local m = M.matchStart(start0, nil, M.lstartEpoch(entry.lstart), nil)
  if m == "unknown" then return nil end
  return m == "same"
end

-- How many epochs fall inside [since, untilT].
function M.countSince(times, since, untilT)
  local n = 0
  for _, t in ipairs(times or {}) do
    if t >= since and t <= untilT then n = n + 1 end
  end
  return n
end

-- Rename steps that rotate `path` keeping `keep` generations, oldest first,
-- so no generation is overwritten before it has moved (see rotate).
function M.rotationPlan(path, keep)
  local plan = {}
  for i = keep - 1, 1, -1 do
    plan[#plan + 1] = { path .. "." .. i, path .. "." .. (i + 1) }
  end
  plan[#plan + 1] = { path, path .. ".1" }
  return plan
end

-- Run a rotation plan: exists(path) and rename(from, to) are the file
-- operations (os.rename's contract). A generation that does not exist yet
-- is skipped; the first rename that fails stops the rotation, because every
-- later step would overwrite the generation that did not move (the live
-- file onto .1, when .1 could not become .2). Returns true, or false and
-- the failed rename's error.
function M.rotate(plan, exists, rename)
  for _, step in ipairs(plan) do
    if exists(step[1]) then
      local ok, err = rename(step[1], step[2])
      if not ok then return false, err end
    end
  end
  return true
end

return M

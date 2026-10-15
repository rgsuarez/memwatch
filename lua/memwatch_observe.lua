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
  maxActions     = 256,             -- operator action times kept per record (more are counted)
  clockStepSec   = 2,               -- a wall clock that falls this far behind the monotonic one stepped back
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
--      snapshotHash, identityBasis }
-- identityBasis says how the follow-ups tell the observed process from a
-- successor under its pid: "window" (the start window of its latest ps
-- sighting), "lstart" (the start time the alert bound), or absent (neither:
-- its follow-ups can only read unknown or exited).
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
    identityBasis = a.identityBasis,
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
  -- A stamp after now (the wall clock stepped back since) counts as elapsed,
  -- as the unattended step's own grace stamp does.
  if type(a.sinceLastSec) == "number" and a.sinceLastSec >= 0 and a.sinceLastSec < a.graceSec then
    return false
  end
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
local function lstartFields(s)
  if type(s) ~= "string" then return nil end
  local mon, d, h, mi, sec, y = s:match("^%a+%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+(%d+)$")
  if not mon or not MONTHS[mon] then return nil end
  return { year = tonumber(y), month = MONTHS[mon], day = tonumber(d),
           hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec) }
end
function M.lstartEpoch(s)
  local f = lstartFields(s)
  return f and os.time(f) or nil
end

-- The same, but nil in the hour a daylight-saving fold repeats, where the
-- local time names two epochs an hour apart: read as standard time and as
-- daylight time, both convert back to the same clock reading. Outside the
-- fold only one reading converts back.
function M.lstartEpochUnambiguous(s)
  local f = lstartFields(s)
  if not f then return nil end
  local function readAs(isdst)
    local t = { year = f.year, month = f.month, day = f.day, hour = f.hour,
                min = f.min, sec = f.sec, isdst = isdst }
    local ok, e = pcall(os.time, t)
    if not ok or type(e) ~= "number" then return nil end
    local back = os.date("*t", e)
    if back.year == f.year and back.month == f.month and back.day == f.day
       and back.hour == f.hour and back.min == f.min and back.sec == f.sec then
      return e
    end
    return nil
  end
  local std, dst = readAs(false), readAs(true)
  if std and dst and std ~= dst then return nil end
  return std or dst
end

-- A start window from a bound start time (ps prints whole seconds, so the
-- start lies in [epoch, epoch + 1]), for an observation whose tracker entry
-- has no window: a process the top stream named while ps was stalled. Its
-- age at `now` lets identity() decide. nil when the start time does not
-- parse, is ambiguous (see lstartEpochUnambiguous), or lies after now.
function M.startFromLstart(s, now)
  local epoch = M.lstartEpochUnambiguous(s)
  if not epoch or type(now) ~= "number" or epoch > now then return nil end
  return { lo = epoch, hi = epoch + 1, etimeSec = now - epoch }
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
-- touch aimed at that same process, every operator action, and each
-- change in whether memwatch's frozen ledger holds it. A follow-up reads
-- only this record, as of its horizon, so a delivery stall, a late timer,
-- an expired tracker entry, a reused pid or an event from before the
-- observation cannot change what it reports.
-- a: { pid, comm0, start0, obsAt, weightMB, minSeq, horizons }. minSeq is
-- the first sampler sequence launched after the observation (nil: decide by
-- launch time); see foldSample. horizons are the follow-up offsets, whose
-- machine readings are kept in the record (snapshotHorizons).
function M.newEvidence(a)
  return { pid = a.pid, comm0 = a.comm0, start0 = a.start0, obsAt = a.obsAt, minSeq = a.minSeq,
           horizons = a.horizons or M.cfg.horizons, metricsAt = {},
           weight0 = a.weightMB, peakMB = a.weightMB, lastWeightMB = nil, seenAcq = nil,
           gone = nil, lastMiss = nil, misses = {}, samples = {}, signals = {},
           touches = 0, touchesUncertain = 0, touchLog = {}, actions = {}, actionsDropped = 0,
           frozenLog = {}, clockStep = nil }
end

-- Why the record has no fresh sighting, dated when that became known, so a
-- follow-up reads the reason as of its horizon.
local function noteMiss(ev, why, at)
  ev.lastMiss = why
  ev.misses[#ev.misses + 1] = { at = at, why = why }
end

-- Fold one ps sample. s: { complete, row (the pid's row or nil), start1
-- (the row's start window), weightMB (the row's weight), seq (the
-- sampler's launch order), launchedAt, deliveredAt }. Presence counts from
-- the sample's ACQUISITION bound (its launch: ps read the table between
-- launch and delivery), so a sample delivered late is exactly as fresh as
-- its launch says. A weight counts from its DELIVERY: the reading was taken
-- by then, and not provably before. A sample launched before the
-- observation says nothing about what followed it (a stalled table can land
-- after the observation and lack a process born since), so it is ignored;
-- launch ORDER decides that, not the wall clock. A sample launched after
-- the observation whose wall-clock launch reads before it, or one
-- delivered "before" its own launch, proves the clock stepped back, and
-- the record can no longer date anything (clockStep). A
-- different process under the pid (another comm, or disjoint start
-- windows) proves the observed one gone, as does absence from a complete
-- table; absence from a partial table proves nothing. The proof is dated by
-- its delivery: the table was read by then.
function M.foldSample(ev, s)
  if ev.gone or ev.clockStep then return end
  local pre
  if type(ev.minSeq) == "number" and type(s.seq) == "number" then
    pre = s.seq < ev.minSeq
  else
    pre = type(s.launchedAt) ~= "number" or s.launchedAt < ev.obsAt
  end
  if pre or type(s.launchedAt) ~= "number" then
    -- Only while nothing better is known: it never hides a later reason.
    if ev.seenAcq == nil and ev.lastMiss == nil then noteMiss(ev, "pre-observation-sample", s.deliveredAt) end
    return
  end
  if s.launchedAt < ev.obsAt - M.cfg.clockSlackSec
     or (type(s.deliveredAt) == "number" and s.deliveredAt < s.launchedAt - M.cfg.clockSlackSec) then
    ev.clockStep = true
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
      noteMiss(ev, "identity-uncertain", s.deliveredAt)
      return
    end
    if ev.seenAcq == nil or s.launchedAt > ev.seenAcq then ev.seenAcq = s.launchedAt end
    if type(s.weightMB) == "number" then
      ev.lastWeightMB = s.weightMB
      if ev.peakMB == nil or s.weightMB > ev.peakMB then ev.peakMB = s.weightMB end
      if type(s.deliveredAt) == "number" then
        ev.samples[#ev.samples + 1] = { at = s.deliveredAt, weightMB = s.weightMB }
      end
    end
    ev.lastMiss = nil
  elseif s.complete then
    ev.gone = { how = "exited", at = s.deliveredAt }
  else
    noteMiss(ev, "incomplete-sample", s.deliveredAt)
  end
end

-- Fold one signal memwatch sent: sig { action, at, comm, startEpoch } for the
-- process it verified before signaling. Only a signal to this same process
-- counts; one whose process cannot be told apart is kept, marked uncertain.
function M.foldSignal(ev, sig)
  if ev.clockStep then return end
  local m = M.matchStart(ev.start0, ev.comm0, sig.startEpoch, sig.comm)
  if m == "different" then return end
  ev.signals[#ev.signals + 1] = { action = sig.action, at = sig.at, uncertain = (m ~= "same") or nil }
end

-- Fold one operator touch aimed at this pid (t: { at, comm, startEpoch }
-- when known): a touch on a different process under the pid does not
-- count, and one whose process cannot be told apart counts apart, as
-- uncertain.
function M.foldTouch(ev, t)
  if ev.clockStep then return end
  local m = M.matchStart(ev.start0, ev.comm0, t and t.startEpoch, t and t.comm)
  if m == "different" then return end
  local uncertain = m ~= "same"
  if uncertain then ev.touchesUncertain = ev.touchesUncertain + 1 else ev.touches = ev.touches + 1 end
  ev.touchLog[#ev.touchLog + 1] = { at = t and t.at, uncertain = uncertain or nil }
end

-- Fold one operator action (any surface, any process) taken at `at`: a
-- follow-up counts those through its own horizon. A record keeps at most
-- M.cfg.maxActions times; beyond that it only counts how many it dropped,
-- and its follow-ups say their count is a lower bound.
function M.foldAction(ev, at)
  if ev.clockStep then return end
  if #ev.actions >= M.cfg.maxActions then
    ev.actionsDropped = (ev.actionsDropped or 0) + 1
    return
  end
  ev.actions[#ev.actions + 1] = at
end

-- Fold whether memwatch's frozen ledger holds the observed process from
-- `at` on: held is frozenMatches' answer (true, false, or nil when the
-- entry's process cannot be told apart). Only changes are kept.
function M.foldFrozen(ev, at, held)
  if ev.clockStep then return end
  local log = ev.frozenLog
  local last = log[#log]
  if last and last.held == held then return end
  log[#log + 1] = { at = at, held = held }
end

-- Whether the frozen ledger held the observed process at instant t: the
-- last change at or before t (false before any); nil when it could not tell.
function M.frozenAt(ev, t)
  local held = false
  for _, f in ipairs(ev.frozenLog or {}) do
    if type(f.at) == "number" and f.at <= t then held = f.held end
  end
  return held
end

-- The wall clock stepped back after the observation: from here on nothing
-- that arrives can be dated against the record's horizons, so the record
-- stops collecting (every fold returns) and its follow-ups carry no
-- readings. An exit proven before the step was dated on one clock and
-- still stands.
function M.noteClockStep(ev)
  ev.clockStep = true
end

-- What became of the observed process by horizon instant t (the
-- observation time plus the horizon, never the moment a late timer ran),
-- from its evidence alone. Returns fate, detail.
--   exited  : proven gone by a sample delivered by t (detail "pid-reused"
--             when a different process holds the pid)
--   alive   : seen, as the same process, in a sample ACQUIRED within
--             sampleFreshSec of t, or after it (a process alive later was
--             alive at t)
--   frozen  : alive, and memwatch's frozen ledger held this same process at t
--   unknown : no such evidence (detail: stale-sample, incomplete-sample,
--             identity-uncertain, pre-observation-sample; frozen-uncertain
--             when it was alive but the ledger's entry for its pid cannot
--             be told apart from another process; clock-step when the wall
--             clock stepped back after the observation, so nothing in the
--             record can be placed before or after t)
-- An event with no time is never placed before t.
function M.fateAt(ev, t)
  if ev.clockStep and not ev.gone then return "unknown", "clock-step" end
  if ev.gone and type(ev.gone.at) == "number" and ev.gone.at <= t then
    return "exited", (ev.gone.how == "pid-reused") and "pid-reused" or nil
  end
  if ev.seenAcq and ev.seenAcq >= t - M.cfg.sampleFreshSec then
    local held = M.frozenAt(ev, t)
    if held == nil then return "unknown", "frozen-uncertain" end
    if held then return "frozen", nil end
    return "alive", nil
  end
  -- The reason as of t: the last miss known by then.
  local why
  for _, m in ipairs(ev.misses or {}) do
    if type(m.at) == "number" and m.at <= t then why = m.why end
  end
  return "unknown", why or "stale-sample"
end

-- The evidence as of horizon instant t: the weight of the last sighting
-- delivered by t, the peak since the observation through t, the last
-- memwatch signal sent by t (and how many), the operator touches by t
-- (certain, and uncertain), and the operator actions by t. A follow-up
-- whose timer ran late reports the horizon it names, not what happened
-- after it. nil after a clock step (see fateAt): nothing can be placed.
function M.asOf(ev, t)
  if ev.clockStep then return nil end
  local function by(at) return type(at) == "number" and at <= t end
  local out = { weightMB = nil, peakMB = ev.weight0, signal = nil, signalCount = 0,
                touches = 0, touchesUncertain = 0, actions = 0 }
  for _, s in ipairs(ev.samples or {}) do
    if by(s.at) then
      -- The weight at t is a reading delivered within the freshness window;
      -- an older one is no reading at t (the peak still counts it).
      out.weightMB = (s.at >= t - M.cfg.sampleFreshSec) and s.weightMB or nil
      if out.peakMB == nil or s.weightMB > out.peakMB then out.peakMB = s.weightMB end
    end
  end
  for _, sig in ipairs(ev.signals or {}) do
    if by(sig.at) then out.signal, out.signalCount = sig, out.signalCount + 1 end
  end
  for _, tc in ipairs(ev.touchLog or {}) do
    if by(tc.at) then
      if tc.uncertain then out.touchesUncertain = out.touchesUncertain + 1 else out.touches = out.touches + 1 end
    end
  end
  for _, a in ipairs(ev.actions or {}) do
    if by(a) then out.actions = out.actions + 1 end
  end
  out.actionsDropped = (ev.actionsDropped or 0) > 0 and ev.actionsDropped or nil
  return out
end

-- Keep each horizon's machine reading in the record once the horizon has
-- passed (from the tick log, while the log still holds it), so a follow-up
-- that runs after the record stopped collecting, or after the log was cut
-- back, still reads its horizon. false records "no reading at that horizon".
function M.snapshotHorizons(ev, log, now, freshSec)
  if ev.clockStep then return end
  for _, h in ipairs(ev.horizons or {}) do
    local tH = ev.obsAt + h
    if ev.metricsAt[h] == nil and now >= tH then
      ev.metricsAt[h] = M.metricAt(log, tH, freshSec) or false
    end
  end
end

-- The machine's reading as of instant t from the glue's tick log (entries
-- { at, availPct, state } in tick order): the last entry at or before t,
-- when it is no older than freshSec (ticks stall with the run loop, and a
-- reading from long before the horizon is not a reading at it); else nil.
function M.metricAt(log, t, freshSec)
  for i = #(log or {}), 1, -1 do
    local m = log[i]
    if type(m.at) == "number" and m.at <= t then
      if m.at >= t - (freshSec or M.cfg.sampleFreshSec) then return m end
      return nil
    end
  end
  return nil
end

-- Is the process a probe found under a pid (probe: { comm, lstart }) the
-- one a tracker entry's data came from? From the entry's start window when
-- it has one: matchStart's answer for the probe's comm and start time.
-- Without a window (a process only the top stream has named), from the
-- start time an alert bound to that pid: "same" when it is the probe's,
-- "different" when not; else "unknown".
function M.sameSource(entry, probe, boundLstart)
  if type(probe) ~= "table" then return "unknown" end
  local w = M.startOf(entry)
  if w then
    -- A start time in a daylight-saving fold cannot be placed: unknown, not
    -- a takeover.
    return M.matchStart(w, entry.comm, M.lstartEpochUnambiguous(probe.lstart), probe.comm)
  end
  if type(boundLstart) == "string" and type(probe.lstart) == "string" then
    return (boundLstart == probe.lstart) and "same" or "different"
  end
  return "unknown"
end

-- Does a frozen-ledger entry hold the observed process? From the entry's
-- bound start time against the observation's start window; nil when that
-- cannot be told.
function M.frozenMatches(entry, start0, comm0)
  if type(entry) ~= "table" then return false end
  -- An entry started in a daylight-saving fold names two epochs: it cannot
  -- be placed, so it is nil (uncertain), never a confident false.
  local m = M.matchStart(start0, nil, M.lstartEpochUnambiguous(entry.lstart), nil)
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

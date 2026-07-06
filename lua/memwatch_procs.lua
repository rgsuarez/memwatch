-- memwatch_procs.lua
-- Pure per-process logic for memwatch: parse process listings, track memory
-- growth per pid, detect runaways, and rank the true memory hogs.
-- NO Hammerspoon dependency: unit-testable with a standalone `lua`
-- interpreter (see ../test_core.lua).
--
-- Detection philosophy: growth rate is the primary signal. A process that is
-- steadily huge (a local model server) is not a problem; a process that is
-- CLIMBING is. Absolute size matters only as attribution once the system is
-- already critical. RSS undercounts a runaway whose pages were compressed
-- away, so ranking adds top's per-process CMPRS column when a fresh top
-- sample is available.

local M = {}

M.cfg = {
  windowSamples      = 12,    -- ring size (12 x 5s ticks = 60s of history)
  staleSec           = 30,    -- forget pids unseen this long
  maxTracked         = 1000,  -- backstop only; the whole ps table is tracked
                              -- because a compressed-away runaway can sit at
                              -- the bottom of any residency-sorted cut
  risingEpsMB        = 8,     -- a sample must climb this much to count as rising
  -- Sustained growth: the primary trigger. Watch-only while the system is ok;
  -- an alert once the system is elevated.
  growthMBmin        = 1500,  -- MB/min over the rising tail
  nRising            = 4,     -- consecutive rising samples (~20s)
  minWindowSec       = 20,    -- the rising tail must span at least this long
  -- Extreme growth: fires even while the system is still ok. This is the
  -- Chrome-runaway catcher: act while there is still headroom. Two routes:
  -- a fast clean streak, or overwhelming net growth across the window even
  -- when heavy load makes the per-tick attribution choppy.
  growthExtremeMBmin = 9000,  -- 150 MB/s over the rising tail
  nRisingExtreme     = 4,     -- rising samples for the streak route (~20s)
  extremeNetMB       = 6000,  -- net window growth route (still-climbing gate)
  extremeLatchSec    = 45,    -- once extreme, stays extreme this long:
                              -- interleaved feeds make the rising tail
                              -- choppy, and RSS collapsing under active
                              -- compression must never read as recovery
  runawayFreshSec    = 12,    -- only pids seen alive this recently can be
                              -- runaways, so a killed process clears the
                              -- list within two ticks despite the latch
  -- Absolute footprint: attribution only, and only once the system is
  -- critical, so a steady 20 GB model server never alarms on size alone.
  absFrac            = 0.40,  -- fraction of total RAM
}

-- Parse `ps -Axo pid,uid,rss,comm -m` rows out of the sampler blob. Lines
-- that do not look like a process row (the sysctl lines, the header) are
-- skipped. rss arrives in KB; comm is the remainder of the line and may
-- contain spaces.
function M.parsePsList(text)
  local list = {}
  for line in (text or ""):gmatch("[^\n]+") do
    local pid, uid, rss, comm = line:match("^%s*(%d+)%s+(%d+)%s+(%d+)%s+(.+)$")
    if pid then
      list[#list + 1] = {
        pid   = tonumber(pid),
        uid   = tonumber(uid),
        rssMB = tonumber(rss) / 1024,
        comm  = comm,
      }
    end
  end
  return list
end

-- Human name for a comm path: the basename. Title compaction beyond that is
-- core.shortName's job.
function M.friendlyName(comm)
  if not comm or comm == "" then return "?" end
  return comm:match("([^/]+)$") or comm
end

local function memValMB(num, unit)
  num = tonumber(num) or 0
  if unit == "K" then return num / 1024 end
  if unit == "M" then return num end
  if unit == "G" then return num * 1024 end
  return num / (1024 * 1024) -- B
end

-- One `top -stats pid,command,mem,cmprs` row. Values look like 1954M, 27M,
-- 0B, 3G, occasionally suffixed with + or -. COMMAND is truncated by top, so
-- the name is display/prefix material only; joins happen by pid. top's MEM
-- approximates the footprint (it includes compressed), so mem alone is the
-- weight-basis-compatible number.
local function parseTopLine(line)
  local pid, name, mem, memU, cmprs, cmprsU =
    line:match("^%s*(%d+)%s+(.-)%s+([%d%.]+)([BKMG])[%+%-]?%s+([%d%.]+)([BKMG])[%+%-]?%s*$")
  if not pid then return nil end
  return tonumber(pid), { memMB = memValMB(mem, memU), cmprsMB = memValMB(cmprs, cmprsU),
                          name = (name or ""):gsub("%s+$", "") }
end

-- Parse a complete one-shot top sample into { [pid] = row }.
function M.parseTop(text)
  local map = {}
  for line in (text or ""):gmatch("[^\n]+") do
    local pid, row = parseTopLine(line)
    if pid then map[pid] = row end
  end
  return map
end

-- Streaming top (`top -l 0`): a single long-lived process that keeps
-- emitting samples right through a memory storm, when forking anything new
-- starves. Chunks arrive with arbitrary boundaries; blocks are delimited by
-- the PID header line. feed() returns the previous block's map whenever a
-- new header completes it, else nil.
function M.newTopStream()
  return { buf = "", cur = nil }
end

function M.feedTopStream(st, chunk)
  st.buf = st.buf .. (chunk or "")
  local published = nil
  while true do
    local nl = st.buf:find("\n", 1, true)
    if not nl then break end
    local line = st.buf:sub(1, nl - 1)
    st.buf = st.buf:sub(nl + 1)
    if line:match("^%s*PID%s") then
      if st.cur and next(st.cur) then published = st.cur end
      st.cur = {}
    elseif st.cur then
      local pid, row = parseTopLine(line)
      if pid then st.cur[pid] = row end
    end
  end
  return published
end

------------------------------------------------------------------------------
-- growth tracking
------------------------------------------------------------------------------

function M.newTracker(cfg)
  return { cfg = cfg or M.cfg, procs = {} }
end

-- Feed one ps snapshot into the tracker. pid reuse is detected by a comm
-- change (ps has no etimes on this macOS), which resets that pid's history.
--
-- Rings hold FOOTPRINT WEIGHT (rss + this pid's compressed size from the
-- most recent top sample, sticky between top refreshes), not raw RSS. A
-- machine under load compresses a fast allocator's pages in near-real-time,
-- deflating its RSS while it grows; weight keeps climbing and stays visible.
-- topMap may be nil or stale; the last known cmprs carries forward.
function M.update(tr, psList, now, topMap)
  local cfg = tr.cfg
  local n = 0
  for _ in pairs(tr.procs) do n = n + 1 end
  for _, p in ipairs(psList) do
    local e = tr.procs[p.pid]
    if e and e.comm and e.comm ~= p.comm then
      tr.procs[p.pid] = nil; e = nil; n = n - 1
    end
    if not e and n < cfg.maxTracked then
      e = { comm = p.comm, uid = p.uid, name = M.friendlyName(p.comm), ring = {} }
      tr.procs[p.pid] = e; n = n + 1
    end
    if e and not e.comm then
      -- Born from a streamed top block: fill in the full identity now that
      -- ps has seen it (reuse detection could not apply to that transition).
      e.comm = p.comm
      e.name = M.friendlyName(p.comm)
    end
    if e then
      local t = topMap and topMap[p.pid]
      if t then e.cmprsMB = t.cmprsMB end
      local w = p.rssMB + (e.cmprsMB or 0)
      e.uid, e.lastSeen, e.rssMB, e.weightMB = p.uid, now, p.rssMB, w
      local ring = e.ring
      ring[#ring + 1] = { t = now, v = w }
      if #ring > cfg.windowSamples then table.remove(ring, 1) end
    end
  end
  for pid, e in pairs(tr.procs) do
    if (now - (e.lastSeen or 0)) > cfg.staleSec then tr.procs[pid] = nil end
  end
end

-- Feed a streamed top block into the tracker: the attribution path that
-- keeps working when the system is too starved to fork ps. Only pids whose
-- ring has not been refreshed in the last 4s get a sample (cadence guard, so
-- interleaved ps and top feeds cannot double-rate the rings). Ring value is
-- top's MEM (footprint, includes compressed), the same basis as the ps
-- formula rss + sticky cmprs. Entries born here carry top's truncated name
-- and no comm/uid; a later ps row fills identity in, and the kill path
-- re-probes the live pid regardless.
function M.updateFromTop(tr, topMap, now)
  if not topMap then return end
  local cfg = tr.cfg
  local n = 0
  for _ in pairs(tr.procs) do n = n + 1 end
  for pid, t in pairs(topMap) do
    local e = tr.procs[pid]
    if not e and n < cfg.maxTracked then
      e = { comm = nil, uid = nil, ring = {},
            name = (t.name and t.name ~= "") and t.name or ("pid " .. pid) }
      tr.procs[pid] = e; n = n + 1
    end
    if e then
      e.cmprsMB = t.cmprsMB
      e.lastSeen = now
      e.weightMB = t.memMB
      local ring = e.ring
      local lastT = ring[#ring] and ring[#ring].t or -1e9
      if (now - lastT) >= 4 then
        ring[#ring + 1] = { t = now, v = t.memMB }
        if #ring > cfg.windowSamples then table.remove(ring, 1) end
      end
    end
  end
end

-- Growth over the RISING TAIL of a ring: how many samples (from the newest
-- backwards) climbed by more than eps, and the slope in MB/min across that
-- tail. Judging the tail, not the whole window, keeps an old flat stretch
-- from diluting a fresh climb. ONE flat tick between rises is tolerated
-- (grace): the compressed component refreshes on top's slower cadence, so a
-- real climb can legitimately land on alternate ticks. Two consecutive flat
-- ticks or any real drop still end the streak, which keeps plateaued
-- installers and steady servers silent.
local function growth(ring, eps)
  local n = #ring
  if n < 2 then return 0, 0, 0 end
  local rising, i0, consecFlat = 0, n, 0
  for i = n, 2, -1 do
    local d = ring[i].v - ring[i - 1].v
    if d > eps then
      rising = rising + 1
      consecFlat = 0
      i0 = i - 1
    elseif d >= -eps then
      consecFlat = consecFlat + 1
      if consecFlat >= 2 then break end
      i0 = i - 1  -- the grace tick joins the tail
    else
      break       -- a real drop ends the story
    end
  end
  if rising == 0 then return 0, 0, 0 end
  local span = ring[n].t - ring[i0].t
  local slope = span > 0 and (ring[n].v - ring[i0].v) / span * 60 or 0
  return slope, rising, span
end
M.growth = growth -- exposed for tests

-- Classify runaways. Returns a sorted array of
--   { pid, name, comm, uid, rssMB, slopeMBmin, kind }
-- kind: "extreme" (fires even at ok), "sustained" (watch at ok, alert once
-- elevated), "absolute" (attribution only while the system is critical).
function M.runaways(tr, now, systemState, totalMB)
  local cfg = tr.cfg
  local out = {}
  for pid, e in pairs(tr.procs) do
    -- Only pids seen alive recently can be runaways: the extreme latch below
    -- must not keep a killed process on the books.
    if (now - (e.lastSeen or 0)) <= cfg.runawayFreshSec then
      local slope, rising, span = growth(e.ring, cfg.risingEpsMB)
      local netMB = (#e.ring >= 2) and (e.ring[#e.ring].v - e.ring[1].v) or 0
      local kind
      if (slope >= cfg.growthExtremeMBmin and rising >= cfg.nRisingExtreme)
         or (netMB >= cfg.extremeNetMB and rising >= 2) then
        kind = "extreme"
        e.extremeUntil = now + cfg.extremeLatchSec
      elseif slope >= cfg.growthMBmin and rising >= cfg.nRising and span >= cfg.minWindowSec then
        kind = "sustained"
      elseif systemState == "critical" and totalMB and (e.weightMB or 0) >= cfg.absFrac * totalMB then
        kind = "absolute"
      end
      -- Latch: an extreme verdict holds for its full window. No deflation
      -- release on purpose: under active compression the kernel collapses a
      -- runaway's RSS while it is still growing, and that must never read
      -- as recovery. A genuinely recovered process ages out with the latch.
      if kind ~= "extreme" and e.extremeUntil and now < e.extremeUntil then
        kind = "extreme"
      end
      if kind then
        out[#out + 1] = { pid = pid, name = e.name, comm = e.comm, uid = e.uid,
                          rssMB = e.rssMB or 0, weightMB = e.weightMB or e.rssMB or 0,
                          slopeMBmin = slope, kind = kind }
      end
    end
  end
  local rank = { extreme = 3, sustained = 2, absolute = 1 }
  table.sort(out, function(a, b)
    if rank[a.kind] ~= rank[b.kind] then return rank[a.kind] > rank[b.kind] end
    return a.slopeMBmin > b.slopeMBmin
  end)
  return out
end

------------------------------------------------------------------------------
-- ranking and offender selection
------------------------------------------------------------------------------

-- Rank current processes by true memory weight: resident + compressed.
-- psList gives fresh RSS; topMap (possibly stale, possibly nil) adds CMPRS.
function M.rankByWeight(psList, topMap, n)
  local rows = {}
  for _, p in ipairs(psList) do
    local t = topMap and topMap[p.pid]
    local cmprs = t and t.cmprsMB or 0
    rows[#rows + 1] = {
      pid = p.pid, uid = p.uid, comm = p.comm, name = M.friendlyName(p.comm),
      rssMB = p.rssMB, cmprsMB = cmprs, weightMB = p.rssMB + cmprs,
    }
  end
  table.sort(rows, function(a, b) return a.weightMB > b.weightMB end)
  local out = {}
  for i = 1, math.min(n or 5, #rows) do out[i] = rows[i] end
  return out
end

-- The single process an alert should name, plus (second return) a watch-only
-- grower for the elevated title hint. A merely-sustained grower while the
-- system is still ok is a watch, not an offender; extreme growth is always an
-- offender. When the system is critical with NO identified runaway, the top
-- hog by weight is named but explicitly tagged kind="hog": it is the largest
-- process, not a proven cause, and every surface must present it that way
-- (a steady VM or model server must never read like a caught runaway).
function M.pickOffender(runawayList, ranked, systemState)
  local r = runawayList and runawayList[1]
  if r then
    if r.kind == "sustained" and systemState == "ok" then return nil, r end
    return r, nil
  end
  if systemState == "critical" and ranked and ranked[1] then
    local h = ranked[1]
    return { pid = h.pid, name = h.name, comm = h.comm, uid = h.uid,
             rssMB = h.rssMB, weightMB = h.weightMB, kind = "hog" }, nil
  end
  return nil, nil
end

return M

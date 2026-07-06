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
  -- Chrome-runaway catcher: act while there is still headroom.
  growthExtremeMBmin = 9000,  -- 150 MB/s
  nRisingExtreme     = 5,     -- consecutive rising samples (~25s)
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

-- Parse `top -l 1 -o mem -stats pid,command,mem,cmprs` into
-- { [pid] = { memMB =, cmprsMB = } }. top truncates COMMAND, so names from
-- here are never used; join by pid. Values look like 1954M, 27M, 0B, 3G,
-- occasionally suffixed with + or -.
function M.parseTop(text)
  local map = {}
  for line in (text or ""):gmatch("[^\n]+") do
    local pid, mem, memU, cmprs, cmprsU =
      line:match("^%s*(%d+)%s+.-%s+([%d%.]+)([BKMG])[%+%-]?%s+([%d%.]+)([BKMG])[%+%-]?%s*$")
    if pid then
      map[tonumber(pid)] = { memMB = memValMB(mem, memU), cmprsMB = memValMB(cmprs, cmprsU) }
    end
  end
  return map
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
    if e and e.comm ~= p.comm then
      tr.procs[p.pid] = nil; e = nil; n = n - 1
    end
    if not e and n < cfg.maxTracked then
      e = { comm = p.comm, uid = p.uid, name = M.friendlyName(p.comm), ring = {} }
      tr.procs[p.pid] = e; n = n + 1
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
    local slope, rising, span = growth(e.ring, cfg.risingEpsMB)
    local kind
    if slope >= cfg.growthExtremeMBmin and rising >= cfg.nRisingExtreme then
      kind = "extreme"
    elseif slope >= cfg.growthMBmin and rising >= cfg.nRising and span >= cfg.minWindowSec then
      kind = "sustained"
    elseif systemState == "critical" and totalMB and (e.weightMB or 0) >= cfg.absFrac * totalMB then
      kind = "absolute"
    end
    if kind then
      out[#out + 1] = { pid = pid, name = e.name, comm = e.comm, uid = e.uid,
                        rssMB = e.rssMB or 0, weightMB = e.weightMB or e.rssMB or 0,
                        slopeMBmin = slope, kind = kind }
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
-- offender; when the system is critical with no identified runaway, the top
-- hog by weight takes the blame line.
function M.pickOffender(runawayList, ranked, systemState)
  local r = runawayList and runawayList[1]
  if r then
    if r.kind == "sustained" and systemState == "ok" then return nil, r end
    return r, nil
  end
  if systemState == "critical" and ranked and ranked[1] then return ranked[1], nil end
  return nil, nil
end

return M

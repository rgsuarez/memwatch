-- test_core.lua
-- Unit tests for memwatch_core (pure logic). Run from the project root:
--   cd ~/projects/memwatch && lua test_core.lua
-- Exercises the three-case floor: ok / warn / crit, plus the parsers.

package.path = "lua/?.lua;" .. package.path
local core = require("memwatch_core")

local fails = 0
local function check(name, got, want)
  if got ~= want then
    fails = fails + 1
    print(string.format("FAIL  %-34s got=%s want=%s", name, tostring(got), tostring(want)))
  else
    print(string.format("ok    %s", name))
  end
end

local TOTAL = 38654705664 -- 36 GiB, this machine (hw.memsize)
local PAGE  = 16384

-- ---- parsers ----
local vmSample = [[
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                   100000.
Pages active:                                 805494.
Pages stored in compressor:                  1119899.
Pages speculative:                              5000.
Pages purgeable:                                1000.
File-backed pages:                             50000.
]]
local vm = core.parseVmStat(vmSample)
check("parse page size",       core.parsePageSize(vmSample), 16384)
check("parse free pages",      vm["Pages free"], 100000)
check("parse compressor pages", vm["Pages stored in compressor"], 1119899)
check("swap used = 0",         core.parseSwapUsed("total = 0.00M  used = 0.00M  free = 0.00M  (encrypted)"), 0)
check("swap used = 1.5G",      core.parseSwapUsed("total = 4096.00M  used = 1.50G  free = 2.00G"), 1.5 * 1024 ^ 3)

-- ---- classify: crit (freeze-like, ~18.3 GB compressor) ----
local mCrit = core.metrics(vm, 0, TOTAL, PAGE)
check("crit: 18GB compressor", core.classify(mCrit), "crit")

-- ---- classify: ok (healthy, 0 compressor, ample available) ----
local vmOk = core.parseVmStat(
  "Pages free: 300000.\nPages stored in compressor: 0.\nFile-backed pages: 200000.\n")
local mOk = core.metrics(vmOk, 0, TOTAL, PAGE)
check("ok: 0 compressor",      core.classify(mOk), "ok")

-- ---- classify: warn (compressor ~9.8 GB, available still healthy) ----
local vmWarn = core.parseVmStat(
  "Pages free: 300000.\nPages stored in compressor: 600000.\nFile-backed pages: 200000.\n")
local mWarn = core.metrics(vmWarn, 0, TOTAL, PAGE)
check("warn: 9.8GB compressor", core.classify(mWarn), "warn")

-- ---- classify: crit via swap alone ----
local mSwap = core.metrics(vmOk, 7 * 1024 ^ 3, TOTAL, PAGE)
check("crit: 7GB swap",         core.classify(mSwap), "crit")

-- ---- native vmStat mapping (hs.host.vmStat field names) ----
local native = {
  pageSize = PAGE, memSize = TOTAL,
  pagesFree = 100000, pagesSpeculative = 5000, pagesPurgeable = 1000,
  fileBackedPages = 50000,
  uncompressedPages = 1119899,        -- vm_stat "Pages stored in compressor"
  pagesUsedByVMCompressor = 400000,   -- physical footprint; must NOT be used
  pagesCompressed = 500000, swapOuts = 20000, pageOuts = 3000,
}
local mn = core.metricsFromVmStat(native, 1.5 * 1024 ^ 3)
check("native compGB uses uncompressedPages",
      string.format("%.1f", mn.compGB), string.format("%.1f", 1119899 * PAGE / 1e9))
check("native availPct matches popen path",
      string.format("%.2f", mn.availPct), string.format("%.2f", mCrit.availPct))
check("native swapGB", string.format("%.1f", mn.swapGB), "1.6")
check("native counters carried", mn.counters.swapOuts, 20000)
check("native empty table safe", core.metricsFromVmStat({}, 0).availPct, 100)

-- ---- rate: normal delta / counter reset / bad dt ----
check("rate normal",        core.rate(1500, 1000, 5), 100)
check("rate counter reset", core.rate(10, 99999, 5), 0)
check("rate zero dt",       core.rate(1500, 1000, 0), 0)
check("rate first sample",  core.rate(1500, nil, 5), 0)

-- ---- parseSampler: consolidated sysctl blob ----
local blob = "1\ntotal = 9216.00M  used = 7987.06M  free = 1228.94M  (encrypted)\n  PID   UID    RSS COMM\n  123   502  50000 /usr/bin/foo\n"
local samp = core.parseSampler(blob)
check("sampler kern level",  samp.kernLevel, 1)
check("sampler swap bytes",  math.floor(samp.swapBytes / 1024 ^ 2), 7987)
check("sampler crit level",  core.parseSampler("4\ntotal = 0M used = 0M free = 0M\n").kernLevel, 4)
check("sampler garbled calm", core.parseSampler("").kernLevel, 1)
check("sampler garbled swap", core.parseSampler("garbage with no fields").swapBytes, 0)

-- ---- signals ----
local R0 = { swapOut = 0, comp = 0, pageOut = 0 }
-- This machine at rest: huge compressor + swap held, but idle rates, kern 1.
local mRest = { availPct = 40, compGB = 31, swapGB = 8.4 }
local sCalm = core.signals(mRest, R0, 1, false)
check("rest: no elev cond",  sCalm.elevCond, false)
check("rest: no crit cond",  sCalm.critCond, false)
check("rest: calm for exit", sCalm.calmElev, true)

local sSwap  = core.signals(mRest, { swapOut = 250,  comp = 0, pageOut = 0 }, 1, false)
check("swap 250pg/s is active",   sSwap.swapActive, true)
check("swap active raises elev",  sSwap.elevCond, true)
check("swap active is not crit",  sSwap.critCond, false)

local sStorm = core.signals(mRest, { swapOut = 2500, comp = 0, pageOut = 0 }, 1, false)
check("swap 2500pg/s is a storm", sStorm.critSlow, true)

local sKern4 = core.signals(mRest, R0, 4, false)
check("kernel 4 is critFast",     sKern4.critFast, true)
local sRun   = core.signals(mRest, R0, 1, true)
check("runaway is critFast",      sRun.critFast, true)

local sFloor = core.signals({ availPct = 4 }, { swapOut = 0, comp = 6000, pageOut = 0 }, 1, false)
check("floor + compActive crit",  sFloor.critSlow, true)
check("floor alone is not crit",  core.signals({ availPct = 4 }, R0, 1, false).critSlow, false)

-- ---- state machine ----
-- confirm debounce: blips never raise
local sm = core.newSMState(0)
core.smStep(sm, sSwap, 5)
check("sm: single blip stays ok", sm.state, "ok")
core.smStep(sm, sCalm, 10)
core.smStep(sm, sSwap, 15)
check("sm: broken streak stays ok", sm.state, "ok")
core.smStep(sm, sSwap, 20); core.smStep(sm, sSwap, 25)
check("sm: 2 consecutive -> elevated", sm.state, "elevated")

-- storm escalation needs its own confirmation
core.smStep(sm, sStorm, 30)
check("sm: 1 storm tick holds elevated", sm.state, "elevated")
core.smStep(sm, sStorm, 35)
check("sm: 2 storm ticks -> critical", sm.state, "critical")

-- release: calm ticks alone are not enough before the dwell expires
for t = 40, 60, 5 do core.smStep(sm, sCalm, t) end
check("sm: calm before dwell holds critical", sm.state, "critical")
core.smStep(sm, sCalm, 65)
check("sm: dwell + release -> elevated", sm.state, "elevated")
for t = 70, 80, 5 do core.smStep(sm, sCalm, t) end
check("sm: elevated holds until its dwell", sm.state, "elevated")
core.smStep(sm, sCalm, 85)
check("sm: elevated -> ok after dwell", sm.state, "ok")

-- kernel critical and extreme runaways take one tick
local sm2 = core.newSMState(0)
core.smStep(sm2, sKern4, 5)
check("sm: kernel 4 -> critical in one tick", sm2.state, "critical")
local sm3 = core.newSMState(0)
local _, _, rs3 = core.smStep(sm3, sRun, 5)
check("sm: runaway -> critical in one tick", sm3.state, "critical")
check("sm: runaway reason", rs3, "runaway-extreme")

-- flap replay: the 2026-06-30 series. compGB oscillated around the old 14 GB
-- absolute boundary (crit<->warn every 5s in the log) with idle rates, kernel
-- normal, avail 27-48%. The new model must not move at all.
local sm4 = core.newSMState(0)
local flips = 0
for i = 1, 60 do
  local sig = core.signals(
    { availPct = (i % 2 == 0) and 27 or 48, compGB = (i % 2 == 0) and 14.3 or 13.9 },
    R0, 1, false)
  local _, changed = core.smStep(sm4, sig, i * 5)
  if changed then flips = flips + 1 end
end
check("sm: flap replay zero transitions", flips, 0)
check("sm: flap replay stays ok", sm4.state, "ok")

-- boundary hover: enter on a sustained rate, then hover just under the entry
-- threshold. Exit needs swapOut < swapLo/2, so hovering must not flap.
local sm5 = core.newSMState(0)
local flips5, t5 = 0, 0
local function hover(rateVal)
  t5 = t5 + 5
  local sig = core.signals(mRest, { swapOut = rateVal, comp = 0, pageOut = 0 }, 1, false)
  local _, changed = core.smStep(sm5, sig, t5)
  if changed then flips5 = flips5 + 1 end
end
hover(210); hover(210)
for i = 1, 20 do hover(i % 2 == 0 and 210 or 190) end
check("sm: boundary hover one transition", flips5, 1)
check("sm: boundary hover holds elevated", sm5.state, "elevated")

-- ---- title rendering ----
check("title ok text",  core.renderTitle("ok", {}).text, core.DOT)
check("title ok level", core.renderTitle("ok", {}).level, "ok")
local tE = core.renderTitle("elevated", { watchName = "Google Chrome Helper (Renderer)" })
check("title elevated hint", tE.text, core.DOT .. " Google Chrome\u{2191}")
check("title elevated level", tE.level, "warn")
check("title elevated bare", core.renderTitle("elevated", {}).text, core.DOT)
local tC = core.renderTitle("critical", { offenderName = "python3", offenderGB = 8.4 })
check("title critical offender", tC.text, core.DOT .. " python3 8G")
check("title critical level", tC.level, "crit")
check("title critical cause", core.renderTitle("critical", { causeTag = "SWAP" }).text, core.DOT .. " SWAP")
check("title long name capped", core.shortName(("A"):rep(20)), ("A"):rep(13) .. "\u{2026}")

if fails == 0 then
  print("\nALL PASS")
else
  print("\n" .. fails .. " FAILED")
  os.exit(1)
end

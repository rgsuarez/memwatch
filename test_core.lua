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

if fails == 0 then
  print("\nALL PASS")
else
  print("\n" .. fails .. " FAILED")
  os.exit(1)
end

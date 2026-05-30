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

if fails == 0 then
  print("\nALL PASS")
else
  print("\n" .. fails .. " FAILED")
  os.exit(1)
end

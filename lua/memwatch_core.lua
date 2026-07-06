-- memwatch_core.lua
-- Pure logic for the memwatch menu-bar memory-pressure gauge.
-- NO Hammerspoon dependency: every function here is unit-testable with a
-- standalone `lua` interpreter (see ../test_core.lua). The Hammerspoon glue
-- in memwatch.lua does the actual command execution and UI; it delegates all
-- parsing and classification to this module.

local M = {}

-- Apple silicon default page size (bytes). Overridable; also auto-detected
-- from the vm_stat header by parsePageSize().
M.PAGE = 16384

-- Thresholds (the "Balanced" profile), calibrated to the 2026-05-29 freeze on
-- this machine: the morning jetsam event sat at ~11 GB compressor with under
-- 600 MB free; the terminal freeze was reached at ~17-18 GB compressor.
-- A signal trips a level if ANY of its conditions are met.
M.cfg = {
  pageSize          = M.PAGE,
  pollSec           = 5,    -- how often the gauge samples
  notifyCooldownSec = 180,  -- min seconds between critical notifications
  -- Pulse the dot on warn/crit? Off by default: the color and the compressor-GB
  -- readout already signal the level, and a blinking menu-bar item is distracting.
  -- Set to true to restore the warn slow-pulse / crit fast-flash.
  flash             = false,
  warn = { compGB = 8,  swapGB = 2, availPct = 15 },
  crit = { compGB = 14, swapGB = 6, availPct = 8  },
}

-- Detect the VM page size from a vm_stat header line, else fall back to M.PAGE.
function M.parsePageSize(vmStatText)
  return tonumber((vmStatText or ""):match("page size of (%d+) bytes")) or M.PAGE
end

-- Parse `vm_stat` output into a { [label] = pageCount } table.
-- Lines look like:  "Pages stored in compressor:            1119899."
function M.parseVmStat(vmStatText)
  local t = {}
  for line in (vmStatText or ""):gmatch("[^\n]+") do
    local key, val = line:match("^(.-):%s+(%d+)%.?$")
    if key and val then t[key] = tonumber(val) end
  end
  return t
end

-- Parse `sysctl -n vm.swapusage` -> swap USED in bytes.
-- Input form: "total = 4096.00M  used = 1.50G  free = 2.00G  (encrypted)"
function M.parseSwapUsed(swapText)
  local num, unit = (swapText or ""):match("used%s*=%s*([%d%.]+)%s*([KMG]?)")
  if not num then return 0 end
  local mult = ({ K = 1024, M = 1024 ^ 2, G = 1024 ^ 3 })[unit] or 1
  return tonumber(num) * mult
end

-- Derive human-facing metrics from parsed inputs.
--   vm         : table from parseVmStat
--   swapBytes  : number from parseSwapUsed
--   totalBytes : hw.memsize
--   pageSize   : bytes per page
-- "available" is reclaimable headroom (free + speculative + purgeable +
-- file-backed), NOT raw free, because macOS deliberately keeps free pages low;
-- raw free would false-alarm constantly.
function M.metrics(vm, swapBytes, totalBytes, pageSize)
  vm = vm or {}
  pageSize = pageSize or M.cfg.pageSize
  local function p(k) return vm[k] or 0 end
  local storedPages = p("Pages stored in compressor")
  local availPages  = p("Pages free") + p("Pages speculative")
                    + p("Pages purgeable") + p("File-backed pages")
  totalBytes = totalBytes or 0
  return {
    compGB   = (storedPages * pageSize) / 1e9,
    swapGB   = (swapBytes or 0) / 1e9,
    availPct = totalBytes > 0 and (availPages * pageSize / totalBytes * 100) or 100,
  }
end

-- Derive metrics from hs.host.vmStat()'s native table (no fork needed).
-- Field note: the native API names vm_stat's "Pages stored in compressor"
-- `uncompressedPages` (the logical volume held by the compressor);
-- `pagesUsedByVMCompressor` is the compressor's physical footprint and is NOT
-- what the compressor row in the UI reports. Also carries the cumulative
-- counters whose deltas give activity rates.
function M.metricsFromVmStat(v, swapBytes)
  v = v or {}
  local pageSize = v.pageSize or M.cfg.pageSize
  local total = v.memSize or 0
  local function n(k) return v[k] or 0 end
  local availPages = n("pagesFree") + n("pagesSpeculative")
                   + n("pagesPurgeable") + n("fileBackedPages")
  return {
    compGB   = n("uncompressedPages") * pageSize / 1e9,
    swapGB   = (swapBytes or 0) / 1e9,
    availPct = total > 0 and (availPages * pageSize / total * 100) or 100,
    totalGB  = total / 1e9,
    counters = {
      swapOuts   = n("swapOuts"),
      compressed = n("pagesCompressed"),
      pageOuts   = n("pageOuts"),
    },
  }
end

-- Per-second rate from a cumulative counter pair. Clamps to 0 on the first
-- sample, a non-positive interval, or a counter reset (reboot / wraparound):
-- a negative delta must never read as activity.
function M.rate(cur, prev, dt)
  if not cur or not prev or not dt or dt <= 0 or cur < prev then return 0 end
  return (cur - prev) / dt
end

-- Parse the consolidated sampler blob. Line 1 is
-- `sysctl -n kern.memorystatus_vm_pressure_level` (1 normal / 2 warn / 4
-- critical); the vm.swapusage line follows. A missing or garbled blob parses
-- to the calm defaults (level 1, swap 0) so a failed fork can never raise an
-- alert on its own.
function M.parseSampler(text)
  text = text or ""
  local kern = tonumber(text:match("^%s*(%d+)%s*\n")) or tonumber(text:match("^%s*(%d+)%s*$")) or 1
  return { kernLevel = kern, swapBytes = M.parseSwapUsed(text) }
end

-- Classify metrics into "ok" | "warn" | "crit".
function M.classify(m, cfg)
  cfg = cfg or M.cfg
  local function hit(th)
    return m.compGB >= th.compGB or m.swapGB >= th.swapGB or m.availPct <= th.availPct
  end
  if hit(cfg.crit) then return "crit" end
  if hit(cfg.warn) then return "warn" end
  return "ok"
end

return M

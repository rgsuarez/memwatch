-- report.lua: CLI for the memwatch value report.
--
--   lua eval/report.lua [--ledger memwatch-lfm.jsonl] [--log memwatch.log]
--     [--league eval/results/league.json] [--out reports/report.html]
--     [--public] [--format html|md]
--
-- --public strips local paths, collapses the bake-off league to the shipped
-- model's headline block, and omits failure analysis; committed screenshots
-- and docs numbers come only from public renders.

package.path = "lua/?.lua;" .. package.path
local report = require("memwatch_report")

local args = {}
do
  local i = 1
  while i <= #arg do
    local key = arg[i]:match("^%-%-(.+)$")
    if key == "public" then
      args.public = true
    elseif key then
      args[key] = arg[i + 1]
      i = i + 1
    end
    i = i + 1
  end
end

os.execute("mkdir -p reports")
local out, err = report.generate({
  ledger = args.ledger or "memwatch-lfm.jsonl",
  log = args.log or "memwatch.log",
  league = args.league or "eval/results/league.json",
  out = args.out or (args.format == "md" and "reports/report.md" or "reports/report.html"),
}, {
  public = args.public,
  format = args.format or "html",
  generatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
})
if not out then
  io.stderr:write("report: " .. tostring(err) .. "\n")
  os.exit(1)
end
print("report written: " .. out)

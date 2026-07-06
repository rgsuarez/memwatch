-- test_report.lua
-- Unit tests for memwatch_report (the value-report renderer). Run:
--   cd ~/projects/memwatch && lua test_report.lua

package.path = "lua/?.lua;" .. package.path
local report = require("memwatch_report")
local lfm = require("memwatch_lfm")

local fails = 0
local function check(name, got, want)
  if got ~= want then
    fails = fails + 1
    print(string.format("FAIL  %-40s got=%s want=%s", name, tostring(got), tostring(want)))
  else
    print(string.format("ok    %s", name))
  end
end

-- ---- htmlEscape (text-node discipline) ----
check("escape: amp", report.htmlEscape("a&b"), "a&amp;b")
check("escape: tags", report.htmlEscape("<script>"), "&lt;script&gt;")
check("escape: quotes", report.htmlEscape('a"b\'c'), "a&quot;b&#39;c")
check("escape: non-string", report.htmlEscape(nil), "")

-- ---- ledger parsing ----
local LEDGER = table.concat({
  '{"action":"wait","adjudicator":"lfm-advisory","at":"2026-07-06T16:33:39Z","confidence":0,"latencyMs":546,"offender":{"kind":"extreme","name":"Python","weightMB":5197}}',
  '{"action":"freeze","adjudicator":"deterministic-fallback","at":"2026-07-06T16:42:53Z","offender":{"kind":"extreme","name":"Python","weightMB":455},"rails":["deterministic"]}',
  '{"at":"2026-07-06T16:43:53Z","outcome_for":"2026-07-06T16:42:53Z","action":"freeze","adjudicator":"deterministic-fallback","fate":"frozen","availPctBefore":10,"availPctAfter":10}',
  'garbage line that must be skipped',
  '{"action":"terminate","adjudicator":"lfm","at":"2026-07-06T17:00:00Z","confidence":0.9,"latencyMs":800,"offender":{"kind":"extreme","name":"node","weightMB":8000},"rationale":"sustained 8GB/min growth"}',
  '{"at":"2026-07-06T17:01:00Z","outcome_for":"2026-07-06T17:00:00Z","action":"terminate","adjudicator":"lfm","fate":"exited","availPctBefore":9,"availPctAfter":27}',
}, "\n")
local decisions, outcomes = report.parseLedger(LEDGER)
check("ledger: decisions parsed", #decisions, 3)
check("ledger: outcome keyed", outcomes["2026-07-06T16:42:53Z"] ~= nil, true)
check("ledger: terminate outcome keyed", outcomes["2026-07-06T17:00:00Z"] ~= nil, true)
check("ledger: garbage skipped", decisions[2].action, "freeze")

-- ---- watchdog log parsing ----
local LOG = table.concat({
  "2026-07-06 11:33:18 state=elevated reason=state:pressure-building kern=1",
  "2026-07-06 11:33:33 state=critical reason=state:swap-storm kern=2 swapout=9479",
  "2026-07-06 11:42:53 state=critical reason=unattended-freeze:Python(63556):deterministic-fallback kern=1",
  "2026-07-06 11:42:54 state=critical reason=freeze-done:Python(63556) kern=2",
  "2026-07-06 11:44:53 state=elevated reason=state:easing kern=1",
  "not a log line",
  "2026-07-06 12:00:00 state=critical reason=state:runaway-extreme kern=1",
  "2026-07-06 12:04:00 state=ok reason=state:recovered kern=1",
}, "\n")
local events, episodes = report.parseWatchLog(LOG)
check("log: events parsed", #events, 7)
check("log: two episodes", #episodes, 2)
check("log: episode duration", math.floor((episodes[1].stop - episodes[1].start) / 60), 11)
check("log: actions attributed", #episodes[1].actions, 2)

-- ---- aggregation ----
local agg = report.aggregate(decisions, outcomes, episodes)
check("agg: decisions", agg.decisions, 3)
-- Interventions are only counted when a terminal outcome corroborates them:
-- the freeze (fate=frozen) and the terminate (fate=exited) both have outcomes.
check("agg: interventions require an outcome", agg.interventions, 2)
check("agg: action mix", agg.waits .. "/" .. agg.freezes .. "/" .. agg.terminates, "1/1/1")
check("agg: fallback counted", agg.byAdjudicator["deterministic-fallback"], 1)
-- Relief is reclaimed memory: ONLY the terminate that exited contributes.
check("agg: relief from terminate only", agg.reliefGBmin > 0, true)
-- The freeze holds memory: reported as growth-stopped, never relief.
check("agg: freeze counted as stopped", agg.freezeStopped, 1)
check("agg: freeze held GB tracked", agg.freezeHeldGB > 0, true)
check("agg: relief cap stated", agg.reliefCapMin, 60)
check("agg: latencies collected", #agg.latencies, 2)
check("agg: episodes counted", agg.episodeCount, 2)

-- ---- HTML rendering invariants ----
local LEAGUE = { league = lfm.jsonArray({
  { label = "350M-Q4_K_M", variant = "taxonomy", gold = 0.8, acceptable = 0.9, danger = 0.0,
    injection_compliance = 0, json_valid = 1.0, warm_p95_ms = 900, footprint_mb = 600,
    gates_passed = true, composite = 0.85 },
  { label = "8B-A1B-Q4_K_M", variant = "taxonomy", gold = 0.9, acceptable = 0.95, danger = 0.0,
    injection_compliance = 0, json_valid = 1.0, warm_p95_ms = 3000, footprint_mb = 5300,
    gates_passed = true, composite = 0.93, reference_only = true },
}), winner = "350M-Q4_K_M", winner_variant = "taxonomy" }

-- Adversarial: attacker-controlled process name and rationale.
local evil = '<script>alert(1)</script><img src="http://evil/x.png">'
local advDecisions = { { action = "freeze", adjudicator = "lfm", at = "2026-07-06T17:00:00Z",
  confidence = 0.8, latencyMs = 500, offender = { name = evil, kind = "extreme", weightMB = 1000 },
  rationale = evil } }
local advAgg = report.aggregate(advDecisions, {}, {})

local html = report.renderHTML(advAgg, { league = LEAGUE, generatedAt = "2026-07-06T17:00:00Z" })
check("html: no script tag survives", html:find("<script", 1, true), nil)
check("html: no external image", html:find('src="http', 1, true), nil)
check("html: evil name escaped", html:find("&lt;script&gt;", 1, true) ~= nil, true)
check("html: no external stylesheet", html:find("<link", 1, true), nil)
check("html: no css url()", html:find("url(", 1, true), nil)
check("html: unverified label present", html:find("model-generated, unverified", 1, true) ~= nil, true)
check("html: full league sentinel", html:find("league:full", 1, true) ~= nil, true)
check("html: league renders rows", html:find("8B-A1B-Q4_K_M", 1, true) ~= nil, true)

local pub = report.renderHTML(advAgg, { league = LEAGUE, public = true, generatedAt = "x" })
check("public: league collapsed", pub:find("league:full", 1, true), nil)
check("public: winner shown", pub:find("350M-Q4_K_M", 1, true) ~= nil, true)
check("public: reference row omitted", pub:find("8B-A1B-Q4_K_M", 1, true), nil)
check("public: methodology pointer", pub:find("bakeoff-methodology", 1, true) ~= nil, true)

-- ---- markdown parity from the same aggregate ----
local md = report.renderMD(agg, {})
check("md: adjudications line", md:find("adjudications: 3", 1, true) ~= nil, true)
check("md: cap stated", md:find("cap 60 min/action", 1, true) ~= nil, true)

-- ---- degrades to log-only ----
local emptyAgg = report.aggregate({}, {}, episodes)
local logOnly = report.renderHTML(emptyAgg, {})
check("degrade: renders without ledger", logOnly:find("critical episodes observed", 1, true) ~= nil, true)
check("degrade: no timeline section", logOnly:find("Decision timeline", 1, true), nil)

if fails == 0 then
  print("\nALL PASS")
else
  print("\n" .. fails .. " FAILED")
  os.exit(1)
end

-- memwatch_report.lua: the value report, rendered from the ledgers.
--
-- Pure and Hammerspoon-free (runs under the eval CLI and the glue alike).
-- Input: the decision ledger (memwatch-lfm.jsonl), the watchdog log
-- (memwatch.log), and optionally the bake-off league/summary. Output: ONE
-- self-contained dark HTML file (inline CSS, hand-rolled SVG, no scripts,
-- no external resources) or a markdown digest from the same aggregates so
-- public numbers cannot drift from what the report shows.
--
-- Honesty contract (rendered in the glossary): every metric is an OBSERVED
-- association with its operational definition printed; no counterfactual
-- "crashes prevented" claims; episode durations are split by cohort because
-- deterministic fallbacks happen under the worst conditions (selection
-- bias); model rationales are display-only text from an unverified model.
-- Untrusted strings (process names, rationales, paths) interpolate into
-- TEXT NODES only, always through htmlEscape.

local lfm = require("memwatch_lfm")

local M = {}

------------------------------------------------------------------------------
-- escaping (text-node discipline)
------------------------------------------------------------------------------

local ESC = {
  ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
  ['"'] = "&quot;", ["'"] = "&#39;",
}

function M.htmlEscape(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub([=[[&<>"']]=], ESC))
end

------------------------------------------------------------------------------
-- parsers
------------------------------------------------------------------------------

-- Decision ledger: JSONL of decision records and outcome records (the
-- latter carry outcome_for). Garbage lines are skipped, never fatal.
function M.parseLedger(text)
  local decisions, outcomes = {}, {}
  for line in (text or ""):gmatch("[^\n]+") do
    local rec = lfm.jsonDecode(line)
    if type(rec) == "table" then
      if rec.outcome_for then
        outcomes[rec.outcome_for] = rec
      elseif rec.action then
        decisions[#decisions + 1] = rec
      end
    end
  end
  return decisions, outcomes
end

local function parseLogTime(datestr)
  local y, mo, d, h, mi, s = datestr:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
  if not y then return nil end
  return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
end

-- Watchdog log: state transitions and action lines across both line eras
-- (the fields after reason= vary; the parser keys on date + state + reason
-- and tolerates anything else).
function M.parseWatchLog(text)
  local events = {}
  for line in (text or ""):gmatch("[^\n]+") do
    local datestr, state, reason = line:match("^(%d+-%d+-%d+ %d+:%d+:%d+) state=(%w+) reason=(%S+)")
    if datestr then
      local t = parseLogTime(datestr)
      if t then events[#events + 1] = { at = t, state = state, reason = reason } end
    end
  end
  -- Critical episodes: enter on a transition INTO critical, exit on the
  -- next non-critical state line.
  local episodes = {}
  local open = nil
  for _, e in ipairs(events) do
    if e.state == "critical" and not open then
      open = { start = e.at, actions = {} }
    elseif open and e.state ~= "critical" then
      open.stop = e.at
      episodes[#episodes + 1] = open
      open = nil
    end
    if open and (e.reason:match("^unattended%-") or e.reason:match("^kill%-done")
                 or e.reason:match("^freeze%-done")) then
      open.actions[#open.actions + 1] = e.reason
    end
  end
  if open then open.stop = nil; episodes[#episodes + 1] = open end
  return events, episodes
end

------------------------------------------------------------------------------
-- aggregation
------------------------------------------------------------------------------

local function median(sorted)
  local n = #sorted
  if n == 0 then return nil end
  if n % 2 == 1 then return sorted[(n + 1) / 2] end
  return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

-- iso8601 (UTC, the ledger's format) -> absolute epoch. os.time interprets
-- the field table as LOCAL, so correct by the local-UTC offset measured AT
-- the target timestamp (not at epoch 0): the offset is DST-dependent, and a
-- summer ledger event compared against a winter-computed offset would land
-- an hour off and mis-correlate with the local watchdog log.
local function parseIso(s)
  if type(s) ~= "string" then return nil end
  local y, mo, d, h, mi, sec = s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
  if not y then return nil end
  local guess = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec) })
  -- Offset at `guess`: os.date("!*t", guess) is the UTC clock at that epoch;
  -- re-interpreting it as local and differencing yields the signed local-UTC
  -- offset in effect then (DST-correct).
  local offset = os.difftime(guess, os.time(os.date("!*t", guess)))
  return guess + offset
end

-- GB-minutes relieved: held GB of an acted-on offender times observed
-- minutes from the action to the episode's end, CAPPED at 60 minutes per
-- action (the cap is printed wherever the number is shown). No action, no
-- relief claimed.
local RELIEF_CAP_MIN = 60

function M.aggregate(decisions, outcomes, episodes)
  local agg = {
    decisions = #decisions,
    interventions = 0,
    waits = 0, freezes = 0, terminates = 0,
    byAdjudicator = { lfm = 0, ["lfm-advisory"] = 0, ["deterministic-fallback"] = 0 },
    reliefGBmin = 0,
    reliefCapMin = RELIEF_CAP_MIN,
    latencies = {},
    confidences = {},
    freezeStopped = 0,   -- freeze actions (growth stopped, memory NOT reclaimed)
    freezeHeldGB = 0,    -- GB held frozen (not released; the honest framing)
    episodeCount = #episodes,
    episodeMinutes = { lfm = {}, fallback = {}, none = {} },
    timeline = {},
  }
  for _, d in ipairs(decisions) do
    local adjudicator = d.adjudicator or "?"
    agg.byAdjudicator[adjudicator] = (agg.byAdjudicator[adjudicator] or 0) + 1
    if d.action == "wait" then agg.waits = agg.waits + 1
    elseif d.action == "freeze" then agg.freezes = agg.freezes + 1
    elseif d.action == "terminate" then agg.terminates = agg.terminates + 1 end
    if d.action ~= "wait" and adjudicator ~= "lfm-advisory" then
      local out = outcomes[d.at]
      -- An intervention is only COUNTED as executed when a terminal outcome
      -- record corroborates it (the decision alone does not prove the signal
      -- landed - it can be refused for pid reuse, policy, or exit).
      local executed = out and (out.fate == "exited" or out.fate == "frozen")
      if executed then agg.interventions = agg.interventions + 1 end
      local heldGB = ((d.offender or {}).weightMB or 0) / 1024
      -- MEMORY RELIEF is reclaimed memory, so ONLY a terminate that actually
      -- exited counts: a freeze (SIGSTOP) STOPS GROWTH but holds every page
      -- resident, so it is tracked separately as growth-stopped time, never
      -- as GB relieved. When the outcome recorded a real availability delta,
      -- prefer that measured reclaim over the held-GB estimate.
      if executed and out.fate == "exited" and d.action == "terminate" then
        local minutes = 0
        local at = parseIso(d.at)
        if at then
          for _, ep in ipairs(episodes) do
            if ep.stop and at >= ep.start - 60 and at <= (ep.stop + 60) then
              minutes = math.max(minutes, (ep.stop - at) / 60)
              break
            end
          end
        end
        minutes = math.max(minutes, 1)
        agg.reliefGBmin = agg.reliefGBmin + heldGB * math.min(minutes, RELIEF_CAP_MIN)
      elseif executed and out.fate == "frozen" then
        agg.freezeStopped = agg.freezeStopped + 1
        agg.freezeHeldGB = agg.freezeHeldGB + heldGB
      end
    end
    if type(d.latencyMs) == "number" then agg.latencies[#agg.latencies + 1] = d.latencyMs end
    if type(d.confidence) == "number" then agg.confidences[#agg.confidences + 1] = d.confidence end
    agg.timeline[#agg.timeline + 1] = d
  end
  -- Episode durations by cohort: an episode belongs to the lfm cohort when
  -- a non-advisory lfm decision landed inside it, to fallback when a
  -- deterministic action landed, else to none.
  for _, ep in ipairs(episodes) do
    if ep.stop then
      local dur = (ep.stop - ep.start) / 60
      local cohort = "none"
      for _, d in ipairs(decisions) do
        local at = parseIso(d.at)
        if at and at >= ep.start - 60 and at <= ep.stop + 60 then
          if d.adjudicator == "lfm" then cohort = "lfm"; break
          elseif d.adjudicator == "deterministic-fallback" then cohort = "fallback" end
        end
      end
      table.insert(agg.episodeMinutes[cohort], dur)
    end
  end
  for _, list in pairs(agg.episodeMinutes) do table.sort(list) end
  table.sort(agg.latencies)
  agg.fallbackRate = agg.decisions > 0
    and (agg.byAdjudicator["deterministic-fallback"] or 0) / agg.decisions or 0
  return agg
end

------------------------------------------------------------------------------
-- rendering
------------------------------------------------------------------------------

local CSS = [[
body{background:#111114;color:#EBEBED;font-family:Menlo,monospace;margin:0;padding:24px;max-width:1080px;margin:0 auto}
h1{font-size:20px;color:#fff;margin:0 0 2px 0}
h2{font-size:13px;color:#9a9aa2;text-transform:uppercase;letter-spacing:1px;margin:28px 0 10px}
.sub{color:#77777e;font-size:11px}
.card{background:#1C1C1F;border-radius:10px;padding:14px 16px;margin:8px 0}
.grid{display:flex;flex-wrap:wrap;gap:10px}
.stat{background:#1C1C1F;border-radius:10px;padding:12px 16px;min-width:150px;flex:1}
.stat .n{font-size:22px;color:#fff}
.stat .l{font-size:10px;color:#9a9aa2;text-transform:uppercase;letter-spacing:1px}
.green{color:#34c759}.amber{color:#ff9f0a}.red{color:#ff453a}.blue{color:#4a9eff}
.chip{display:inline-block;background:#26262b;border-radius:6px;padding:2px 8px;font-size:10px;color:#9a9aa2;margin-left:6px}
.bar{display:flex;height:14px;border-radius:7px;overflow:hidden;margin:6px 0}
.seg-wait{background:#3a3a40}.seg-freeze{background:#4a9eff}.seg-term{background:#ff453a}
table{border-collapse:collapse;width:100%;font-size:11px}
td,th{padding:5px 8px;text-align:left;border-bottom:1px solid #26262b;color:#c8c8cd}
th{color:#9a9aa2;text-transform:uppercase;font-size:9px;letter-spacing:1px}
tr.shipped td{background:#1a2636;color:#fff}
.rationale{color:#8ab4f8;font-style:italic}
.label-unverified{font-size:9px;color:#77777e;text-transform:uppercase;letter-spacing:1px}
.glossary{font-size:10px;color:#77777e;line-height:1.6}
]]

local function svgSparkline(values, w, h, color)
  if #values == 0 then return "" end
  local maxV = 1
  for _, v in ipairs(values) do if v > maxV then maxV = v end end
  local pts = {}
  for i, v in ipairs(values) do
    local x = math.floor((i - 1) / math.max(#values - 1, 1) * (w - 4)) + 2
    local y = h - 2 - math.floor(v / maxV * (h - 6))
    pts[#pts + 1] = x .. "," .. y
  end
  return string.format(
    '<svg width="%d" height="%d"><polyline fill="none" stroke="%s" stroke-width="1.5" points="%s"/></svg>',
    w, h, color, table.concat(pts, " "))
end

local function fmtMedian(list)
  local m = median(list)
  return m and string.format("%.1f min (n=%d)", m, #list) or "no data"
end

-- opts: { public = bool, league = decoded league.json or nil,
--         summary = decoded shipped-summary or nil, generatedAt = string }
function M.renderHTML(agg, opts)
  opts = opts or {}
  local esc = M.htmlEscape
  local out = {}
  local function w(s) out[#out + 1] = s end

  w("<!DOCTYPE html><html><head><meta charset='utf-8'><title>memwatch value report</title>")
  w("<style>" .. CSS .. "</style></head><body>")
  w("<h1>memwatch value report</h1>")
  w(string.format("<div class='sub'>generated %s%s \u{00B7} every metric is observed, definitions in the glossary</div>",
    esc(opts.generatedAt or "(unknown)"), opts.public and " \u{00B7} public rendering" or ""))

  -- Scoreboard.
  w("<h2>Scoreboard</h2><div class='grid'>")
  w(string.format("<div class='stat'><div class='n'>%d</div><div class='l'>adjudications</div></div>", agg.decisions))
  w(string.format("<div class='stat'><div class='n'>%d</div><div class='l'>interventions executed</div></div>", agg.interventions))
  w(string.format("<div class='stat'><div class='n blue'>%.0f</div><div class='l'>GB-minutes relieved by terminate (cap %d min/action)</div></div>",
    agg.reliefGBmin, agg.reliefCapMin))
  w(string.format("<div class='stat'><div class='n'>%d</div><div class='l'>freezes: growth stopped, %.1f GB held (not released)</div></div>",
    agg.freezeStopped, agg.freezeHeldGB))
  w(string.format("<div class='stat'><div class='n'>%.0f%%</div><div class='l'>deterministic fallback share</div></div>",
    agg.fallbackRate * 100))
  w("<div class='stat'><div class='n green'>$0</div><div class='l'>marginal inference cost<span class='chip'>local CPU; cloud LLM call priced $0.002+</span></div></div>")
  w("</div>")

  -- Action mix.
  local total = math.max(agg.waits + agg.freezes + agg.terminates, 1)
  w("<div class='card'><div class='l sub'>action mix</div><div class='bar'>")
  w(string.format("<div class='seg-wait' style='width:%d%%'></div>", math.floor(agg.waits / total * 100)))
  w(string.format("<div class='seg-freeze' style='width:%d%%'></div>", math.floor(agg.freezes / total * 100)))
  w(string.format("<div class='seg-term' style='width:%d%%'></div>", math.floor(agg.terminates / total * 100)))
  w(string.format("</div><div class='sub'>wait %d \u{00B7} freeze %d \u{00B7} terminate %d</div></div>",
    agg.waits, agg.freezes, agg.terminates))

  -- Episode durations by cohort (selection bias stated).
  w("<h2>Critical episodes</h2><div class='card'>")
  w(string.format("<div>%d critical episodes observed</div>", agg.episodeCount))
  w(string.format("<div class='sub'>median duration \u{00B7} model-adjudicated: %s \u{00B7} deterministic fallback: %s \u{00B7} no action: %s</div>",
    fmtMedian(agg.episodeMinutes.lfm), fmtMedian(agg.episodeMinutes.fallback), fmtMedian(agg.episodeMinutes.none)))
  w("<div class='glossary'>Cohorts are not comparable populations: fallbacks fire precisely when the model is unavailable, which skews toward the worst storms. Observed association only.</div>")
  w("</div>")

  -- Model telemetry.
  if #agg.latencies > 0 then
    w("<h2>Model telemetry</h2><div class='card'>")
    w("<div class='l sub'>verdict latency (ms, chronological)</div>")
    w(svgSparkline(agg.latencies, 480, 46, "#4a9eff"))
    local p50 = agg.latencies[math.max(1, math.ceil(#agg.latencies * 0.5))]
    local p95 = agg.latencies[math.max(1, math.ceil(#agg.latencies * 0.95))]
    w(string.format("<div class='sub'>p50 %dms \u{00B7} p95 %dms \u{00B7} n=%d</div>", p50, p95, #agg.latencies))
    w("</div>")
  end

  -- Decision timeline.
  if #agg.timeline > 0 then
    w("<h2>Decision timeline</h2>")
    local first = math.max(1, #agg.timeline - 19)
    for i = #agg.timeline, first, -1 do
      local d = agg.timeline[i]
      local off = d.offender or {}
      local color = d.action == "terminate" and "red" or (d.action == "freeze" and "blue" or "green")
      w("<div class='card'>")
      w(string.format("<div><span class='%s'>%s</span> %s <span class='sub'>%s \u{00B7} %s \u{00B7} %.1f GB held</span></div>",
        color, esc(d.action or "?"), esc(off.name or "?"), esc(d.at or ""), esc(d.adjudicator or "?"),
        (off.weightMB or 0) / 1024))
      if d.rationale and d.rationale ~= "" then
        w(string.format("<div class='label-unverified'>model-generated, unverified</div><div class='rationale'>%s</div>",
          esc(d.rationale)))
      end
      w("</div>")
    end
  end

  -- Bake-off league.
  if opts.league and opts.league.league then
    if opts.public then
      -- Public rendering: the shipped row's headline only.
      w("<h2>Shipped model</h2>")
      for _, row in ipairs(opts.league.league) do
        if row.label == opts.league.winner then
          w("<div class='card'>")
          w(string.format("<div><span class='blue'>%s</span> <span class='sub'>prompt variant %s \u{00B7} selected by the gated bake-off</span></div>",
            esc(row.label), esc(row.variant or "?")))
          w(string.format("<div class='sub'>gold %.0f%% \u{00B7} acceptable %.0f%% \u{00B7} constrained JSON %.1f%% \u{00B7} warm p95 %dms \u{00B7} footprint %sMB</div>",
            (row.gold or 0) * 100, (row.acceptable or 0) * 100, (row.json_valid or 0) * 100,
            row.warm_p95_ms or 0, tostring(row.footprint_mb or "?")))
          w("<div class='glossary'>Methodology in docs/bakeoff-methodology.md; the full comparative table is not published.</div>")
          w("</div>")
        end
      end
    else
      w("<h2>Bake-off league (local)</h2>")
      w("<!-- league:full -->")
      w("<div class='card'><table><tr><th>model</th><th>gold</th><th>acceptable</th><th>danger</th><th>inject</th><th>json</th><th>p95 warm</th><th>footprint</th><th>gates</th></tr>")
      for _, row in ipairs(opts.league.league) do
        w(string.format("<tr class='%s'><td>%s%s</td><td>%.2f</td><td>%.2f</td><td>%.3f</td><td>%d</td><td>%.3f</td><td>%dms</td><td>%sMB</td><td>%s</td></tr>",
          row.label == opts.league.winner and "shipped" or "",
          esc(row.label), row.reference_only and " (ref)" or "",
          row.gold or 0, row.acceptable or 0, row.danger or 0,
          row.injection_compliance or 0, row.json_valid or 0,
          row.warm_p95_ms or 0, tostring(row.footprint_mb or "?"),
          row.gates_passed and "PASS" or "fail"))
      end
      w("</table></div>")
    end
  end

  -- Glossary.
  w("<h2>Honest metrics glossary</h2><div class='card glossary'>")
  w("<div>ADJUDICATIONS: ledger decision records, advisory and acting.</div>")
  w("<div>INTERVENTIONS: non-wait actions executed by the unattended path (advisory verdicts excluded).</div>")
  w(string.format("<div>GB-MINUTES RELIEVED: reclaimed memory only - a TERMINATE that actually exited, its held GB times observed minutes to episode end, capped at %d min per action. A FREEZE stops growth but holds every page resident, so it is reported separately (freezes: GB held), never as relief.</div>", agg.reliefCapMin))
  w("<div>INTERVENTIONS EXECUTED: acting decisions corroborated by a terminal outcome record (exited/frozen); a decision alone is not counted, since the signal can be refused for pid reuse, policy, or exit.</div>")
  w("<div>EPISODE DURATION: wall time from entering critical to leaving it, split by cohort; the cohorts are differently selected populations and are not a controlled comparison.</div>")
  w("<div>MARGINAL COST: local CPU inference on hardware already owned; the comparison chip prices one hosted-LLM call at typical published rates.</div>")
  w("<div>No crashes-prevented or counterfactual claims appear in this report.</div>")
  w("</div>")

  w("</body></html>")
  return table.concat(out, "\n")
end

-- Markdown digest from the SAME aggregate (public docs numbers come from
-- here so they cannot drift from the report).
function M.renderMD(agg, opts)
  opts = opts or {}
  local lines = {
    "# memwatch value digest",
    "",
    string.format("- adjudications: %d (interventions: %d)", agg.decisions, agg.interventions),
    string.format("- action mix: wait %d / freeze %d / terminate %d", agg.waits, agg.freezes, agg.terminates),
    string.format("- GB-minutes relieved (cap %d min/action): %.0f", agg.reliefCapMin, agg.reliefGBmin),
    string.format("- deterministic fallback share: %.0f%%", agg.fallbackRate * 100),
    string.format("- critical episodes observed: %d", agg.episodeCount),
  }
  if #agg.latencies > 0 then
    lines[#lines + 1] = string.format("- verdict latency p50/p95: %d/%d ms",
      agg.latencies[math.max(1, math.ceil(#agg.latencies * 0.5))],
      agg.latencies[math.max(1, math.ceil(#agg.latencies * 0.95))])
  end
  return table.concat(lines, "\n") .. "\n"
end

------------------------------------------------------------------------------
-- entry point
------------------------------------------------------------------------------

-- paths: { ledger, log, league, out }; opts: { public, format = "html"|"md",
-- generatedAt }. Returns the output path (or nil, err). Degrades to a
-- log-only report when the ledger is missing.
function M.generate(paths, opts)
  opts = opts or {}
  local function slurp(p)
    if not p then return nil end
    local f = io.open(p, "r")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
  end
  local decisions, outcomes = M.parseLedger(slurp(paths.ledger) or "")
  local _, episodes = M.parseWatchLog(slurp(paths.log) or "")
  local agg = M.aggregate(decisions, outcomes, episodes)
  local league = lfm.jsonDecode(slurp(paths.league) or "")
  local body
  if opts.format == "md" then
    body = M.renderMD(agg, opts)
  else
    body = M.renderHTML(agg, {
      public = opts.public, league = league, generatedAt = opts.generatedAt,
    })
  end
  local f, err = io.open(paths.out, "w")
  if not f then return nil, err end
  f:write(body)
  f:close()
  return paths.out
end

return M

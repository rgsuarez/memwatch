-- memwatch_lfm.lua: the pure half of LFM adjudication.
--
-- Everything here is Hammerspoon-free and runs under both the Hammerspoon
-- Lua 5.4 runtime and standalone Lua 5.5 (the eval CLIs). The glue module
-- owns timers, the llama-server process, and signal execution; this module
-- owns the adjudication CONTRACT: the JSON codec, the system prompt, the
-- snapshot serialization, the response validator, and the deterministic
-- rails that bound what any model verdict may do.
--
-- Trust model: process names and paths are attacker-controlled input. The
-- model's reply is untrusted input. The model never sees a pid and no code
-- path derives a signal target from model text; the caller binds the target
-- before the request and keeps it. A garbage reply decodes to calm: the
-- fail-closed result of every parse or validation error is "no verdict",
-- which the decision path treats exactly like "no model".

local M = {}

------------------------------------------------------------------------------
-- Config (defaults; the glue overlays operator config on top)
------------------------------------------------------------------------------

M.cfg = {
  enabled = false,          -- master switch: off reproduces model-free memwatch
  model = "",               -- GGUF filename under models/ (set by the bake-off)
  port = 11435,
  ctx = 4096,
  threads = 4,
  resident = false,         -- keep the server warm instead of retiring on calm
  retireCalmSec = 600,
  timeoutSec = 8,
  advisory = true,
  advisoryIntervalSec = 45,
  minConfTerminate = 0.70,
  minConfFreeze = 0.50,
  promptVariant = "baseline",
  verdictFreshSec = 90,     -- cached verdict age a decision point may consume
}

------------------------------------------------------------------------------
-- JSON codec: deterministic encoder, strict fail-closed decoder.
--
-- Why bundled: the report and bake-off CLIs run under standalone lua where
-- hs.json does not exist, and this repo is zero-dependency by policy. The
-- decoder sits on the LLM trust boundary, so it is a bounded grammar:
-- depth-limited, length-capped, duplicate-key-rejecting, garbage-is-calm.
------------------------------------------------------------------------------

local JSON_MAX_BYTES = 65536
local JSON_MAX_DEPTH = 8

local ESCAPES = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escapeString(s)
  return (s:gsub('[%z\1-\31"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", c:byte())
  end))
end

-- Mark a table as a JSON array (needed so an EMPTY list encodes as []).
local ARRAY_MT = { __jsonarray = true }
function M.jsonArray(t)
  return setmetatable(t or {}, ARRAY_MT)
end

local function isArray(t)
  local mt = getmetatable(t)
  if mt == ARRAY_MT then return true end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  if n == 0 then return false end -- empty unmarked table encodes as {}
  return n == #t
end

local encodeValue -- forward declaration (assigned below, referenced by itself)

encodeValue = function(v, depth)
  if depth > JSON_MAX_DEPTH then return nil, "encode: too deep" end
  local tv = type(v)
  if tv == "nil" then
    return "null"
  elseif tv == "boolean" then
    return v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      return nil, "encode: non-finite number"
    end
    if math.type and math.type(v) == "integer" then
      return string.format("%d", v)
    end
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      return string.format("%d", math.floor(v))
    end
    return string.format("%.10g", v)
  elseif tv == "string" then
    return '"' .. escapeString(v) .. '"'
  elseif tv == "table" then
    if isArray(v) then
      local parts = {}
      for i = 1, #v do
        local enc, err = encodeValue(v[i], depth + 1)
        if not enc then return nil, err end
        parts[#parts + 1] = enc
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do
      if type(k) ~= "string" then return nil, "encode: non-string key" end
      keys[#keys + 1] = k
    end
    table.sort(keys) -- determinism: sorted keys, always
    local parts = {}
    for _, k in ipairs(keys) do
      local enc, err = encodeValue(v[k], depth + 1)
      if not enc then return nil, err end
      parts[#parts + 1] = '"' .. escapeString(k) .. '":' .. enc
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return nil, "encode: unsupported type " .. tv
end

function M.jsonEncode(v)
  return encodeValue(v, 0)
end

-- Decoder: recursive descent over a byte string. Strict JSON only.
local function decodeError(pos, msg)
  return nil, string.format("decode@%d: %s", pos, msg)
end

local function skipWs(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return j + 1
end

local decodeValueAt -- forward declaration (mutually recursive)

local function decodeString(s, i)
  -- s:sub(i, i) is the opening quote.
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == "" then return decodeError(j, "unterminated string") end
    if c == '"' then return table.concat(out), j + 1 end
    if c == "\\" then
      local e = s:sub(j + 1, j + 1)
      if e == '"' then out[#out + 1] = '"'; j = j + 2
      elseif e == "\\" then out[#out + 1] = "\\"; j = j + 2
      elseif e == "/" then out[#out + 1] = "/"; j = j + 2
      elseif e == "b" then out[#out + 1] = "\b"; j = j + 2
      elseif e == "f" then out[#out + 1] = "\f"; j = j + 2
      elseif e == "n" then out[#out + 1] = "\n"; j = j + 2
      elseif e == "r" then out[#out + 1] = "\r"; j = j + 2
      elseif e == "t" then out[#out + 1] = "\t"; j = j + 2
      elseif e == "u" then
        local hex = s:sub(j + 2, j + 5)
        if not hex:match("^%x%x%x%x$") then
          return decodeError(j, "bad \\u escape")
        end
        local cp = tonumber(hex, 16)
        j = j + 6
        if cp >= 0xD800 and cp <= 0xDBFF then
          -- high surrogate: require the paired low surrogate
          if s:sub(j, j + 1) ~= "\\u" then
            return decodeError(j, "lone high surrogate")
          end
          local hex2 = s:sub(j + 2, j + 5)
          if not hex2:match("^%x%x%x%x$") then
            return decodeError(j, "bad low surrogate")
          end
          local cp2 = tonumber(hex2, 16)
          if cp2 < 0xDC00 or cp2 > 0xDFFF then
            return decodeError(j, "invalid low surrogate")
          end
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
          j = j + 6
        elseif cp >= 0xDC00 and cp <= 0xDFFF then
          return decodeError(j, "lone low surrogate")
        end
        out[#out + 1] = utf8.char(cp)
      else
        return decodeError(j, "invalid escape \\" .. e)
      end
    elseif c:byte() < 0x20 then
      return decodeError(j, "raw control character in string")
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
end

local function decodeNumber(s, i)
  local numstr = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
  if not numstr or not numstr:match("^-?%d") then
    return decodeError(i, "invalid number")
  end
  -- Reject leading zeros like 0123 (strict JSON).
  if numstr:match("^-?0%d") then return decodeError(i, "leading zero") end
  local n = tonumber(numstr)
  if not n or n ~= n or n == math.huge or n == -math.huge then
    return decodeError(i, "non-finite number")
  end
  return n, i + #numstr
end

decodeValueAt = function(s, i, depth)
  if depth > JSON_MAX_DEPTH then return decodeError(i, "too deep") end
  i = skipWs(s, i)
  local c = s:sub(i, i)
  if c == "" then return decodeError(i, "unexpected end") end
  if c == "{" then
    local obj = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      i = skipWs(s, i)
      if s:sub(i, i) ~= '"' then return decodeError(i, "expected key string") end
      local key, ni = decodeString(s, i)
      if key == nil then return nil, ni end
      i = skipWs(s, ni)
      if s:sub(i, i) ~= ":" then return decodeError(i, "expected colon") end
      local val, nj = decodeValueAt(s, i + 1, depth + 1)
      -- Failure iff the second return is not a numeric next-index (a decoded
      -- null is a legitimate nil value WITH a numeric index).
      if type(nj) ~= "number" then return nil, nj end
      if obj[key] ~= nil then
        return decodeError(i, "duplicate key " .. key)
      end
      obj[key] = val
      i = skipWs(s, nj)
      local d = s:sub(i, i)
      if d == "," then i = i + 1
      elseif d == "}" then return obj, i + 1
      else return decodeError(i, "expected , or }") end
    end
  elseif c == "[" then
    local arr = M.jsonArray({})
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
      local val, nj = decodeValueAt(s, i, depth + 1)
      if type(nj) ~= "number" then return nil, nj end
      if val == nil then return decodeError(i, "null in array unsupported") end
      arr[#arr + 1] = val
      i = skipWs(s, nj)
      local d = s:sub(i, i)
      if d == "," then i = i + 1
      elseif d == "]" then return arr, i + 1
      else return decodeError(i, "expected , or ]") end
    end
  elseif c == '"' then
    return decodeString(s, i)
  elseif c == "t" then
    if s:sub(i, i + 3) == "true" then return true, i + 4 end
    return decodeError(i, "invalid literal")
  elseif c == "f" then
    if s:sub(i, i + 4) == "false" then return false, i + 5 end
    return decodeError(i, "invalid literal")
  elseif c == "n" then
    if s:sub(i, i + 3) == "null" then return nil, i + 4 end
    return decodeError(i, "invalid literal")
  else
    return decodeNumber(s, i)
  end
end

-- Returns value, nil on success; nil, err on failure. A decoded top-level
-- null returns nil, "null" (indistinguishable from failure BY DESIGN: the
-- trust boundary treats "the model said null" as "no verdict").
function M.jsonDecode(s)
  if type(s) ~= "string" then return nil, "decode: not a string" end
  if #s > JSON_MAX_BYTES then return nil, "decode: input too large" end
  local val, ni = decodeValueAt(s, 1, 0)
  if type(ni) ~= "number" then return nil, ni end
  if val == nil then return nil, "null" end
  local rest = skipWs(s, ni)
  if rest <= #s then return nil, "decode: trailing garbage" end
  return val
end

------------------------------------------------------------------------------
-- Verdict validation: whitelist the model's reply down to exactly four
-- fields with hard bounds. Anything malformed fails closed to no-verdict.
------------------------------------------------------------------------------

local ACTIONS = { wait = true, freeze = true, terminate = true }
local PROCESS_CLASSES = {
  runaway = true, hog = true, build = true, ["llm-server"] = true,
  browser = true, vm = true, db = true, backup = true, indexer = true,
  other = true,
}

-- Extract the assistant message content from a chat-completions response
-- body, then decode the verdict object it carries. Returns the RAW verdict
-- table (unvalidated) or nil, err.
function M.parseResponse(body)
  local resp, err = M.jsonDecode(body)
  if not resp then return nil, "response: " .. tostring(err) end
  if type(resp) ~= "table" then return nil, "response: not an object" end
  local choices = resp.choices
  if type(choices) ~= "table" or type(choices[1]) ~= "table" then
    return nil, "response: no choices"
  end
  local msg = choices[1].message
  if type(msg) ~= "table" or type(msg.content) ~= "string" then
    return nil, "response: no message content"
  end
  local verdict, verr = M.jsonDecode(msg.content)
  if not verdict then return nil, "verdict: " .. tostring(verr) end
  if type(verdict) ~= "table" then return nil, "verdict: not an object" end
  return verdict
end

-- Validate and normalize a raw verdict. Returns the whitelisted verdict
-- table or nil, reason. Model text is DISPLAY-ONLY downstream; nothing here
-- or anywhere else derives a signal target from it.
function M.validateVerdict(raw)
  if type(raw) ~= "table" then return nil, "not a table" end
  local action = raw.action
  if type(action) ~= "string" or not ACTIONS[action] then
    return nil, "bad action"
  end
  local class = raw.process_class
  if type(class) ~= "string" or not PROCESS_CLASSES[class] then
    class = "other"
  end
  local conf = raw.confidence
  if type(conf) ~= "number" or conf ~= conf then conf = 0 end
  if conf < 0 then conf = 0 elseif conf > 1 then conf = 1 end
  local rationale = raw.rationale
  if type(rationale) ~= "string" then rationale = "" end
  -- Strip control characters (newlines become spaces) and clamp length.
  rationale = rationale:gsub("[%z\1-\31\127]", " "):sub(1, 240)
  return {
    action = action,
    process_class = class,
    confidence = conf,
    rationale = rationale,
  }
end

------------------------------------------------------------------------------
-- Deterministic rails: the bounds no model verdict can escape. Applied in
-- a fixed order; every applied rail is recorded for the ledger.
--
--   1. ceiling caps      (unattended mode: off -> wait; freeze caps terminate)
--   2. offender-kind cap (hog/absolute offenders are never terminated)
--   3. confidence floors (terminate >= minConfTerminate else freeze;
--                         freeze >= minConfFreeze else wait)
--   4. policy gate       (killAllowed false -> wait; freeze uses the same
--                         gate as kill: same uid, denylist, protected pids)
------------------------------------------------------------------------------

-- verdict: validated verdict (or nil -> wait). ceiling: "off"|"freeze"|"kill".
-- actionAllowed: the killAllowed result for the bound target. opts:
-- { offenderKind = "extreme"|"hog"|..., minConfTerminate, minConfFreeze }.
-- Returns effectiveAction, railsApplied (array of tags).
function M.applyVerdict(verdict, ceiling, actionAllowed, opts)
  opts = opts or {}
  local rails = {}
  if type(verdict) ~= "table" or not ACTIONS[verdict.action or ""] then
    return "wait", { "no-verdict" }
  end
  local action = verdict.action
  local conf = type(verdict.confidence) == "number" and verdict.confidence or 0

  -- Rail 1: ceiling caps.
  if ceiling ~= "freeze" and ceiling ~= "kill" then
    if action ~= "wait" then rails[#rails + 1] = "ceiling-off" end
    return "wait", rails
  end
  if ceiling == "freeze" and action == "terminate" then
    action = "freeze"
    rails[#rails + 1] = "ceiling-freeze"
  end

  -- Rail 2: hog/absolute offenders are never terminated autonomously.
  if action == "terminate" and opts.offenderKind ~= "extreme" then
    action = "freeze"
    rails[#rails + 1] = "hog-cap"
  end

  -- Rail 3: confidence floors, applied to the CURRENT action.
  local minTerm = opts.minConfTerminate or M.cfg.minConfTerminate
  local minFreeze = opts.minConfFreeze or M.cfg.minConfFreeze
  if action == "terminate" and conf < minTerm then
    action = "freeze"
    rails[#rails + 1] = "conf-floor-terminate"
  end
  if action == "freeze" and conf < minFreeze then
    action = "wait"
    rails[#rails + 1] = "conf-floor-freeze"
  end

  -- Rail 4: the policy gate is final. No gate, no signal of any kind.
  if action ~= "wait" and not actionAllowed then
    action = "wait"
    rails[#rails + 1] = "policy-denied"
  end

  return action, rails
end

------------------------------------------------------------------------------
-- Snapshot hash: FNV-1a 32-bit over the serialized snapshot. Correlation id
-- for the ledger and the verdict cache, not a cryptographic hash.
------------------------------------------------------------------------------

function M.snapshotHash(s)
  local hash = 2166136261
  for i = 1, #s do
    hash = hash ~ s:byte(i)
    hash = (hash * 16777619) & 0xFFFFFFFF
  end
  return string.format("%08x", hash)
end

------------------------------------------------------------------------------
-- Ledger line: one decision record as a single deterministic JSON line.
------------------------------------------------------------------------------

function M.ledgerLine(record)
  local enc, err = M.jsonEncode(record)
  if not enc then return nil, err end
  return enc .. "\n"
end

return M

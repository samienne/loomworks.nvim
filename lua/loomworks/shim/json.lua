-- Candidate portable JSON for the standalone `vim` shim.
-- Goal: reproduce nvim's vim.json semantics for the shapes loomworks uses,
-- WITHOUT nvim. Pure Lua 5.1 / LuaJIT.
--
-- Fidelity requirements discovered from the codebase:
--   * vim.empty_dict()  -> serialize {} as a JSON *object* "{}"
--   * plain empty table -> serialize as JSON *array*  "[]"
--   * JSON null         -> decode to a NIL sentinel (== nvim behavior)
--   * decode "{}"       -> object-marked empty table (so re-encode stays "{}")
--   * decode "[]"       -> plain empty table         (re-encode stays "[]")

local M = {}

-- NIL sentinel for JSON null (mirrors vim.NIL).
M.NIL = setmetatable({}, { __tostring = function() return "shim.NIL" end })

-- Empty-dict marker: an empty table carrying this metatable encodes as "{}".
M._empty_dict_mt = { __is_empty_dict = true }
function M.empty_dict()
  return setmetatable({}, M._empty_dict_mt)
end

-- ---------------------------------------------------------------------------
-- Encode
-- ---------------------------------------------------------------------------

local encode_value

local ESCAPES = {
  ['"'] = '\\"', ['\\'] = '\\\\',
  ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n',
  ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encode_string(s)
  local out = s:gsub('[%z\1-\31"\\]', function(c)
    local e = ESCAPES[c]
    if e then return e end
    return string.format('\\u%04x', string.byte(c))
  end)
  return '"' .. out .. '"'
end

local function encode_number(n)
  if n ~= n or n == math.huge or n == -math.huge then
    error("Cannot serialize non-finite number")
  end
  -- Integral value within safe range -> integer form (matches nvim).
  if n == math.floor(n) and math.abs(n) < 1e15 then
    return string.format("%d", n)
  end
  return string.format("%.17g", n)
end

-- Decide if a table is a JSON array (list) vs object.
-- nvim: a table with contiguous integer keys 1..n is a list; empty plain
-- table is a list ("[]"); empty_dict-marked table is an object ("{}").
local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    if k < 1 or k ~= math.floor(k) then return false end
    n = n + 1
  end
  -- contiguous check
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true, n
end

encode_value = function(v)
  if v == M.NIL then
    return "null"
  end
  local t = type(v)
  if t == "nil" then
    return "null"
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "number" then
    return encode_number(v)
  elseif t == "string" then
    return encode_string(v)
  elseif t == "table" then
    if getmetatable(v) == M._empty_dict_mt then
      return "{}"
    end
    local arr, n = is_array(v)
    if arr then
      if n == 0 then return "[]" end
      local parts = {}
      for i = 1, n do
        parts[i] = encode_value(v[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, val in pairs(v) do
        if type(k) ~= "string" then
          error("Cannot serialize table with non-string key: " .. tostring(k))
        end
        parts[#parts + 1] = encode_string(k) .. ":" .. encode_value(val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  error("Cannot serialize value of type " .. t)
end

function M.encode(v)
  return encode_value(v)
end

-- ---------------------------------------------------------------------------
-- Decode (recursive descent)
-- ---------------------------------------------------------------------------

local function decode_error(str, i, msg)
  error(string.format("json decode error at %d: %s", i, msg))
end

local parse_value

local function skip_ws(str, i)
  local _, j = str:find("^[ \t\r\n]*", i)
  return j + 1
end

local UNESCAPES = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
  ['b'] = '\b', ['f'] = '\f', ['n'] = '\n', ['r'] = '\r', ['t'] = '\t',
}

-- Encode a Unicode codepoint to UTF-8 (raw bytes, like nvim).
local function utf8_encode(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40)
  else
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + math.floor(cp / 0x1000) % 0x40,
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40)
  end
end

local function parse_string(str, i)
  -- assumes str:sub(i,i) == '"'
  i = i + 1
  local buf = {}
  while true do
    local c = str:sub(i, i)
    if c == "" then decode_error(str, i, "unterminated string") end
    if c == '"' then
      return table.concat(buf), i + 1
    elseif c == "\\" then
      local e = str:sub(i + 1, i + 1)
      if e == "u" then
        local hex = str:sub(i + 2, i + 5)
        local cp = tonumber(hex, 16)
        if not cp then decode_error(str, i, "bad \\u escape") end
        i = i + 6
        -- surrogate pair
        if cp >= 0xD800 and cp <= 0xDBFF and str:sub(i, i + 1) == "\\u" then
          local hex2 = str:sub(i + 2, i + 5)
          local lo = tonumber(hex2, 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          end
        end
        buf[#buf + 1] = utf8_encode(cp)
      else
        local u = UNESCAPES[e]
        if not u then decode_error(str, i, "bad escape \\" .. e) end
        buf[#buf + 1] = u
        i = i + 2
      end
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
end

local function parse_number(str, i)
  local s, e = str:find("^%-?%d+%.?%d*[eE]?[+%-]?%d*", i)
  if not s then decode_error(str, i, "bad number") end
  local numstr = str:sub(s, e)
  local n = tonumber(numstr)
  if not n then decode_error(str, i, "bad number: " .. numstr) end
  return n, e + 1
end

local function parse_object(str, i)
  i = i + 1 -- skip {
  i = skip_ws(str, i)
  if str:sub(i, i) == "}" then
    return M.empty_dict(), i + 1 -- empty object -> marked
  end
  local obj = {}
  while true do
    i = skip_ws(str, i)
    if str:sub(i, i) ~= '"' then decode_error(str, i, "expected string key") end
    local key
    key, i = parse_string(str, i)
    i = skip_ws(str, i)
    if str:sub(i, i) ~= ":" then decode_error(str, i, "expected :") end
    i = skip_ws(str, i + 1)
    local val
    val, i = parse_value(str, i)
    obj[key] = val
    i = skip_ws(str, i)
    local c = str:sub(i, i)
    if c == "," then
      i = i + 1
    elseif c == "}" then
      return obj, i + 1
    else
      decode_error(str, i, "expected , or }")
    end
  end
end

local function parse_array(str, i)
  i = i + 1 -- skip [
  i = skip_ws(str, i)
  if str:sub(i, i) == "]" then
    return {}, i + 1 -- empty array -> plain table
  end
  local arr = {}
  local n = 0
  while true do
    i = skip_ws(str, i)
    local val
    val, i = parse_value(str, i)
    n = n + 1
    arr[n] = val
    i = skip_ws(str, i)
    local c = str:sub(i, i)
    if c == "," then
      i = i + 1
    elseif c == "]" then
      return arr, i + 1
    else
      decode_error(str, i, "expected , or ]")
    end
  end
end

parse_value = function(str, i)
  i = skip_ws(str, i)
  local c = str:sub(i, i)
  if c == "{" then
    return parse_object(str, i)
  elseif c == "[" then
    return parse_array(str, i)
  elseif c == '"' then
    return parse_string(str, i)
  elseif c == "t" then
    if str:sub(i, i + 3) == "true" then return true, i + 4 end
    decode_error(str, i, "bad literal")
  elseif c == "f" then
    if str:sub(i, i + 4) == "false" then return false, i + 5 end
    decode_error(str, i, "bad literal")
  elseif c == "n" then
    if str:sub(i, i + 3) == "null" then return M.NIL, i + 4 end
    decode_error(str, i, "bad literal")
  elseif c:match("[%-%d]") then
    return parse_number(str, i)
  else
    decode_error(str, i, "unexpected char '" .. c .. "'")
  end
end

function M.decode(str)
  local v, i = parse_value(str, 1)
  i = skip_ws(str, i)
  if i <= #str then
    decode_error(str, i, "trailing content")
  end
  return v
end

return M

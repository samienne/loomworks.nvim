-- Minimal JSON decoder for the host bootstrap (spec §16.11–16.13).
--
-- The bootstrap parses the release manifest *before* any system Lua exists, so
-- it cannot use the shim's `vim.json` (that lives in the very bundle being
-- verified). This is decode-only and deliberately tiny — the bootstrap only
-- ever reads its own manifest, whose bytes are already signature-verified when
-- this runs. It is not a general-purpose or Neovim-fidelity codec.

local M = {}

-- Distinct sentinel for JSON `null`, so a null never collapses to a nil Lua
-- value (which would leave a hole in arrays and silently shift indices).
M.null = setmetatable({}, { __tostring = function() return "null" end })

local function decode_error(str, pos, msg)
  return nil, ("json: " .. msg .. " at position " .. pos)
end

local function skip_ws(str, pos)
  local _, e = str:find("^[ \t\r\n]*", pos)
  return (e or pos - 1) + 1
end

local escapes = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
  n = "\n", r = "\r", t = "\t",
}

local parse_value

local function parse_string(str, pos)
  -- pos points at the opening quote
  local buf, i = {}, pos + 1
  while i <= #str do
    local c = str:sub(i, i)
    if c == '"' then
      return table.concat(buf), i + 1
    elseif c == "\\" then
      local nxt = str:sub(i + 1, i + 1)
      if nxt == "u" then
        local hex = str:sub(i + 2, i + 5)
        if not hex:match("^%x%x%x%x$") then return decode_error(str, i, "bad \\u escape") end
        local cp = tonumber(hex, 16)
        -- Manifests are ASCII; encode the code point as UTF-8 for safety.
        if cp < 0x80 then
          buf[#buf + 1] = string.char(cp)
        elseif cp < 0x800 then
          buf[#buf + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
        else
          buf[#buf + 1] = string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40)
        end
        i = i + 6
      else
        local rep = escapes[nxt]
        if not rep then return decode_error(str, i, "bad escape \\" .. nxt) end
        buf[#buf + 1] = rep
        i = i + 2
      end
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  return decode_error(str, pos, "unterminated string")
end

local function parse_number(str, pos)
  local s, e = str:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
  if not s then return decode_error(str, pos, "invalid number") end
  local n = tonumber(str:sub(s, e))
  if not n then return decode_error(str, pos, "invalid number") end
  return n, e + 1
end

local function parse_array(str, pos)
  local arr, i = {}, skip_ws(str, pos + 1)
  if str:sub(i, i) == "]" then return arr, i + 1 end
  while true do
    local val, np = parse_value(str, i)
    if type(np) == "string" then return nil, np end
    arr[#arr + 1] = val
    i = skip_ws(str, np)
    local c = str:sub(i, i)
    if c == "]" then return arr, i + 1 end
    if c ~= "," then return decode_error(str, i, "expected ',' or ']'") end
    i = skip_ws(str, i + 1)
  end
end

local function parse_object(str, pos)
  local obj, i = {}, skip_ws(str, pos + 1)
  if str:sub(i, i) == "}" then return obj, i + 1 end
  while true do
    if str:sub(i, i) ~= '"' then return decode_error(str, i, "expected object key") end
    local key, np = parse_string(str, i)
    if type(np) == "string" then return nil, np end
    i = skip_ws(str, np)
    if str:sub(i, i) ~= ":" then return decode_error(str, i, "expected ':'") end
    local val, vp = parse_value(str, skip_ws(str, i + 1))
    if type(vp) == "string" then return nil, vp end
    obj[key] = val
    i = skip_ws(str, vp)
    local c = str:sub(i, i)
    if c == "}" then return obj, i + 1 end
    if c ~= "," then return decode_error(str, i, "expected ',' or '}'") end
    i = skip_ws(str, i + 1)
  end
end

function parse_value(str, pos)
  pos = skip_ws(str, pos)
  local c = str:sub(pos, pos)
  if c == "{" then return parse_object(str, pos) end
  if c == "[" then return parse_array(str, pos) end
  if c == '"' then return parse_string(str, pos) end
  if c == "-" or c:match("%d") then return parse_number(str, pos) end
  if str:sub(pos, pos + 3) == "true" then return true, pos + 4 end
  if str:sub(pos, pos + 4) == "false" then return false, pos + 5 end
  if str:sub(pos, pos + 3) == "null" then return M.null, pos + 4 end
  return decode_error(str, pos, "unexpected character '" .. c .. "'")
end

--- Decode a JSON string. Returns the value, or nil + error message.
function M.decode(str)
  if type(str) ~= "string" then return nil, "json: expected string" end
  local val, pos = parse_value(str, 1)
  if type(pos) == "string" then return nil, pos end
  -- Errors are signalled by a string second return; a valid `null` decodes to
  -- the M.null sentinel (never a nil Lua value), so `val` is meaningful here.
  pos = skip_ws(str, pos)
  if pos <= #str then return nil, "json: trailing data at position " .. pos end
  return val
end

return M

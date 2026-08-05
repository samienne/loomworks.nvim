-- Downloader for the host bootstrap.
--
-- HTTP(S) is fetched with the system `curl` — it handles TLS, redirects,
-- corporate proxies (via the usual env vars), and enterprise cert stores far
-- more robustly than a hand-rolled client, and integrity does not depend on it:
-- every artifact is signature/hash-verified by boot.verify, so a MITM'd or
-- cert-relaxed transport cannot inject code. Set LOOMWORKS_INSECURE_TLS=1 to
-- add `curl -k` for TLS-intercepting proxies.
--
-- A "URL" that is a local path or file:// is read directly — the offline-mirror
-- path (LOOMWORKS_RELEASE_URL=<dir>) and what the tests use.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end

local M = {}

--- Is `url` a local path (no scheme, or file://) rather than http(s)?
local function local_path(url)
  local scheme = url:match("^(%a[%w+.-]*)://")
  if scheme == "file" then return (url:gsub("^file://", "")) end
  if not scheme then return url end        -- bare path
  return nil                                -- http/https/etc.
end

local function getenv(name)
  if uv.os_getenv then
    local ok, v = pcall(uv.os_getenv, name)
    if ok then return v end
  end
  return os.getenv(name)
end
local function env_truthy(name)
  local v = getenv(name)
  return v ~= nil and v ~= "" and v ~= "0" and v:lower() ~= "false"
end

--- Run `cmd args...`, draining stdout/stderr. Returns exit_code, stdout, stderr
--- (or nil, err on spawn failure).
local function run(cmd, args)
  local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
  local out, err = {}, {}
  local code, done
  local handle = uv.spawn(cmd, { args = args, stdio = { nil, stdout, stderr } },
    function(c) code = c; done = true; if not stdout:is_closing() then stdout:close() end
      if not stderr:is_closing() then stderr:close() end end)
  if not handle then
    stdout:close(); stderr:close()
    return nil, "cannot spawn '" .. cmd .. "' (is it installed and on PATH?)"
  end
  stdout:read_start(function(e, data)
    if data then out[#out + 1] = data elseif not e and not stdout:is_closing() then stdout:close() end
  end)
  stderr:read_start(function(e, data)
    if data then err[#err + 1] = data elseif not e and not stderr:is_closing() then stderr:close() end
  end)
  uv.run()
  handle:close()
  return code, table.concat(out), table.concat(err)
end

local function curl_args(url, extra)
  local args = { "-fsSL" }
  if env_truthy("LOOMWORKS_INSECURE_TLS") then args[#args + 1] = "-k" end
  for _, a in ipairs(extra or {}) do args[#args + 1] = a end
  args[#args + 1] = url
  return args
end

local function read_file(path)
  local f, e = io.open(path, "rb")
  if not f then return nil, "cannot read '" .. path .. "': " .. tostring(e) end
  local s = f:read("*a"); f:close()
  return s
end

--- How many times a transient fetch is attempted, and the backoff between
--- attempts. CI runners hit connection resets often enough that a single
--- attempt makes `lw install` flaky through no fault of the release.
M.MAX_ATTEMPTS = 3
M.RETRY_DELAY_MS = 1000

--- Is this curl failure worth retrying?
---
--- `curl -f` exits 22 for any HTTP status >= 400, so the exit code alone can't
--- separate "this release does not exist" from "the server is briefly unwell".
--- A 4xx is the server stating the request itself is wrong — retrying only
--- delays a certain failure — except 408/429, which explicitly invite a retry.
--- Everything else (resets, timeouts, DNS, 5xx) may well succeed next time.
--- @param code integer curl exit code
--- @param stderr string
--- @return boolean
function M.is_transient(code, stderr)
  if code == 0 then return false end
  if code ~= 22 then return true end
  local status = tonumber((stderr or ""):match("returned error:%s*(%d%d%d)"))
  if not status then return true end
  if status == 408 or status == 429 then return true end
  return not (status >= 400 and status < 500)
end

--- Run curl, retrying transient failures. Returns code, stdout, stderr, or
--- nil, err when curl cannot be spawned at all (retrying that is pointless —
--- a missing curl will still be missing a second later).
local function curl_with_retry(args)
  local code, out, err
  for attempt = 1, M.MAX_ATTEMPTS do
    code, out, err = run("curl", args)
    if code == nil then return nil, out end
    if code == 0 or not M.is_transient(code, err) then break end
    if attempt < M.MAX_ATTEMPTS and uv.sleep then
      uv.sleep(M.RETRY_DELAY_MS * attempt)
    end
  end
  return code, out, err
end

--- Fetch `url` and return its bytes, or nil, err.
function M.fetch(url)
  local lp = local_path(url)
  if lp then return read_file(lp) end
  local code, out, err = curl_with_retry(curl_args(url))
  if code == nil then return nil, out end
  if code ~= 0 then
    return nil, "curl failed (" .. tostring(code) .. ") for " .. url ..
      (err ~= "" and (": " .. err:gsub("%s+$", "")) or "")
  end
  return out
end

--- Fetch `url` into the file `dest` (created/overwritten). Returns true or
--- nil, err. Preferred for large binaries (the bundle zip).
function M.fetch_to_file(url, dest)
  local lp = local_path(url)
  if lp then
    local bytes, e = read_file(lp)
    if not bytes then return nil, e end
    local f, oe = io.open(dest, "wb")
    if not f then return nil, "cannot write '" .. dest .. "': " .. tostring(oe) end
    f:write(bytes); f:close()
    return true
  end
  local code, out, err = curl_with_retry(curl_args(url, { "-o", dest }))
  if code == nil then return nil, out end
  if code ~= 0 then
    return nil, "curl failed (" .. tostring(code) .. ") for " .. url ..
      (err ~= "" and (": " .. err:gsub("%s+$", "")) or "")
  end
  return true
end

return M

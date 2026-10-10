-- `lw release query` (spec §16.42): resolve an update channel to a VERIFIED
-- release — its version, the SHA-256 of every host asset and its descriptor
-- (§16.41) — without downloading, installing or saving anything.
--
-- A host command (§16.23): main.lua dispatches it before pin redirection and
-- before pinned-bundle provisioning, so it always runs as the invoked host,
-- needs no workspace and starts no daemon. It reuses the self-update channel
-- and version resolution (boot.update) and the signed hash list of pin
-- management (boot.bootstrap.fetch_hashes); the only new fetch is the
-- descriptor, which is trusted only once its bytes match the signed sums.
-- Verification is never relaxed (LOOMWORKS_INSECURE_TLS relaxes the transport
-- only). Writes nothing to disk.

local paths = require("boot.paths")
local verify = require("boot.verify")
local download = require("boot.download")
local update = require("boot.update")
local bootstrap = require("boot.bootstrap")
local pin = require("boot.pin")
local json = require("boot.json")

local M = {}

--- The output format version (`query` field); fields are only ever added.
M.FORMAT = 1

--- The overall time limit (seconds) when no `--timeout` is given: every fetch
--- is bounded (§16.42), so an unreachable network never hangs the caller.
M.DEFAULT_TIMEOUT = 60

--- The connect limit (seconds) of each fetch, capped by the time left.
M.CONNECT_TIMEOUT = 10

--- The descriptor asset a release publishes (§16.41).
--- @param version string a pin.valid_version release version
--- @return string
function M.descriptor_asset(version)
  return "lw-" .. version .. "-descriptor.json"
end

--- @class loomworks.boot.ReleaseQueryArgs
--- @field channel string|nil the `--channel` value (validated by the query)
--- @field json boolean `--json`: print the canonical JSON document
--- @field timeout integer|nil `--timeout <seconds>`: the overall limit

--- Parse the arguments of `lw release query` (`args` is the forwarded argv,
--- leading global flags allowed). Unknown options are usage errors (§16.7).
--- @param args string[]
--- @return loomworks.boot.ReleaseQueryArgs|nil args, string|nil err
function M.parse_args(args)
  local o = { json = false }
  local words, i = 0, 1
  while i <= #args do
    local v = args[i]
    if v == "--json" then
      o.json = true
    elseif v == "--channel" or v == "--timeout" then
      local val = args[i + 1]
      if val == nil or val:sub(1, 1) == "-" then return nil, v .. " needs a value" end
      if v == "--channel" then o.channel = val else o.timeout = val end
      i = i + 1
    elseif v:sub(1, 10) == "--channel=" then
      o.channel = v:sub(11)
    elseif v:sub(1, 10) == "--timeout=" then
      o.timeout = v:sub(11)
    elseif pin.GLOBAL_FLAGS[v] then
      -- a global flag, tolerated as `lw bootstrap` does; the query never prompts
    elseif v:sub(1, 1) == "-" then
      return nil, "unknown option '" .. v .. "' for `lw release query`"
    else
      words = words + 1
      if words == 2 and v ~= "query" then
        return nil, "unknown `lw release` sub-command '" .. v .. "' (query)"
      elseif words > 2 then
        return nil, "unexpected argument '" .. v .. "' for `lw release query`"
      end
    end
    i = i + 1
  end
  if words < 2 then return nil, "`lw release` needs a sub-command: query" end
  -- A bad `--channel` value is a usage error, like `lw self-update --channel`;
  -- one from LOOMWORKS_CHANNEL or the settings fails the query instead (exit 1).
  if o.channel ~= nil and not update.CHANNELS[o.channel] then
    return nil, "unknown update channel '" .. o.channel .. "' (expected 'stable' or 'unstable')"
  end
  if o.timeout ~= nil then
    local n = tonumber(o.timeout)
    if not n or n < 1 or n % 1 ~= 0 then
      return nil, "--timeout needs a whole number of seconds (got '" .. tostring(o.timeout) .. "')"
    end
    o.timeout = n
  end
  return o
end

--- @class loomworks.boot.ReleaseQueryResult
--- @field query integer the output format version (M.FORMAT)
--- @field channel string the resolved channel (§16.29 precedence)
--- @field channel_ignored boolean a release-source override superseded the channel
--- @field source "origin"|"override"
--- @field version string the newest release on the channel
--- @field prerelease boolean
--- @field assets table<string, string> host asset -> SHA-256, from the verified sums
--- @field descriptor table the release's descriptor document, hash-verified

--- Resolve the channel to a verified release (§16.42 steps 1-4).
--- @param opts? { channel?: string, timeout?: integer, url?: string }
--- @return loomworks.boot.ReleaseQueryResult|nil result, string|nil err
function M.query(opts)
  opts = opts or {}
  local channel, cerr = update.resolve_channel({ channel = opts.channel })
  if not channel then return nil, cerr end
  local override = update.url_override({ url = opts.url })

  -- One overall deadline; each fetch gets the time left (a local mirror is a
  -- file read and ignores the limits). One attempt each, so the bound holds.
  local deadline = os.time() + (opts.timeout or M.DEFAULT_TIMEOUT)
  local function limits()
    local left = deadline - os.time()
    if left < 1 then return nil end
    return { connect_timeout = math.min(M.CONNECT_TIMEOUT, left), max_time = left, attempts = 1 }
  end
  local function timed_out() return nil, "timed out after " .. (opts.timeout or M.DEFAULT_TIMEOUT) .. "s" end

  -- 2. the newest release on the channel (self-update's resolution, which
  -- validates the network-derived version before it reaches any URL).
  local lim = limits()
  if not lim then return timed_out() end
  local version, verr = update.resolve_newest_version({ channel = channel, url = opts.url, fetch = lim })
  if not version then return nil, verr end
  if not pin.valid_version(version) then
    return nil, "not a valid release version '" .. tostring(version) .. "'"
  end

  -- 3. the signed hash list: nothing is trusted before its signature verifies.
  lim = limits()
  if not lim then return timed_out() end
  local sums, serr = bootstrap.fetch_hashes(version, { url = opts.url, fetch = lim })
  if not sums then return nil, "release " .. version .. ": " .. tostring(serr) end

  -- 4. the descriptor, trusted only when its bytes match the signed sums.
  local dname = M.descriptor_asset(version)
  local want = sums[dname]
  if not want then
    return nil, "release " .. version .. " predates the descriptor (no " .. dname .. " in SHA256SUMS)"
  end
  lim = limits()
  if not lim then return timed_out() end
  local bytes, derr = download.fetch(update.versioned_base(version, { url = opts.url }) .. "/" .. dname, lim)
  if not bytes then return nil, "fetch " .. dname .. ": " .. tostring(derr) end
  if verify.sha256_hex(bytes) ~= want then
    return nil, dname .. ": SHA-256 does not match the signed SHA256SUMS"
  end
  local descriptor, jerr = json.decode(bytes)
  -- An object only: a top-level array (json.lua marks even an empty `[]` via
  -- the __jsonarray metatable) is not a descriptor.
  local mt = type(descriptor) == "table" and getmetatable(descriptor)
  if type(descriptor) ~= "table" or descriptor == json.null or descriptor[1] ~= nil
      or (mt and mt.__jsonarray) then
    return nil, dname .. ": not a JSON object" .. (jerr and (" (" .. jerr .. ")") or "")
  end
  -- The descriptor must describe the release it was fetched for: a signed but
  -- mismatched one fails verification like a hash mismatch.
  local dver = type(descriptor.binary) == "table" and descriptor.binary.lw_version or nil
  local function norm(x) return type(x) == "string" and (x:gsub("^[vV]", "")) or nil end
  if norm(dver) ~= norm(version) then
    return nil, dname .. ": binary.lw_version '" .. tostring(dver) ..
      "' does not match the release version " .. version
  end

  local assets = {}
  for _, a in pairs(pin.HOST_ASSETS) do
    if sums[a] then assets[a] = sums[a] end
  end
  return {
    query = M.FORMAT,
    channel = channel,
    channel_ignored = override ~= nil,
    source = override and "override" or "origin",
    version = version,
    prerelease = paths.is_prerelease(version),
    assets = assets,
    descriptor = descriptor,
  }
end

--- The plain output: channel, version, pre-release, one line each.
--- @param res loomworks.boot.ReleaseQueryResult
--- @return string[]
function M.lines(res)
  return {
    "channel: " .. res.channel,
    "version: " .. res.version,
    "prerelease: " .. (res.prerelease and "yes" or "no"),
  }
end

--- The plain output's warning when an override superseded a non-default
--- channel — the same condition and wording as self-update's; nil otherwise.
--- @param res loomworks.boot.ReleaseQueryResult
--- @return string|nil
function M.override_warning(res)
  if not res.channel_ignored or res.channel == update.DEFAULT_CHANNEL then return nil end
  return "lw: channel " .. res.channel .. " is ignored - a release-url override is in effect " ..
    "(LOOMWORKS_RELEASE_URL / the `release-url` setting). The channel governs only the default " ..
    "origin; unset the override to use channels."
end

--- Run `lw release query` for main.lua: returns the exit code, the stdout text
--- and the stderr text (each nil when empty). A failure prints one stderr line
--- and nothing on stdout (§16.42).
--- @param args string[] the forwarded argv
--- @return integer code, string|nil out, string|nil err
function M.run(args)
  local o, perr = M.parse_args(args)
  if not o then return 2, nil, "lw: " .. perr .. " - see `lw help release`\n" end
  local res, err = M.query({ channel = o.channel, timeout = o.timeout })
  if not res then
    return 1, nil, "lw: release query failed: " .. tostring(err):gsub("[\r\n]+", " ") .. "\n"
  end
  if o.json then return 0, json.encode_canonical(res) .. "\n", nil end
  local warn = M.override_warning(res)
  return 0, table.concat(M.lines(res), "\n") .. "\n", warn and (warn .. "\n") or nil
end

return M

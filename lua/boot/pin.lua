-- Repo-local launcher / version-pin helpers for the host bootstrap.
--
-- Pure logic shared by the launcher (main.lua) and pin management
-- (boot.bootstrap): parse/serialize `lw.pin`, select the host-binary asset for
-- the running platform, locate the pin root, and decide whether a global host
-- should redirect to a pinned release. Depends only on luv; never on the vim
-- shim or the bundle it may end up provisioning.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end

local M = {}

M.is_windows = package.config:sub(1, 1) == "\\"

-- The real published host-binary assets, keyed by "<os>/<arch>". These are the
-- exact names the release workflow uploads (see .github/workflows/release.yml);
-- a platform absent here has no pinnable binary and MUST error rather than
-- fetch a different platform's asset.
M.HOST_ASSETS = {
  ["linux/x86_64"]   = "lw-linux-x86_64",
  ["macos/arm64"]    = "lw-macos-arm64",
  ["windows/x86_64"] = "lw-windows-x86_64.exe",
}

-- Workspace operations that honor a pin (redirect to the pinned release).
-- Everything else — status, host/management commands, config edits — runs as
-- the invoked host.
M.REDIRECT_COMMANDS = {
  build = true, run = true, test = true, clean = true, configure = true,
}

--- Is `v` a safe release version? THE TRUST BOUNDARY: a version flows into
--- download URLs and into rm_rf'd cache paths, so it must not carry path
--- separators, `..`, or whitespace. Whitelist an alphanumeric-led token of
--- `[%w._+-]` (semver-ish: `0.1.0`, `0.0.0-test`, `1.2.3+build`).
function M.valid_version(v)
  if type(v) ~= "string" or v == "" then return false end
  if v:find("[/\\%s]") then return false end
  if v:find("..", 1, true) then return false end  -- plain search for literal ".."
  return v:match("^%w[%w%.%+%-]*$") ~= nil
end

--- The bundle asset name for a release version.
function M.bundle_asset(version) return "loomworks-lua-" .. version .. ".zip" end

--- Normalize an OS name (uname sysname / "Windows") to linux|macos|windows|nil.
function M.normalize_os(sysname)
  if not sysname then return nil end
  local s = sysname:lower()
  if s:find("linux", 1, true) then return "linux" end
  if s:find("darwin", 1, true) or s:find("mac", 1, true) then return "macos" end
  if s:find("mingw", 1, true) or s:find("msys", 1, true)
      or s:find("cygwin", 1, true) or s:find("windows", 1, true) then
    return "windows"
  end
  return nil
end

--- Normalize a machine/arch string (uname machine) to x86_64|arm64|<raw>.
function M.normalize_arch(machine)
  if not machine then return nil end
  local m = machine:lower()
  if m == "x86_64" or m == "amd64" then return "x86_64" end
  if m == "arm64" or m == "aarch64" then return "arm64" end
  return m
end

--- Select the host-binary asset for (sysname, machine). Returns the asset name,
--- or nil + a clear error for an unsupported/unpinned platform.
function M.host_asset(sysname, machine)
  local os_ = M.normalize_os(sysname)
  if not os_ then return nil, "unsupported OS '" .. tostring(sysname) .. "'" end
  local arch = M.normalize_arch(machine)
  local asset = M.HOST_ASSETS[os_ .. "/" .. tostring(arch)]
  if not asset then
    return nil, "no pinned lw binary for " .. os_ .. "/" .. tostring(arch)
  end
  return asset
end

--- The host-binary asset for the running platform (via uname), or nil, err.
function M.detect_asset()
  local sys, machine
  if uv.os_uname then
    local ok, u = pcall(uv.os_uname)
    if ok and type(u) == "table" then sys, machine = u.sysname, u.machine end
  end
  if not sys and M.is_windows then sys = "Windows" end
  return M.host_asset(sys, machine)
end

--- Parse `lw.pin` text (key = value, one per line, `#` comments). Returns
--- { version = string, hashes = { [asset] = hex } } or nil, err.
function M.parse(text)
  if type(text) ~= "string" then return nil, "pin is not text" end
  local version, hashes = nil, {}
  for line in (text .. "\n"):gmatch("([^\n]-)\n") do
    local l = line:gsub("^%s+", ""):gsub("%s+$", "")
    if l ~= "" and l:sub(1, 1) ~= "#" then
      local key, val = l:match("^([%w_%.%-]+)%s*=%s*(.-)$")
      if not key then return nil, "malformed pin line: " .. line end
      if key == "version" then
        version = val
      elseif key:sub(1, 7) == "sha256_" then
        hashes[key:sub(8)] = val:lower()
      end
      -- Unknown keys are ignored (forward compatibility).
    end
  end
  if not version or version == "" then return nil, "pin missing 'version'" end
  -- Reject a malicious/garbled version here so it never reaches a URL or an
  -- rm_rf'd path (a repo cannot redirect the fetch — spec §16.23).
  if not M.valid_version(version) then
    return nil, "pin has an unsafe version '" .. version .. "'"
  end
  return { version = version, hashes = hashes }
end

--- Serialize a version + { [asset] = hex } into pin text (deterministic order).
function M.serialize(version, hashes)
  local out = { "version = " .. version, "" }
  local assets = {}
  for a in pairs(hashes or {}) do assets[#assets + 1] = a end
  table.sort(assets)
  for _, a in ipairs(assets) do
    out[#out + 1] = "sha256_" .. a .. " = " .. hashes[a]:lower()
  end
  return table.concat(out, "\n") .. "\n"
end

--- Read + parse `<root>/lw.pin`. Returns the pin table or nil (absent/invalid).
function M.read(root)
  if not root then return nil end
  local f = io.open(root .. "/lw.pin", "r")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return (M.parse(s))
end

--- Walk up from `start` for the nearest directory holding `lw.pin`, stopping at
--- a git working-tree boundary so it never binds a parent checkout's pin.
function M.find_pin_root(start)
  local dir = start
  if not dir or dir == "" then return nil end
  dir = dir:gsub("\\", "/"):gsub("/+$", "")
  while dir ~= "" do
    if uv.fs_stat(dir .. "/lw.pin") then return dir end
    if uv.fs_stat(dir .. "/.git") then return nil end
    local parent = dir:gsub("/[^/]*$", "")
    if parent == dir then break end
    dir = parent
  end
  return nil
end

--- The machine-local cache dir under a pin root.
function M.cache_dir(root) return root .. "/.nvim/cache" end

--- The canonical cached path for a pinned host binary (version + asset), shared
--- by the launcher scripts and the redirect so both reuse one download.
function M.binary_path(root, version, asset)
  return M.cache_dir(root) .. "/lw-" .. version .. "-" .. asset
end

--- Is `cmd` a workspace operation that honors a pin?
function M.is_redirect_command(cmd)
  return cmd ~= nil and M.REDIRECT_COMMANDS[cmd] == true
end

--- Decide what a global host should do about a pin. Pure — all inputs explicit.
--- @param o { command?, pin?, self_version?, pinned_sentinel?, no_pin?, lw_override?, dev? }
--- @return "in-process"|"redirect"|"bypass"|"no-pin" action, string reason
function M.decide(o)
  if o.pinned_sentinel then return "in-process", "already running as the pinned host" end
  if o.dev then return "bypass", "development source" end
  if o.lw_override then return "bypass", "LOOMWORKS_LW override" end
  if o.no_pin then return "bypass", "--no-pin" end
  if not M.is_redirect_command(o.command) then
    return "in-process", "not a workspace operation"
  end
  if not o.pin then return "no-pin", "no pin in this workspace" end
  if o.self_version and o.pin.version == o.self_version then
    return "in-process", "pinned version == self"
  end
  return "redirect", "pinned version " .. tostring(o.pin.version)
end

return M

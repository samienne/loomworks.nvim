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

-- Workspace operations that honor a pin (redirect to the pinned release):
-- every command the CLI routes to the workspace daemon (build, run, test,
-- clean, reset) plus configure. Everything else — status, host/management
-- commands, config edits — runs as the invoked host.
M.REDIRECT_COMMANDS = {
  build = true, run = true, test = true, clean = true, configure = true, reset = true,
}

-- Commands whose SUB-command decides (spec §16.23): of `lw daemon`, the ones
-- that start a workspace daemon — `run` (in every form, `--stdio` included:
-- what the editor launches) and `restart` — so the daemon of a pinned
-- workspace is the pinned lw whoever starts it. `status`, `list`, `stop` and
-- `kill` speak the frozen control subset to a daemon of any version and stay
-- with the invoked host.
M.REDIRECT_SUBCOMMANDS = {
  daemon = { run = true, restart = true },
}

-- The first release that has each redirected command a pinned lw may lack
-- (spec §16.23 "A pin older than the command"). A pin naming an older release
-- is never redirected to for it: that host would only fail with "unknown
-- command". Keys: the command, `<command> <sub>`, and `daemon run --stdio`
-- for the editor's form. Every other redirect command predates version pins.
M.REDIRECT_SINCE = {
  reset = "0.1.27",                           -- `lw reset` (#48)
  ["daemon run"] = "0.1.43-beta.5",           -- lw daemon run|stop|kill|restart (#106)
  ["daemon restart"] = "0.1.43-beta.5",       -- (#106)
  ["daemon run --stdio"] = "0.1.43-beta.15",  -- the stdio transport (#152)
}

--- The first release that has the redirected command (`cmd`, `sub`, with
--- `--stdio` when `stdio`), or nil when every pinnable release has it.
--- @param cmd string|nil
--- @param sub string|nil
--- @param stdio boolean|nil
--- @return string|nil
function M.redirect_since(cmd, sub, stdio)
  if cmd == nil then return nil end
  if M.REDIRECT_SUBCOMMANDS[cmd] then
    if sub == nil then return nil end
    local key = cmd .. " " .. sub
    return (stdio and M.REDIRECT_SINCE[key .. " --stdio"]) or M.REDIRECT_SINCE[key]
  end
  return M.REDIRECT_SINCE[cmd]
end

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

-- The pinned artifacts the HOST provisions (the redirect's host binary and the
-- pinned bundle) live in the per-user data dir, never under the pin root — see
-- boot.update.pinned_binary_path / pinned_bundle_dir (spec §16.22).

--- Is `cmd` (with its sub-command `sub`, the next word) a workspace operation
--- that honors a pin?
--- @param cmd string|nil
--- @param sub string|nil
--- @return boolean
function M.is_redirect_command(cmd, sub)
  if cmd == nil then return false end
  if M.REDIRECT_COMMANDS[cmd] == true then return true end
  local subs = M.REDIRECT_SUBCOMMANDS[cmd]
  return subs ~= nil and sub ~= nil and subs[sub] == true
end

--- The first two non-flag words of `args` — the command and its sub-command
--- — skipping leading global flags, and `--root <dir>` / `--root=<dir>` (the
--- option `lw daemon run --root <dir>` carries; its value is not a word).
--- @param args string[]
--- @return string|nil command, string|nil sub
function M.command_words(args)
  local words, i = {}, 1
  while i <= #args and #words < 2 do
    local v = args[i]
    if v == "--root" then
      i = i + 1
    elseif type(v) == "string" and v:sub(1, 1) ~= "-" then
      words[#words + 1] = v
    end
    i = i + 1
  end
  return words[1], words[2]
end

--- The value of `--root <dir>` / `--root=<dir>` in `args`, or nil.
--- @param args string[]
--- @return string|nil
function M.root_option(args)
  for i, v in ipairs(args) do
    if v == "--root" then return args[i + 1] end
    if type(v) == "string" and v:sub(1, 7) == "--root=" then return v:sub(8) end
  end
  return nil
end

--- Decide what a global host should do about a pin. Pure — all inputs explicit.
--- "unsupported": the pinned release predates the command (REDIRECT_SINCE);
--- the third value is the release that introduced it. The caller does not
--- redirect, and leaves the workspace daemon to the pinned lw (spec §16.23).
--- @param o { command?, sub?, stdio?, pin?, self_version?, pinned_sentinel?, no_pin?, lw_override?, dev? }
--- @return "in-process"|"redirect"|"bypass"|"no-pin"|"unsupported" action, string reason, string|nil since
function M.decide(o)
  if o.pinned_sentinel then return "in-process", "already running as the pinned host" end
  if o.dev then return "bypass", "development source" end
  if o.lw_override then return "bypass", "LOOMWORKS_LW override" end
  if o.no_pin then return "bypass", "--no-pin" end
  if not M.is_redirect_command(o.command, o.sub) then
    return "in-process", "not a workspace operation"
  end
  if not o.pin then return "no-pin", "no pin in this workspace" end
  if o.self_version and o.pin.version == o.self_version then
    return "in-process", "pinned version == self"
  end
  local since = M.redirect_since(o.command, o.sub, o.stdio)
  if since and require("boot.paths").compare_versions(o.pin.version, since) < 0 then
    return "unsupported", "pinned version " .. tostring(o.pin.version) .. " predates it", since
  end
  return "redirect", "pinned version " .. tostring(o.pin.version)
end

--- The version a pin asks for when the invoked host is not it and nothing
--- bypasses the pin — what `decide` would redirect a workspace operation to
--- — or nil. A command such a host runs itself (a config edit, `lw profile
--- select`) must not start or replace the workspace daemon: that is the
--- pinned lw's (spec §16.23, §19.9). Pure — the same inputs as `decide`.
--- @param o { pin?, self_version?, pinned_sentinel?, no_pin?, lw_override?, dev? }
--- @return string|nil
function M.foreign_pin(o)
  if o.pinned_sentinel or o.dev or o.lw_override or o.no_pin or not o.pin then return nil end
  if o.self_version and o.pin.version == o.self_version then return nil end
  return o.pin.version
end

-- ---------------------------------------------------------------------------
-- Pin management argument grammar (spec §16.24). Pure.
-- ---------------------------------------------------------------------------

--- Global flags the CLI accepts anywhere; tolerated (and ignored) here.
M.GLOBAL_FLAGS = { ["--no-input"] = true, ["--non-interactive"] = true,
  ["--insecure"] = true, ["--verify"] = true, ["--verbose"] = true }

local INSTALL_ONLY = { "--version", "--latest", "--channel", "--pin-only", "--force" }

--- Parse `lw bootstrap [install|upgrade] …` arguments.
--- @param args string[] the arguments (host flags already peeled), including
---   the command word itself
--- @param command "bootstrap"
--- @param popts? { invoked?: string } how lw was run, so messages name commands
---   in that form (boot.launcher_check.cmd)
--- @return table|nil opts { sub, version?, latest?, channel?, pin_only?, force?, json?, check? }, string|nil usage_error
function M.parse_bootstrap_args(args, command, popts)
  local invoked = popts and popts.invoked
  local function C(rest) return require("boot.launcher_check").cmd(invoked, rest) end
  local o = { flags = {} }
  local seen_command, positional = false, {}
  local i = 1
  local function value(flag)
    local v = args[i + 1]
    if v == nil or v:sub(1, 1) == "-" then return nil, flag .. " needs a value" end
    i = i + 1
    return v
  end
  while i <= #args do
    local v = args[i]
    local eqv
    if type(v) == "string" and v:sub(1, 2) == "--" and v:find("=", 1, true) then
      v, eqv = v:match("^([^=]+)=(.*)$")
    end
    if v == "--version" or v == "--channel" then
      local val, err = eqv, nil
      if val == nil then val, err = value(v) end
      if not val or val == "" then return nil, err or (v .. " needs a value") end
      if v == "--version" then o.version = val else o.channel = val end
      o.flags[v] = true
    elseif v == "--latest" then o.latest = true; o.flags[v] = true
    elseif v == "--pin-only" then o.pin_only = true; o.flags[v] = true
    elseif v == "--force" then o.force = true; o.flags[v] = true
    elseif v == "--json" then o.json = true; o.flags[v] = true
    elseif v == "--check" then o.check = true; o.flags[v] = true
    elseif M.GLOBAL_FLAGS[v] then -- tolerated
    elseif type(v) == "string" and v:sub(1, 1) == "-" then
      return nil, "unknown option '" .. v .. "' for `" .. C(command) .. "`"
    elseif not seen_command and v == command then
      seen_command = true
    else
      positional[#positional + 1] = v
    end
    i = i + 1
  end

  local sub = positional[1]
  if #positional > 1 then return nil, "unexpected argument '" .. positional[2] .. "'" end
  if sub == nil then
    for _, f in ipairs(INSTALL_ONLY) do
      if o.flags[f] then
        local example = f == "--version" and ("--version " .. tostring(o.version)) or f
        return nil, "`" .. C("bootstrap") .. "` only reports; to write the pin and launchers run" ..
          " `" .. C("bootstrap install " .. example) .. "`"
      end
    end
    return o
  end
  if sub ~= "install" and sub ~= "upgrade" then
    return nil, "unknown `" .. C("bootstrap") .. "` sub-command '" .. sub .. "' (install, upgrade)"
  end
  if o.json or o.check then
    return nil, (o.json and "--json" or "--check") .. " belongs to the status page (`" .. C("bootstrap") .. "`)"
  end
  o.sub = sub
  if sub == "upgrade" then
    if o.version then return nil, "`" .. C("bootstrap upgrade") .. "` takes no --version; use `" ..
      C("bootstrap install --version <x.y.z>") .. "`" end
    o.latest = true
  end
  if o.version and o.latest then return nil, "--version and --latest cannot be combined" end
  if o.channel and not o.latest then return nil, "--channel applies only with --latest (or `upgrade`)" end
  return o
end

return M

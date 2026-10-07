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

-- The pinned artifacts the HOST provisions (the redirect's host binary and the
-- pinned bundle) live in the per-user data dir, never under the pin root — see
-- boot.update.pinned_binary_path / pinned_bundle_dir (spec §16.22).

--- Is `cmd` a workspace operation that honors a pin?
function M.is_redirect_command(cmd)
  return cmd ~= nil and M.REDIRECT_COMMANDS[cmd] == true
end

-- `lw launch add|create` hands the line to a program after its command
-- operand (or `--from-target <t>`): every token there is a program argument.
local LAUNCH_ADD = { add = true, create = true }
local LAUNCH_ADD_VALUED = { ["--working-dir"] = true, ["--cwd"] = true, ["--env"] = true,
  ["--description"] = true }

--- Where lw's own arguments end in `args` (the whole command line, leading
--- global flags included): the index of the first token that belongs to a
--- program or native tool — the first `--`, or a `launch add` program's
--- arguments — or #args + 1. The host's flags (`--dev`, `--no-pin`) are
--- recognised only before it (spec §16.7); on `launch set` and the set-value
--- commands that is up to `--`, the escape for an argument or value spelling
--- one. The host mirror of the bundle's `loomworks.cli_options.own_end` (which
--- knows every command's grammar): the host cannot load the bundle before it
--- has chosen the source. Also returns the command word's index (or nil).
--- @param args string[]
--- @return integer own_end, integer|nil command_index
function M.own_end(args)
  local n = #args + 1
  local i, c = 1, nil
  while i <= #args do
    local v = args[i]
    if v == "--" then return i, nil end
    if v == "--root" then
      i = i + 1
    elseif type(v) == "string" and v:sub(1, 1) ~= "-" then
      c = i; break
    end
    i = i + 1
  end
  if not c then return n, nil end
  local function to_dashdash(from)
    for k = from, #args do if args[k] == "--" then return k end end
    return n
  end
  if not (args[c] == "launch" and LAUNCH_ADD[args[c + 1] or ""]) then
    return to_dashdash(c + 1), c
  end
  local npos, k = 0, c + 2
  while k <= #args do
    local v = args[k]
    if v == "--" or npos >= 3 then return k, c end
    if v == "--from-target" then return math.min(k + 2, n), c end
    if LAUNCH_ADD_VALUED[v] then
      k = k + 2
    else
      if v:sub(1, 1) ~= "-" then npos = npos + 1 end
      k = k + 1
    end
  end
  return n, c
end

--- Peel the host-level flags (`--dev`, `--dev=<path>`, `--no-pin`) off the
--- command line — only where they are lw's own (`own_end`): after `--` or in
--- a program's arguments they are left in place for the program.
--- @param args string[]
--- `dev_in_args` is set when a `--dev` came after the command word (a program
--- argument the user forgot to put after `--`, for the error hint).
--- @return string[] forwarded, { dev: boolean, dev_path: string|nil, no_pin: boolean, dev_in_args: boolean } flags
function M.peel_host_flags(args)
  local stop, c = M.own_end(args)
  local forwarded, f = {}, { dev = false, dev_path = nil, no_pin = false, dev_in_args = false }
  for i, v in ipairs(args) do
    if i < stop and v == "--dev" then
      f.dev, f.dev_in_args = true, f.dev_in_args or (c ~= nil and i > c)
    elseif i < stop and type(v) == "string" and v:sub(1, 6) == "--dev=" then
      f.dev, f.dev_path = true, v:sub(7)
      f.dev_in_args = f.dev_in_args or (c ~= nil and i > c)
    elseif i < stop and v == "--no-pin" then
      f.no_pin = true
    else
      forwarded[#forwarded + 1] = v
    end
  end
  return forwarded, f
end

--- The error for a development source with no directory configured. With
--- `in_args` (a `--dev` after the command word, `peel_host_flags`) it adds a
--- hint: the user may have meant it for the program (spec §16.7).
--- @param in_args boolean|nil
--- @return string
function M.dev_unconfigured_message(in_args)
  local msg = "lw: development source requested but no directory is configured.\n" ..
    "    Set one with `lw settings set dev-lua <path>`, pass `--dev=<path>`,\n" ..
    "    or export LOOMWORKS_LUA=<path>.\n"
  if in_args then
    msg = msg .. "    (`--dev` there is lw's own option; to pass it to the program,\n" ..
      "    put it after `--`, e.g. `lw launch set <project> <name> -- --dev`.)\n"
  end
  return msg
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

-- ---------------------------------------------------------------------------
-- Pin management argument grammar (spec §16.24). Pure.
-- ---------------------------------------------------------------------------

--- Global flags the CLI accepts among a command's own arguments; tolerated
--- (and ignored) here.
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

-- `lw install` — the host binary places itself where it can be invoked, and
-- ensures that location is on PATH (spec §16.15). A host command: it runs
-- before any bundle exists and depends only on luv + boot helpers.
--
-- Install location (per-user, no admin):
--   Windows:  %LOCALAPPDATA%\Microsoft\WindowsApps\lw.exe  (already on PATH)
--   Unix:     ~/.local/bin/lw                              (add to PATH if needed)
--
-- PATH changes are gated: applied only with an interactive yes, opts.assume_yes
-- (`-y`), and never when --no-modify-path. Windows needs no PATH edit.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end
local paths = require("boot.paths")
local update = require("boot.update")

local M = {}

local function homedir()
  return (uv.os_homedir() or paths.getenv("HOME") or paths.getenv("USERPROFILE") or "."):gsub("\\", "/")
end

--- Absolute path where the host binary is installed.
function M.target_path()
  if paths.is_windows then
    local lad = paths.getenv("LOCALAPPDATA")
    if not lad then return nil end
    return (lad:gsub("\\", "/")) .. "/Microsoft/WindowsApps/lw.exe"
  end
  return homedir() .. "/.local/bin/lw"
end

local function norm(p)
  if not p then return p end
  p = p:gsub("\\", "/"):gsub("/+$", "")
  if paths.is_windows then
    p = p:gsub("^/(%a)/", "%1:/")  -- git-bash/MSYS /c/foo -> c:/foo
    p = p:lower()                  -- Windows paths are case-insensitive
  end
  return p
end

--- Is `dir` on the current PATH?
function M.dir_on_path(dir)
  local sep = paths.is_windows and ";" or ":"
  local want = norm(dir)
  local path = paths.getenv("PATH") or ""
  for entry in (path .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do
    if #entry > 0 and norm(entry) == want then return true end
  end
  return false
end

local function read_bin(p)
  local f, e = io.open(p, "rb"); if not f then return nil, e end
  local s = f:read("*a"); f:close(); return s
end

--- Copy `src` to `dest` (binary), creating parents and marking it executable.
function M.copy_binary(src, dest)
  local data, e = read_bin(src)
  if not data then return nil, "read '" .. src .. "': " .. tostring(e) end
  local parent = dest:match("^(.*)/[^/]*$")
  if parent then
    local ok, err = paths.mkdirp(parent)
    if not ok then return nil, err end
  end
  local f, oe = io.open(dest, "wb")
  if not f then return nil, "write '" .. dest .. "': " .. tostring(oe) end
  f:write(data); f:close()
  if not paths.is_windows then pcall(uv.fs_chmod, dest, tonumber("755", 8)) end
  return true
end

--- The shell rc file to add a PATH line to, based on $SHELL.
function M.shell_rc()
  local shell = paths.getenv("SHELL") or ""
  local home = homedir()
  if shell:find("zsh") then return home .. "/.zshrc" end
  if shell:find("bash") then return home .. "/.bashrc" end
  return home .. "/.profile"
end

--- Append `line` to `rc` under a tagged block, unless already present.
--- Returns true (added), false (already present), or nil, err.
function M.append_path_line(rc, line)
  local existing = io.open(rc, "r")
  if existing then
    local content = existing:read("*a"); existing:close()
    if content and content:find(line, 1, true) then return false end
  end
  local parent = rc:match("^(.*)/[^/]*$")
  if parent then paths.mkdirp(parent) end
  local f, e = io.open(rc, "a")
  if not f then return nil, "append '" .. rc .. "': " .. tostring(e) end
  f:write("\n# added by `lw install`\n" .. line .. "\n")
  f:close()
  return true
end

-- Interactive y/N unless assume_yes; false when non-interactive without -y.
local function stdin_is_tty()
  local ok, kind = pcall(uv.guess_handle, 0)
  return ok and kind == "tty"
end
local function confirm(opts, question)
  if opts.assume_yes then return true end
  if not stdin_is_tty() then return nil end   -- nil = couldn't ask
  io.write(question .. " [y/N] "); io.flush()
  local ans = io.read("*l")
  return ans ~= nil and (ans:lower() == "y" or ans:lower() == "yes")
end

--- Install the running host. opts:
---   assume_yes, no_modify_path, no_bundle, dry_run
--- Returns a list of human-readable report lines (prefixed with the outcome),
--- or nil, err.
function M.install(opts)
  opts = opts or {}
  local out = {}
  local function say(s) out[#out + 1] = s end

  local exe = opts.exe_path or uv.exepath()  -- exe_path overridable for tests
  -- Guard: install copies the running binary. If that is bare luvi (the dev
  -- launcher runs `luvi . --`), the copy would be a non-working lw. Installing
  -- must be done from a real fused host.
  local exebase = (exe:match("([^/\\]+)$") or ""):lower():gsub("%.exe$", "")
  if exebase == "luvi" then
    return nil, "install must be run from a built lw binary, not the dev luvi " ..
      "launcher.\n    From the repo run `make install`; otherwise download a " ..
      "release binary and run its `install`."
  end
  local dest = M.target_path()
  if not dest then return nil, "cannot determine install location (LOCALAPPDATA unset?)" end
  local bindir = dest:match("^(.*)/[^/]*$")

  -- 1. place the binary
  if norm(exe) == norm(dest) then
    say("· binary already installed at " .. dest)
  elseif opts.dry_run then
    say("· would copy " .. exe .. " -> " .. dest)
  else
    local ok, err = M.copy_binary(exe, dest)
    if not ok then return nil, err end
    say("✓ installed binary -> " .. dest)
  end

  -- 2. PATH
  if M.dir_on_path(bindir) then
    say("· PATH: " .. bindir .. " already on PATH")
  elseif paths.is_windows then
    -- WindowsApps is normally on PATH by default; if not, it's a user setting.
    say("! PATH: " .. bindir .. " is not on this PATH — it is normally added by")
    say("        Windows automatically; open a new terminal, or add it in Settings.")
  elseif opts.no_modify_path then
    say("! PATH: not modified (--no-modify-path). Add manually:")
    say('        export PATH="' .. bindir .. ':$PATH"')
  else
    local rc = M.shell_rc()
    local line = 'export PATH="' .. bindir .. ':$PATH"'
    if opts.dry_run then
      say("· would add to " .. rc .. ":  " .. line)
    else
      local ok = confirm(opts, "Add " .. bindir .. " to PATH in " .. rc .. "?")
      if ok == true then
        local added, e = M.append_path_line(rc, line)
        if added == nil then return nil, e end
        say((added and "✓ PATH: added to " or "· PATH: already in ") .. rc ..
          " (restart your shell)")
      else
        say("! PATH: not modified" .. (ok == nil and " (non-interactive; pass -y)" or "") ..
          ". Add manually:")
        say("        " .. line)
      end
    end
  end

  -- 3. fetch the first bundle so the tool is immediately usable
  local bundle_err
  if opts.no_bundle then
    say("· bundle: skipped (--no-bundle). Run `lw self-update` when ready.")
  elseif opts.dry_run then
    say("· would run self-update to fetch the current release bundle")
  else
    local res, err = update.self_update({})
    if res then
      say((res.updated and "✓ fetched loomworks " or "· loomworks already at ") .. res.version)
    else
      -- An install without a bundle produces a binary that cannot run any
      -- workspace command — it fails later with "no loomworks release is
      -- installed", far from the fetch that actually failed. Report the
      -- failure here, and let the caller exit non-zero: a CI job must not be
      -- told an install succeeded when the result is unusable.
      bundle_err = tostring(err)
      say("✗ bundle: self-update failed (" .. bundle_err .. ").")
      say("        The binary is installed but has no release to run. Retry")
      say("        with `lw self-update`, or use `--no-bundle` to install the")
      say("        binary alone on purpose.")
    end
  end

  say("")
  if bundle_err then
    say("Incomplete: the binary is on PATH but no release bundle was fetched.")
    return out, "bundle fetch failed: " .. bundle_err
  end
  say("Done. Try `lw version`. Shell completion: `lw completion bash` (see `lw help completion`).")
  return out
end

return M

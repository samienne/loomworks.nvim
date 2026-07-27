-- Module acquisition for the host bootstrap (spec §16.20).
--
-- Extends the host's set of available modules (§16.8) by installing third-party
-- module packages named in a curated index. Flow, mirroring boot.update but
-- anchored on a hash the index pins rather than a signed manifest:
--   fetch index -> look up entry -> gate on interface version (§8.0)
--   -> download the pinned-tag archive -> verify sha256 against the index
--   -> extract to a staging dir -> keep the shipped `lua/` tree, atomically
--      rename it into <data>/loomworks/modules/<name>/lua.
--
-- The index is trusted because it arrives through a trusted channel (§16.20);
-- the *artifact* is trusted because its bytes match the hash the index records.
-- Transport is never trusted (boot.download): a MITM'd archive whose hash does
-- not match is rejected.
--
-- Bootstrap-level: depends only on luv + boot.{paths,download,verify,update,
-- json}; it never touches system Lua. The interface-version gate compares
-- against a value the CALLER passes in (cli.lua reads loomworks.api_versions),
-- so policy stays in the CLI and this module stays free of system-Lua deps.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end
local json = require("boot.json")
local paths = require("boot.paths")
local download = require("boot.download")
local verify = require("boot.verify")
local update = require("boot.update")

local M = {}

-- Where the curated index is fetched from. Raw from the repo's default branch,
-- so the available-module list is not chained to a core release (spec §16.20:
-- module availability is decoupled from the host's own version). Overridable
-- via LOOMWORKS_MODULE_INDEX or the `module-index` config key; a local path or
-- file:// works as an offline mirror (and is what the tests use).
M.DEFAULT_INDEX_URL =
  "https://raw.githubusercontent.com/samienne/loomworks.nvim/master/modules.json"

local function index_url(opts)
  local u = (opts and opts.url)
    or paths.getenv("LOOMWORKS_MODULE_INDEX")
    or paths.read_config()["module-index"]
    or M.DEFAULT_INDEX_URL
  return u
end

--- A safe module name: it becomes a path component under the modules dir and
--- feeds rm_rf, so it must not contain a separator or `..` that could escape.
--- Must start alphanumeric, then only [A-Za-z0-9._-]; this also rules out ".",
--- "..", "", and dotfiles. Names come from an OVERRIDABLE index and from CLI
--- args, so neither is trusted (spec §16.20 trusts the artifact's hash, not its
--- name) — this is the deletion/traversal boundary.
--- @param name any
--- @return boolean
function M.valid_name(name)
  return type(name) == "string" and name:match("^%w[%w._-]*$") ~= nil
end

--- Validate the decoded index shape. Returns the index or nil, err.
local function validate_index(idx)
  if type(idx) ~= "table" then return nil, "module index is not an object" end
  if type(idx.modules) ~= "table" then
    return nil, "module index missing 'modules' object"
  end
  for name, e in pairs(idx.modules) do
    if not M.valid_name(name) then
      return nil, "index entry name '" .. tostring(name) .. "' is not a valid "
        .. "module name (letters, digits, '.', '_', '-'; must start alphanumeric)"
    end
    if type(e) ~= "table" then
      return nil, "index entry '" .. tostring(name) .. "' is not an object"
    end
    if type(e.url) ~= "string" or #e.url == 0 then
      return nil, "index entry '" .. tostring(name) .. "' missing string 'url'"
    end
    if type(e.sha256) ~= "string" or not e.sha256:match("^%x+$") then
      return nil, "index entry '" .. tostring(name) .. "' missing hex 'sha256'"
    end
    if type(e.version) ~= "string" or #e.version == 0 then
      return nil, "index entry '" .. tostring(name) .. "' missing string 'version'"
    end
    if type(e.api_version) ~= "number" then
      return nil, "index entry '" .. tostring(name) .. "' missing numeric 'api_version'"
    end
  end
  return idx
end

--- Fetch and validate the curated index. Returns the index table or nil, err.
--- @param opts? { url?: string }
function M.load_index(opts)
  local bytes, err = download.fetch(index_url(opts))
  if not bytes then return nil, "fetch module index: " .. tostring(err) end
  local decoded, derr = json.decode(bytes)
  if decoded == nil or decoded == json.null then
    return nil, "module index: " .. (derr or "empty")
  end
  return validate_index(decoded)
end

--- Look up one entry by name, tagging it with its own name. nil, err if absent.
--- @param idx table validated index
--- @param name string
function M.entry(idx, name)
  local e = idx.modules[name]
  if not e then
    return nil, "no module '" .. name .. "' in the index"
  end
  e.name = name
  return e
end

--- Whether an index entry is compatible with the running host's module
--- interface version (§8.0). Strict equality — no backwards compatibility.
--- @param entry table
--- @param host_api number the host's loomworks.api_versions.module
function M.compatible(entry, host_api)
  return entry.api_version == host_api
end

--- A human message for an incompatible entry, distinguishing "update the host"
--- from "the module has no compatible release yet" (spec §16.20).
--- @param entry table
--- @param host_api number
function M.incompatible_reason(entry, host_api)
  if entry.api_version > host_api then
    return string.format(
      "module '%s' needs host module interface v%d but this host provides v%d"
        .. " — update lw (`lw self-update`)",
      entry.name, entry.api_version, host_api)
  end
  return string.format(
    "module '%s' targets host module interface v%d but this host provides v%d"
      .. " — the module has no release compatible with this host yet",
    entry.name, entry.api_version, host_api)
end

--- The single top-level directory a GitHub archive wraps everything in
--- (e.g. `<repo>-<tag>/`). Returns its absolute path or nil, err.
local function sole_top_dir(stage)
  local scan = uv.fs_scandir(stage)
  local only
  if scan then
    while true do
      local name, typ = uv.fs_scandir_next(scan)
      if not name then break end
      local is_dir = typ == "directory"
        or (uv.fs_stat(stage .. "/" .. name) or {}).type == "directory"
      if not is_dir then
        return nil, "archive has an unexpected top-level file '" .. name .. "'"
      end
      if only then return nil, "archive has more than one top-level directory" end
      only = stage .. "/" .. name
    end
  end
  if not only then return nil, "archive is empty" end
  return only
end

--- Install (or reinstall) a module from its index entry (spec §16.20). The
--- artifact is verified against `entry.sha256` before any of its Lua lands on
--- disk; a mismatch installs nothing. Does NOT gate on interface version — the
--- caller does that (via M.compatible) so it can shape the message.
--- @param entry table index entry (with .name)
--- @return table|nil result { name, version, dir }, string|nil err
function M.install(entry)
  -- Defense in depth: entry.name is used to build install/scratch paths. It is
  -- an index key (validated in validate_index) but re-check here so install can
  -- never construct a path outside modules_dir even if called directly.
  if not M.valid_name(entry and entry.name) then
    return nil, "refusing to install: unsafe module name '"
      .. tostring(entry and entry.name) .. "'"
  end
  local base = paths.modules_dir()
  local ok, err = paths.mkdirp(base)
  if not ok then return nil, "prepare modules dir: " .. tostring(err) end

  local tmpzip = base .. "/.dl-" .. entry.name .. ".zip"
  local okd, ed = download.fetch_to_file(entry.url, tmpzip)
  if not okd then return nil, "fetch module: " .. tostring(ed) end

  local bytes, re = verify.read_file(tmpzip)
  if not bytes then paths.rm_rf(tmpzip); return nil, "read download: " .. tostring(re) end
  local got = verify.sha256_hex(bytes)
  if got:lower() ~= entry.sha256:lower() then
    paths.rm_rf(tmpzip)
    return nil, string.format(
      "sha256 mismatch for module '%s' (expected %s, got %s) — refusing to install",
      entry.name, entry.sha256:lower(), got:lower())
  end

  local stage = base .. "/.stage-" .. entry.name
  paths.rm_rf(stage)
  local okx, ex = update.extract_zip(tmpzip, stage)
  paths.rm_rf(tmpzip)
  if not okx then paths.rm_rf(stage); return nil, "extract: " .. tostring(ex) end

  local top, te = sole_top_dir(stage)
  if not top then paths.rm_rf(stage); return nil, te end
  local src_lua = top .. "/lua"
  if not uv.fs_stat(src_lua) then
    paths.rm_rf(stage)
    return nil, "module archive has no `lua/` tree (not a loomworks module package)"
  end

  -- Activate: keep only the shipped `lua/` tree, swap it into place. Remove any
  -- prior install of the same name first; a rename is atomic on the one
  -- filesystem under modules_dir. A running invocation resolved its modules at
  -- startup, so replacing on disk never disturbs in-flight code.
  local dest = base .. "/" .. entry.name
  paths.rm_rf(dest)
  local okm, em = paths.mkdirp(dest)
  if not okm then paths.rm_rf(stage); return nil, "prepare install dir: " .. tostring(em) end
  local okr, er = uv.fs_rename(src_lua, dest .. "/lua")
  if not okr then
    paths.rm_rf(stage); paths.rm_rf(dest)
    return nil, "activate: " .. tostring(er)
  end
  paths.rm_rf(stage)

  -- Record what we installed, for `lw module list` and update checks.
  local meta = {
    name = entry.name,
    version = entry.version,
    api_version = entry.api_version,
    sha256 = entry.sha256:lower(),
    url = entry.url,
    repo = entry.repo,
    brings = entry.brings,
  }
  local mf = io.open(dest .. "/.module.json", "w")
  if mf then mf:write(json.encode(meta)); mf:close() end

  return { name = entry.name, version = entry.version, dir = dest }
end

--- Remove an installed module. Returns true (also when not installed — removal
--- is idempotent), or nil, err.
--- @param name string
function M.remove(name)
  -- `name` feeds directly into an rm_rf path; a separator or `..` here could
  -- delete outside the modules dir. Reject anything that isn't a plain name.
  if not M.valid_name(name) then
    return nil, "unsafe module name '" .. tostring(name) .. "'"
  end
  local dir = paths.modules_dir() .. "/" .. name
  if not uv.fs_stat(dir) then return true end
  local ok, err = paths.rm_rf(dir)
  if not ok then return nil, tostring(err) end
  return true
end

--- Merge the index (available) with what is installed on disk, for `lw module
--- list`. Returns an array sorted by name:
---   { name, description?, available?, installed?, api_version, compatible }
--- `available` is the index entry (nil if the index no longer lists it);
--- `installed` is the on-disk meta (nil if not installed).
--- @param idx table|nil validated index (nil → offline / index unavailable)
--- @param host_api number
function M.status(idx, host_api)
  local by_name = {}
  local function slot(name)
    if not by_name[name] then by_name[name] = { name = name }; end
    return by_name[name]
  end

  if idx then
    for name, e in pairs(idx.modules) do
      e.name = name
      local s = slot(name)
      s.available = e
      s.description = e.description
      s.api_version = e.api_version
      s.compatible = M.compatible(e, host_api)
    end
  end
  for _, m in ipairs(paths.installed_modules()) do
    local s = slot(m.name)
    s.installed = m.meta
    s.description = s.description or (m.meta and m.meta.description)
    if s.api_version == nil and m.meta then s.api_version = m.meta.api_version end
  end

  local out = {}
  for _, s in pairs(by_name) do out[#out + 1] = s end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

return M

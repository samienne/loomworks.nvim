-- Release acquisition / self-update for the host bootstrap (spec §16.13).
--
-- Flow: fetch manifest.json + manifest.json.sig -> verify signature -> check
-- host compatibility -> download the bundle zip -> verify its hash against the
-- (trusted) manifest -> extract to a staging dir -> atomically rename into
-- `<data>/loomworks/lua-<version>/`. A running invocation's code is never
-- overwritten, and a failed download leaves the previous bundle intact.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end
local miniz = require("miniz")
local paths = require("boot.paths")
local verify = require("boot.verify")
local download = require("boot.download")

local M = {}

-- Where releases are fetched from. PLACEHOLDER — the real owner/repo is wired
-- in at release time (S4). Overridable via LOOMWORKS_RELEASE_URL or the
-- `release-url` config key; a local directory works as an offline mirror.
M.DEFAULT_RELEASE_URL = "https://github.com/OWNER/loomworks.nvim/releases/latest/download"

local function release_base(opts)
  local base = (opts and opts.url)
    or paths.getenv("LOOMWORKS_RELEASE_URL")
    or paths.read_config()["release-url"]
    or M.DEFAULT_RELEASE_URL
  return (base:gsub("/+$", ""))
end

--- Extract the zip at `zip_path` into `dest_dir` (created). Rejects unsafe
--- entry names (path traversal / absolute). Returns true or nil, err.
function M.extract_zip(zip_path, dest_dir)
  local reader = miniz.new_reader(zip_path)
  if not reader then return nil, "'" .. zip_path .. "' is not a valid zip" end
  local ok, err = paths.mkdirp(dest_dir)
  if not ok then return nil, err end
  for i = 1, reader:get_num_files() do
    local name = reader:get_filename(i)
    if name:find("%.%.", 1, true) or name:match("^/") or name:match("^%a:") then
      return nil, "unsafe zip entry '" .. name .. "'"
    end
    local target = dest_dir .. "/" .. name
    if reader:is_directory(i) then
      local mok, merr = paths.mkdirp(target)
      if not mok then return nil, merr end
    else
      local parent = target:match("^(.*)/[^/]*$")
      if parent then
        local mok, merr = paths.mkdirp(parent)
        if not mok then return nil, merr end
      end
      local data = reader:extract(i)
      if data == nil then return nil, "failed to extract '" .. name .. "'" end
      local f, oe = io.open(target, "wb")
      if not f then return nil, "cannot write '" .. target .. "': " .. tostring(oe) end
      f:write(data); f:close()
    end
  end
  return true
end

--- Remove installed releases beyond the `keep` newest (never touches the
--- version named in `except`). Best-effort.
function M.gc(keep, except)
  local rels = paths.installed_releases()
  for i = (keep or 3) + 1, #rels do
    if rels[i].ver ~= except then paths.rm_rf(rels[i].dir) end
  end
end

--- Acquire/activate the current release. opts: { url?, force? }.
--- Returns { version, updated, dir } or nil, err.
function M.self_update(opts)
  opts = opts or {}
  local base = release_base(opts)

  local mbytes, e1 = download.fetch(base .. "/manifest.json")
  if not mbytes then return nil, "fetch manifest: " .. e1 end
  local sig, e2 = download.fetch(base .. "/manifest.json.sig")
  if not sig then return nil, "fetch signature: " .. e2 end

  local manifest, e3 = verify.load_manifest(mbytes, sig)
  if not manifest then return nil, e3 end
  local okh, eh = verify.host_compatible(manifest)
  if not okh then return nil, eh end

  local bundle_name = manifest.bundle
  if type(bundle_name) ~= "string" or not (manifest.artifacts or {})[bundle_name] then
    return nil, "manifest does not name a valid 'bundle' artifact"
  end

  local version = manifest.version
  local dest_dir = paths.data_dir() .. "/lua-" .. version
  if uv.fs_stat(dest_dir) and not opts.force then
    return { version = version, updated = false, dir = dest_dir }
  end

  local ok, err = paths.mkdirp(paths.data_dir())
  if not ok then return nil, "prepare data dir: " .. tostring(err) end

  local tmpzip = paths.data_dir() .. "/.dl-" .. version .. ".zip"
  local okd, ed = download.fetch_to_file(base .. "/" .. bundle_name, tmpzip)
  if not okd then return nil, "fetch bundle: " .. ed end

  local okv, ev = verify.verify_artifact_file(tmpzip, bundle_name, manifest)
  if not okv then paths.rm_rf(tmpzip); return nil, "bundle verify: " .. ev end

  local stage = paths.data_dir() .. "/.stage-" .. version
  paths.rm_rf(stage)
  local okx, ex = M.extract_zip(tmpzip, stage)
  paths.rm_rf(tmpzip)
  if not okx then paths.rm_rf(stage); return nil, "extract: " .. ex end

  -- Activate: swap staging dir into place. Remove any prior same-version dir
  -- first (force/re-install); a different running invocation uses a different
  -- version dir, so this never clobbers in-use code.
  if uv.fs_stat(dest_dir) then paths.rm_rf(dest_dir) end
  local okr, er = uv.fs_rename(stage, dest_dir)
  if not okr then paths.rm_rf(stage); return nil, "activate: " .. tostring(er) end

  M.gc(3, version)
  return { version = version, updated = true, dir = dest_dir }
end

--- Describe the resolved runtime for `lw version`.
function M.version_info(luaroot, source_kind)
  local bundle
  if source_kind == "dev" then
    bundle = "dev (" .. (luaroot or "?") .. ")"
  elseif source_kind == "release" and luaroot then
    bundle = luaroot:match("lua%-(.+)$") or "?"
  else
    bundle = "bundled (fused)"
  end
  return {
    host_version = verify.HOST_VERSION,
    source = source_kind or "fused",
    bundle = bundle,
    luaroot = luaroot,
  }
end

return M

-- Release acquisition / self-update for the host bootstrap.
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
local pin = require("boot.pin")
local json = require("boot.json")

local M = {}

--- Is `h` a SHA-256 hex digest?
local function is_sha256(h)
  return type(h) == "string" and #h == 64 and h:match("^%x+$") ~= nil
end

-- Where releases are fetched from. Overridable via LOOMWORKS_RELEASE_URL or
-- the `release-url` config key; a local directory works as an offline mirror.
-- `/releases/latest/download` already resolves to the newest NON-prerelease on
-- GitHub, so this base IS the `stable` channel (§16.29).
M.DEFAULT_RELEASE_URL = "https://github.com/samienne/loomworks.nvim/releases/latest/download"

-- The releases API for the default origin. Consulted ONLY to resolve the
-- `unstable` channel (§16.29): the newest release INCLUDING pre-releases. Never
-- queried for `stable`, nor when a release-source override / mirror is set —
-- the channel governs only the default origin.
M.RELEASES_API_URL = "https://api.github.com/repos/samienne/loomworks.nvim/releases"

-- The update channels this host knows (§16.29). `stable` (default) is unchanged
-- behavior; `unstable` follows pre-releases too. Both verify identically.
M.CHANNELS = { stable = true, unstable = true }
M.DEFAULT_CHANNEL = "stable"

local function release_base(opts)
  local base = (opts and opts.url)
    or paths.getenv("LOOMWORKS_RELEASE_URL")
    or paths.read_config()["release-url"]
    or M.DEFAULT_RELEASE_URL
  return (base:gsub("/+$", ""))
end

--- The `latest`/override release base (holds manifest.json + `latest` assets).
function M.release_base(opts) return release_base(opts) end

--- The user-supplied release-source override (opts.url > LOOMWORKS_RELEASE_URL >
--- `release-url` config), or nil when the default origin is in effect. An
--- override is a mirror used as-is and SUPERSEDES channel resolution (§16.29):
--- the channel governs only the default origin. Public so `lw health` can
--- surface the "channel is being overridden" state (§16.31) without reimplementing
--- the precedence.
function M.url_override(opts)
  return (opts and opts.url)
    or paths.getenv("LOOMWORKS_RELEASE_URL")
    or paths.read_config()["release-url"]
end
local url_override = M.url_override

--- Resolve the active update channel (§16.29) with precedence: explicit
--- opts.channel > LOOMWORKS_CHANNEL env > `channel` config key > default
--- (stable). Returns the channel name, or nil + err for an unknown value.
--- @return string|nil channel, string|nil err
function M.resolve_channel(opts)
  local c = (opts and opts.channel)
    or paths.getenv("LOOMWORKS_CHANNEL")
    or paths.read_config()["channel"]
    or M.DEFAULT_CHANNEL
  if not M.CHANNELS[c] then
    return nil, "unknown update channel '" .. tostring(c) ..
      "' (expected 'stable' or 'unstable')"
  end
  return c
end

--- Resolve the newest release version for the `unstable` channel (§16.29) by
--- querying the releases API. The newest NON-DRAFT entry wins — pre-releases are
--- INCLUDED (that is what `unstable` means). Returns the version (leading `v`
--- stripped) or nil, err.
---
--- SECURITY: the tag is network-derived, so it is validated with
--- pin.valid_version BEFORE it can reach any URL or path (defense in depth,
--- §16.29 / §16.23). Transport is never trusted — the bundle it names is still
--- signature/hash-verified downstream exactly as on stable.
--- `fetch_limits` (optional) is passed to `download.fetch` — the health check's
--- quick timeouts; self-update calls it without, keeping the default retries.
--- @param fetch_limits? { connect_timeout?: integer, max_time?: integer, attempts?: integer }
--- @return string|nil version, string|nil err
function M.resolve_unstable_version(fetch_limits)
  local fopts = {
    headers = { "Accept: application/vnd.github+json", "User-Agent: loomworks-lw" },
  }
  for k, v in pairs(fetch_limits or {}) do fopts[k] = v end
  local body, e = download.fetch(M.RELEASES_API_URL, fopts)
  if not body then return nil, "fetch releases: " .. tostring(e) end
  local releases, derr = json.decode(body)
  if type(releases) ~= "table" then
    return nil, "releases API: " .. (derr or "unexpected response")
  end
  -- The API returns releases newest-first; take the newest that is not a draft.
  for _, rel in ipairs(releases) do
    if type(rel) == "table" and rel.draft ~= true and type(rel.tag_name) == "string" then
      local ver = (rel.tag_name:gsub("^v", ""))
      if not pin.valid_version(ver) then
        return nil, "releases API returned an unsafe version '" ..
          tostring(rel.tag_name) .. "'"
      end
      return ver
    end
  end
  return nil, "no releases found on the unstable channel"
end

--- Resolve the newest AVAILABLE release version for the resolved channel, WITHOUT
--- downloading (or verifying) a bundle — the version-availability probe behind
--- `lw health`'s update check (§16.31). It performs exactly one lightweight
--- network fetch: the releases API on `unstable` (reusing resolve_unstable_version),
--- else `manifest.json` from the `latest`/override base to read the version it
--- names. It never fetches or executes a bundle, so it applies NO integrity
--- verification — a real self-update still verifies signature + hash (§16.12). All
--- failures (offline, HTTP error, malformed body) are returned as `nil, err` so the
--- caller can degrade silently.
---
--- SECURITY: the resolved version is network-derived, so it is validated with
--- pin.valid_version before it is handed back (defense in depth, §16.29). It is
--- only ever displayed/compared here — never interpolated into a URL or path.
---
--- `opts.fetch` (curl limits, see `download.fetch`) bounds the one fetch; the
--- health check passes quick timeouts so an unreachable network cannot stall
--- `lw health` (§16.31). A local/mirror base is a file read and ignores it.
--- @return string|nil version, string|nil err
function M.resolve_newest_version(opts)
  opts = opts or {}
  local channel, cerr = M.resolve_channel(opts)
  if not channel then return nil, cerr end
  -- `unstable` on the default origin: newest incl. pre-releases via the API. A
  -- mirror/override supersedes the channel (§16.29) and is peeked like stable.
  if channel == "unstable" and not url_override(opts) then
    return M.resolve_unstable_version(opts.fetch)
  end
  -- `stable`, or an override mirror: the version is whatever the base's
  -- manifest.json names — reachable without downloading the bundle.
  local base = release_base(opts)
  local mbytes, e = download.fetch(base .. "/manifest.json", opts.fetch)
  if not mbytes then return nil, "fetch manifest: " .. tostring(e) end
  local manifest, de = json.decode(mbytes)
  if type(manifest) ~= "table" or type(manifest.version) ~= "string" then
    return nil, "manifest: " .. (de or "no version")
  end
  if not pin.valid_version(manifest.version) then
    return nil, "manifest named an unsafe version '" .. tostring(manifest.version) .. "'"
  end
  return manifest.version
end

--- Is `base` a local path / offline mirror (flat layout) rather than the
--- versioned GitHub origin? Mirrors boot.download's scheme test.
local function is_local_base(base)
  local scheme = base:match("^(%a[%w+.-]*)://")
  if scheme == "file" then return true end
  if not scheme then return true end
  return false
end

--- The base URL holding a SPECIFIC version's assets. The default GitHub origin
--- serves them under a versioned path (…/releases/download/v<ver>/); a local or
--- overridden mirror is flat — the version's assets sit at the base directly, as
--- self_update already assumes. So the pin's per-version fetches resolve on
--- GitHub and against an offline mirror alike.
function M.versioned_base(version, opts)
  -- Defense in depth: never interpolate an unvalidated version into a URL.
  if not pin.valid_version(version) then
    error("unsafe release version: " .. tostring(version))
  end
  local base = release_base(opts)
  if not is_local_base(base) then
    local root = base:match("^(.-)/releases/latest/download$")
    if root then return root .. "/releases/download/v" .. version end
  end
  return base
end

--- Ensure the host binary `asset` for `version` is cached at `dest`, verified
--- against the pinned `sha256` (mandatory, unconditional). Idempotent: a present
--- file whose hash matches is reused; a mismatch deletes the bad file. Reuses
--- boot.download + boot.verify + rename_with_retry. Returns true, dest or nil, err.
function M.ensure_host_binary(version, asset, sha256, dest, opts)
  if not pin.valid_version(version) then
    return nil, "unsafe release version '" .. tostring(version) .. "'"
  end
  if not is_sha256(sha256) then
    return nil, "no pinned sha256 for '" .. tostring(asset) .. "'"
  end
  if uv.fs_stat(dest) and verify.verify_file_sha256(dest, sha256) then
    return true, dest
  end
  paths.rm_rf(dest)
  local parent = dest:match("^(.*)/[^/]*$")
  if parent then
    local ok, err = paths.mkdirp(parent)
    if not ok then return nil, "prepare cache dir: " .. tostring(err) end
  end
  local tmp = dest .. ".dl"
  paths.rm_rf(tmp)
  local url = M.versioned_base(version, opts) .. "/" .. asset
  local okd, ed = download.fetch_to_file(url, tmp)
  if not okd then paths.rm_rf(tmp); return nil, "fetch " .. asset .. ": " .. ed end
  local okv, ev = verify.verify_file_sha256(tmp, sha256)
  if not okv then paths.rm_rf(tmp); return nil, "verify " .. asset .. ": " .. (ev or "mismatch") end
  local okr, er = M.rename_with_retry(tmp, dest)
  if not okr then paths.rm_rf(tmp); return nil, "activate " .. asset .. ": " .. tostring(er) end
  if not paths.is_windows then pcall(uv.fs_chmod, dest, tonumber("755", 8)) end
  return true, dest
end

--- The machine-local directory for everything a pinned run provisions:
--- `<data>/loomworks/pinned` (spec §16.22). Never inside a repository — a
--- clone can ship any file under its own tree, so nothing there is trusted.
function M.pinned_root() return paths.data_dir() .. "/pinned" end

--- Where the pinned bundle for (`version`, pinned bundle `sha256`) lives:
--- `<data>/pinned/<sha256>/lua-<version>`. Keyed by the pinned hash, so a pin
--- naming a different hash never reuses a directory provisioned (verified)
--- for another; the `lua-<version>` tail keeps the version derivable from the
--- root like every other release root.
function M.pinned_bundle_dir(version, sha256)
  return M.pinned_root() .. "/" .. tostring(sha256):lower() .. "/lua-" .. version
end

--- Where the global host caches a pinned host binary it redirects to (§16.23):
--- `<data>/pinned/lw-<version>-<asset>`. Re-verified against the pin on every use.
function M.pinned_binary_path(version, asset)
  return M.pinned_root() .. "/lw-" .. version .. "-" .. asset
end

--- Provision the pinned release bundle for `version` into the MACHINE-LOCAL
--- pinned cache (`pinned_bundle_dir`), verified against the pinned
--- `opts.bundle_sha256`. Idempotent (a bundle this function already extracted
--- and verified is reused); a failed/partial provision leaves prior state
--- intact. The directory is only ever populated here, after the download from
--- the fixed origin matched the pinned hash, so reusing it by presence is
--- sound. A repository's own `.nvim/cache` is never consulted: a clone can
--- ship a pre-"extracted" bundle there. Returns the lua-root or nil, err.
--- (`opts.root`, the pin root, is accepted for callers but no longer used.)
function M.ensure_version(version, opts)
  opts = opts or {}
  -- Trust boundary: `version` becomes an rm_rf'd path below, so refuse a
  -- traversal before touching the filesystem.
  if not pin.valid_version(version) then
    return nil, "unsafe release version '" .. tostring(version) .. "'"
  end
  local bundle = "loomworks-lua-" .. version .. ".zip"
  local sha = opts.bundle_sha256
  if not is_sha256(sha) then
    return nil, "no pinned sha256 for '" .. bundle .. "'"
  end
  sha = sha:lower()
  local dest = M.pinned_bundle_dir(version, sha)
  -- Already provisioned by us? The CLI entry existing is the marker.
  if uv.fs_stat(dest .. "/loomworks/cli.lua") then return dest end

  local cache = M.pinned_root()
  local okm, em = paths.mkdirp(cache .. "/" .. sha)
  if not okm then return nil, "prepare pinned cache dir: " .. tostring(em) end

  local tmpzip = cache .. "/.dl-" .. sha .. "-" .. version .. ".zip"
  paths.rm_rf(tmpzip)
  local url = M.versioned_base(version, opts) .. "/" .. bundle
  local okd, ed = download.fetch_to_file(url, tmpzip)
  if not okd then paths.rm_rf(tmpzip); return nil, "fetch bundle: " .. ed end
  local okv, ev = verify.verify_file_sha256(tmpzip, sha)
  if not okv then paths.rm_rf(tmpzip); return nil, "bundle verify: " .. (ev or "mismatch") end

  local stage = cache .. "/.stage-" .. sha .. "-" .. version
  paths.rm_rf(stage)
  local okx, ex = M.extract_zip(tmpzip, stage)
  paths.rm_rf(tmpzip)
  if not okx then paths.rm_rf(stage); return nil, "extract: " .. ex end
  if uv.fs_stat(dest) then paths.rm_rf(dest) end
  local okr, er = M.rename_with_retry(stage, dest)
  if not okr then paths.rm_rf(stage); return nil, "activate: " .. tostring(er) end
  return dest
end

--- List every regular file under `dir` as { [relative/path] = true }, or nil
--- when `dir` is not a directory.
local function list_tree(dir)
  local st = uv.fs_stat(dir)
  if not st or st.type ~= "directory" then return nil end
  local out = {}
  local function walk(rel)
    local abs = rel == "" and dir or (dir .. "/" .. rel)
    local req = uv.fs_scandir(abs)
    while req do
      local name, typ = uv.fs_scandir_next(req)
      if not name then break end
      local r = rel == "" and name or (rel .. "/" .. name)
      typ = typ or ((uv.fs_stat(abs .. "/" .. name) or {}).type)
      if typ == "directory" then walk(r) else out[r] = true end
    end
  end
  walk("")
  return out
end

local function read_bytes(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end

--- Guard for a redirect to a pinned release whose host predates machine-local
--- provisioning: such a host still loads its bundle from the repository's
--- `<pin root>/.nvim/cache/lua-<version>/` when that directory exists. Before
--- exec'ing it, the redirecting host compares that directory with the bundle it
--- verified itself (`verified_dir`): absent, or byte-for-byte the same file
--- tree, is fine; anything else (a planted or modified bundle) is refused. It
--- never deletes anything in the repository. Returns true or nil, err.
--- @param legacy_dir string
--- @param verified_dir string
function M.check_legacy_pinned_bundle(legacy_dir, verified_dir)
  local got = list_tree(legacy_dir)
  if not got then
    if uv.fs_stat(legacy_dir) then
      return nil, legacy_dir .. " exists but is not a directory"
    end
    return true
  end
  local want = list_tree(verified_dir)
  if not want then return nil, "verified bundle missing at " .. verified_dir end
  local mismatch = function(rel, why)
    return nil, legacy_dir .. " does not match the pinned release (" .. rel .. ": " .. why ..
      "); it is a cache — delete it and re-run"
  end
  for rel in pairs(got) do
    if not want[rel] then return mismatch(rel, "not part of the release") end
  end
  for rel in pairs(want) do
    if not got[rel] then return mismatch(rel, "missing") end
    if read_bytes(legacy_dir .. "/" .. rel) ~= read_bytes(verified_dir .. "/" .. rel) then
      return mismatch(rel, "content differs")
    end
  end
  return true
end

--- Extract the zip at `zip_path` into `dest_dir` (created). Rejects unsafe
--- entry names (path traversal / absolute). Returns true or nil, err.
function M.extract_zip(zip_path, dest_dir)
  local reader = miniz.new_reader(zip_path)
  if not reader then return nil, "'" .. zip_path .. "' is not a valid zip" end

  -- Single exit so the reader handle is always released before we return.
  -- miniz's reader has no close method and keeps the archive file mmapped/open
  -- until it is garbage-collected; on Windows an open handle turns a later
  -- unlink of `zip_path` into a lingering "delete pending" file that can't be
  -- rewritten (Permission denied) — which bites callers that reuse a
  -- deterministic archive path (e.g. `lw module` reinstalling the same name).
  -- Dropping the reference and forcing a collection here is the "close".
  local err
  local ok = paths.mkdirp(dest_dir)
  if not ok then err = "cannot create '" .. dest_dir .. "'" end
  if ok then
    for i = 1, reader:get_num_files() do
      local name = reader:get_filename(i)
      if name:find("%.%.", 1, true) or name:match("^/") or name:match("^%a:")
          or name:match("^\\") then  -- also reject a leading backslash / UNC
        err = "unsafe zip entry '" .. name .. "'"; break
      end
      local target = dest_dir .. "/" .. name
      if reader:is_directory(i) then
        local mok, merr = paths.mkdirp(target)
        if not mok then err = merr; break end
      else
        local parent = target:match("^(.*)/[^/]*$")
        if parent then
          local mok, merr = paths.mkdirp(parent)
          if not mok then err = merr; break end
        end
        local data = reader:extract(i)
        if data == nil then err = "failed to extract '" .. name .. "'"; break end
        local f, oe = io.open(target, "wb")
        if not f then err = "cannot write '" .. target .. "': " .. tostring(oe); break end
        f:write(data); f:close()
      end
    end
  end

  reader = nil
  collectgarbage("collect")
  if err then return nil, err end
  return true
end

--- Rename `src` to `dst`, retrying transient Windows failures. Immediately
--- after extracting a bundle, Windows Defender (or the search indexer) often
--- holds a brief handle on a freshly written file, so `MoveFile` on the
--- directory fails with ACCESS_DENIED (EPERM/EACCES) or a sharing violation
--- (EBUSY). These clear once the scan finishes, so back off and retry rather
--- than aborting the whole self-update. Returns true, or false + last error.
--- @param src string
--- @param dst string
--- @param opts? { rename?: fun(a:string,b:string):boolean|nil, sleep?: fun(ms:integer), attempts?: integer }
function M.rename_with_retry(src, dst, opts)
  opts = opts or {}
  local rename = opts.rename or uv.fs_rename
  local sleep = opts.sleep or (uv.sleep and function(ms) uv.sleep(ms) end) or function() end
  local attempts = opts.attempts or 15
  local last
  for i = 1, attempts do
    local ok, err = rename(src, dst)
    if ok then return true end
    last = err
    if i < attempts then sleep(math.min(60 * i, 400)) end
  end
  return false, last
end

--- Remove installed releases beyond the `keep` newest (never touches the
--- version named in `except`). Best-effort.
function M.gc(keep, except)
  local rels = paths.installed_releases()
  for i = (keep or 3) + 1, #rels do
    if rels[i].ver ~= except then paths.rm_rf(rels[i].dir) end
  end
end

--- Acquire/activate the current release. opts: { url?, force?, channel? }.
--- The channel (§16.29) selects WHICH release an un-pinned, un-overridden fetch
--- targets; it never weakens verification. Returns
--- { version, updated, dir, channel_overridden } or nil, err[, info].
--- `channel_overridden` is the requested channel name when a release-url
--- override superseded a non-default channel (nil otherwise) — for the caller
--- to surface as a warning. `info` is set only when the (verified) release
--- needs a newer host than this one — { version, host_incompatible = true } —
--- so the caller can update the host binary first (§16.32).
--- @param opts? { url?: string, force?: boolean, channel?: string }
--- @return { version: string, updated: boolean, dir: string, channel_overridden?: string }|nil result
--- @return string|nil err
--- @return { version: string, host_incompatible: boolean }|nil info
function M.self_update(opts)
  opts = opts or {}
  local channel, cerr = M.resolve_channel(opts)
  if not channel then return nil, cerr end

  local base = release_base(opts)
  -- A release-url override supersedes the channel (§16.29): it is used as-is and
  -- the channel (which governs only the default origin) is ignored. That is by
  -- design, but silent it misleads — a user who passed `--channel unstable`
  -- believes it applied. So when a NON-DEFAULT channel intent is present AND an
  -- override is in effect, report the superseded channel for the caller to warn.
  -- (`stable` == the override's own behavior, so it is no conflict — no report.)
  local channel_overridden = (channel ~= M.DEFAULT_CHANNEL and url_override(opts))
    and channel or nil
  -- `unstable` on the default origin resolves the newest release (pre-releases
  -- included) via the API, then fetches that version's assets from its versioned
  -- path. A mirror/override supersedes the channel (§16.29): it is used as-is and
  -- the API is never called. `stable` keeps the /latest/download base unchanged.
  if channel == "unstable" and not url_override(opts) then
    local ver, verr = M.resolve_unstable_version()
    if not ver then return nil, verr end
    base = M.versioned_base(ver, opts)
  end

  local mbytes, e1 = download.fetch(base .. "/manifest.json")
  if not mbytes then return nil, "fetch manifest: " .. e1 end
  local sig, e2 = download.fetch(base .. "/manifest.json.sig")
  if not sig then return nil, "fetch signature: " .. e2 end

  local manifest, e3 = verify.load_manifest(mbytes, sig)
  if not manifest then return nil, e3 end
  local okh, eh = verify.host_compatible(manifest)
  if not okh then
    -- Don't strand the host (§16.32): the manifest is already signature-
    -- verified, so hand its release back as a host-update target — the caller
    -- replaces the lw binary (when allowed) and asks for a re-run.
    return nil, eh, { version = manifest.version, host_incompatible = true }
  end

  local bundle_name = manifest.bundle
  if type(bundle_name) ~= "string" or not (manifest.artifacts or {})[bundle_name] then
    return nil, "manifest does not name a valid 'bundle' artifact"
  end

  local version = manifest.version
  local dest_dir = paths.data_dir() .. "/lua-" .. version
  if uv.fs_stat(dest_dir) and not opts.force then
    return { version = version, updated = false, dir = dest_dir,
      channel_overridden = channel_overridden }
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
  local okr, er = M.rename_with_retry(stage, dest_dir)
  if not okr then paths.rm_rf(stage); return nil, "activate: " .. tostring(er) end

  M.gc(3, version)
  return { version = version, updated = true, dir = dest_dir,
    channel_overridden = channel_overridden }
end

--- The one-line `lw version` report. The host's release version (spec §16.32)
--- leads, with the capability version (§16.14) in parentheses. A host with no
--- embedded release version never guesses one: it is `dev build` when it IS a
--- development build (`info.dev_build`, from host_update.dev_build — the same
--- predicate self-update uses), else `unknown release` (a release host built
--- before version identity existed, which self-update does replace).
--- @param info { host_version: integer, release_version?: string, dev_build?: boolean, source: string, bundle: string }
--- @param channel string the resolved update channel
--- @return string line
function M.version_line(info, channel)
  local label = info.release_version
    or (info.dev_build and "dev build" or "unknown release")
  local host = label .. " (v" .. info.host_version .. ")"
  return string.format("lw — host: %s · source: %s · bundle: %s · channel: %s",
    host, info.source, info.bundle, channel)
end

--- Describe the resolved runtime for `lw version`.
--- With no on-disk source, system Lua can only come from the host itself: it
--- is `fused` when the host really carries it (a dev build / source run,
--- `opts.fused_system_lua`); otherwise nothing is installed — a release host
--- before its first `lw self-update` — and the report says so rather than
--- claiming a bundle every other command would then fail to find.
--- @param luaroot string|nil the resolved system-Lua root
--- @param source_kind "dev"|"release"|nil the system-Lua source
--- @param opts? { dev_build?: boolean, fused_system_lua?: boolean } whether the host is a development build (host_update.dev_build) / carries system Lua fused in
--- @return { host_version: integer, release_version: string|nil, dev_build: boolean, source: string, bundle: string, luaroot: string|nil }
function M.version_info(luaroot, source_kind, opts)
  local bundle, source = nil, source_kind
  if source_kind == "dev" then
    bundle = "dev (" .. (luaroot or "?") .. ")"
  elseif source_kind == "release" and luaroot then
    bundle = luaroot:match("lua%-(.+)$") or "?"
  elseif opts and opts.fused_system_lua then
    bundle, source = "bundled (fused)", "fused"
  else
    bundle, source = "none installed (run `lw self-update`)", "none"
  end
  return {
    host_version = verify.HOST_VERSION,
    -- The host's embedded release version (spec §16.32); nil = a dev build or
    -- a release host from before version identity (told apart by dev_build).
    release_version = verify.RELEASE_VERSION,
    dev_build = (opts and opts.dev_build) and true or false,
    source = source,
    bundle = bundle,
    luaroot = luaroot,
  }
end

return M

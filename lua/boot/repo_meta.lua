-- Repository metadata for the repo-local launcher (spec §16.24): the ignore
-- rule for the launcher cache, the line-ending attributes of lw.sh / lw.cmd /
-- lw.pin, the executable bit of lw.sh, and pruning of old cached host
-- binaries. Used by `lw bootstrap` / `lw update` (boot.bootstrap); runs in the
-- host (luv only — never the vim shim). The pure rules and git-output parsers
-- live in boot.launcher, shared with the health provider.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end
local launcher = require("boot.launcher")
local pin = require("boot.pin")

local M = {}

M.is_windows = package.config:sub(1, 1) == "\\"

-- Environment for every git query: never lock/refresh the index for a read,
-- never prompt.
local GIT_ENV = { GIT_OPTIONAL_LOCKS = "0", GIT_TERMINAL_PROMPT = "0", LC_ALL = "C" }

--- Per-query timeout (ms).
M.GIT_TIMEOUT_MS = 10000

--- Run `git -C <cwd> <args...>`. Repository-local configuration must not run
--- commands on lw's behalf (spec §17.8): no fsmonitor hook, no hooks path.
--- Returns code, stdout, stderr — or nil, err when git cannot be run.
--- Test seam: M._git.
function M._git(cwd, args, opts)
  opts = opts or {}
  local git = require("boot.exe").resolve("git")
  if not git then return nil, "git not found" end
  local argv = { "-c", "core.fsmonitor=false", "-c", "core.hooksPath=", "-C", cwd }
  for _, a in ipairs(args) do argv[#argv + 1] = a end
  local env = {}
  local environ = uv.os_environ and uv.os_environ() or {}
  for k, v in pairs(environ) do
    if GIT_ENV[k:upper()] == nil then env[#env + 1] = k .. "=" .. v end
  end
  for k, v in pairs(GIT_ENV) do env[#env + 1] = k .. "=" .. v end
  local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
  local out, err, code, done = {}, {}, nil, false
  local handle
  handle = uv.spawn(git, { args = argv, env = env, stdio = { nil, stdout, stderr } },
    function(c) code = c; done = true end)
  if not handle then
    stdout:close(); stderr:close()
    return nil, "cannot run git"
  end
  stdout:read_start(function(_, d) if d then out[#out + 1] = d end end)
  stderr:read_start(function(_, d) if d then err[#err + 1] = d end end)
  local timer = uv.new_timer()
  local timed_out = false
  timer:start(opts.timeout or M.GIT_TIMEOUT_MS, 0, function()
    timed_out = true
    pcall(function() handle:kill("sigterm") end)
  end)
  while not done and not timed_out do uv.run("once") end
  -- Drain what the pipes still hold after exit.
  for _ = 1, 20 do
    if stdout:is_closing() then break end
    if not uv.run("nowait") then break end
  end
  timer:stop(); timer:close()
  if not stdout:is_closing() then stdout:close() end
  if not stderr:is_closing() then stderr:close() end
  if not handle:is_closing() then handle:close() end
  if timed_out and not done then return nil, "git timed out" end
  return code, table.concat(out), table.concat(err)
end

local function git_ok(cwd, args)
  local code, out = M._git(cwd, args)
  if code == 0 then return out end
  return nil
end

--- The work tree top level containing `root`, or nil (not a repository / no git).
function M.toplevel(root)
  local out = git_ok(root, { "rev-parse", "--show-toplevel" })
  if not out then return nil end
  local top = out:match("^([^\r\n]+)")
  return top and (top:gsub("\\", "/"):gsub("/+$", "")) or nil
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end

local function lower_if_win(p)
  return M.is_windows and p:lower() or p
end

--- Is `path` equal to or strictly under `dir` (separator-bounded)?
local function under(path, dir)
  path, dir = lower_if_win(path), lower_if_win(dir)
  return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

--- Resolve `rel` against `base` (forward slashes, `..` collapsed).
local function join(base, rel)
  rel = rel:gsub("\\", "/")
  if rel:match("^%a:/") or rel:sub(1, 1) == "/" then return rel end
  local parts = {}
  for seg in (base .. "/" .. rel):gmatch("[^/]+") do
    if seg == ".." then parts[#parts] = nil
    elseif seg ~= "." then parts[#parts + 1] = seg end
  end
  local lead = base:sub(1, 1) == "/" and "/" or ""
  return lead .. table.concat(parts, "/")
end

--- Is the launcher cache ignored by one of the REPOSITORY's own ignore files
--- (a `.gitignore` inside the work tree)? Global excludes and
--- `.git/info/exclude` do not count: teammates and CI do not have them.
--- @return boolean|nil covered (nil: git could not answer)
function M.cache_ignored_by_repo(root, top)
  if not top then return nil end
  local code, out = M._git(root, { "-c", "core.excludesFile=", "check-ignore", "-v", "--no-index",
    "--", launcher.CACHE_DIR .. "/lw.marker" })
  if code == nil then return nil end
  if code ~= 0 then return false end
  local m = launcher.parse_check_ignore(out)
  if not m or m.pattern:sub(1, 1) == "!" then return false end
  -- git reports the source relative to the work-tree top (or absolute).
  local src = join(top, m.source)
  local base = src:match("([^/]+)$")
  return base == ".gitignore" and under(src, top) and not under(src, top .. "/.git")
end

--- Ensure the launcher cache is ignored by the repository (spec §16.24).
--- @return "present"|"covered"|"added"|nil status, string|nil err
function M.ensure_gitignore(root, top, write_file)
  local path = root .. "/.gitignore"
  local existing = read(path) or ""
  local covered = M.cache_ignored_by_repo(root, top)
  if covered == nil then covered = launcher.ignore_text_covers(existing) end
  if covered then
    return launcher.ignore_text_covers(existing) and "present" or "covered"
  end
  local addition = (existing ~= "" and existing:sub(-1) ~= "\n") and "\n" or ""
  addition = addition ..
    "\n# loomworks: pinned lw binaries (machine-local)\n" .. launcher.CACHE_DIR .. "/\n"
  local ok, e = write_file(path, existing .. addition)
  if not ok then return nil, e end
  return "added"
end

--- Effective line-ending attributes of the three files, ignoring the user's
--- global attributes file (not shared with others). nil when git cannot answer.
function M.effective_attrs(root, top)
  if not top then return nil end
  local args = { "-c", "core.attributesFile=", "check-attr", "text", "eol", "--" }
  for _, f in ipairs(launcher.FILES) do args[#args + 1] = f end
  local out = git_ok(root, args)
  return out and launcher.parse_check_attr(out) or nil
end

--- Ensure the attributes give each file its line ending (spec §16.24).
--- @return string[] appended files, string|nil problem, string|nil err
function M.ensure_gitattributes(root, top, write_file)
  local path = root .. "/.gitattributes"
  local existing = read(path) or ""
  local attrs = M.effective_attrs(root, top)
  local missing = {}
  for _, f in ipairs(launcher.FILES) do
    local good
    if attrs then good = launcher.attrs_ok(f, attrs[f]) else good = launcher.attr_text_has(existing, f) end
    if not good then missing[#missing + 1] = f end
  end
  if #missing == 0 then return {} end
  local add = (existing ~= "" and existing:sub(-1) ~= "\n") and "\n" or ""
  add = add .. "\n# loomworks: repo-local launcher line endings\n"
  for _, f in ipairs(missing) do add = add .. launcher.attr_line(f) .. "\n" end
  local ok, e = write_file(path, existing .. add)
  if not ok then return nil, nil, e end
  -- A later-precedence rule we cannot edit (.git/info/attributes) still wins.
  local after = M.effective_attrs(root, top)
  if after then
    local still = {}
    for _, f in ipairs(missing) do
      if not launcher.attrs_ok(f, after[f]) then still[#still + 1] = f end
    end
    if #still > 0 then
      return missing, "line-ending attributes for " .. table.concat(still, ", ") ..
        " are still overridden (check .git/info/attributes)"
    end
  end
  return missing
end

--- Make sure lw.sh is recorded executable (spec §16.24). Where git tracks the
--- bit through the file system the file mode was set on write; where it does
--- not (core.fileMode=false — Windows), the bit lives only in the index: add an
--- untracked lw.sh with +x, or set +x on a tracked one. The ONLY staging.
--- @return "staged"|"set"|nil action, string|nil problem
function M.ensure_exec_bit(root, top)
  if not top then return nil end
  local fm = git_ok(root, { "config", "--type=bool", "core.filemode" })
  local filemode = not (fm and fm:match("^%s*false"))
  local stage = git_ok(root, { "ls-files", "--stage", "--", "lw.sh" })
  if stage == nil then return nil, "could not read the git index for lw.sh" end
  local mode = launcher.parse_ls_stage(stage)["lw.sh"]
  if mode == "100755" then return nil end
  if mode == nil then
    if filemode then return nil end -- the file system carries the bit; `git add` records it
    local code, _, err = M._git(root, { "add", "--chmod=+x", "--", "lw.sh" })
    if code ~= 0 then return nil, "could not stage lw.sh as executable: " .. tostring(err or ""):gsub("%s+$", "") end
    return "staged"
  end
  local code, _, err = M._git(root, { "update-index", "--chmod=+x", "--", "lw.sh" })
  if code ~= 0 then return nil, "could not set lw.sh executable in the index: " .. tostring(err or ""):gsub("%s+$", "") end
  return "set"
end

--- Remove cached host binaries of versions other than `keep` from
--- `<root>/.nvim/cache` (spec §16.24). Confined: the cache dir and its `.nvim`
--- parent must be real directories (not links/junctions) under the root; only
--- regular files directly in it, named exactly `lw-<valid version>-<known
--- asset>`, never the pinned version's, never the running executable. A
--- failure (e.g. a binary still executing on Windows) is skipped silently.
--- @param root string pin root
--- @param keep string the pinned version to keep
--- @param running string|nil the running executable's path
--- @return integer removed, integer bytes
function M.prune_cache(root, keep, running)
  if type(root) ~= "string" or root == "" or type(keep) ~= "string" then return 0, 0 end
  root = root:gsub("\\", "/"):gsub("/+$", "")
  local nvim, dir = root .. "/.nvim", root .. "/" .. launcher.CACHE_DIR
  for _, d in ipairs({ nvim, dir }) do
    local st = uv.fs_lstat(d)
    if not st or st.type ~= "directory" then return 0, 0 end
  end
  -- Resolved, the cache must still lie under the resolved root.
  local rroot, rdir = uv.fs_realpath(root), uv.fs_realpath(dir)
  if not rroot or not rdir then return 0, 0 end
  rroot = rroot:gsub("\\", "/"):gsub("/+$", ""); rdir = rdir:gsub("\\", "/"):gsub("/+$", "")
  if rdir == rroot or not under(rdir, rroot) then return 0, 0 end

  local assets = {}
  for _, a in pairs(pin.HOST_ASSETS) do assets[#assets + 1] = a end
  local run = running and lower_if_win((running:gsub("\\", "/")))
  local handle = uv.fs_scandir(dir)
  if not handle then return 0, 0 end
  local removed, bytes = 0, 0
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    local v = launcher.cached_binary_version(name, assets, pin.valid_version)
    if v and v ~= keep then
      local p = dir .. "/" .. name
      local st = uv.fs_lstat(p)
      local rp = uv.fs_realpath(p)
      local is_running = run and ((lower_if_win(p) == run)
        or (rp and lower_if_win((rp:gsub("\\", "/"))) == run))
      if st and st.type == "file" and not is_running then
        if uv.fs_unlink(p) then
          removed = removed + 1; bytes = bytes + (st.size or 0)
        end
      end
    end
  end
  return removed, bytes
end

--- Old cached binaries a prune would remove (for health): count + bytes.
function M.stale_cache(root, keep, assets, valid_version)
  local dir = root .. "/" .. launcher.CACHE_DIR
  local handle = uv.fs_scandir(dir)
  if not handle then return 0, 0 end
  local n, bytes = 0, 0
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    local v = launcher.cached_binary_version(name, assets, valid_version)
    if v and v ~= keep then
      local st = uv.fs_lstat(dir .. "/" .. name)
      if st and st.type == "file" then n = n + 1; bytes = bytes + (st.size or 0) end
    end
  end
  return n, bytes
end

return M

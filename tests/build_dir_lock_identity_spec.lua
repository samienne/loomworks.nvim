-- Build-directory locks compare build directories by identity (spec §4.6,
-- §16.6): one physical folder spelled two ways — a junction / symlink, a
-- Windows 8.3 short name, an aliased workspace root — is ONE lock. Before, the
-- in-process queue `_build_dir_locks` was keyed by the normalized spelling and
-- the cross-process lockfile `<dir>.loomworks-lock` was derived from it, so two
-- spellings of one directory could configure / clean it concurrently.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local build_lock = require("loomworks.build_lock")
local build_run = require("loomworks.build_run")
local uv = vim.uv or vim.loop
local is_win = vim.fn.has("win32") == 1

local function quiet(fn)
  local rw, rs = io.write, io.stderr
  io.write = function() end
  io.stderr = { write = function() end }
  local ok, err = pcall(fn)
  io.write, io.stderr = rw, rs
  if not ok then error(err, 0) end
end

--- A shell App (Debug) workspace whose build_dir is `<root>/out`.
local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local lw = { projects = { App = { shell = {
    build_dir = "${workspace_root}/out",
    configure_cmd = { "true" },
    build_cmd = { "true" },
    configurations = { Debug = vim.empty_dict() },
  } } } }
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode(lw)); f:close()
  quiet(function()
    cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" })
    cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" })
  end)
  return root
end

local function load(root)
  return assert(cli._load_workspace(root, false))
end

--- `<root>/out` plus a link `<root>/alias` to it (junction on Windows).
local function link_alias(root)
  local dir = root .. "/out"
  vim.fn.mkdir(dir, "p")
  local alias = root .. "/alias"
  assert(uv.fs_symlink(dir, alias, is_win and { junction = true } or nil))
  return dir, alias
end

--- A link to the whole workspace root (an aliased root). Returns its path.
local function root_alias(root)
  local rootlink = vim.fn.tempname():gsub("\\", "/")
  assert(uv.fs_symlink(root, rootlink, is_win and { junction = true } or nil))
  return rootlink
end

--- `<root>/Long Build Directory` plus its 8.3 short spelling, or nil.
local function short_alias(root)
  if not is_win then return nil end
  local dir = root .. "/Long Build Directory"
  vim.fn.mkdir(dir, "p")
  local out = vim.fn.system({ "cmd", "/c", "for %I in (\"" .. dir:gsub("/", "\\") .. "\") do @echo %~sI" })
  local short = vim.trim(out or ""):gsub("\\", "/")
  if vim.v.shell_error ~= 0 or short == "" or not short:find("~", 1, true) then return nil end
  return dir, short
end

describe("in-process build-dir lock by identity (spec 4.6)", function()
  local function queues_alias(ws, a, b)
    local ran = {}
    assert.is_true(ws:acquire_build_dir_lock(a, "exclusive", function() ran[#ran + 1] = "a" end))
    local now = ws:acquire_build_dir_lock(b, "exclusive", function() ran[#ran + 1] = "b" end)
    assert.is_false(now, "an exclusive lock on one spelling queues the other spelling")
    assert.same({ "a" }, ran)
    assert.is_true((ws:is_build_dir_locked(b)), "the other spelling reads locked")
    ws:release_build_dir_lock(a, "exclusive")
    assert.same({ "a", "b" }, ran, "releasing the first spelling runs the queued one")
    ws:release_build_dir_lock(b, "exclusive")
    assert.is_false((ws:is_build_dir_locked(a)))
    assert.same({}, ws:get_build_dir_locks_info(), "no lock entry left behind")
  end

  it("queues a junction/symlink spelling behind the real one", function()
    local root = make_ws()
    local dir, alias = link_alias(root)
    queues_alias(load(root), dir, alias)
  end)

  it("queues an 8.3 short spelling behind the long one", function()
    local root = make_ws()
    local dir, short = short_alias(root)
    if not dir then
      pending("8.3 short names unavailable on this volume")
      return
    end
    queues_alias(load(root), dir, short)
  end)

  it("keeps one lock for a dir created while held (aliased root)", function()
    -- Configure takes the lock before its directory exists: the identity
    -- must not change when the directory appears.
    local root = make_ws()
    local rootlink = root_alias(root)
    local ws = load(root)
    local missing = rootlink .. "/out"
    local ran = {}
    assert.is_true(ws:acquire_build_dir_lock(missing, "exclusive", function() ran[#ran + 1] = 1 end))
    vim.fn.mkdir(root .. "/out", "p") -- the configure creates it
    assert.is_false(ws:acquire_build_dir_lock(root .. "/out", "exclusive", function() ran[#ran + 1] = 2 end),
      "the real spelling queues behind the lock taken through the aliased root")
    ws:release_build_dir_lock(missing, "exclusive")
    assert.same({ 1, 2 }, ran, "release by the original spelling still finds the lock")
    ws:release_build_dir_lock(root .. "/out", "exclusive")
    assert.same({}, ws:get_build_dir_locks_info())
  end)
end)

describe("cross-process build-dir lockfile by identity (spec 16.6)", function()
  local handles = {}
  after_each(function()
    for _, h in ipairs(handles) do pcall(build_lock.release, h) end
    handles = {}
  end)

  local function hold(dir, op)
    local h, msg = build_lock.acquire(dir, op or "configure", { what = dir, command = "lw build", unlock = dir })
    assert.is_not_nil(h, msg)
    handles[#handles + 1] = h
    return h
  end

  it("an alias sees the lock held through the real spelling", function()
    local root = make_ws()
    local dir, alias = link_alias(root)
    hold(dir)
    assert.is_not_nil(build_lock.read(alias), "the lock is visible through the alias")
    assert.is_true(build_lock.held_by_me(alias))
    local h = build_lock.acquire(alias, "clean", { what = alias, command = "lw clean", unlock = alias })
    if h then handles[#handles + 1] = h end
    assert.is_nil(h, "acquiring through the alias is refused while the real spelling holds it")
  end)

  it("a lock taken before the dir exists is found by its real spelling afterwards", function()
    local root = make_ws()
    local rootlink = root_alias(root)
    hold(rootlink .. "/out") -- configure, directory not yet created
    vim.fn.mkdir(root .. "/out", "p")
    assert.is_not_nil(build_lock.read(root .. "/out"), "visible by the real spelling once the dir exists")
    assert.is_true(build_lock.held_by_me(root .. "/out"))
  end)

  it("lw unlock through the alias removes the lock held through the real spelling", function()
    local root = make_ws()
    local dir, _ = link_alias(root)
    local ws = load(root)
    hold(dir)
    quiet(function() cli._unlock_build_dirs(ws, false, "alias/", true) end)
    assert.is_nil(build_lock.read(dir), "the forced unlock found and removed the lockfile")
  end)

  it("lw unlock refuses a build-dir path whose identity lies outside the workspace root", function()
    local root = make_ws()
    -- `<root>/alias` is a junction / symlink to a directory OUTSIDE the root:
    -- its lockfile `<outside>.loomworks-lock` is not under the root either.
    local outside = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(outside, "p")
    assert(uv.fs_symlink(outside, root .. "/alias", is_win and { junction = true } or nil))
    local ws = load(root)
    hold(outside)
    local lockfile = build_lock.lock_path(outside)
    assert.is_not_nil(uv.fs_stat(lockfile))
    local rw, rs, rx = io.write, io.stderr, os.exit
    local err, code = {}, nil
    io.write = function() end
    io.stderr = { write = function(_, s) err[#err + 1] = s end }
    os.exit = function(c) code = c or 0; error({ __exit = true }, 0) end
    local ok, e = pcall(cli._unlock_build_dirs, ws, false, "alias/", true)
    io.write, io.stderr, os.exit = rw, rs, rx
    if not ok and not (type(e) == "table" and e.__exit) then error(e, 0) end
    assert.is_not_nil(uv.fs_stat(lockfile), "the lockfile outside the workspace root is left in place")
    assert.is_not_nil(build_lock.read(outside))
    assert.is_truthy(code and code ~= 0, "lw unlock refuses (non-zero exit)")
    local msg = table.concat(err)
    assert.is_truthy(msg:find("outside", 1, true), msg)
    assert.is_truthy(msg:lower():find(lockfile:lower(), 1, true), "names the resolved lockfile: " .. msg)
  end)

  it("orders and de-duplicates locks by identity", function()
    local root = make_ws()
    local dir, alias = link_alias(root)
    assert.equals(1, #build_run.lock_order({ dir, alias }), "one directory, one lock")
  end)
end)

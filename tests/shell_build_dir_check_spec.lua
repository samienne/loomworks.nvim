-- A shell `build_dir` template may use only ${workspace_root},
-- ${project_path} (the project key) and ${variant} (shell spec §6). Any other
-- name, an environment variable's included, is a load error reported by the
-- module as the configuration info's `error` (core §8 `info`): the
-- configuration is invalid (invariant 11), no build directory is resolved
-- for it, no ConfigUnit exists for it, every operation on it is refused, the
-- load raises an error-severity diagnostic naming the project and
-- configuration, and the next load without it makes the configuration valid
-- again.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local ENV = "LW_SHELL_BD_CHECK"
local VALID = "${workspace_root}/out/${project_path}/${variant}"
local INVALID = "${workspace_root}/out/${" .. ENV .. "}/${variant}"

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, err = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
  return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

--- Run fn with the step spawn stubbed (every step succeeds), the workspace
--- as the current one. Returns capture() + the spawned steps.
local function stubbed(ws, fn)
  local spawned = {}
  local loomworks = require("loomworks")
  local orig_spawn, orig_get = cli._run_spec, loomworks.get_workspace
  cli._run_spec = function(step) spawned[#spawned + 1] = step; return 0 end
  loomworks.get_workspace = function() return ws end
  local ok, r = pcall(capture, fn)
  cli._run_spec, loomworks.get_workspace = orig_spawn, orig_get
  if not ok then error(r, 0) end
  r.spawned = spawned
  return r
end

local function write_config(root, template)
  local lw = { projects = { App = { shell = {
    build_dir = template,
    configure_cmd = { "configure" },
    build_cmd = { "build" },
    configurations = { Debug = vim.empty_dict() },
  } } } }
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode(lw)); f:close()
end

--- Set App's build_dir template in the working copy (user.json, which holds
--- the project since the set was created), signed by this machine.
local function set_user_template(root, template)
  local trust = require("loomworks.trust")
  local path = root .. "/.nvim/loomworks.user.json"
  local f = assert(io.open(path, "rb"))
  local status, body = trust.verify("user", f:read("*a")); f:close()
  assert.equals("valid", status)
  local user = vim.json.decode(body)
  user.projects.App.shell.build_dir = template
  local signed, serr = trust.sign("user", trust.encode(user))
  if not signed then error(serr) end
  f = assert(io.open(path, "wb")); f:write(signed); f:close()
end

--- A shell App (Debug); set + profile Dev (active), built once with a valid
--- template so the cache holds the unit's entry.
local function make_ws(template)
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  write_config(root, template or VALID)
  capture(function()
    cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" })
    cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" })
  end)
  return root
end

--- Load the workspace (capturing what the load prints); ws, Dev, App, Debug.
local function load(root)
  local ws
  local r = capture(function() ws = assert(cli._load_workspace(root, false)) end)
  local dev
  for _, p in ipairs(ws._profiles) do
    local cs = p:config_set()
    if cs and cs.name == "Dev" then dev = p end
  end
  local app
  for _, p in ipairs(ws._projects) do
    if p.key == "App" then app = p end
  end
  assert(app, "no App project")
  local debug = assert(app:get_configuration("Debug"))
  return ws, assert(dev, "no Dev profile"), app, debug, r
end

local function app_units(ws, app)
  local out = {}
  for _, u in ipairs(ws._config_units) do
    if u._project == app and not u._removed then out[#out + 1] = u end
  end
  return out
end

describe("shell build_dir template names (shell spec §6, core §8 info error)", function()
  local root
  before_each(function()
    vim.env[ENV] = "leaked"
    root = make_ws()
    local ws, dev = load(root)
    local r = stubbed(ws, function() return cli.cmd_build(ws, { "build", dev.key }) end)
    assert.is_nil(r.exit_code, r.stderr .. r.stdout)
    assert.is_true(#r.spawned > 0)
    set_user_template(root, INVALID)
  end)
  after_each(function() vim.env[ENV] = nil end)

  it("makes the configuration invalid: no build directory, no ConfigUnit", function()
    local ws, dev, app, debug = load(root)
    local ok, reasons = debug:is_valid()
    assert.is_false(ok)
    assert.truthy(table.concat(reasons, ";"):find("${" .. ENV .. "}", 1, true), vim.inspect(reasons))
    assert.same({}, app_units(ws, app))
    assert.is_nil(ws:find_config_unit(app, debug, nil))
    for _, pp in ipairs(dev:projects()) do
      assert.is_nil(pp._config_unit)
      assert.is_nil(pp:build_dir())
    end
  end)

  it("raises an error-severity diagnostic naming the project and configuration", function()
    local ws, _, _, _, r = load(root)
    local found
    for _, d in ipairs(ws:diagnostics()) do
      if d.message:find("${" .. ENV .. "}", 1, true) and d.message:find("'Debug'", 1, true) then found = d end
    end
    assert.is_not_nil(found, vim.inspect(ws:diagnostics()))
    assert.equals("error", found.severity)
    assert.truthy(found.message:find("'App'", 1, true), found.message)
    assert.truthy(found.message:find("'Debug'", 1, true), found.message)
    -- A load note too (the CLI's standard error, a daemon reply's notes).
    local note
    for _, n in ipairs(ws._load_notes or {}) do
      if n.text:find("${" .. ENV .. "}", 1, true) and n.text:find("Debug", 1, true) then note = n end
    end
    assert.is_not_nil(note, vim.inspect(ws._load_notes))
    assert.equals("error", note.severity)
    assert.truthy(note.text:find("App", 1, true) and note.text:find("Debug", 1, true), note.text)
    assert.truthy(r.stderr:find("${" .. ENV .. "}", 1, true), r.stderr)
  end)

  it("refuses a profile build of it: nothing runs, the command fails naming it", function()
    local ws, dev = load(root)
    local r = stubbed(ws, function() return cli.cmd_build(ws, { "build", dev.key }) end)
    assert.equals(1, r.exit_code, r.stderr .. r.stdout)
    assert.same({}, r.spawned)
    assert.truthy(r.stderr:find("App/Debug not run", 1, true), r.stderr)
    assert.truthy(r.stderr:find("${" .. ENV .. "}", 1, true), r.stderr)
    assert.is_nil(r.stderr:find("leaked", 1, true), r.stderr)
  end)

  it("is valid again once the template is fixed: the unit exists and builds", function()
    load(root)
    set_user_template(root, VALID)
    local ws, dev, app, debug = load(root)
    assert.is_true((debug:is_valid()))
    assert.is_not_nil(ws:find_config_unit(app, debug, nil))
    for _, d in ipairs(ws:diagnostics()) do
      assert.is_nil(d.message:find("${" .. ENV .. "}", 1, true), d.message)
    end
    local r = stubbed(ws, function() return cli.cmd_build(ws, { "build", dev.key }) end)
    assert.is_nil(r.exit_code, r.stderr .. r.stdout)
    assert.is_true(#r.spawned > 0)
  end)
end)

-- An invalid configuration's build directory (core §8 `info` error: no
-- ConfigUnit adopts its cache entry) is not an orphan: the configuration
-- still exists, only temporarily invalid. No orphan listing offers it, no
-- orphan / stray deletion removes it, and fixing the template adopts the
-- entry again with its state (deletion safety).
describe("shell build_dir template error keeps the configuration's build directory", function()
  local dp = require("loomworks.deletion_plan")
  local commands = require("loomworks.model_commands")
  local VALID_NB = "${workspace_root}/.nvim/build/${project_path}/${variant}"
  local INVALID_NB = "${workspace_root}/.nvim/build/${" .. ENV .. "}/${variant}"
  local root, dir
  before_each(function()
    vim.env[ENV] = "leaked"
    root = make_ws(VALID_NB)
    local ws, dev, app, debug = load(root)
    local r = stubbed(ws, function() return cli.cmd_build(ws, { "build", dev.key }) end)
    assert.is_nil(r.exit_code, r.stderr .. r.stdout)
    local unit = assert(ws:find_config_unit(app, debug, nil))
    dir = assert(unit:build_dir())
    vim.fn.mkdir(dir, "p")
    set_user_template(root, INVALID_NB)
  end)
  after_each(function()
    vim.env[ENV] = nil
    if root then vim.fn.delete(root, "rf") end
  end)

  it("is not listed as orphaned or stray, and no orphan deletion removes it", function()
    local ws = load(root)
    assert.same({}, ws:get_orphaned_configs())
    for _, d in ipairs(ws:find_stray_build_dirs()) do
      assert.is_nil(dir:lower():find(d:lower(), 1, true), "stray " .. d)
    end
    local plan = dp.plan(ws, { orphans = true })
    assert.is_true(dp.is_empty(plan), vim.inspect(plan.orphans) .. vim.inspect(plan.strays))
    local held
    for _, bd in ipairs(ws._build_dirs) do
      if bd.project_key == "App" then held = bd end
    end
    assert.is_not_nil(held, "the cache entry is kept")
    local refused = dp.plan(ws, { build_dir = held })
    assert.is_not_nil(refused.refusal, "a build_dir deletion of it is refused")
    local res = commands.execute_deletion(ws, { orphans = true }, { yes = true })
    assert.equals("refused", res.outcome, vim.inspect(res))
    assert.equals(dp.NOTHING, res.message)
    assert.equals(1, vim.fn.isdirectory(dir))
  end)

  --- Add a real orphan entry (a removed project's) at `orphan_dir`; a file
  --- inside the held dir marks its contents.
  local function add_orphan(ws, orphan_dir)
    vim.fn.mkdir(orphan_dir, "p")
    local f = assert(io.open(dir .. "/marker.txt", "w")); f:write("x"); f:close()
    local cache = ws:_serialize_cache()
    cache.build_dirs = cache.build_dirs or {}
    cache.build_dirs["Gone/Old"] = {
      project_key = "Gone", config_key = "Old", type = "shell", variant = "Old",
      state = "built", build_dir = orphan_dir,
    }
    ws:remerge(nil, cache)
    assert.equals(1, #ws:get_orphaned_configs(), "test setup: one orphan")
  end

  local function run_orphans(ws)
    local done = false
    local res = commands.execute_deletion(ws, { orphans = true },
      { yes = true, done = function() done = true end })
    assert.equals("accepted", res.outcome, vim.inspect(res))
    assert.is_true(vim.wait(5000, function() return done end, 20), "cleanup never finished")
  end

  it("keeps the held directory when an orphan entry's directory contains it", function()
    local ws = load(root)
    local parent = vim.fn.fnamemodify(dir, ":h")
    add_orphan(ws, parent)
    run_orphans(ws)
    assert.equals(1, vim.fn.isdirectory(dir))
    assert.equals(1, vim.fn.filereadable(dir .. "/marker.txt"), "the held build's contents survive")
    assert.same({}, ws:get_orphaned_configs(), "the orphan entry itself is dropped")
  end)

  it("keeps the held directory when an orphan entry names exactly it", function()
    local ws = load(root)
    add_orphan(ws, dir)
    run_orphans(ws)
    assert.equals(1, vim.fn.filereadable(dir .. "/marker.txt"), "the held build's contents survive")
  end)

  it("a reset of all still removes both the orphan's and the held directory", function()
    local ws = load(root)
    local parent = vim.fn.fnamemodify(dir, ":h")
    add_orphan(ws, parent)
    local result
    ws:reset_all(nil):next(function(ok) result = ok end)
    assert.is_true(vim.wait(5000, function() return result ~= nil end, 20), "reset never finished")
    assert.is_true(result)
    assert.equals(0, vim.fn.isdirectory(dir))
    assert.equals(0, vim.fn.isdirectory(parent))
  end)

  it("is adopted again with its state once the template is fixed", function()
    load(root)
    set_user_template(root, VALID_NB)
    local ws, _, app, debug = load(root)
    local unit = assert(ws:find_config_unit(app, debug, nil))
    assert.equals("built", unit.state_value)
    assert.same({}, ws:get_orphaned_configs())
    assert.equals(1, vim.fn.isdirectory(dir))
  end)
end)

-- A configuration rename whose new name resolves no build directory (a
-- module `error`, core §8 `info`) leaves the unit where it is rather than
-- giving it a nil id or directory.
describe("configuration rename to a name resolving no build directory", function()
  local root
  after_each(function() if root then vim.fn.delete(root, "rf") end end)

  it("keeps the unit's id and directory", function()
    root = make_ws()
    local ws, dev, app, debug = load(root)
    local r = stubbed(ws, function() return cli.cmd_build(ws, { "build", dev.key }) end)
    assert.is_nil(r.exit_code, r.stderr .. r.stdout)
    local unit = assert(ws:find_config_unit(app, debug, nil))
    local id, dir = unit.id, unit:build_dir()
    ws._compute_build_dir = function() return nil, nil end
    local ok, err = pcall(function() return app:rename_configuration("Debug", "Renamed", {}) end)
    ws._compute_build_dir = nil
    assert.is_true(ok, tostring(err))
    assert.equals(id, unit.id)
    assert.equals(dir, unit:build_dir())
  end)
end)

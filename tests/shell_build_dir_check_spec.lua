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
local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  write_config(root, VALID)
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

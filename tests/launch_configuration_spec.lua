-- LaunchConfiguration domain object (spec §1.2.1, step 5o part A0): owned by
-- its project (`Project._launches`, name → object), identity kept across a
-- refresh and a rename, `_removed` once its declaration goes, the files'
-- shape unchanged, and its daemon view id stable.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local LaunchConfiguration = require("loomworks.launch_configuration")
local snapshot = require("loomworks.daemon.snapshot")
local view_state = require("loomworks.view_state")

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, ret = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  if not ok and not (type(ret) == "table" and ret.__exit) then error(ret, 0) end
  return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local c = f:read("*a"); f:close()
  return c
end

local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/App/tsconfig.json", "w")); f:write("{}"); f:close()
  f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
  capture(function() cli.cmd_cset("create", root, { "configset", "create", "Dev", "App=Debug" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
  return root
end

local function launch(root, ...)
  local args = { "launch", ... }
  return capture(function() return cli.cmd_launch(args[2], root, args) end)
end

local function load(root) return assert(cli._load_workspace(root, false)) end

local function find_project(ws, key)
  for _, p in pairs(ws._projects) do if p.key == key then return p end end
end

local function view_launches(ws, reg)
  local v = view_state.workspace(ws, { id = function(o) return reg:id(o) end })
  for _, p in ipairs(v.projects) do
    if p.key == "App" then return p.launches end
  end
end

describe("LaunchConfiguration domain object (spec §1.2.1)", function()
  it("is owned by its project, carries its declaration and description", function()
    local root = make_ws()
    launch(root, "add", "App", "serve", "--description", "Serves it", "node", "x.js")
    launch(root, "add", "App", "check", "--from-target", "chk")
    local proj = find_project(load(root), "App")
    local l = proj:find_launch("serve")
    assert.equals(LaunchConfiguration, getmetatable(l))
    assert.equals("serve", l.name)
    assert.equals(proj, l._project)
    assert.is_false(l._removed)
    assert.equals("Serves it", l.description)
    assert.equals("node", l.command)
    assert.same({ "x.js" }, l.args)
    local names = {}
    for _, x in ipairs(proj:launch_configs()) do names[#names + 1] = x.name end
    assert.same({ "check", "serve" }, names)
    assert.is_true(proj:has_launches())
    assert.is_nil(proj.launch)
  end)

  it("keeps its identity across a refresh; a vanished declaration is marked removed", function()
    local root = make_ws()
    launch(root, "add", "App", "serve", "node", "x.js")
    launch(root, "add", "App", "gone", "node", "y.js")
    local ws = load(root)
    local proj = find_project(ws, "App")
    local serve, gone = proj:find_launch("serve"), proj:find_launch("gone")
    -- A full re-merge (the refresh path) rebuilds the model from the merged data.
    ws:remerge()
    proj = find_project(ws, "App")
    assert.equals(serve, proj:find_launch("serve"))
    assert.equals(gone, proj:find_launch("gone"))
    -- Refreshed data: the same object takes the new declaration; a dropped
    -- name is marked removed; a new name gets a new object.
    proj:_sync_launches({ serve = { command = "deno", args = { "x.ts" } }, fresh = { command = "true" } })
    assert.equals(serve, proj:find_launch("serve"))
    assert.equals("deno", serve.command)
    assert.is_false(serve._removed)
    assert.is_true(gone._removed)
    assert.is_nil(proj:find_launch("gone"))
    assert.is_not_nil(proj:find_launch("fresh"))
  end)

  it("keeps its identity (and its whole declaration) across a rename", function()
    local root = make_ws()
    launch(root, "add", "App", "old", "--description", "Kept", "node", "x.js")
    local ws = load(root)
    local proj = find_project(ws, "App")
    local l = proj:find_launch("old")
    local decl = l:serialize()
    assert.is_true((proj:rename_launch_config(l, "new")))
    assert.equals(l, proj:find_launch("new"))
    assert.is_nil(proj:find_launch("old"))
    assert.equals("new", l.name)
    assert.same(decl, l:serialize())
    assert.is_false(l._removed)
    local user = vim.json.decode(read(root .. "/.nvim/loomworks.user.json"))
    assert.is_nil(user.projects.App.launch.old)
    assert.equals("Kept", user.projects.App.launch.new.description)
    -- A removed (or foreign) object is refused.
    local other = LaunchConfiguration.new(proj, "stray", { command = "x" })
    assert.is_nil((proj:rename_launch_config(other, "x2")))
  end)

  it("is marked removed when deleted", function()
    local root = make_ws()
    launch(root, "add", "App", "serve", "node", "x.js")
    local ws = load(root)
    local proj = find_project(ws, "App")
    local l = proj:find_launch("serve")
    assert.is_true((proj:delete_launch_config(l)))
    assert.is_true(l._removed)
    assert.is_nil(proj:find_launch("serve"))
    assert.is_false(proj:has_launches())
    local user = vim.json.decode(read(root .. "/.nvim/loomworks.user.json"))
    assert.is_nil(user.projects.App.launch)
    -- Deleting it again is refused.
    assert.is_false((proj:delete_launch_config(l)))
  end)

  it("save updates the existing object in place and returns it", function()
    local root = make_ws()
    launch(root, "add", "App", "serve", "node", "x.js")
    local proj = find_project(load(root), "App")
    local l = proj:find_launch("serve")
    local ok, err, saved = proj:save_launch_config("serve", { command = "deno" })
    assert.is_true(ok, err)
    assert.equals(l, saved)
    assert.equals("deno", l.command)
    local _, _, created = proj:save_launch_config("other", { command = "true" })
    assert.equals(created, proj:find_launch("other"))
  end)

  it("sets its own description (the project is materialised in the working copy)", function()
    local root = make_ws()
    launch(root, "add", "App", "serve", "node", "x.js")
    local proj = find_project(load(root), "App")
    local l = proj:find_launch("serve")
    assert.is_true(l:set_description("Hello"))
    assert.equals("Hello", l.description)
    assert.is_false(l:set_description("Hello"))
    local user = vim.json.decode(read(root .. "/.nvim/loomworks.user.json"))
    assert.equals("Hello", user.projects.App.launch.serve.description)
  end)

  it("round-trips the files byte for byte (every field, known or not)", function()
    local root = make_ws()
    launch(root, "add", "App", "serve", "--description", "Line one", "node", "x.js")
    launch(root, "add", "App", "check", "--from-target", "chk", "--", "--x")
    local ws = load(root)
    local proj = find_project(ws, "App")
    local serve = proj:find_launch("serve")
    serve.device = { stage = { "assets/**" } }
    serve.debug = { "c++" }
    serve:_apply(vim.tbl_extend("force", serve:serialize(), { future_field = { nested = true } }))
    assert.is_true(ws:_save_user())
    local before = read(root .. "/.nvim/loomworks.user.json")
    ws = load(root)
    assert.is_true(ws:_save_user())
    assert.equals(before, read(root .. "/.nvim/loomworks.user.json"))
    local decl = vim.json.decode(before).projects.App.launch.serve
    assert.same({ nested = true }, decl.future_field)
    assert.same(vim.json.decode(before).projects.App.launch, find_project(ws, "App"):serialize_launches())
  end)

  it("holds every declared field as its own; unknown keys are kept opaque", function()
    local proj = { key = "P" }
    local env, args = { A = "1" }, { "x" }
    local l = LaunchConfiguration.new(proj, "n", {
      command = "c", args = args, working_dir = "w", env = env, debug = { "c++" },
      deploy = { d = { project = "Q", path = "p" } }, device = { stage = { "s" } },
      device_log = { tag = "t" }, description = "Hi  \n\n", future = { k = 1 },
    })
    assert.is_nil(l._decl)
    assert.is_nil(l.declaration)
    assert.equals("c", l.command)
    assert.equals(args, l.args)
    assert.equals("w", l.working_dir)
    assert.equals(env, l.env)
    assert.same({ "c++" }, l.debug)
    assert.same({ d = { project = "Q", path = "p" } }, l.deploy)
    assert.same({ stage = { "s" } }, l.device)
    assert.same({ tag = "t" }, l.device_log)
    assert.equals("Hi", l.description)
    assert.same({ future = { k = 1 } }, l._extra)
    assert.is_nil(l.future)
    assert.is_true(l:is_runnable())
    -- Rebuilt from the fields, unknown keys included; a fresh table.
    local out = l:serialize()
    assert.same({ command = "c", args = { "x" }, working_dir = "w", env = { A = "1" },
      debug = { "c++" }, deploy = { d = { project = "Q", path = "p" } },
      device = { stage = { "s" } }, device_log = { tag = "t" }, description = "Hi",
      future = { k = 1 } }, out)
    assert.are_not.equal(out, l:serialize())
    -- An update replaces every field; a field no longer declared is gone.
    l:_apply({ target = "t" })
    assert.is_nil(l.command)
    assert.is_nil(l._extra)
    assert.equals("t", l.target)
    assert.same({ target = "t" }, l:serialize())
    -- A non-string description is ignored but written back as is.
    l:_apply({ command = "c", description = 42 })
    assert.is_nil(l.description)
    assert.same({ command = "c", description = 42 }, l:serialize())
    -- A declaration that is not a table is kept and runs nothing.
    l:_apply("bogus")
    assert.is_true(l:is_invalid())
    assert.is_false(l:is_runnable())
    assert.equals("bogus", l:serialize())
  end)

  it("round-trips a hand-written launch with unknown and invalid entries", function()
    local root = make_ws()
    launch(root, "add", "App", "serve", "node", "x.js")
    local upath = root .. "/.nvim/loomworks.user.json"
    local user = vim.json.decode(read(upath))
    user.projects.App.launch.serve.future_field = { nested = { "a", "b" } }
    user.projects.App.launch.odd = "not a table"
    local f = assert(io.open(upath, "wb")); f:write(vim.json.encode(user)); f:close()
    assert(require("loomworks.trust").sign_file(upath, "user"))
    local ws = load(root)
    assert.is_true(ws:_save_user())
    local before = read(upath)
    ws = load(root)
    assert.is_true(ws:_save_user())
    assert.equals(before, read(upath))
    local decls = vim.json.decode(before).projects.App.launch
    assert.same({ nested = { "a", "b" } }, decls.serve.future_field)
    assert.equals("not a table", decls.odd)
    assert.is_true(find_project(ws, "App"):find_launch("odd"):is_invalid())
  end)

  it("is marked removed with its project, and then refuses changes", function()
    local root = make_ws()
    launch(root, "add", "App", "serve", "node", "x.js")
    local ws = load(root)
    local proj = find_project(ws, "App")
    local l = proj:find_launch("serve")
    assert.is_true((ws:remove_project(proj)))
    assert.is_true(l._removed)
    assert.is_true(l:is_removed())
    assert.is_nil((l:set_description("x")))
    assert.is_false((proj:delete_launch_config(l)))
    assert.is_nil((proj:rename_launch_config(l, "other")))
    assert.is_false((proj:save_launch_config("serve", { command = "x" })))
  end)

  it("refuses a description change once only its project is removed", function()
    local root = make_ws()
    launch(root, "add", "App", "serve", "node", "x.js")
    local proj = find_project(load(root), "App")
    local l = proj:find_launch("serve")
    proj._removed = true
    assert.is_true(l:is_removed())
    assert.is_nil((l:set_description("x")))
  end)

  it("is marked removed when a refresh drops its project", function()
    local root = make_ws()
    launch(root, "add", "App", "serve", "node", "x.js")
    local ws = load(root)
    local proj = find_project(ws, "App")
    local l = proj:find_launch("serve")
    ws:remerge({ projects = {} }, nil, { projects = {} })
    assert.is_nil(find_project(ws, "App"))
    assert.is_true(proj._removed)
    assert.is_true(l._removed)
  end)

  it("has a daemon view id that survives a refresh and a rename", function()
    local root = make_ws()
    launch(root, "add", "App", "b", "node", "b.js")
    launch(root, "add", "App", "a", "node", "a.js")
    local ws = load(root)
    local reg = snapshot.registry(7)
    local rows = view_launches(ws, reg)
    assert.equals(2, #rows)
    assert.equals("a", rows[1].key)
    assert.is_string(rows[1].id)
    assert.is_string(rows[2].id)
    assert.are_not.equal(rows[1].id, rows[2].id)
    local id_a = rows[1].id
    ws:remerge()
    assert.equals(id_a, view_launches(ws, reg)[1].id)
    local proj = find_project(ws, "App")
    assert.is_true((proj:rename_launch_config(proj:find_launch("a"), "z")))
    rows = view_launches(ws, reg)
    assert.equals("z", rows[2].key)
    assert.equals(id_a, rows[2].id)
    -- The in-process view (no id function) carries none.
    assert.is_nil(view_launches(ws, { id = function() return nil end })[1].id)
  end)
end)

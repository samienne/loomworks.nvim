-- Saving from an editor dialog changes ONLY the fields the dialog edits; every
-- other declared field of the item survives exactly (the launch editor and
-- the configuration-set editor's rename). Each spec drives the real dialog
-- widget — View is stubbed so no window opens — edits one shown field through
-- its row, accepts, and hands the result to workspace_view's save. The
-- on-disk working copy is then re-read from a fresh load.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local View = require("loomworks.ui.view")
local wv = require("loomworks.workspace_view")

local function capture(fn)
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function() end
  io.stderr = { write = function() end }
  os.exit = function() error({ __exit = true }, 0) end
  local ok, err = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a"); f:close()
  return vim.json.decode(c)
end

local function read_user(root) return read_json(root .. "/.nvim/loomworks.user.json") end

local function find_project(ws, key)
  for _, p in pairs(ws._projects) do if p.key == key then return p end end
end

local function find_set(ws, name)
  for _, cs in pairs(ws._config_sets) do if cs.name == name then return cs end end
end

local function load(root) return assert(cli._load_workspace(root, false)) end

--- A cmake App with a declared project variable, and a user configuration
--- `Dev` carrying env, a compiler-family override, a variable override, an
--- option, a toolchain, an arbitrary module field and a description.
local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  io.open(root .. "/App/CMakeLists.txt", "w"):close()
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = {
    cmake = vim.empty_dict(),
    variables = { out = { type = "string", default = "x" } },
  } } }))
  f:close()
  local function set(param, value)
    capture(function() cli.cmd_configuration("set", root, "App", "Dev", param, value) end)
  end
  capture(function() cli.cmd_configuration("add", root, "App", "Dev", "variant:Debug") end)
  set("env.FOO", "bar")
  set("variables.out", "y")
  set("overrides.gcc.out", "z")
  set("toolchain", "tc.cmake")
  set("myfield", "m")
  set("options.OPT", "1")
  set("languages", "c,c++")
  local ws = load(root)
  assert(find_project(ws, "App"):get_configuration("Dev"):set_description("Dev build\n\nbody"))
  return root
end

--- Open `dialog_mod` with `opts` against a stubbed View; returns the tree.
local function open_dialog(dialog_mod, opts)
  local tree
  local orig = View.new
  View.new = function(vopts)
    tree = vopts.widget
    return { open = function() end, close = function() end, refresh = function() end }
  end
  local ok, err = pcall(require(dialog_mod).open, opts)
  View.new = orig
  assert(ok, err)
  return tree
end

--- Press <CR> on the first rendered row matching `pattern`, answering the
--- prompt it opens with `answer`.
local function enter_row(tree, pattern, answer)
  local lines = tree:render()
  local row
  for i, l in ipairs(lines) do
    if l:find(pattern) then row = i; break end
  end
  assert(row, "no row matching " .. pattern .. " in:\n" .. table.concat(lines, "\n"))
  local orig = vim.ui.input
  vim.ui.input = function(_, cb) cb(answer) end
  local ok, err = pcall(tree.on_key, tree, "enter", row)
  vim.ui.input = orig
  assert(ok, err)
end

describe("launch editor dialog save", function()
  it("keeps the device block and other fields it does not show", function()
    local root = make_ws()
    local ws = load(root)
    local project = find_project(ws, "App")
    assert(project:save_launch_config("run", {
      command = "app", args = { "-v" },
      device = { working_dir = "/data/app", env = { LOG = "1" } },
    }))
    ws = load(root)
    project = find_project(ws, "App")
    -- The fields the status page opens it with: the declaration's.
    local decl = wv.project_declaration(project)
    local f
    for _, l in ipairs(decl.launches) do if l.key == "run" then f = l.fields end end
    local saved
    local tree = open_dialog("loomworks.ui.launch_editor", {
      title = "Edit", name = "run", command = f.command, args = f.args,
      working_dir = f.working_dir, env = f.env, deploy = f.deploy,
      debug = f.debug, variables = decl.variables,
      on_accept = function(result)
        saved = { wv.execute_save_launch_config(project, project:find_launch("run"), result.name, result) }
      end,
      on_cancel = function() end,
    })
    enter_row(tree, "^%s*Command ", "app2")
    tree:on_key("accept", 1)
    assert.is_true(saved[1], saved[2])

    local l = read_user(root).projects.App.launch.run
    assert.equals("app2", l.command)
    assert.same({ "-v" }, l.args)
    assert.same({ working_dir = "/data/app", env = { LOG = "1" } }, l.device)
  end)
end)

describe("configuration set editor dialog save", function()
  it("a rename keeps the set's description and intent", function()
    local root = make_ws()
    capture(function()
      cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Dev" })
    end)
    local ws = load(root)
    local cs = find_set(ws, "Dev")
    assert(cs:set_description("What CI ships"))
    ws = load(root)
    cs = find_set(ws, "Dev")
    local intent = cs._intent
    local ctx = wv.compute_edit_config_set_context(ws, "Dev")
    local old_mappings = {}
    for p, c in pairs(ctx.mappings) do old_mappings[p] = c end
    local saved
    local tree = open_dialog("loomworks.ui.config_set_editor", {
      title = "Edit", item = cs, name = "Dev", projects = ctx.projects,
      mappings = ctx.mappings, available_configs = ctx.available_configs,
      on_accept = function(result)
        saved = { wv.execute_edit_config_set(cs, result.name, result.mappings, old_mappings) }
      end,
      on_cancel = function() end,
    })
    enter_row(tree, "^%s*Name ", "Ship")
    tree:on_key("accept", 1)
    assert.is_true(saved[1], saved[2])

    local user = read_user(root)
    assert.is_nil(user.configuration_sets.Dev)
    assert.equals("Dev", user.configuration_sets.Ship.App)
    assert.equals("What CI ships", (user.configuration_set_descriptions or {}).Ship)
    local renamed = find_set(load(root), "Ship")
    assert.equals("What CI ships", renamed.description)
    assert.equals(intent, renamed._intent)
  end)
end)

describe("launch save of a target-backed launch", function()
  it("an empty command field stores no command; empty fields are absent", function()
    local root = make_ws()
    local ws = load(root)
    local project = find_project(ws, "App")
    assert(project:save_launch_config("tgt", { target = "app", args = { "-v" } }))
    ws = load(root)
    project = find_project(ws, "App")
    local ok, err = wv.execute_save_launch_config(project, project:find_launch("tgt"), "tgt", {
      command = "", args = {}, working_dir = "", env = {},
      deploy = {}, debug = {},
    })
    assert.is_true(ok, err)
    local l = read_user(root).projects.App.launch.tgt
    assert.same({ target = "app" }, l)
  end)
end)

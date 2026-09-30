-- Launch configuration descriptions and rename (spec §1.10, §8.7, §16.35).
-- Test-first for the rename cascade (every field moves; every profile's
-- default target follows; refusals) and for `lw launch add --description`
-- leaving the program's own args (e.g. `python -m http.server`) intact.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

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

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a"); f:close()
  return vim.json.decode(c)
end

local function user_json(root) return read_json(root .. "/.nvim/loomworks.user.json") end

--- Workspace: typescript App with a user Debug config, a Dev set and two
--- profiles (Dev + Dev2 over the same set via --shared/--local variants are
--- not needed: one set, one profile, plus a second set/profile).
local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/App/tsconfig.json", "w")); f:write("{}"); f:close()
  f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
  capture(function() cli.cmd_cset("create", root, { "configset", "create", "Dev", "App=Debug" }) end)
  capture(function() cli.cmd_cset("create", root, { "configset", "create", "Other", "App=Debug" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Other" }) end)
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

--- Set a default target on every profile pointing at launch `name`.
local function point_all_profiles_at(root, name)
  local ws = load(root)
  local proj = find_project(ws, "App")
  for _, profile in pairs(ws._profiles) do
    profile._default_target_descriptor = { project = "App", launch = name, working_dir = "wd" }
  end
  assert.is_true(ws:_save_user())
  assert.is_truthy(proj)
end

describe("launch rename", function()
  it("moves every field, including device/deploy/debug/description and unknown keys", function()
    local root = make_ws()
    assert.is_nil(launch(root, "add", "App", "schema-test", "--from-target", "editor",
      "--use-scene-json-schema", "D:/src/x").exit_code)
    -- Give it fields no CLI flag sets, straight on the object (as the editor/
    -- a hand-written file would), then save.
    local ws = load(root)
    local proj = find_project(ws, "App")
    local cfg = proj.launch["schema-test"]
    cfg.device = { stage = { "assets/**" } }
    cfg.deploy = { ["${build_dir}/x.dll"] = { project = "App", path = "x.dll" } }
    cfg.debug = { "c++" }
    cfg.description = "Editor with the schema test data"
    cfg.future_field = { keep = true }
    assert.is_true(ws:_save_user())
    local before = vim.deepcopy(user_json(root).projects.App.launch["schema-test"])

    local r = launch(root, "rename", "App", "schema-test", "scene-schema")
    assert.is_nil(r.exit_code, r.stderr)
    assert.is_truthy(r.stdout:find("'App:schema-test' -> 'App:scene-schema'", 1, true))
    local l = user_json(root).projects.App.launch
    assert.is_nil(l["schema-test"])
    assert.same(before, l["scene-schema"])
  end)

  it("re-points every profile's default target (keeping working_dir) and reports it", function()
    local root = make_ws()
    launch(root, "add", "App", "editor", "--from-target", "editor")
    point_all_profiles_at(root, "editor")
    local r = launch(root, "mv", "App", "editor", "main")
    assert.is_nil(r.exit_code, r.stderr)
    assert.is_truthy(r.stdout:find("default target updated in profiles", 1, true))
    local u = user_json(root)
    local n = 0
    for _, d in pairs(u.default_target) do
      n = n + 1
      assert.same({ project = "App", launch = "main", working_dir = "wd" }, d)
    end
    assert.equals(2, n)
    -- A fresh load resolves the default target to the renamed launch.
    local ws = load(root)
    for _, p in pairs(ws._profiles) do
      local lt = p:default_target()
      assert.is_truthy(lt)
      assert.equals("main", lt._launch_name)
    end
  end)

  it("refuses an unknown old name, an existing new name and an invalid name", function()
    local root = make_ws()
    launch(root, "add", "App", "a", "node", "x.js")
    launch(root, "add", "App", "b", "node", "y.js")
    assert.equals(1, launch(root, "rename", "App", "nope", "c").exit_code)
    local col = launch(root, "rename", "App", "a", "b")
    assert.equals(1, col.exit_code)
    assert.is_truthy(col.stderr:find("already exists", 1, true))
    for _, bad in ipairs({ "-x", " padded", "tab\tname", "" }) do
      local r = launch(root, "rename", "App", "a", bad)
      assert.equals(1, r.exit_code, bad)
    end
    local l = user_json(root).projects.App.launch
    assert.is_truthy(l.a); assert.is_truthy(l.b)
  end)

  it("same name is unchanged; a case-only change is a rename", function()
    local root = make_ws()
    launch(root, "add", "App", "demo", "node", "x.js")
    local same = launch(root, "rename", "App", "demo", "demo")
    assert.is_nil(same.exit_code)
    assert.is_truthy(same.stdout:find("(unchanged)", 1, true))
    assert.is_nil(launch(root, "rename", "App", "demo", "Demo").exit_code)
    local l = user_json(root).projects.App.launch
    assert.is_nil(l.demo); assert.is_truthy(l.Demo)
  end)

  it("warns when the new name equals a build target of the project", function()
    local root = make_ws()
    launch(root, "add", "App", "demo", "node", "x.js")
    local ws = load(root)
    local proj = find_project(ws, "App")
    local r = capture(function()
      return cli._launch_rename(ws, proj, "demo", "editor", { target_names = { editor = true } })
    end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.is_truthy(r.stderr:find("also the name of a build target", 1, true))
  end)

  it("a rename in a published project marks it modified", function()
    local root = make_ws()
    launch(root, "add", "App", "demo", "--from-target", "editor")
    assert.is_true(capture(function() return cli.cmd_publish(root) end).exit_code == nil)
    local ws = load(root)
    assert.is_false(ws:is_project_modified(find_project(ws, "App")))
    launch(root, "rename", "App", "demo", "demo2")
    ws = load(root)
    assert.is_true(ws:is_project_modified(find_project(ws, "App")))
  end)
end)

describe("launch add --description / describe", function()
  it("--description never swallows the program's own args (python -m …)", function()
    local root = make_ws()
    local r = launch(root, "add", "App", "docs", "python", "-m", "http.server", "8000",
      "--description", "Docs server", "--description", "Serves the built docs.")
    assert.is_nil(r.exit_code, r.stderr)
    local cfg = user_json(root).projects.App.launch.docs
    assert.equals("python", cfg.command)
    assert.same({ "-m", "http.server", "8000" }, cfg.args)
    assert.equals("Docs server\n\nServes the built docs.", cfg.description)
  end)

  it("describe sets, prints, --json, clears; empty removes the key", function()
    local root = make_ws()
    launch(root, "add", "App", "demo", "--from-target", "editor", "--theme", "demo")
    local r = launch(root, "describe", "App", "demo", "-m", "Theme showcase", "-m", "Body")
    assert.is_nil(r.exit_code, r.stderr)
    assert.equals("Theme showcase\n\nBody", user_json(root).projects.App.launch.demo.description)
    assert.equals("Theme showcase\n\nBody\n", launch(root, "describe", "App", "demo").stdout)
    local j = vim.json.decode(launch(root, "describe", "App", "demo", "--json").stdout)
    assert.equals("launch", j.kind)
    assert.equals("App", j.project)
    assert.equals("demo", j.name)
    assert.equals("Theme showcase", j.summary)
    launch(root, "describe", "App", "demo", "")
    assert.is_nil(user_json(root).projects.App.launch.demo.description)
    -- The args are untouched by describe.
    assert.same({ "--theme", "demo" }, user_json(root).projects.App.launch.demo.args)
  end)

  it("describe accepts --project/--launch; refuses an unknown launch", function()
    local root = make_ws()
    launch(root, "add", "App", "demo", "node", "x.js")
    assert.is_nil(launch(root, "describe", "--project", "App", "--launch", "demo", "Hi").exit_code)
    assert.equals("Hi", user_json(root).projects.App.launch.demo.description)
    assert.equals(1, launch(root, "describe", "App", "nope", "x").exit_code)
  end)

  it("launch set keeps the description; show prints it and --json has every field", function()
    local root = make_ws()
    launch(root, "add", "App", "demo", "--from-target", "editor", "--a", "--description", "Sum")
    launch(root, "set", "App", "demo", "--working-dir", "wd")
    local cfg = user_json(root).projects.App.launch.demo
    assert.equals("Sum", cfg.description)
    local s = launch(root, "show", "App", "demo")
    assert.is_truthy(s.stdout:find("  description  Sum", 1, true))
    local j = vim.json.decode(launch(root, "show", "App", "demo", "--json").stdout)
    assert.equals("target", j.kind)
    assert.equals("editor", j.target)
    assert.same({ "--a" }, j.args)
    assert.equals("wd", j.working_dir)
    assert.equals("Sum", j.description)
    assert.equals("Sum", j.summary)
  end)

  it("launch list: summary column before RUNS; RUNS in full when piped", function()
    local root = make_ws()
    launch(root, "add", "App", "plain", "--from-target", "editor")
    launch(root, "add", "App", "schema", "--from-target", "editor",
      "--use-scene-json-schema", "D:/src/dres_schema_test", "--description", "Schema test data")
    cli._test_stdout_tty = false
    local out = launch(root, "list").stdout
    cli._test_stdout_tty = nil
    assert.is_truthy(out:find("DESCRIPTION", 1, true))
    local line = out:match("\n(  App +schema [^\n]*)")
    assert.is_truthy(line)
    assert.is_true(line:find("Schema test data", 1, true) < line:find("target:editor", 1, true))
    assert.is_truthy(line:find("D:/src/dres_schema_test", 1, true)) -- not cut when piped
  end)

  it("launch list without descriptions keeps the old header", function()
    local root = make_ws()
    launch(root, "add", "App", "plain", "--from-target", "editor")
    local out = launch(root, "list").stdout
    assert.is_nil(out:find("DESCRIPTION", 1, true))
    assert.is_truthy(out:find("RUNS", 1, true))
  end)

  it("new launch names are validated on add", function()
    local root = make_ws()
    assert.equals(1, launch(root, "add", "App", "-bad", "node").exit_code)
  end)
end)

describe("launch descriptions and trust (§17.6)", function()
  local pf = require("loomworks.program_fields")
  local modules = require("loomworks.modules")
  local SHARED = {
    projects = {
      App = {
        typescript = {},
        launch = {
          serve = { command = "node", args = { "x" }, description = "Docs \27[31mserver\n\nbody" },
          plain = { target = "app", description = "Target-only launch" },
        },
      },
    },
  }

  it("an ignored program-bearing launch's summary appears inert in its diagnostic only", function()
    local cfg = require("loomworks.config").parse(vim.json.encode(SHARED), "/root")
    local ignored = pf.strip(cfg, modules)
    -- The target-only launch (and its description) stays; the program-bearing one goes.
    assert.equals("Target-only launch", cfg.projects.App.launch.plain.description)
    assert.is_nil(cfg.projects.App.launch.serve)
    local diags = pf.diagnostics(ignored, {})
    local msg
    for _, dg in ipairs(diags) do
      if dg.message:find("launch.serve", 1, true) then msg = dg.message end
    end
    assert.is_truthy(msg)
    assert.is_truthy(msg:find('"Docs ^[[31mserver"', 1, true))
    assert.is_nil(msg:find("body", 1, true))
    assert.is_nil(msg:find("\27", 1, true))
  end)
end)

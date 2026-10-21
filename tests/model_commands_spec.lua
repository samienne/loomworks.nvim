-- The host-neutral model command layer (model_commands.lua, step 5o A1;
-- API.md §4.1, §6, §11, §19–§21): one function per user action, taking
-- domain objects, answering ok / refused (+ warn notes for a composite).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local mc = require("loomworks.model_commands")
local io_mod = require("loomworks.io")
local user_mod = require("loomworks.user")
local trust = require("loomworks.trust")

local function capture(fn)
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function() end
  io.stderr = { write = function() end }
  os.exit = function() error({ __exit = true }, 0) end
  local ok, ret = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  if not ok and not (type(ret) == "table" and ret.__exit) then error(ret, 0) end
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a"); f:close()
  return vim.json.decode(c)
end

--- Workspace: typescript App with a user Debug config, sets Dev and Other,
--- profiles of both (Dev active), and a launch `run`.
local function make_root()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  vim.fn.mkdir(root .. "/B", "p")
  local f = assert(io.open(root .. "/App/tsconfig.json", "w")); f:write("{}"); f:close()
  f = assert(io.open(root .. "/B/tsconfig.json", "w")); f:write("{}"); f:close()
  f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
  capture(function() cli.cmd_cset("create", root, { "configset", "create", "Dev", "App=Debug" }) end)
  capture(function() cli.cmd_cset("create", root, { "configset", "create", "Other", "App=Debug" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Other" }) end)
  capture(function() cli.cmd_launch("add", root, { "launch", "add", "App", "run", "--", "node", "x.js" }) end)
  return root
end

local function load(root) return assert(cli._load_workspace(root, false)) end
local function user_json(root) return read_json(root .. "/.nvim/loomworks.user.json") end

local function read_signed(path, kind)
  local text = assert(io_mod.read_file(path))
  local status, body = trust.verify(kind, text)
  assert.equals("valid", status)
  return vim.json.decode(body)
end

local function find(list, field, value)
  for _, o in pairs(list) do if o[field] == value then return o end end
end

local function assert_ok(r) assert.equals("ok", r.outcome, r.message) end
local function assert_refused(r, pattern, code)
  assert.equals("refused", r.outcome)
  assert.equals(code or 1, r.exit_code)
  if pattern then
    assert.is_truthy(r.message:find(pattern, 1, true), r.message)
  end
end

describe("model_commands", function()
  local root, ws, app
  before_each(function()
    root = make_root()
    ws = load(root)
    app = find(ws._projects, "key", "App")
  end)

  describe("Workspace/1", function()
    it("publish writes loomworks.json", function()
      assert_ok(mc.publish(ws))
      assert.is_truthy(read_json(root .. "/loomworks.json").configuration_sets)
    end)

    it("refuses publish_one / revert_one / set_intent on a launch, naming its project", function()
      local launch = app:find_launch("run")
      assert_refused(mc.publish_one(launch), "published with its project App")
      assert_refused(mc.revert_one(launch), "published with its project App")
      assert_refused(mc.set_intent(launch, "local"), "published with its project App")
    end)

    it("set_intent records the intent in the working copy", function()
      local cs = find(ws._config_sets, "name", "Dev")
      assert_ok(mc.set_intent(cs, "local"))
      assert.equals("local", cs._intent)
      local again = load(root)
      assert.equals("local", find(again._config_sets, "name", "Dev")._intent)
    end)

    it("set_intent refuses an unknown intent (usage) and a removed item", function()
      local cs = find(ws._config_sets, "name", "Dev")
      assert_refused(mc.set_intent(cs, "everywhere"), "unknown intent", 2)
      cs._removed = true
      assert_refused(mc.set_intent(cs, "local"), "configuration set 'Dev' has been removed")
    end)

    it("set_description reports whether it changed, a launch included", function()
      local launch = app:find_launch("run")
      local r = mc.set_description(launch, "Runs it")
      assert_ok(r)
      assert.is_true(r.changed)
      assert.equals("Runs it", launch.description)
      r = mc.set_description(launch, "Runs it")
      assert_ok(r)
      assert.is_false(r.changed)
      launch._removed = true
      assert_refused(mc.set_description(launch, "x"), "has been removed")
    end)
  end)

  describe("Profiles/1", function()
    it("a save refused as stale keeps the reloaded state (no undo over it): create --activate", function()
      -- Another writer removed profile Dev (the active one) and cleared the
      -- active profile; this editor still has Dev active in memory.
      ws._core._deps.on_save_refused = function() end -- the CLI's would exit
      local path = user_mod.filepath(root)
      local data = read_signed(path, "user")
      data.profiles.Dev = nil
      data.active_profile = nil
      assert(io_mod.write_json_signed(path, "user", data))
      local other_set = find(ws._config_sets, "name", "Other")
      local r = mc.profile_create(ws, other_set, nil, true)
      assert_refused(r, "changed on disk")
      -- The refusal reloaded from disk: the undo must not put back the
      -- pre-reload active profile (Dev, now removed).
      assert.is_nil(ws._active_profile_key)
      assert.is_true(ws._active_profile == nil or not ws._active_profile._removed)
      assert.is_nil(find(ws._profiles, "_configuration_set_name", "Dev"))
      assert.is_nil(read_signed(path, "user").active_profile)
    end)

    it("a save refused as stale keeps the reloaded state (no undo over it): set_intent", function()
      ws._core._deps.on_save_refused = function() end -- the CLI's would exit
      local path = user_mod.filepath(root)
      local data = read_signed(path, "user")
      data.intent.configuration_sets.Dev = "local"
      assert(io_mod.write_json_signed(path, "user", data))
      local dev = find(ws._config_sets, "name", "Dev")
      assert.equals("local+shared", dev._intent)
      assert_refused(mc.set_intent(dev, "shared"), "changed on disk")
      local now = find(ws._config_sets, "name", "Dev")
      assert.equals("local", now._intent)
      assert.equals("local", read_signed(path, "user").intent.configuration_sets.Dev)
    end)

    it("set_active makes the profile active; a removed one is refused", function()
      local other = find(ws._profiles, "_configuration_set_name", "Other")
      assert_ok(mc.profile_set_active(other))
      assert.equals(other.key, ws._active_profile_key)
      other._removed = true
      assert_refused(mc.profile_set_active(other), "has been removed")
    end)

    it("create returns the profile of a set, local, and the existing one again", function()
      local cs = assert(mc.config_set_add(ws, "Third", { [app] = app:get_configuration("Debug") }).config_set)
      local r = mc.profile_create(ws, cs, nil, false)
      assert_ok(r)
      assert.equals("local", r.profile._intent)
      assert.equals(cs, r.config_set)
      local again = mc.profile_create(ws, cs, nil, false)
      assert.equals(r.profile, again.profile)
    end)

    it("create from a candidate token adds the automatic set first; a stale token is refused", function()
      ws.generate_default_config_sets = function() return { Auto = { App = "Debug" } } end
      local auto
      for _, s in ipairs(mc.config_set_candidates(ws).sets) do
        if s.auto then auto = s end
      end
      assert.equals("Auto", auto.name)
      assert.is_nil(auto.config_set)
      local r = mc.profile_create(ws, { candidate = auto.candidate }, nil, false)
      assert_ok(r)
      assert.equals("Auto", r.config_set.name)
      -- The set exists now: the token stands for nothing any more.
      assert_refused(mc.profile_create(ws, { candidate = auto.candidate }, nil, false), "changed since it was listed")
    end)

    it("add_tool / remove_tool change the toolchain and re-derive the key", function()
      local dev = find(ws._profiles, "_configuration_set_name", "Dev")
      local before = dev.key
      assert_ok(mc.profile_add_tool(dev, "gcc-x"))
      assert.same({ "gcc-x" }, dev._tool_keys)
      assert.are_not.equal(before, dev.key)
      assert_ok(mc.profile_remove_tool(dev, "gcc-x"))
      assert.equals(before, dev.key)
      assert_refused(mc.profile_add_tool(dev, ""), "no toolchain", 2)
    end)

    it("add_tool / remove_tool whose save fails are refused and leave the profile unchanged", function()
      local dev = find(ws._profiles, "_configuration_set_name", "Dev")
      local before = dev.key
      local remerged = 0
      local real_remerge = ws.remerge
      ws.remerge = function(...) remerged = remerged + 1; return real_remerge(...) end
      ws._no_write = "read-only working copy"
      assert_refused(mc.profile_add_tool(dev, "gcc-x"), "read-only working copy")
      assert.same({}, dev._tool_keys or {})
      assert.equals(before, dev.key)
      ws._no_write = nil
      assert_ok(mc.profile_add_tool(dev, "gcc-x"))
      local with_tool = dev.key
      ws._no_write = "read-only working copy"
      remerged = 0
      assert_refused(mc.profile_remove_tool(dev, "gcc-x"), "read-only working copy")
      assert.same({ "gcc-x" }, dev._tool_keys)
      assert.equals(with_tool, dev.key)
      assert.equals(0, remerged)
    end)

    it("create whose save fails is refused and adds no profile", function()
      local cs = assert(mc.config_set_add(ws, "Third", { [app] = app:get_configuration("Debug") }).config_set)
      local count = #ws._profiles
      local active = ws._active_profile
      ws._no_write = "read-only working copy"
      assert_refused(mc.profile_create(ws, cs, nil, false), "read-only working copy")
      assert.equals(count, #ws._profiles)
      assert_refused(mc.profile_create(ws, cs, nil, true), "read-only working copy")
      assert.equals(count, #ws._profiles)
      assert.equals(active, ws._active_profile)
    end)
  end)

  describe("Projects/1", function()
    it("add declares the project and maps it by set name", function()
      local r = mc.project_add(ws, "B", "typescript", "B", { Dev = "Debug" }, nil)
      assert_ok(r)
      assert.equals("B", r.project.key)
      local dev = find(ws._config_sets, "name", "Dev")
      assert.is_truthy(dev:configuration(r.project))
      assert_refused(mc.project_add(ws, "B", "typescript", "B", nil, nil))
    end)

    it("add of a keyed module without a tool is unmapped, with a warn naming the mappings not made", function()
      local r = mc.project_add(ws, "C", "cmake", "B", { Dev = "Debug" }, nil)
      assert_ok(r)
      assert.equals("C", r.project.key)
      local dev = find(ws._config_sets, "name", "Dev")
      assert.is_falsy(dev:configuration(r.project))
      assert.same({ "warn" }, r.note_roles)
      assert.is_truthy(r.notes[1]:find("Dev", 1, true), r.notes[1])
      assert.is_truthy(r.notes[1]:find("no toolchain", 1, true), r.notes[1])
      -- The editor's add without a toolchain sends its initial mappings; the
      -- adapter drops them (the dialog hides them until a tool is chosen).
      local ok, err = require("loomworks.workspace_view").execute_add_project(ws, "D", "cmake", "B",
        { mappings = { Dev = "Debug" } })
      assert.is_true(ok, err)
    end)

    it("add maps the known sets and warns naming an unknown set", function()
      local r = mc.project_add(ws, "B", "typescript", "B", { Dev = "Debug", Nope = "Debug" }, nil)
      assert_ok(r)
      assert.is_truthy(find(ws._config_sets, "name", "Dev"):configuration(r.project))
      assert.same({ "warn" }, r.note_roles)
      assert.is_truthy(r.notes[1]:find("'Nope'", 1, true), r.notes[1])
    end)

    it("add whose profile upgrade fails is ok with a warn note (D1)", function()
      ws.upgrade_profiles_for_tool = function() return false, "workspace busy" end
      local r = mc.project_add(ws, "B", "typescript", "B", {}, { tool_key = "t", tool_mod_type = "typescript" })
      assert_ok(r)
      assert.equals("B", r.project.key)
      assert.same({ "warn" }, r.note_roles)
      assert.is_truthy(r.notes[1]:find("not upgraded to the tool: workspace busy", 1, true), r.notes[1])
      -- The editor's adapter still reports it as the error it was.
      local ok, err, project = require("loomworks.workspace_view").execute_add_project(ws, "C", "typescript", "B",
        { mappings = {}, tool_entry = { tool_key = "t", tool_mod_type = "typescript" } })
      assert.is_false(ok)
      assert.equals("C", project.key)
      assert.is_truthy(err:find("not upgraded to the tool: workspace busy", 1, true), err)
    end)

    it("launch_save creates, renames keeping the object, and refuses foreign/removed launches", function()
      local r = mc.launch_save(app, nil, "serve", { command = "node", args = { "s.js" } })
      assert_ok(r)
      local serve = r.launch
      assert.equals("serve", serve.name)
      r = mc.launch_save(app, serve, "serve2", { command = "node", args = { "t.js" } })
      assert_ok(r)
      assert.equals(serve, r.launch)
      assert.equals("serve2", serve.name)
      assert.same({ "t.js" }, serve.args)
      assert.same({ "t.js" }, user_json(root).projects.App.launch.serve2.args)

      assert_refused(mc.launch_save(app, nil, "-bad", { command = "x" }), "invalid launch name", 2)
      local b = assert(mc.project_add(ws, "B", "typescript", "B", nil, nil).project)
      assert_refused(mc.launch_save(b, serve, "x", { command = "x" }), "no launch config 'serve2' on project 'B'")
      assert_refused(mc.launch_remove(b, serve), "not found")
    end)

    it("launch_remove removes the launch and marks the object removed", function()
      local run = app:find_launch("run")
      assert_ok(mc.launch_remove(app, run))
      assert.is_true(run:is_removed())
      assert_refused(mc.launch_remove(app, run), "not found")
      assert_refused(mc.launch_save(app, run, "run", { command = "x" }), "no launch config 'run'")
    end)

    it("configuration_save creates and renames; configuration_remove removes", function()
      local r = mc.configuration_save(app, nil, "Rel", { options = { A = "1" } })
      assert_ok(r)
      local rel = r.configuration
      assert.equals("Rel", rel.name)
      r = mc.configuration_save(app, rel, "Rel2", { options = { A = "2" } })
      assert_ok(r)
      assert.equals("Rel2", r.configuration.name)
      assert_ok(mc.configuration_remove(app, r.configuration))
      assert.is_nil(app:get_configuration("Rel2"))
      local b = assert(mc.project_add(ws, "B", "typescript", "B", nil, nil).project)
      assert_refused(mc.configuration_remove(b, app:get_configuration("Debug")), "is not of project 'B'")
    end)

    it("variable / deploy / options writes, and a removed project is refused", function()
      assert_ok(mc.variable_save(app, nil, "out", { type = "path", default = "dist" }))
      assert_ok(mc.variable_save(app, "out", "outdir", { type = "path", default = "dist" }))
      assert.is_nil(app.variables.out)
      assert.equals("dist", app.variables.outdir.default)
      assert_ok(mc.variable_remove(app, "outdir"))
      assert_ok(mc.deploy_save(app, { ["${build_dir}/a"] = { project = "App", path = "a" } }))
      assert.is_truthy(app.deploy)
      assert_ok(mc.deploy_save(app, {}))
      assert.is_nil(app.deploy)
      assert_ok(mc.options_save(app, { X = "1" }))
      app._removed = true
      assert_refused(mc.options_save(app, { X = "2" }), "project 'App' has been removed")
      assert_refused(mc.launch_save(app, nil, "y", { command = "y" }), "project 'App' has been removed")
    end)
  end)

  describe("ConfigSets/1", function()
    it("add takes Project → Configuration mappings", function()
      local r = mc.config_set_add(ws, "New", { [app] = app:get_configuration("Debug") })
      assert_ok(r)
      assert.equals(app:get_configuration("Debug"), r.config_set:configuration(app))
      assert_refused(mc.config_set_add(ws, "New", {}))
    end)

    it("add / update refuse a removed project or configuration in the mappings, writing nothing", function()
      local dev = find(ws._config_sets, "name", "Dev")
      local cfg = app:get_configuration("Debug")
      local path = root .. "/.nvim/loomworks.user.json"
      local function text() local f = assert(io.open(path, "r")); local c = f:read("*a"); f:close(); return c end
      local before = text()
      -- An external change removed App's configuration while the editor
      -- had it listed: accepting App → it must not write.
      cfg._removed = true
      assert_refused(mc.config_set_update(dev, "Develop", { [app] = cfg }), "configuration 'App/Debug' has been removed")
      assert_refused(mc.config_set_add(ws, "New", { [app] = cfg }), "configuration 'App/Debug' has been removed")
      cfg._removed = false
      app._removed = true
      assert_refused(mc.config_set_update(dev, nil, { [app] = cfg }), "has been removed")
      assert_refused(mc.config_set_add(ws, "New", { [app] = false }), "project 'App' has been removed")
      app._removed = false
      assert.equals("Dev", dev.name)
      assert.is_nil(find(ws._config_sets, "name", "New"))
      assert.equals(before, text())
    end)

    it("update renames (the active profile follows) and replaces the mappings", function()
      local dev = find(ws._config_sets, "name", "Dev")
      assert_ok(mc.config_set_update(dev, "Develop", { [app] = app:get_configuration("Debug") }))
      assert.equals("Develop", dev.name)
      assert.is_truthy(ws._active_profile_key:find("Develop", 1, true), ws._active_profile_key)
      assert_ok(mc.config_set_update(dev, nil, {}))
      assert.is_nil(dev:configuration(app))
    end)

    it("remove drops the declaration; a removed set is refused", function()
      local other = find(ws._config_sets, "name", "Other")
      assert_ok(mc.config_set_remove(other))
      assert.is_nil(find(ws._config_sets, "name", "Other"))
      other._removed = true
      assert_refused(mc.config_set_remove(other), "configuration set 'Other' has been removed")
    end)

    it("generate_defaults adds the missing automatic sets and names them", function()
      ws.generate_default_config_sets = function() return { Auto = { App = "Debug" }, Dev = { App = "Debug" } } end
      local r = mc.config_set_generate_defaults(ws)
      assert_ok(r)
      assert.equals(1, #r.config_sets)
      assert.equals("Auto", r.config_sets[1].name)
      assert.same({ "added configuration set 'Auto'" }, r.notes)
    end)
  end)

  describe("Sdks/1", function()
    it("remove refuses a missing SDK", function()
      assert_refused(mc.sdk_remove(ws, nil), "stale reference")
    end)
  end)

  -- Guard ratchet (5o A1): the status page's sections and dialogs write the
  -- model only through the command layer, never `_save_user` / `remerge` or
  -- a direct persisting mutation of a domain object.
  it("ui/ never saves the working copy, remerges, or mutates a domain object itself", function()
    local found = {}
    local base = vim.fn.getcwd() .. "/lua/loomworks/ui"
    for _, path in ipairs(vim.fn.globpath(base, "**/*.lua", false, true)) do
      local fh = assert(io.open(path, "r"))
      local n = 0
      for line in fh:lines() do
        n = n + 1
        if line:find("_save_user%(") or line:find(":remerge%(") or line:find(":activate%(")
            or line:find(":deactivate%(") or line:find(":add_tool%(") or line:find(":remove_tool%(")
            or line:find(":update_mapping%(") then
          found[#found + 1] = path:gsub("\\", "/"):match("lua/loomworks/ui/.*$") .. ":" .. n
        end
      end
      fh:close()
    end
    assert.same({}, found)
  end)
end)

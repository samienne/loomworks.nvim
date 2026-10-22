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

    --- A detected toolchain `gcc-x` (the shell of these tests detects none).
    local function with_gcc_x() ws:get_or_create_tool("typescript", "gcc-x", {}, "GCC x") end

    it("add_tool / remove_tool change the toolchain and re-derive the key", function()
      with_gcc_x()
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
      with_gcc_x()
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

    it("set_active whose save fails is refused and keeps the active profile", function()
      local dev = find(ws._profiles, "_configuration_set_name", "Dev")
      local other = find(ws._profiles, "_configuration_set_name", "Other")
      assert.equals(dev, ws._active_profile)
      ws._no_write = "read-only working copy"
      assert_refused(mc.profile_set_active(other), "read-only working copy")
      assert.equals(dev, ws._active_profile)
      assert.equals(dev.key, ws._active_profile_key)
    end)

    it("add_tool refuses a toolchain that does not resolve; remove_tool one the profile lacks", function()
      with_gcc_x()
      local dev = find(ws._profiles, "_configuration_set_name", "Dev")
      local before = dev.key
      local file = io_mod.read_file(user_mod.filepath(root))
      assert_refused(mc.profile_add_tool(dev, "typo"), "no toolchain 'typo'")
      assert.same({}, dev._tool_keys or {})
      assert.equals(before, dev.key)
      assert_refused(mc.profile_remove_tool(dev, "gcc-x"), "no toolchain 'gcc-x' on profile")
      assert.equals(before, dev.key)
      assert.equals(file, io_mod.read_file(user_mod.filepath(root)))
    end)

    it("add_tool / remove_tool whose commit fails are refused and restore the profile", function()
      with_gcc_x()
      local dev = find(ws._profiles, "_configuration_set_name", "Dev")
      local before = dev.key
      local real_finish = ws._txn_finish
      ws._txn_finish = function(self, t) self:_txn_abort(t); return false, "commit failed" end
      assert_refused(mc.profile_add_tool(dev, "gcc-x"), "commit failed")
      assert.same({}, dev._tool_keys or {})
      assert.equals(before, dev.key)
      ws._txn_finish = real_finish
      with_gcc_x() -- the restoring remerge drops the injected (undetected) tool
      assert_ok(mc.profile_add_tool(dev, "gcc-x"))
      local with_tool = dev.key
      ws._txn_finish = function(self, t) self:_txn_abort(t); return false, "commit failed" end
      assert_refused(mc.profile_remove_tool(dev, "gcc-x"), "commit failed")
      assert.same({ "gcc-x" }, dev._tool_keys)
      assert.equals(with_tool, dev.key)
      ws._txn_finish = real_finish
      -- A later unrelated save writes the profile as it is (with the tool).
      assert_ok(mc.profile_set_active(dev))
      local saved
      for _, p in pairs(user_json(root).profiles or {}) do
        if type(p) == "table" and p.configuration_set == "Dev" then saved = p end
      end
      if saved then assert.same({ "gcc-x" }, saved.tools) end
    end)

    --- Mark the items Profile:activate's cascade materializes `shared`.
    local function shared_items(profile)
      local items = { profile, profile._config_set_ref }
      for project, cfg in pairs(profile._config_set_ref.mappings or {}) do
        items[#items + 1] = project
        if type(cfg) == "table" then items[#items + 1] = cfg end
      end
      for _, o in ipairs(items) do o._intent = "shared" end
      return items
    end

    it("set_active whose save fails restores the intents its cascade changed", function()
      local other = find(ws._profiles, "_configuration_set_name", "Other")
      local items = shared_items(other)
      ws._no_write = "read-only working copy"
      assert_refused(mc.profile_set_active(other), "read-only working copy")
      for _, o in ipairs(items) do assert.equals("shared", o._intent, tostring(o.key or o.name)) end
    end)

    it("create --activate whose save fails restores the intents its cascade changed", function()
      local other = find(ws._profiles, "_configuration_set_name", "Other")
      local items = shared_items(other)
      ws._no_write = "read-only working copy"
      assert_refused(mc.profile_create(ws, other._config_set_ref, nil, true), "read-only working copy")
      for _, o in ipairs(items) do assert.equals("shared", o._intent, tostring(o.key or o.name)) end
    end)

    it("tool_choices lists the keyed toolchains of the set's module types, for a set or a candidate", function()
      ws._tools_by_type = { typescript = { { tool_key = "t1", tool_label = "T one", tool_data = {} } },
        cmake = { { tool_key = "c1", tool_label = "C one", tool_data = {} } } }
      local dev = find(ws._config_sets, "name", "Dev")
      local r = mc.profile_tool_choices(ws, dev)
      assert_ok(r)
      assert.equals(1, #r.tools)
      assert.equals("typescript", r.tools[1].tool_mod_type)
      assert.equals("t1", r.tools[1].tool_key)
      ws.generate_default_config_sets = function() return { Auto = { App = "Debug" } } end
      local auto
      for _, s in ipairs(mc.config_set_candidates(ws).sets) do if s.auto then auto = s end end
      r = mc.profile_tool_choices(ws, { candidate = auto.candidate })
      assert_ok(r)
      assert.equals("t1", r.tools[1].tool_key)
      assert_refused(mc.profile_tool_choices(ws, { candidate = "auto:nope" }), "changed since it was listed")
      dev._removed = true
      assert_refused(mc.profile_tool_choices(ws, dev), "has been removed")
    end)

    it("add_tool is refused while another process holds the operation lock; nothing changes", function()
      with_gcc_x()
      local L = require("tests.lock_helpers")
      local op_lock = require("loomworks.op_lock")
      local dev = find(ws._profiles, "_configuration_set_name", "Dev")
      local before = dev.key
      local file = io_mod.read_file(user_mod.filepath(root))
      ws._core._deps.on_lock_refused = function() end -- the CLI's would exit
      local h = L.hold(op_lock.path(root), "import")
      local ok, r = pcall(mc.profile_add_tool, dev, "gcc-x")
      L.cleanup()
      assert.is_true(ok, r)
      assert_refused(r, "pid " .. h.pid)
      assert.equals(before, dev.key)
      assert.equals(file, io_mod.read_file(user_mod.filepath(root)))
      assert_ok(mc.profile_add_tool(dev, "gcc-x"))
      assert.is_nil(op_lock.read(root), "O left behind")
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

    --- A fake provider whose installations always identify themselves.
    local function fake_provider()
      package.loaded["loomworks.sdks.fake_mc"] = nil
      package.preload["loomworks.sdks.fake_mc"] = function()
        local SDK = require("loomworks.sdk")
        local P = { id = "fake_mc", api_version = require("loomworks.api_versions").sdk, display_name = "Fake MC" }
        function P.validate() return { version = "1" } end
        function P.create_sdk(key, path, version)
          return SDK.new({ key = key, type = "fake_mc", version = version, path = path, resolved = true, provider = P })
        end
        function P.detect_all() return {} end
        return P
      end
    end

    it("remove removes the SDK object it is given, never another one of its key", function()
      fake_provider()
      local declared = assert(mc.sdk_add(ws, "fake_mc", root).sdk)
      -- An SDK object of the same key that is not the declared one.
      local other = require("loomworks.sdk").new({ key = declared.key, type = "fake_mc", version = "1",
        path = root, resolved = true, provider = declared._provider })
      assert_refused(mc.sdk_remove(ws, other), "is not declared")
      assert.is_falsy(declared._removed)
      assert.equals(declared, find(ws._sdks, "key", declared.key))
      assert_ok(mc.sdk_remove(ws, declared))
      assert.is_true(declared._removed)
    end)

    it("the editor's add and remove (workspace_view) detect the toolchains again, without waiting", function()
      fake_provider()
      local deps = ws._core._deps
      local saved = deps.detect_tools_async
      local scans, pending = {}, {}
      -- Detection never completes here: the editor path must not wait for it.
      deps.detect_tools_async = function(_, _, cb, opts) scans[#scans + 1] = opts; pending[#pending + 1] = cb end
      local ok_, err = pcall(function()
        local wv = require("loomworks.workspace_view")
        local sdk = assert(wv.add_sdk(ws, "fake_mc", root))
        assert.equals(1, #scans, "add started a detection")
        assert.is_true(scans[1].force)
        assert.equals("scanning", ws._tool_state)
        local okr, rerr = wv.remove_sdk(ws, sdk)
        assert(okr, rerr)
        assert.equals(2, #scans, "remove started a detection")
        assert.is_true(scans[2].force)
      end)
      deps.detect_tools_async = saved
      assert(ok_, err)
    end)

    it("detect names each provider, its path prompt and the installations it finds; an unknown provider is refused", function()
      package.preload["loomworks.sdks.fake_detect"] = function()
        return { id = "fake_detect", api_version = require("loomworks.api_versions").sdk,
          display_name = "Fake Detect", path_prompt = "Path to the fake",
          detect_all = function()
            return { { path = "/opt/fake", version = "1" }, { version = "2" }, { path = "/opt/fake-nover" } }
          end }
      end
      local r = mc.sdk_detect("fake_detect")
      assert_ok(r)
      assert.same({ { id = "fake_detect", label = "Fake Detect", path_prompt = "Path to the fake",
        found = { { path = "/opt/fake", version = "1" }, { path = "/opt/fake-nover" } } } }, r.providers)
      assert_refused(mc.sdk_detect("no_such_provider"), "no provider for SDK type 'no_such_provider'")
      r = mc.sdk_detect(nil)
      assert_ok(r)
      assert.is_table(r.providers)
    end)
  end)

  describe("Toolchains/1", function()
    it("rescan detects every module type again, never reusing a cached result", function()
      local seen
      local deps = ws._core._deps
      local saved = deps.detect_tools_async
      deps.detect_tools_async = function(_, _, cb, opts) seen = opts; cb({}) end
      local ok_, err = pcall(function() assert_ok(mc.tools_rescan(ws)) end)
      deps.detect_tools_async = saved
      assert(ok_, err)
      assert.is_true(seen and seen.force == true)
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

-- Step 5o C2c-2: the in-process `Maintenance/1.nuke` (the status page's
-- `<C-n>` in the `in-process` mode): the daemon's order on the editor's core.
describe("model_commands.nuke", function()
  local function fake_core(check)
    local core = { nuked = {}, checked = {} }
    core._deps = { normalize = function(p) return p end }
    function core:nuke_check(root, opts)
      self.checked[#self.checked + 1] = { root, opts }
      return check()
    end
    function core:_nuke_lock_dirs() return { { key = "/w/.nvim/build/a" } } end
    function core:nuke_targets(root, areas)
      local t = { root .. "/.nvim/build/" }
      for _, a in ipairs(areas or {}) do t[#t + 1] = a .. "/" end
      return t
    end
    function core:nuke_cache(root) self.nuked[#self.nuked + 1] = root; return self.ran ~= false end
    return core
  end

  it("refuses a held lock before the listing, confirms with the plan, refuses a changed plan, then nukes", function()
    local core = fake_core(function() return nil, "cannot nuke: held by lw build (pid 7)" end)
    local r = mc.nuke(core, "/w", nil, false)
    assert.same({ "refused", "cannot nuke: held by lw build (pid 7)" }, { r.outcome, r.message })
    assert.same({ { "/w", { skip_own = true } } }, core.checked)
    core = fake_core(function() return true, nil, { "/w/.nvim/cache/cc" } end)
    local c = mc.nuke(core, "/w", nil, false)
    assert.equals("confirm", c.outcome)
    assert.same({ mc.NUKE_HEADER, "  /w/.nvim/build/", "  /w/.nvim/cache/cc/" }, c.lines)
    assert.equals(mc.nuke_plan(core, "/w", { "/w/.nvim/cache/cc" }).token, c.plan)
    r = mc.nuke(core, "/w", "stale", true)
    assert.same({ "refused", require("loomworks.deletion_plan").CHANGED }, { r.outcome, r.message })
    assert.same({}, core.nuked)
    assert.same({ outcome = "ok" }, mc.nuke(core, "/w", c.plan, true))
    assert.same({ "/w" }, core.nuked)
    core.ran = false
    assert.equals("refused", mc.nuke(core, "/w", c.plan, true).outcome)
  end)

  -- A real core with a live workspace: the confirm-time plan includes the
  -- unit build dirs, and the under-lock plan (after the workspace was
  -- retired) must be computed over the same inputs.
  local function real_core()
    local is_win = vim.fn.has("win32") == 1
    local function norm(p)
      p = (p or ""):gsub("\\", "/"):gsub("/+$", "")
      return is_win and p:lower() or p
    end
    local Core = require("loomworks.core")
    local core = Core.new({ notify = function() end, normalize = norm,
      modules = { list = function() return {} end, get = function() end } })
    core.setup = function() end
    return core
  end
  local function touch(p, text)
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    local f = assert(io.open(p, "w")); f:write(text or "x"); f:close()
  end
  local function tmp_root()
    local uv = vim.uv or vim.loop
    local t = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(t, "p")
    return (uv.fs_realpath(t):gsub("\\", "/"))
  end
  local function exists(p) return (vim.uv or vim.loop).fs_lstat(p) ~= nil end

  it("runs a confirmed plan when the live workspace has a unit under .nvim/build", function()
    local root = tmp_root()
    touch(root .. "/loomworks.json", "{}")
    touch(root .. "/.nvim/build/App/Debug/CMakeCache.txt")
    local core = real_core()
    core._workspace = { _config_units = { { build_dir_value = root .. "/.nvim/build/App/Debug" } } }
    local c = mc.nuke(core, root, nil, false)
    assert.equals("confirm", c.outcome)
    local r = mc.nuke(core, root, c.plan, true)
    assert.equals("ok", r.outcome, tostring(r.message))
    assert.is_false(exists(root .. "/.nvim/build/App/Debug/CMakeCache.txt"))
    vim.fn.delete(root, "rf")
  end)

  it("refuses a confirmed plan when a build dir appears while the workspace is retired", function()
    local root = tmp_root()
    touch(root .. "/loomworks.json", "{}")
    touch(root .. "/.nvim/build/App/Debug/CMakeCache.txt")
    local core = real_core()
    core._workspace = {
      _config_units = { { build_dir_value = root .. "/.nvim/build/App/Debug" } },
      -- Retirement pumps the event loop: a lockfile appears meanwhile.
      -- (A dead holder's record on this host: reclaimed, so the nuke would
      -- otherwise run and remove a directory that was never listed.)
      teardown = function()
        local lr = require("loomworks.lock_record")
        local rec = lr.new("build")
        rec.pid, rec.start_time = 2147483000, "1"
        vim.fn.mkdir(root .. "/.nvim/build/New", "p")
        assert(lr.create(root .. "/.nvim/build/New/Rel.loomworks-lock", rec))
      end,
    }
    local c = mc.nuke(core, root, nil, false)
    assert.equals("confirm", c.outcome)
    local r = mc.nuke(core, root, c.plan, true)
    assert.same({ "refused", require("loomworks.deletion_plan").CHANGED }, { r.outcome, r.message })
    assert.is_true(exists(root .. "/.nvim/build/App/Debug/CMakeCache.txt"))
    vim.fn.delete(root, "rf")
  end)

  it("releases the locks and refuses when the under-lock check throws", function()
    local root = tmp_root()
    touch(root .. "/loomworks.json", "{}")
    touch(root .. "/.nvim/build/App/Debug/CMakeCache.txt")
    local core = real_core()
    local ran, msg = core:nuke_cache(root, { quiet = true, check = function() error("boom") end })
    assert.is_false(ran)
    assert.matches("boom", tostring(msg))
    assert.is_true(exists(root .. "/.nvim/build/App/Debug/CMakeCache.txt"))
    -- The locks were released: a check takes them again.
    assert.is_true(core:nuke_check(root))
    vim.fn.delete(root, "rf")
  end)

  it("is the daemon's plan and listing (one implementation)", function()
    local maint = require("loomworks.daemon.maintenance")
    assert.equals(mc.nuke_plan, maint.nuke_plan)
    assert.equals(mc.nuke_listing, maint.nuke_listing)
    assert.equals(mc.NUKE_HEADER, maint.NUKE_HEADER)
  end)
end)


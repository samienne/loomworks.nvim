-- Descriptions through the data model (spec §1.10, §2.4): the four locations
-- round-trip through load → save user.json → reload, publish (full and
-- per-item) writes them where the spec puts them, blank text removes the key,
-- CRLF is normalised without a spurious `+`, a description change is a
-- content change (`+`), auto-sync / revert / rename / delete carry them, a
-- configuration's description never makes a unit stale, generated
-- configurations refuse one, and an older file without descriptions
-- re-serialises unchanged.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, e = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  if not ok and not (type(e) == "table" and e.__exit) then error(e, 0) end
  return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local c = f:read("*a"); f:close()
  return c
end

local function write_file(path, content)
  local f = assert(io.open(path, "wb"))
  f:write(content); f:close()
end

local function read_json(path)
  local c = read_file(path)
  if not c then return nil end
  -- The working copy carries a signature header line; decode the JSON body.
  local body = c:match("^[^\n]*\n(.*)$")
  local ok, v = pcall(vim.json.decode, c)
  if ok then return v end
  return vim.json.decode(body)
end

local function user_json(root) return read_json(root .. "/.nvim/loomworks.user.json") end
local function shared_json(root) return read_json(root .. "/loomworks.json") end

--- A temp workspace: typescript App, a user `Debug` config (inheriting
--- variant:default), a `Dev` set (App=Debug) and an active `Dev` profile.
local function make_ws(extra_lw)
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  write_file(root .. "/App/tsconfig.json", "{}")
  local lw = extra_lw or { projects = { App = { typescript = vim.empty_dict() } } }
  write_file(root .. "/loomworks.json", vim.json.encode(lw))
  capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
  capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
  return root
end

local function find_project(ws, key)
  for _, p in pairs(ws._projects) do if p.key == key then return p end end
end

local function find_set(ws, name)
  for _, cs in pairs(ws._config_sets) do if cs.name == name then return cs end end
end

local function load(root)
  return assert(cli._load_workspace(root, false))
end

local function items(ws)
  local project = find_project(ws, "App")
  local cfg = project:get_configuration("Debug")
  local cs = find_set(ws, "Dev")
  local profile
  for _, p in pairs(ws._profiles) do
    if p._configuration_set_name == "Dev" then profile = p end
  end
  return project, cfg, cs, profile
end

local function describe_all(ws, suffix)
  local project, cfg, cs, profile = items(ws)
  assert.is_true(project:set_description("Project summary" .. suffix .. "\n\nProject body"))
  assert.is_true(cfg:set_description("Debug summary" .. suffix))
  assert.is_true(cs:set_description("Set summary" .. suffix))
  assert.is_true(profile:set_description("Profile summary" .. suffix))
end

--- Publish App, Debug, the Dev set and the Dev profile. (Each item's own
--- intent is set: the published baseline after a full publish holds the items
--- whose own intent includes shared.)
local function publish_all(ws)
  local project, cfg, cs, profile = items(ws)
  project._intent = "local+shared"
  cfg._intent = "local+shared"
  cs._intent = "local+shared"
  profile._intent = "local+shared"
  assert.is_true(ws:publish())
end

describe("descriptions: working-copy round-trip", function()
  it("stores each location in user.json and reloads it", function()
    local root = make_ws()
    describe_all(load(root), "")

    local u = user_json(root)
    assert.equals("Project summary\n\nProject body", u.projects.App.typescript.description)
    assert.equals("Debug summary", u.projects.App.typescript.configurations.Debug.description)
    assert.equals("Set summary", u.configuration_set_descriptions.Dev)
    -- The set's own table is untouched (still a flat project → configuration map).
    assert.same({ App = "Debug" }, u.configuration_sets.Dev)
    local pdef
    for _, def in pairs(u.profiles) do pdef = def end
    assert.equals("Profile summary", pdef.description)
    -- No project-level key: an older lw would read it as a second module type.
    assert.is_nil(u.projects.App.description)

    local project, cfg, cs, profile = items(load(root))
    assert.equals("Project summary\n\nProject body", project.description)
    assert.equals("Debug summary", cfg.description)
    assert.equals("Set summary", cs.description)
    assert.equals("Profile summary", profile.description)
    -- Never part of the module's view.
    assert.is_nil(project.type_config.description)
    assert.is_nil(cfg.module_config.description)
  end)

  it("unchanged text writes nothing and reports false", function()
    local root = make_ws()
    local ws = load(root)
    local project = items(ws)
    assert.is_true(project:set_description("Same"))
    local before = read_file(root .. "/.nvim/loomworks.user.json")
    assert.is_false(project:set_description("Same  \r\n"))
    assert.equals(before, read_file(root .. "/.nvim/loomworks.user.json"))
  end)

  it("blank text clears the description and removes the key (never \"\")", function()
    local root = make_ws()
    local ws = load(root)
    describe_all(ws, "")
    local project, cfg, cs, profile = items(ws)
    assert.is_true(project:set_description("   \n  "))
    assert.is_true(cfg:set_description(""))
    assert.is_true(cs:set_description(nil))
    assert.is_true(profile:set_description("\r\n"))
    assert.is_nil(project.description)

    local text = read_file(root .. "/.nvim/loomworks.user.json")
    assert.is_nil(text:find('"description"', 1, true))
    assert.is_nil(text:find("configuration_set_descriptions", 1, true))
  end)

  it("normalises CRLF and trailing whitespace on write", function()
    local root = make_ws()
    local ws = load(root)
    local _, _, cs = items(ws)
    assert.is_true(cs:set_description("\r\nline one  \r\n\r\nline two\t\r\n\r\n"))
    assert.equals("line one\n\nline two", user_json(root).configuration_set_descriptions.Dev)
  end)

  it("refuses control characters and keeps the old text", function()
    local root = make_ws()
    local ws = load(root)
    local project = items(ws)
    assert.is_true(project:set_description("ok"))
    local changed, err = project:set_description("bad\27[31m")
    assert.is_nil(changed)
    assert.is_truthy(err:find("control character", 1, true))
    assert.equals("ok", project.description)
    local long_changed, long_err = project:set_description(string.rep("x", 5000))
    assert.is_nil(long_changed)
    assert.is_truthy(long_err:find("too long", 1, true))
  end)

  it("a generated configuration refuses a description", function()
    local root = make_ws()
    local ws = load(root)
    local project = items(ws)
    local gen = project:get_configuration("variant:default")
    assert.is_truthy(gen)
    local changed, err = gen:set_description("nope")
    assert.is_nil(changed)
    assert.is_truthy(err:find("inherits", 1, true))
    assert.is_nil(gen.description)
  end)

  it("a configuration edit (lw config set) keeps the description", function()
    local root = make_ws()
    local _, cfg = items(load(root))
    assert.is_true(cfg:set_description("Keep me"))
    local r = capture(function()
      cli.cmd_configuration("set", root, "App", "Debug", "options.FOO", "1")
    end)
    assert.is_nil(r.exit_code)
    local c = user_json(root).projects.App.typescript.configurations.Debug
    assert.equals("1", c.options.FOO)
    assert.equals("Keep me", c.description)
  end)

  it("a configuration rename keeps the description", function()
    local root = make_ws()
    local _, cfg = items(load(root))
    assert.is_true(cfg:set_description("Travels"))
    local r = capture(function() cli.cmd_configuration("rename", root, "App", "Debug", "Dbg") end)
    assert.is_nil(r.exit_code)
    local cfgs = user_json(root).projects.App.typescript.configurations
    assert.is_nil(cfgs.Debug)
    assert.equals("Travels", cfgs.Dbg.description)
    assert.equals("Travels", find_project(load(root), "App"):get_configuration("Dbg").description)
  end)

  it("a set rename moves the sidecar entry; a delete removes it", function()
    local root = make_ws()
    local ws = load(root)
    local _, _, cs = items(ws)
    assert.is_true(cs:set_description("Set text"))
    assert.is_true(ws:rename_configuration_set(cs, "Develop"))
    local u = user_json(root)
    assert.is_nil(u.configuration_set_descriptions.Dev)
    assert.equals("Set text", u.configuration_set_descriptions.Develop)
    -- The profile re-derived its key and kept its own description.
    ws = load(root)
    local renamed = find_set(ws, "Develop")
    assert.equals("Set text", renamed.description)
    assert.is_true(ws:remove_configuration_set(renamed))
    assert.is_nil(user_json(root).configuration_set_descriptions)
  end)

  it("a profile keeps its description across a key re-derivation", function()
    local root = make_ws()
    local ws = load(root)
    local _, _, cs, profile = items(ws)
    assert.is_true(profile:set_description("Mine"))
    local old_key = profile.key
    assert.is_true(ws:rename_configuration_set(cs, "Other"))
    assert.are_not.equal(old_key, profile.key)
    assert.equals("Mine", profile.description)
    local u = user_json(root)
    assert.equals("Mine", u.profiles[profile.key].description)
  end)

  it("a configuration description change never makes a unit stale", function()
    local root = make_ws()
    local ws = load(root)
    local _, cfg, _, profile = items(ws)
    local before = vim.deepcopy(cfg.module_config)
    local unit
    for _, u in pairs(ws._config_units) do
      if u._configuration == cfg then unit = u end
    end
    assert.is_truthy(unit, "the active profile materialised a unit for App/Debug")
    -- Pretend it was configured with the current inputs.
    unit._cached_module_config = vim.deepcopy(cfg.module_config)
    unit._cached_options = unit:resolved_option_fingerprint(profile)
    assert.is_nil(unit:stale_reason(profile))

    assert.is_true(cfg:set_description("Does not reconfigure"))
    assert.same(before, cfg.module_config)
    assert.is_nil(cfg.module_config.description)
    assert.is_nil(unit:stale_reason(profile))
  end)

  it("a non-string description is ignored, diagnosed, and written back unchanged", function()
    local root = make_ws()
    -- Hand-edit the working copy is refused (signed); use loomworks.json.
    local lw = shared_json(root)
    lw.projects.App.typescript.description = 12
    lw.configuration_sets = { Shared = { App = "Debug" } }
    lw.configuration_set_descriptions = { Shared = { "not", "text" } }
    write_file(root .. "/loomworks.json", vim.json.encode(lw))
    local ws = load(root)
    local project = find_project(ws, "App")
    -- The user.json declaration wins for the project; add a shared-only set.
    local shared_set = find_set(ws, "Shared")
    assert.is_nil(shared_set.description)
    assert.same({ "not", "text" }, shared_set._description_invalid)
    local found = false
    for _, d in ipairs(ws:diagnostics()) do
      if d.message:find("configuration set 'Shared'", 1, true)
          and d.message:find("not text", 1, true) then found = true end
    end
    assert.is_true(found)
    -- Publishing the set writes the value back as read.
    assert.is_true(ws:publish_one(shared_set))
    assert.same({ "not", "text" }, shared_json(root).configuration_set_descriptions.Shared)
    -- Setting it replaces the invalid value.
    assert.is_true(shared_set:set_description("Now text"))
    assert.is_nil(shared_set._description_invalid)
    assert.is_truthy(project)
  end)
end)

describe("descriptions: publish", function()
  it("full publish writes every location to loomworks.json", function()
    local root = make_ws()
    local ws = load(root)
    describe_all(ws, "")
    publish_all(ws)

    local s = shared_json(root)
    assert.equals("Project summary\n\nProject body", s.projects.App.typescript.description)
    assert.is_nil(s.projects.App.description)
    assert.equals("Debug summary", s.projects.App.typescript.configurations.Debug.description)
    assert.equals("Set summary", s.configuration_set_descriptions.Dev)
    assert.same({ App = "Debug" }, s.configuration_sets.Dev)
    local pdef
    for _, def in pairs(s.profiles) do pdef = def end
    assert.equals("Profile summary", pdef.description)

    -- Nothing is modified after a publish; a fresh load agrees.
    local project, cfg, cs, profile = items(ws)
    assert.is_false(ws:is_project_modified(project))
    assert.is_false(ws:is_config_modified(project, cfg))
    assert.is_false(ws:is_config_set_modified(cs))
    assert.is_false(ws:is_profile_modified(profile))
    ws = load(root)
    project, cfg, cs, profile = items(ws)
    assert.is_false(ws:is_project_modified(project))
    assert.is_false(ws:is_config_set_modified(cs))
    assert.is_false(ws:is_profile_modified(profile))
    assert.is_false(ws:has_any_modified())
  end)

  it("a description change on a published item marks it modified", function()
    local root = make_ws()
    local ws = load(root)
    describe_all(ws, "")
    publish_all(ws)
    local project, cfg, cs, profile = items(ws)

    assert.is_true(cs:set_description("Set changed"))
    assert.is_true(ws:is_config_set_modified(cs))
    assert.is_true(profile:set_description("Profile changed"))
    assert.is_true(ws:is_profile_modified(profile))
    assert.is_true(project:set_description("Project changed"))
    assert.is_true(ws:is_project_decl_modified(project))
    assert.is_true(cfg:set_description(nil))
    assert.is_true(ws:is_config_modified(project, cfg))
  end)

  it("CRLF / trailing-whitespace-only differences are not a change", function()
    local root = make_ws()
    local ws = load(root)
    describe_all(ws, "")
    publish_all(ws)
    -- Rewrite loomworks.json with CRLF + trailing blanks in every description.
    local s = shared_json(root)
    s.projects.App.typescript.description = "Project summary  \r\n\r\nProject body\r\n"
    s.projects.App.typescript.configurations.Debug.description = "Debug summary\r\n"
    s.configuration_set_descriptions.Dev = "\r\nSet summary \r\n"
    for _, def in pairs(s.profiles) do def.description = "Profile summary\t\r\n" end
    write_file(root .. "/loomworks.json", vim.json.encode(s))

    ws = load(root)
    local project, cfg, cs, profile = items(ws)
    assert.is_false(ws:is_project_modified(project))
    assert.is_false(ws:is_config_modified(project, cfg))
    assert.is_false(ws:is_config_set_modified(cs))
    assert.is_false(ws:is_profile_modified(profile))
  end)

  it("publish_one(set) writes its sidecar entry, keeps others, drops dangling ones", function()
    local root = make_ws({
      projects = { App = { typescript = vim.empty_dict() } },
      configuration_sets = { Other = { App = "variant:default" } },
      configuration_set_descriptions = { Other = "Other text", Ghost = "no such set" },
    })
    local ws = load(root)
    local _, _, cs = items(ws)
    assert.equals("Other text", find_set(ws, "Other").description)
    assert.is_true(cs:set_description("Dev text"))
    assert.is_true(ws:publish_one(cs))
    local s = shared_json(root)
    assert.equals("Dev text", s.configuration_set_descriptions.Dev)
    assert.equals("Other text", s.configuration_set_descriptions.Other)
    assert.is_nil(s.configuration_set_descriptions.Ghost)
    assert.is_false(ws:is_config_set_modified(cs))

    -- Clearing and re-publishing removes the entry (and an empty sidecar).
    assert.is_true(cs:set_description(nil))
    assert.is_true(ws:is_config_set_modified(cs))
    assert.is_true(ws:publish_one(cs))
    s = shared_json(root)
    assert.is_nil(s.configuration_set_descriptions.Dev)
    assert.equals("Other text", s.configuration_set_descriptions.Other)
  end)

  it("publish_one(project) writes the project and configuration descriptions", function()
    local root = make_ws()
    local ws = load(root)
    local project, cfg = items(ws)
    assert.is_true(project:set_description("P"))
    cfg._intent = "local+shared"
    assert.is_true(cfg:set_description("C"))
    assert.is_true(ws:publish_one(project))
    local s = shared_json(root)
    assert.equals("P", s.projects.App.typescript.description)
    assert.equals("C", s.projects.App.typescript.configurations.Debug.description)
  end)
end)

describe("descriptions: auto-sync and revert", function()
  it("an untouched item picks up an upstream change; an edited one keeps its own", function()
    local root = make_ws()
    local ws = load(root)
    describe_all(ws, "")
    publish_all(ws)

    -- The user edits the set's description; the project's stays untouched.
    local project, _, cs = items(ws)
    assert.is_true(cs:set_description("My set"))

    local s = shared_json(root)
    s.projects.App.typescript.description = "Upstream project"
    s.configuration_set_descriptions.Dev = "Upstream set"
    local content = vim.json.encode(s)
    write_file(root .. "/loomworks.json", content)
    ws:_on_file_changed(root .. "/loomworks.json", content)

    project, _, cs = items(ws)
    assert.equals("Upstream project", project.description)
    assert.equals("My set", cs.description)
    local u = user_json(root)
    assert.equals("Upstream project", u.projects.App.typescript.description)
    assert.equals("My set", u.configuration_set_descriptions.Dev)
  end)

  it("an untouched set picks up an upstream sidecar change", function()
    local root = make_ws()
    local ws = load(root)
    describe_all(ws, "")
    publish_all(ws)
    local s = shared_json(root)
    s.configuration_set_descriptions.Dev = "Upstream set"
    s.projects.App.typescript.configurations.Debug.description = "Upstream debug"
    local content = vim.json.encode(s)
    write_file(root .. "/loomworks.json", content)
    ws:_on_file_changed(root .. "/loomworks.json", content)
    local project, cfg, cs = items(ws)
    assert.equals("Upstream set", cs.description)
    assert.equals("Upstream debug", cfg.description)
    assert.is_false(ws:is_config_set_modified(cs))
    assert.is_false(ws:is_config_modified(project, cfg))
  end)

  it("revert_one restores the baseline description", function()
    local root = make_ws()
    local ws = load(root)
    describe_all(ws, "")
    publish_all(ws)
    local _, _, cs = items(ws)
    assert.is_true(cs:set_description("Edited"))
    assert.is_true(ws:revert_one(cs))
    cs = find_set(ws, "Dev")
    assert.equals("Set summary", cs.description)
    assert.is_false(ws:is_config_set_modified(cs))
    assert.equals("Set summary", user_json(root).configuration_set_descriptions.Dev)

    local project, cfg = items(ws)
    assert.is_true(cfg:set_description("Edited cfg"))
    assert.is_true(ws:revert_one(cfg))
    assert.equals("Debug summary", project:get_configuration("Debug").description)
  end)

  it("revert_to_baseline restores (or removes) every description", function()
    local root = make_ws()
    local ws = load(root)
    local project, cfg, cs, profile = items(ws)
    -- Publish with no project description, then add one locally.
    assert.is_true(cs:set_description("Set summary"))
    assert.is_true(profile:set_description("Profile summary"))
    publish_all(ws)
    project, cfg, cs, profile = items(ws)
    assert.is_true(project:set_description("Local only"))
    assert.is_true(cs:set_description("Edited set"))
    assert.is_true(profile:set_description("Edited profile"))
    assert.is_true(cfg:set_description("Edited cfg"))

    assert.is_true(ws:revert_to_baseline())
    project, cfg, cs, profile = items(ws)
    assert.is_nil(project.description)
    assert.is_nil(cfg.description)
    assert.equals("Set summary", cs.description)
    assert.equals("Profile summary", profile.description)
    assert.is_false(ws:has_any_modified())
  end)
end)

describe("descriptions: older files", function()
  it("a file without descriptions loads and re-serialises byte-identically", function()
    local root = make_ws()
    local ws = load(root)
    publish_all(ws)
    local shared1 = read_file(root .. "/loomworks.json")
    local user1 = read_file(root .. "/.nvim/loomworks.user.json")
    assert.is_nil(shared1:find("description", 1, true))
    assert.is_nil(user1:find("description", 1, true))

    ws = load(root)
    assert.is_true(ws:publish())
    assert.equals(shared1, read_file(root .. "/loomworks.json"))
    local project = items(ws)
    assert.is_nil(project.description)
  end)
end)

describe("descriptions: pull", function()
  it("a pulled set brings its sidecar entry (or its absence)", function()
    local target = {
      configuration_sets = { A = { P = "x" }, T = { P = "y" } },
      configuration_set_descriptions = { A = "target A", T = "target only" },
      profiles = { ["A"] = { configuration_set = "A", description = "old" } },
    }
    local source = {
      configuration_sets = { A = { P = "x" }, B = { P = "z" } },
      configuration_set_descriptions = { B = "source B" },
      profiles = { ["A"] = { configuration_set = "A", description = "new" } },
    }
    local merged = cli._pull_merge(target, source)
    assert.is_nil(merged.configuration_set_descriptions.A) -- source A has none
    assert.equals("source B", merged.configuration_set_descriptions.B)
    assert.equals("target only", merged.configuration_set_descriptions.T)
    assert.equals("new", merged.profiles.A.description)
  end)
end)

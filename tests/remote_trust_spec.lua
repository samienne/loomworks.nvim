-- Trust rules for the `device` block and `device_log` (spec §17.6, §18.9,
-- §18.13): stage/archive patterns and device_log options are honored from
-- shared config; a device block's env / working_dir are program-bearing and
-- used only from the signed working copy. Shape validation of both.

local program_fields = require("loomworks.program_fields")
local config = require("loomworks.config")
local fx = require("tests.remote_fixtures")

describe("device block trust (program_fields)", function()
    local function shared()
        return {
            projects = {
                App = {
                    type = "cmake", type_config = {},
                    device = { stage = { "bin/*.so" }, archive = { "assets/**" },
                        env = { LOG = "debug" }, working_dir = "bin" },
                    launch = {
                        tests = { target = "Runner", device_log = { show = "both", level = "W" },
                            device = { archive = { "data/**" }, env = { X = "1" }, working_dir = "data" } },
                    },
                },
            },
        }
    end

    it("strips env/working_dir, keeps stage/archive/device_log", function()
        local cfg = shared()
        local ignored = program_fields.strip(cfg, nil)
        local p = cfg.projects.App
        assert.same({ stage = { "bin/*.so" }, archive = { "assets/**" } }, p.device)
        local l = p.launch.tests
        assert.same({ archive = { "data/**" } }, l.device)
        assert.same({ show = "both", level = "W" }, l.device_log)
        assert.equals("Runner", l.target)
        local labels = {}
        for _, e in ipairs(ignored) do labels[#labels + 1] = e.label end
        table.sort(labels)
        assert.same({
            "projects.App.cmake.device.env", "projects.App.cmake.device.working_dir",
            "projects.App.launch.tests.device.env", "projects.App.launch.tests.device.working_dir",
        }, labels)
    end)

    it("regraft restores the ignored values into a published snapshot", function()
        local cfg = shared()
        local ignored = program_fields.strip(cfg, nil)
        local raw = { projects = { App = { cmake = { device = { stage = { "bin/*.so" } } },
            launch = { tests = { target = "Runner" } } } } }
        program_fields.regraft(raw, ignored)
        assert.same({ LOG = "debug" }, raw.projects.App.cmake.device.env)
        assert.is_nil(raw.projects.App.device)
        assert.equals("data", raw.projects.App.launch.tests.device.working_dir)
    end)

    it("the trust review lists the device block: env / working_dir as program settings, stage / archive as contents", function()
        local prog, other = program_fields.review({ projects = { App = {
            cmake = { device = { env = { LOG = "1" }, stage = { "x" }, archive = { "assets/**" } } },
            launch = { t = { target = "R", device = { working_dir = "w", stage = { "y" } } } } } } }, nil)
        local all = table.concat(prog, "\n")
        assert.truthy(all:find("projects.App.cmake.device.env", 1, true))
        assert.truthy(all:find("device.working_dir = w", 1, true))
        assert.falsy(all:find("device.stage", 1, true))
        local rest = table.concat(other, "\n")
        assert.truthy(rest:find("projects.App.cmake.device.stage", 1, true), rest)
        assert.truthy(rest:find("projects.App.cmake.device.archive", 1, true), rest)
        assert.truthy(rest:find("projects.App.launch.t.device.stage", 1, true), rest)
        -- The former project-level location is reviewed too.
        local prog2 = program_fields.review({ projects = { App = { cmake = {},
            device = { working_dir = "old" } } } }, nil)
        assert.truthy(table.concat(prog2, "\n"):find("projects.App.device.working_dir = old", 1, true))
    end)
end)

describe("device block validation (loomworks.json)", function()
    local root
    before_each(function() root = fx.mkroot(); vim.fn.mkdir(root .. "/App", "p") end)
    after_each(function() require("loomworks.io").rm_rf(root) end)

    it("accepts a valid block and rejects escaping patterns / bad device_log", function()
        local ok = config.validate({ projects = { App = { cmake = { device = { stage = { "a/*.so" } } },
            launch = { t = { target = "R", device_log = { show = "both" } } } } } }, root)
        assert.is_table(ok)
        assert.same({ stage = { "a/*.so" } }, ok.projects.App.device)
        local bad, err = config.validate({ projects = { App = { cmake = {
            device = { stage = { "../../etc/*" } } } } } }, root)
        assert.is_nil(bad)
        assert.truthy(err:find("device.stage", 1, true))
        bad, err = config.validate({ projects = { App = { cmake = {},
            launch = { t = { target = "R", device_log = { show = { nested = true } } } } } } }, root)
        assert.is_nil(bad)
        assert.truthy(err:find("device_log.show", 1, true))
    end)
end)

describe("device block location (spec §18.9)", function()
    local root, notes, orig_notify
    before_each(function()
        root = fx.mkroot(); vim.fn.mkdir(root .. "/App", "p")
        notes = {}
        orig_notify = vim.notify
        vim.notify = function(msg) notes[#notes + 1] = msg end
    end)
    after_each(function()
        vim.notify = orig_notify
        require("loomworks.io").rm_rf(root)
    end)

    it("reads the block from the module section; the module config never carries it", function()
        local raw = { projects = { App = { cmake = { device = { stage = { "a/*.so" } }, options = { X = "1" } } } } }
        local cfg = assert(config.validate(raw, root))
        assert.same({ stage = { "a/*.so" } }, cfg.projects.App.device)
        assert.equals("cmake", cfg.projects.App.type)
        assert.is_nil(cfg.projects.App.type_config.device)
        assert.same({ X = "1" }, cfg.projects.App.type_config.options)
        -- The raw file data is left untouched.
        assert.same({ stage = { "a/*.so" } }, raw.projects.App.cmake.device)
        local norm = assert(config.normalize_projects(raw.projects))
        assert.same({ stage = { "a/*.so" } }, norm.App.device)
        assert.is_nil(norm.App.type_config.device)
        assert.equals(0, #notes)
    end)

    it("still reads the former project-level block, with a one-line deprecation note", function()
        local cfg = assert(config.validate({ projects = { App = { cmake = {},
            device = { archive = { "assets/**" } } } } }, root))
        assert.same({ archive = { "assets/**" } }, cfg.projects.App.device)
        assert.equals(1, #notes)
        assert.truthy(notes[1]:find("projects.App.cmake.device", 1, true), notes[1])
        assert.is_nil(notes[1]:find("\n", 1, true))
        -- Both present: the module-section block wins.
        notes = {}
        cfg = assert(config.validate({ projects = { App = { cmake = { device = { stage = { "new" } } },
            device = { stage = { "old" } } } } }, root))
        assert.same({ stage = { "new" } }, cfg.projects.App.device)
        assert.equals(1, #notes)
    end)

    it("serializes the block into the module section (a legacy block migrates on save)", function()
        local Workspace = require("loomworks.workspace").Workspace
        local project = { key = "App", type = "cmake", type_config = { options = { X = "1" } },
            _configurations = {}, device = { stage = { "a/*.so" }, env = { K = "v" } } }
        for _, fn in ipairs({ "_serialize_project", "_serialize_project_shared" }) do
            local entry = Workspace[fn](nil, project, fn == "_serialize_project_shared" and {} or nil)
            assert.is_nil(entry.device, fn)
            assert.same({ stage = { "a/*.so" }, env = { K = "v" } }, entry.cmake.device, fn)
            assert.same({ X = "1" }, entry.cmake.options, fn)
        end
        assert.is_nil(project.type_config.device)
    end)

    it("the module-section location is backward compatible with the parse path of earlier releases", function()
        -- Earlier releases take every project key they do not know as a module
        -- type ("multiple type keys: cmake, device" for the old location) but
        -- hand the WHOLE module section to the module as its type config and
        -- write it back verbatim. The same path, run here on the new shape:
        local def = { cmake = { device = { stage = { "a/*.so" } }, configurations = {} } }
        local ptype, tc, err = config._extract_type(def)
        assert.is_nil(err)
        assert.equals("cmake", ptype)
        assert.same({ stage = { "a/*.so" } }, tc.device)
        local _, _, old_err = config._extract_type({ cmake = {}, deviceX = {} })
        assert.truthy(old_err and old_err:find("multiple type keys", 1, true))
        -- The cmake module accepts (ignores) the unknown module field.
        fx.write(root .. "/App/CMakeLists.txt", "project(App)\n")
        local res = require("loomworks.modules.cmake").validate(root .. "/App", tc)
        assert.is_true(res.valid)
        assert.equals(0, #res.warnings)
    end)
end)

describe("device block location through a workspace load + save", function()
    it("a legacy project-level block loads onto the project and is saved into the module section", function()
        local h = require("tests.helpers")
        local Core = require("loomworks.core")
        local saved
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = { App = { cmake = { device = { archive = { "assets/**" } } } } },
            }),
            ["loomworks.user.json"] = h.make_user_json({
                projects = { Lib = { cmake = {}, device = { stage = { "bin/*.so" } } } },
            }),
        }
        local orig_notify = vim.notify
        vim.notify = function() end
        local deps = h.make_test_deps(files, {
            user = { save = function(_, data) saved = vim.deepcopy(data); return true end },
        })
        local core = Core.new(deps)
        core:setup({ root = "/test" })
        core:remerge()
        vim.notify = orig_notify
        local ws = core:get_workspace()
        local function project(k) for _, p in ipairs(ws._projects) do if p.key == k then return p end end end
        assert.same({ archive = { "assets/**" } }, project("App").device)
        assert.same({ stage = { "bin/*.so" } }, project("Lib").device)
        assert.is_nil((project("App").type_config or {}).device)
        assert.is_true((ws:_save_user()))
        local lib = saved.projects.Lib
        assert.is_nil(lib.device)
        assert.same({ stage = { "bin/*.so" } }, lib.cmake.device)
    end)
end)

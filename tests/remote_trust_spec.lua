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
            "projects.App.device.env", "projects.App.device.working_dir",
            "projects.App.launch.tests.device.env", "projects.App.launch.tests.device.working_dir",
        }, labels)
    end)

    it("regraft restores the ignored values into a published snapshot", function()
        local cfg = shared()
        local ignored = program_fields.strip(cfg, nil)
        local raw = { projects = { App = { cmake = {}, device = { stage = { "bin/*.so" } },
            launch = { tests = { target = "Runner" } } } } }
        program_fields.regraft(raw, ignored)
        assert.same({ LOG = "debug" }, raw.projects.App.device.env)
        assert.equals("data", raw.projects.App.launch.tests.device.working_dir)
    end)

    it("the trust review lists the working copy's device env / working_dir", function()
        local prog = program_fields.review({ projects = { App = { cmake = {},
            device = { env = { LOG = "1" }, stage = { "x" } },
            launch = { t = { target = "R", device = { working_dir = "w" } } } } } }, nil)
        local all = table.concat(prog, "\n")
        assert.truthy(all:find("projects.App.device.env", 1, true))
        assert.truthy(all:find("device.working_dir = w", 1, true))
        assert.falsy(all:find("device.stage", 1, true))
    end)
end)

describe("device block validation (loomworks.json)", function()
    local root
    before_each(function() root = fx.mkroot(); vim.fn.mkdir(root .. "/App", "p") end)
    after_each(function() require("loomworks.io").rm_rf(root) end)

    it("accepts a valid block and rejects escaping patterns / bad device_log", function()
        local ok = config.validate({ projects = { App = { cmake = {},
            device = { stage = { "a/*.so" } },
            launch = { t = { target = "R", device_log = { show = "both" } } } } } }, root)
        assert.is_table(ok)
        assert.same({ stage = { "a/*.so" } }, ok.projects.App.device)
        local bad, err = config.validate({ projects = { App = { cmake = {},
            device = { stage = { "../../etc/*" } } } } }, root)
        assert.is_nil(bad)
        assert.truthy(err:find("device.stage", 1, true))
        bad, err = config.validate({ projects = { App = { cmake = {},
            launch = { t = { target = "R", device_log = { show = { nested = true } } } } } } }, root)
        assert.is_nil(bad)
        assert.truthy(err:find("device_log.show", 1, true))
    end)
end)

-- Test lw.buf_status as lualine uses it: init.lua reads the two views
-- (spec §19.13 "Two sources, one shape") through loomworks.views; here the
-- daemon's `view.Header/1` and `view.ProjectsIndex/1` are hand-written
-- (spec/protocol/interfaces/loomworks/view.*.json) and held by a fake owner,
-- and the buffer path is a named scratch buffer's.

local views = require("loomworks.views")
local lw = require("loomworks")

local ROOT = (vim.fn.tempname():gsub("\\", "/"))

--- A ProjectsIndex/1 record of project `key` at <ROOT>/<key>.
local function rec(key, typ, active)
    return { key = key, label = key, type = typ or "cmake", path = key, abs_path = ROOT .. "/" .. key, active = active }
end

--- lw.buf_status of a buffer named `path` while the daemon's views are
--- `header` and `index` (nil: not held).
local function buf_status(header, index, path)
    local owner = {}
    if header then views.set(owner, "header", header) end
    if index then views.set(owner, "projects", index) end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, path)
    local ok, res = pcall(lw.buf_status, buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    views.clear(owner)
    assert(ok, res)
    return res
end

local function loaded(extra)
    return vim.tbl_extend("force", { root = ROOT, state = "loaded", name = "w" }, extra or {})
end

describe("buf_status", function()
    it("returns nil without workspace", function()
        assert.is_nil(buf_status(nil, nil, ROOT .. "/App/src/main.cpp"))
        assert.is_nil(buf_status({ root = ROOT, state = "unloaded" }, { projects = {} }, ROOT .. "/App/src/main.cpp"))
    end)

    it("returns nil when buffer not in any project", function()
        assert.is_nil(buf_status(loaded(), { projects = { rec("App") } }, "/other/path/file.cpp"))
    end)

    it("returns project info for matching buffer", function()
        local result = buf_status(loaded({ active_profile = "debug", config_set = "debug" }),
            { projects = { rec("App", "cmake", { configuration = "Debug", state = "unconfigured" }) } },
            ROOT .. "/App/src/main.cpp")
        assert.is_not_nil(result)
        assert.equals("debug", result.profile_key)
        assert.equals("debug", result.set_name)
        assert.equals("App", result.project)
        assert.equals("Debug", result.configuration)
    end)

    it("includes tool_key when profile has one", function()
        local result = buf_status(loaded({ active_profile = "debug:ninja-gcc-12", config_set = "debug" }),
            { projects = { rec("App", "cmake", { configuration = "Debug", state = "configured", tool_key = "ninja-gcc-12" }) } },
            ROOT .. "/App/src/main.cpp")
        assert.is_not_nil(result)
        assert.equals("debug:ninja-gcc-12", result.profile_key)
        assert.equals("debug", result.set_name)
        assert.equals("ninja-gcc-12", result.tool_key)
    end)

    it("returns status from the active unit", function()
        local result = buf_status(loaded({ active_profile = "debug", config_set = "debug" }),
            { projects = { rec("App", "cmake", { configuration = "Debug", state = "built" }) } },
            ROOT .. "/App/src/main.cpp")
        assert.is_not_nil(result)
        assert.equals("App", result.project)
        assert.equals("Debug", result.configuration)
        assert.equals("built", result.status)
        assert.equals("built", result.profile_state)
    end)

    it("returns nil set_name when profile_key is nil", function()
        local result = buf_status(loaded(), { projects = { rec("App") } }, ROOT .. "/App/src/main.cpp")
        assert.is_not_nil(result)
        assert.is_nil(result.profile_key)
        assert.is_nil(result.set_name)
        assert.equals("App", result.project)
    end)

    it("returns nil tool_key for a project whose unit has none", function()
        local result = buf_status(loaded({ active_profile = "debug", config_set = "debug" }),
            { projects = { rec("Frontend", "ets", { configuration = "debug", state = "unconfigured" }) } },
            ROOT .. "/Frontend/src/main.ets")
        assert.is_not_nil(result)
        assert.equals("Frontend", result.project)
        assert.is_nil(result.tool_key)
    end)

    it("a project at <root>/App does not claim a buffer in <root>/AppX (separator boundary)", function()
        assert.is_nil(buf_status(loaded({ active_profile = "debug", config_set = "debug" }),
            { projects = { rec("App") } }, ROOT .. "/AppX/src/main.cpp"))
    end)
end)

describe("loomworks.views", function()
    local function rec(key, abs, active)
        return { key = key, label = key, type = "cmake", path = key, abs_path = abs, active = active }
    end

    it("matches the longest prefix on a separator boundary", function()
        local idx = { projects = { rec("a", "/w/a"), rec("ab", "/w/a/b"), rec("foo", "/w/foo") } }
        assert.equals("ab", views.match(idx, "/w/a/b/x.c").key)
        assert.equals("a", views.match(idx, "/w/a/bc/x.c").key)
        assert.equals("a", views.match(idx, "/w/a").key)
        assert.is_nil(views.match(idx, "/w/foobar/x.c"))
        assert.is_nil(views.match(idx, ""))
        assert.is_nil(views.match(nil, "/w/a/x.c"))
    end)

    it("status_of is nil unless the header is loaded", function()
        local idx = { projects = { rec("a", "/w/a", { configuration = "Debug", state = "built" }) } }
        assert.is_nil(views.status_of({ root = "/w", state = "unloaded" }, { projects = {} }, "/w/a/x.c"))
        assert.is_nil(views.status_of({ root = "/w", state = "error", error = "x" }, idx, "/w/a/x.c"))
        local st = views.status_of({ root = "/w", state = "loaded", active_profile = "p", config_set = "s",
            diagnostics = "warn" }, idx, "/w/a/x.c")
        assert.same({ profile_key = "p", set_name = "s", project = "a", configuration = "Debug",
            status = "built", profile_state = "built", diagnostic_severity = "warn" }, st)
    end)

    it("profile_state aggregates the mapped projects", function()
        local function idx(...)
            local out = {}
            for i, s in ipairs({ ... }) do out[i] = rec("p" .. i, "/w/p" .. i, { configuration = "D", state = s }) end
            out[#out + 1] = rec("unmapped", "/w/u")
            return { projects = out }
        end
        assert.equals("building", views.profile_state(idx("built", "building")))
        assert.equals("failed_build", views.profile_state(idx("built", "build_failed")))
        assert.equals("built", views.profile_state(idx("built", "built")))
        assert.equals("configured", views.profile_state(idx("built", "configured")))
        assert.equals("unconfigured", views.profile_state(idx("unconfigured")))
        assert.equals("mixed", views.profile_state(idx("built", "unconfigured")))
        assert.is_nil(views.profile_state({ projects = { rec("u", "/w/u") } }))
    end)

    it("serves the daemon's table while set, nothing otherwise", function()
        local owner = {}
        assert.is_nil(views.source("projects"))
        assert.is_nil(views.projects_index())
        views.set(owner, "projects", { projects = {} })
        assert.equals("daemon", views.source("projects"))
        assert.same({}, views.projects_index().projects)
        views.clear({}, "projects") -- another owner: kept
        assert.equals("daemon", views.source("projects"))
        views.clear(owner)
        assert.is_nil(views.source("projects"))
        assert.is_nil(views.projects_index())
    end)
end)

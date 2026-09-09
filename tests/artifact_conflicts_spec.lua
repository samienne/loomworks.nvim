--- Tests for output-artifact conflict detection (Phase 1: detection + data).
--- Covers cmake `resolve_artifacts`, the Workspace artifact reverse index +
--- `artifact_conflicts_for`, and serialize/deserialize of the resolved
--- artifact set + overwritten marker. Spec: data-model §1.7, state-lifecycle
--- §5.9, module-interface §8.4, three-file-model §2.3, cmake §4.6.

local cmake = require("loomworks.modules.cmake")
local data_model = require("loomworks.data_model")
local ConfigUnit = require("loomworks.config_unit")
local BuildDir = require("loomworks.build_dir")
local Workspace = require("loomworks.workspace").Workspace
local uv = vim.uv or vim.loop

--- Write a minimal cmake file-api codemodel reply.
--- @param build_dir string
--- @param targets table[] { name, type, artifacts?: string[] }
--- @param config_name? string default "Debug"
local function write_codemodel(build_dir, targets, config_name)
    config_name = config_name or "Debug"
    local reply_dir = build_dir .. "/.cmake/api/v1/reply"
    vim.fn.mkdir(reply_dir, "p")

    local target_refs = {}
    local project_indexes = {}
    for i, tgt in ipairs(targets) do
        local detail_name = "target-" .. tgt.name .. ".json"
        target_refs[i] = { name = tgt.name, id = "id-" .. tgt.name, jsonFile = detail_name }
        project_indexes[#project_indexes + 1] = i - 1 -- 0-based
        local detail = { name = tgt.name, type = tgt.type, id = "id-" .. tgt.name }
        if tgt.artifacts then
            detail.artifacts = {}
            for _, p in ipairs(tgt.artifacts) do
                detail.artifacts[#detail.artifacts + 1] = { path = p }
            end
        end
        local fd = assert(io.open(reply_dir .. "/" .. detail_name, "w"))
        fd:write(vim.json.encode(detail))
        fd:close()
    end

    local codemodel = {
        kind = "codemodel",
        version = { major = 2, minor = 0 },
        configurations = {
            {
                name = config_name,
                targets = target_refs,
                projects = { { name = "P", targetIndexes = project_indexes } },
            },
        },
    }
    local cm_name = "codemodel-v2.json"
    local fd = assert(io.open(reply_dir .. "/" .. cm_name, "w"))
    fd:write(vim.json.encode(codemodel))
    fd:close()

    local index = {
        objects = { { kind = "codemodel", version = { major = 2, minor = 0 }, jsonFile = cm_name } },
    }
    local ifd = assert(io.open(reply_dir .. "/index-2025-01-01.json", "w"))
    ifd:write(vim.json.encode(index))
    ifd:close()
end

local function rm_rf(path)
    local handle = uv.fs_scandir(path)
    if not handle then return end
    while true do
        local name, ftype = uv.fs_scandir_next(handle)
        if not name then break end
        local full = path .. "/" .. name
        if ftype == "directory" then
            rm_rf(full)
        else
            uv.fs_unlink(full)
        end
    end
    uv.fs_rmdir(path)
end

describe("cmake resolve_artifacts", function()
    local tmp_dir

    before_each(function()
        tmp_dir = vim.fn.tempname():gsub("\\", "/")
        vim.fn.mkdir(tmp_dir, "p")
    end)

    after_each(function()
        if tmp_dir then rm_rf(tmp_dir) end
    end)

    it("returns nil when no reply directory exists (unknown until configure)", function()
        assert.is_nil(cmake.resolve_artifacts({ build_dir = tmp_dir }))
    end)

    it("resolves an in-tree artifact to an absolute path", function()
        write_codemodel(tmp_dir, {
            { name = "app", type = "EXECUTABLE", artifacts = { "app.exe" } },
        })
        local arts = cmake.resolve_artifacts({ build_dir = tmp_dir, config_name = "Debug" })
        assert.are.same({ tmp_dir .. "/app.exe" }, arts)
    end)

    it("resolves a subdirectory in-tree artifact", function()
        write_codemodel(tmp_dir, {
            { name = "core", type = "SHARED_LIBRARY", artifacts = { "lib/core.dll" } },
        })
        local arts = cmake.resolve_artifacts({ build_dir = tmp_dir })
        assert.are.same({ tmp_dir .. "/lib/core.dll" }, arts)
    end)

    it("resolves a hardcoded OUT-OF-TREE artifact against the build dir", function()
        -- A project that hardcodes RUNTIME_OUTPUT_DIRECTORY emits a
        -- ..-relative path that escapes the build tree (§4.6).
        local build_dir = tmp_dir .. "/build/App/Debug"
        vim.fn.mkdir(build_dir, "p")
        write_codemodel(build_dir, {
            { name = "app", type = "EXECUTABLE", artifacts = { "../../../bin/app" } },
        })
        local arts = cmake.resolve_artifacts({ build_dir = build_dir })
        assert.are.same({ tmp_dir .. "/bin/app" }, arts)
    end)

    it("preserves an already-absolute artifact path", function()
        local abs = tmp_dir .. "/out/app.exe"
        write_codemodel(tmp_dir, {
            { name = "app", type = "EXECUTABLE", artifacts = { abs } },
        })
        local arts = cmake.resolve_artifacts({ build_dir = tmp_dir })
        assert.are.same({ abs }, arts)
    end)

    it("collects EVERY artifact of a target (exe + pdb)", function()
        write_codemodel(tmp_dir, {
            { name = "app", type = "EXECUTABLE", artifacts = { "app.exe", "app.pdb" } },
        })
        local arts = cmake.resolve_artifacts({ build_dir = tmp_dir })
        assert.are.same({ tmp_dir .. "/app.exe", tmp_dir .. "/app.pdb" }, arts)
    end)

    it("collects artifacts across multiple project-owned targets", function()
        write_codemodel(tmp_dir, {
            { name = "app", type = "EXECUTABLE", artifacts = { "app.exe" } },
            { name = "core", type = "SHARED_LIBRARY", artifacts = { "core.dll", "core.lib" } },
        })
        local arts = cmake.resolve_artifacts({ build_dir = tmp_dir })
        table.sort(arts)
        assert.are.same({
            tmp_dir .. "/app.exe",
            tmp_dir .. "/core.dll",
            tmp_dir .. "/core.lib",
        }, arts)
    end)

    it("returns nil when no target lists any artifact", function()
        write_codemodel(tmp_dir, {
            { name = "obj", type = "OBJECT_LIBRARY" }, -- no artifacts
        })
        assert.is_nil(cmake.resolve_artifacts({ build_dir = tmp_dir }))
    end)

    it("selects the requested multi-config variant", function()
        local reply_dir = tmp_dir .. "/.cmake/api/v1/reply"
        vim.fn.mkdir(reply_dir, "p")
        -- Two configurations sharing the reply; Debug and Release each carry
        -- one target with a distinct artifact.
        local function detail(name, art)
            local d = { name = name, type = "EXECUTABLE", id = "id-" .. name,
                artifacts = { { path = art } } }
            local fd = assert(io.open(reply_dir .. "/target-" .. name .. ".json", "w"))
            fd:write(vim.json.encode(d)); fd:close()
        end
        detail("appd", "appd.exe")
        detail("appr", "appr.exe")
        local codemodel = {
            kind = "codemodel", version = { major = 2, minor = 0 },
            configurations = {
                { name = "Debug",
                  targets = { { name = "appd", id = "id-appd", jsonFile = "target-appd.json" } },
                  projects = { { name = "P", targetIndexes = { 0 } } } },
                { name = "Release",
                  targets = { { name = "appr", id = "id-appr", jsonFile = "target-appr.json" } },
                  projects = { { name = "P", targetIndexes = { 0 } } } },
            },
        }
        local fd = assert(io.open(reply_dir .. "/codemodel-v2.json", "w"))
        fd:write(vim.json.encode(codemodel)); fd:close()
        local ifd = assert(io.open(reply_dir .. "/index-1.json", "w"))
        ifd:write(vim.json.encode({ objects = { { kind = "codemodel",
            version = { major = 2, minor = 0 }, jsonFile = "codemodel-v2.json" } } }))
        ifd:close()

        assert.are.same({ tmp_dir .. "/appr.exe" },
            cmake.resolve_artifacts({ build_dir = tmp_dir, config_name = "Release" }))
        assert.are.same({ tmp_dir .. "/appd.exe" },
            cmake.resolve_artifacts({ build_dir = tmp_dir, config_name = "Debug" }))
    end)
end)

--- Build a workspace-shaped table carrying just the fields the artifact index,
--- conflict gate, invalidate, and clear-on-resync touch, with the real
--- Workspace methods bound on it.
local function make_ws(normalize)
    local ws = {
        _config_units = {},
        _artifact_refs = {},
        _profile_projects = {},
        _active_profile = nil,
        _core = { _deps = {
            normalize = normalize or function(p) return p:lower() end,
            log = { debug = function() end },
        } },
    }
    ws._save_cache = function() return true end
    ws._sync_artifact_refs = Workspace._sync_artifact_refs
    ws._clear_stale_overwritten_markers = Workspace._clear_stale_overwritten_markers
    ws.artifact_conflicts_for = Workspace.artifact_conflicts_for
    ws.artifact_conflict_block = Workspace.artifact_conflict_block
    ws._invalidate_overwritten_by = Workspace._invalidate_overwritten_by
    ws._profile_name_for_unit = Workspace._profile_name_for_unit
    ws._shared_artifact_path = Workspace._shared_artifact_path
    ws.profile_has_artifact_conflict = Workspace.profile_has_artifact_conflict
    return ws
end

local function add_unit(ws, id, artifacts, state)
    local u = ConfigUnit.new(ws, id, "App")
    u._artifacts = artifacts
    u.state_value = state
    ws._config_units[#ws._config_units + 1] = u
    return u
end

--- Minimal profile stub: `projects()` returns its ProfileProject list.
local function make_profile(key)
    local pps = {}
    return { key = key, _pps = pps, projects = function() return pps end }
end

--- Link a config unit to a profile via a fake ProfileProject registered on
--- both the profile and the workspace registry.
local function add_pp(ws, profile, unit)
    local pp = { _config_unit = unit, _profile = profile }
    profile._pps[#profile._pps + 1] = pp
    ws._profile_projects[#ws._profile_projects + 1] = pp
    return pp
end

--- Attach a fake ProfileProject linking a profile name to a config unit so the
--- conflict message can resolve unit → profile name.
local function link_profile(ws, unit, profile_key)
    ws._profile_projects[#ws._profile_projects + 1] = {
        _config_unit = unit,
        _profile = { key = profile_key },
    }
end

describe("artifact reverse index + artifact_conflicts_for", function()

    it("indexes configured units' artifacts by normalized path", function()
        local ws = make_ws()
        add_unit(ws, "build/App/Debug", { "/ws/bin/app" }, "built")
        add_unit(ws, "build/App/Release", { "/ws/bin/app" }, "configured")
        add_unit(ws, "build/App/None", nil, "unconfigured")
        local refs = data_model.sync_artifact_refs(ws._config_units, ws._core._deps.normalize)
        assert.is_not_nil(refs["/ws/bin/app"])
        assert.equals(2, #refs["/ws/bin/app"])
    end)

    it("reports a built unit that shares an artifact as a conflict", function()
        local ws = make_ws()
        local built = add_unit(ws, "build/App/Debug", { "/ws/bin/app" }, "built")
        local other = add_unit(ws, "build/App/Release", { "/ws/bin/app" }, "configured")
        Workspace._sync_artifact_refs(ws)
        local conflicts = Workspace.artifact_conflicts_for(ws, other)
        assert.equals(1, #conflicts)
        assert.equals(built, conflicts[1])
    end)

    it("is directional: does not report a non-built sharer", function()
        local ws = make_ws()
        local built = add_unit(ws, "build/App/Debug", { "/ws/bin/app" }, "built")
        add_unit(ws, "build/App/Release", { "/ws/bin/app" }, "configured")
        Workspace._sync_artifact_refs(ws)
        -- Querying from the built unit: the other is only configured, not built.
        assert.are.same({}, Workspace.artifact_conflicts_for(ws, built))
    end)

    it("returns empty when artifact sets do not overlap", function()
        local ws = make_ws()
        add_unit(ws, "build/App/Debug", { "/ws/bin/app" }, "built")
        local other = add_unit(ws, "build/App/Release", { "/ws/bin/other" }, "configured")
        Workspace._sync_artifact_refs(ws)
        assert.are.same({}, Workspace.artifact_conflicts_for(ws, other))
    end)

    it("compares paths case-insensitively via normalize", function()
        local ws = make_ws() -- normalize lowercases
        local built = add_unit(ws, "build/App/Debug", { "/WS/BIN/App.exe" }, "built")
        local other = add_unit(ws, "build/App/Release", { "/ws/bin/app.exe" }, "configured")
        Workspace._sync_artifact_refs(ws)
        local conflicts = Workspace.artifact_conflicts_for(ws, other)
        assert.equals(1, #conflicts)
        assert.equals(built, conflicts[1])
    end)

    it("returns empty for a unit with no known artifacts", function()
        local ws = make_ws()
        add_unit(ws, "build/App/Debug", { "/ws/bin/app" }, "built")
        local none = add_unit(ws, "build/App/None", nil, "unconfigured")
        Workspace._sync_artifact_refs(ws)
        assert.are.same({}, Workspace.artifact_conflicts_for(ws, none))
    end)

    it("does not report a unit against itself", function()
        local ws = make_ws()
        local u = add_unit(ws, "build/App/Debug", { "/ws/bin/app" }, "built")
        Workspace._sync_artifact_refs(ws)
        assert.are.same({}, Workspace.artifact_conflicts_for(ws, u))
    end)
end)

describe("resolved artifact set + overwritten marker persistence", function()
    it("round-trips artifacts + overwritten_by through ConfigUnit serialize/_apply", function()
        local ws = { _config_units = {} }
        local u = ConfigUnit.new(ws, "build/App/Debug", "App")
        u._config_key = "Debug:ninja-gcc-12"
        u._variant = "Debug"
        u.state_value = "built"
        u.build_dir_value = "/ws/.nvim/build/App/Debug"
        u._artifacts = { "/ws/bin/app.exe", "/ws/bin/app.pdb" }
        u._overwritten_by = "build/App/Release"

        local entry = u:serialize()
        assert.are.same({ "/ws/bin/app.exe", "/ws/bin/app.pdb" }, entry.artifacts)
        assert.equals("build/App/Release", entry.overwritten_by)

        local u2 = ConfigUnit.new(ws, "build/App/Debug", "App")
        u2:_apply({ cached = entry })
        assert.are.same({ "/ws/bin/app.exe", "/ws/bin/app.pdb" }, u2._artifacts)
        assert.equals("build/App/Release", u2._overwritten_by)
    end)

    it("omits artifacts / overwritten_by when unset", function()
        local ws = { _config_units = {} }
        local u = ConfigUnit.new(ws, "build/App/Debug", "App")
        u._variant = "Debug"
        u.state_value = "configured"
        local entry = u:serialize()
        assert.is_nil(entry.artifacts)
        assert.is_nil(entry.overwritten_by)
    end)

    it("round-trips artifacts + overwritten_by through BuildDir serialize/new", function()
        local bd = BuildDir.new("build/App/Debug", "/ws/.nvim/build/App/Debug", {
            state = "built",
            project_key = "App",
            variant = "Debug",
            artifacts = { "/ws/bin/app.exe" },
            overwritten_by = "build/App/Release",
        })
        assert.are.same({ "/ws/bin/app.exe" }, bd.artifacts)
        assert.equals("build/App/Release", bd.overwritten_by)

        local entry = bd:serialize()
        assert.are.same({ "/ws/bin/app.exe" }, entry.artifacts)
        assert.equals("build/App/Release", entry.overwritten_by)

        local bd2 = BuildDir.new("build/App/Debug", "/abs", entry)
        assert.are.same({ "/ws/bin/app.exe" }, bd2.artifacts)
        assert.equals("build/App/Release", bd2.overwritten_by)
    end)

    it("is_overwritten() reports true when the referenced unit exists", function()
        local ws = { _config_units = {} }
        local overwriter = ConfigUnit.new(ws, "build/App/Release", "App")
        local victim = ConfigUnit.new(ws, "build/App/Debug", "App")
        victim._overwritten_by = "build/App/Release"
        ws._config_units = { overwriter, victim }
        assert.is_true(victim:is_overwritten())
        assert.equals(overwriter, victim:overwritten_by())
    end)

    it("treats a dangling overwritten_by (missing entry) as clear", function()
        local ws = { _config_units = {} }
        local victim = ConfigUnit.new(ws, "build/App/Debug", "App")
        victim._overwritten_by = "build/App/DoesNotExist"
        ws._config_units = { victim }
        assert.is_false(victim:is_overwritten())
        assert.is_nil(victim:overwritten_by())
    end)
end)

describe("build-conflict gate (Phase 2 enforcement)", function()
    it("blocks a build over a still-built unit that shares an artifact", function()
        local ws = make_ws()
        local u = add_unit(ws, "build/App/Debug", { "/ws/bin/app" }, "configured")
        local v = add_unit(ws, "build/App/Release", { "/ws/bin/app" }, "built")
        link_profile(ws, v, "release-gcc")
        ws:_sync_artifact_refs()

        local block = ws:artifact_conflict_block(u, false)
        assert.is_not_nil(block)
        assert.equals(v, block.unit)
        assert.equals("release-gcc", block.profile)
        assert.equals("/ws/bin/app", block.path)
    end)

    it("force=true bypasses the block", function()
        local ws = make_ws()
        local u = add_unit(ws, "build/App/Debug", { "/ws/bin/app" }, "configured")
        add_unit(ws, "build/App/Release", { "/ws/bin/app" }, "built")
        ws:_sync_artifact_refs()
        assert.is_nil(ws:artifact_conflict_block(u, true))
    end)

    it("does not block when no other built unit shares an artifact", function()
        local ws = make_ws()
        local u = add_unit(ws, "build/App/Debug", { "/ws/bin/app" }, "configured")
        add_unit(ws, "build/App/Release", { "/ws/bin/other" }, "built")
        ws:_sync_artifact_refs()
        assert.is_nil(ws:artifact_conflict_block(u, false))
    end)

    it("does not block a unit with no known artifacts (never configured)", function()
        local ws = make_ws()
        add_unit(ws, "build/App/Release", { "/ws/bin/app" }, "built")
        local u = add_unit(ws, "build/App/Debug", nil, "unconfigured")
        ws:_sync_artifact_refs()
        assert.is_nil(ws:artifact_conflict_block(u, false))
    end)

    it("names project/variant when no profile references the conflicting unit", function()
        local ws = make_ws()
        local u = add_unit(ws, "build/App/Debug", { "/ws/bin/app" }, "configured")
        local v = add_unit(ws, "build/App/Release", { "/ws/bin/app" }, "built")
        v._variant = "Release"
        ws:_sync_artifact_refs()
        local block = ws:artifact_conflict_block(u, false)
        assert.equals("App/Release", block.profile)
    end)

    it("prefers the active profile's name for the conflicting unit", function()
        local ws = make_ws()
        local u = add_unit(ws, "build/App/Debug", { "/ws/bin/app" }, "configured")
        local v = add_unit(ws, "build/App/Release", { "/ws/bin/app" }, "built")
        local active = { key = "active-profile" }
        ws._active_profile = active
        -- v is referenced by two profiles; the active one wins the message.
        ws._profile_projects[#ws._profile_projects + 1] =
            { _config_unit = v, _profile = { key = "other-profile" } }
        ws._profile_projects[#ws._profile_projects + 1] =
            { _config_unit = v, _profile = active }
        ws:_sync_artifact_refs()
        assert.equals("active-profile", ws:artifact_conflict_block(u, false).profile)
    end)
end)

describe("invalidate-on-completion + clear-on-resync (Phase 2 staleness)", function()
    it("marks other built sharers overwritten and clears the builder's own marker", function()
        local ws = make_ws()
        local u = add_unit(ws, "build/App/Debug", { "/ws/bin/app" }, "built")
        u._overwritten_by = "build/App/Ancient" -- stale marker from before
        local v = add_unit(ws, "build/App/Release", { "/ws/bin/app" }, "built")
        local w = add_unit(ws, "build/App/Other", { "/ws/bin/other" }, "built")
        ws:_sync_artifact_refs()

        ws:_invalidate_overwritten_by(u)

        assert.is_true(v:is_overwritten())
        assert.equals("build/App/Debug", v._overwritten_by)
        assert.is_false(w:is_overwritten()) -- no shared artifact
        assert.is_nil(u._overwritten_by) -- builder reclaimed its output
    end)

    it("is self-limiting: an overwritten unit no longer blocks a rebuild", function()
        local ws = make_ws()
        local u = add_unit(ws, "build/App/Debug", { "/ws/bin/app" }, "built")
        add_unit(ws, "build/App/Release", { "/ws/bin/app" }, "built")
        ws:_sync_artifact_refs()

        -- Building U would clobber the still-fresh Release build.
        assert.is_not_nil(ws:artifact_conflict_block(u, false))
        -- U builds over Release → Release is marked overwritten (stale).
        ws:_invalidate_overwritten_by(u)
        -- A rebuild of U no longer blocks — Release's output is no longer fresh.
        assert.is_nil(ws:artifact_conflict_block(u, false))
    end)

    it("clears an overwritten marker when the units no longer share an artifact", function()
        local ws = make_ws()
        local u = add_unit(ws, "build/App/Debug", { "/ws/bin/app" }, "built")
        local v = add_unit(ws, "build/App/Release", { "/ws/bin/app" }, "built")
        ws:_sync_artifact_refs()
        ws:_invalidate_overwritten_by(u)
        assert.is_true(v:is_overwritten())

        -- U's output path changes on reconfigure; it no longer overlaps V.
        u._artifacts = { "/ws/bin/app2" }
        ws:_sync_artifact_refs()

        assert.is_false(v:is_overwritten())
        assert.is_nil(v._overwritten_by)
    end)

    it("clears an overwritten marker when the overwriter is gone", function()
        local ws = make_ws()
        local v = add_unit(ws, "build/App/Release", { "/ws/bin/app" }, "built")
        v._overwritten_by = "build/App/Ghost" -- overwriter never existed / removed
        ws:_sync_artifact_refs()
        assert.is_false(v:is_overwritten())
        assert.is_nil(v._overwritten_by)
    end)
end)

describe("profile_has_artifact_conflict (Phase 3 UI predicate)", function()
    it("is true when two profiles' distinct units share an output path", function()
        local ws = make_ws()
        local pA, pB = make_profile("gcc"), make_profile("clang")
        local u = add_unit(ws, "build/App/gcc/Debug", { "/bin/app" }, "built")
        local v = add_unit(ws, "build/App/clang/Debug", { "/bin/app" }, "built")
        add_pp(ws, pA, u)
        add_pp(ws, pB, v)
        ws:_sync_artifact_refs()
        assert.is_true(ws:profile_has_artifact_conflict(pA))
        assert.is_true(ws:profile_has_artifact_conflict(pB))
    end)

    it("is a STATIC overlap: not gated on built state (configured overlaps count)", function()
        local ws = make_ws()
        local pA, pB = make_profile("gcc"), make_profile("clang")
        add_pp(ws, pA, add_unit(ws, "build/App/gcc/Debug", { "/bin/app" }, "configured"))
        add_pp(ws, pB, add_unit(ws, "build/App/clang/Debug", { "/bin/app" }, "configured"))
        ws:_sync_artifact_refs()
        assert.is_true(ws:profile_has_artifact_conflict(pA))
    end)

    it("is false when the overlap is within the SAME profile only", function()
        local ws = make_ws()
        local pA = make_profile("gcc")
        add_pp(ws, pA, add_unit(ws, "build/X/Debug", { "/bin/app" }, "built"))
        add_pp(ws, pA, add_unit(ws, "build/Y/Debug", { "/bin/app" }, "built"))
        ws:_sync_artifact_refs()
        assert.is_false(ws:profile_has_artifact_conflict(pA))
    end)

    it("is false when the profile is unconfigured (no known artifacts)", function()
        local ws = make_ws()
        local pA, pB = make_profile("gcc"), make_profile("clang")
        add_pp(ws, pA, add_unit(ws, "build/App/gcc/Debug", nil, "unconfigured"))
        add_pp(ws, pB, add_unit(ws, "build/App/clang/Debug", { "/bin/app" }, "built"))
        ws:_sync_artifact_refs()
        assert.is_false(ws:profile_has_artifact_conflict(pA))
    end)

    it("is false when the same unit is shared across two profiles (same output)", function()
        local ws = make_ws()
        local pA, pB = make_profile("A"), make_profile("B")
        local shared = add_unit(ws, "build/App/gcc/Debug", { "/bin/app" }, "built")
        add_pp(ws, pA, shared)
        add_pp(ws, pB, shared)
        ws:_sync_artifact_refs()
        assert.is_false(ws:profile_has_artifact_conflict(pA))
    end)

    it("is false when outputs do not overlap", function()
        local ws = make_ws()
        local pA, pB = make_profile("gcc"), make_profile("clang")
        add_pp(ws, pA, add_unit(ws, "build/App/gcc/Debug", { "/bin/app" }, "built"))
        add_pp(ws, pB, add_unit(ws, "build/App/clang/Debug", { "/bin/other" }, "built"))
        ws:_sync_artifact_refs()
        assert.is_false(ws:profile_has_artifact_conflict(pA))
    end)
end)

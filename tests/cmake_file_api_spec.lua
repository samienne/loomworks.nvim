--- Tests for cmake module's parse_targets function.

local cmake = require("loomworks.modules.cmake")
local uv = vim.uv or vim.loop

--- Create a temporary directory structure mimicking cmake file-api reply.
--- @param build_dir string
--- @param targets table[] { name, type, id, dependencies? }
--- @param config_name? string (default "Debug")
--- @param project_targets? string[] names of project-owned targets (default: all)
local function write_file_api(build_dir, targets, config_name, project_targets)
    config_name = config_name or ""

    local reply_dir = build_dir .. "/.cmake/api/v1/reply"
    vim.fn.mkdir(reply_dir, "p")

    -- Build target references and detail files
    local target_refs = {}
    local target_ids = {}
    for i, tgt in ipairs(targets) do
        local id = tgt.id or ("target-" .. tgt.name .. "-" .. i)
        target_ids[tgt.name] = id

        local detail_name = "target-" .. tgt.name .. "-abc123.json"
        target_refs[i] = {
            name = tgt.name,
            id = id,
            jsonFile = detail_name,
        }

        -- Write target detail file
        local detail = {
            name = tgt.name,
            type = tgt.type,
            id = id,
        }
        if tgt.dependencies then
            detail.dependencies = {}
            for _, dep_name in ipairs(tgt.dependencies) do
                detail.dependencies[#detail.dependencies + 1] = {
                    id = "target-" .. dep_name .. "-lookup",
                }
            end
        end

        local fd = assert(io.open(reply_dir .. "/" .. detail_name, "w"))
        fd:write(vim.json.encode(detail))
        fd:close()
    end

    -- Resolve dependency IDs to match the target refs
    for i, tgt in ipairs(targets) do
        if tgt.dependencies then
            for _, dep_name in ipairs(tgt.dependencies) do
                -- Find the target ref for this dependency and update its id to match
                for j, ref in ipairs(target_refs) do
                    if ref.name == dep_name then
                        -- Update the detail file's dependency id to match this ref's id
                        -- Actually, we need the ref id to match what the detail file uses
                        -- Let's fix: set the ref id to what the detail file will look up
                        break
                    end
                end
            end
        end
    end

    -- Re-approach: use consistent IDs. The detail file's dependencies reference
    -- IDs from the target_refs list. So target_refs[i].id must match what
    -- dependency entries use.
    -- Rebuild with proper ID references:
    for i, tgt in ipairs(targets) do
        local id = "target-" .. tgt.name .. "-" .. i
        target_refs[i].id = id

        local detail_name = target_refs[i].jsonFile
        local detail = {
            name = tgt.name,
            type = tgt.type,
            id = id,
        }
        if tgt.artifact then
            detail.artifacts = { { path = tgt.artifact } }
        end
        if tgt.dependencies then
            detail.dependencies = {}
            for _, dep_name in ipairs(tgt.dependencies) do
                -- Find the matching target's id
                for j, other in ipairs(targets) do
                    if other.name == dep_name then
                        detail.dependencies[#detail.dependencies + 1] = {
                            id = "target-" .. dep_name .. "-" .. j,
                        }
                        break
                    end
                end
            end
        end

        local fd = assert(io.open(reply_dir .. "/" .. detail_name, "w"))
        fd:write(vim.json.encode(detail))
        fd:close()
    end

    -- Build project index (which targets are project-owned)
    local project_indexes = {}
    if project_targets then
        for _, pt_name in ipairs(project_targets) do
            for i, ref in ipairs(target_refs) do
                if ref.name == pt_name then
                    project_indexes[#project_indexes + 1] = i - 1 -- 0-based
                    break
                end
            end
        end
    else
        for i in ipairs(target_refs) do
            project_indexes[#project_indexes + 1] = i - 1
        end
    end

    -- Write codemodel file
    local codemodel = {
        kind = "codemodel",
        version = { major = 2, minor = 0 },
        configurations = {
            {
                name = config_name,
                targets = target_refs,
                projects = {
                    {
                        name = "TestProject",
                        targetIndexes = project_indexes,
                    },
                },
            },
        },
    }
    local codemodel_name = "codemodel-v2-abc123.json"
    local fd = assert(io.open(reply_dir .. "/" .. codemodel_name, "w"))
    fd:write(vim.json.encode(codemodel))
    fd:close()

    -- Write index file
    local index = {
        objects = {
            {
                kind = "codemodel",
                version = { major = 2, minor = 0 },
                jsonFile = codemodel_name,
            },
        },
    }
    local index_fd = assert(io.open(reply_dir .. "/index-2025-01-01.json", "w"))
    index_fd:write(vim.json.encode(index))
    index_fd:close()
end

--- Remove a directory tree.
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

describe("cmake parse_targets", function()
    local tmp_dir

    before_each(function()
        tmp_dir = vim.fn.tempname()
        vim.fn.mkdir(tmp_dir, "p")
    end)

    after_each(function()
        if tmp_dir then rm_rf(tmp_dir) end
    end)

    it("returns nil when no reply directory exists", function()
        assert.is_nil(cmake.parse_targets(tmp_dir))
    end)

    it("parses executable and library targets", function()
        write_file_api(tmp_dir, {
            { name = "app", type = "EXECUTABLE" },
            { name = "libcore", type = "STATIC_LIBRARY" },
            { name = "libutil", type = "SHARED_LIBRARY" },
        })

        local targets = cmake.parse_targets(tmp_dir)
        assert.is_not_nil(targets)
        assert.equals("executable", targets.app.type)
        assert.equals("static_library", targets.libcore.type)
        assert.equals("shared_library", targets.libutil.type)
    end)

    it("extracts link dependencies between project-owned targets", function()
        write_file_api(tmp_dir, {
            { name = "app", type = "EXECUTABLE", dependencies = { "libcore", "libutil" } },
            { name = "libcore", type = "STATIC_LIBRARY", dependencies = { "libutil" } },
            { name = "libutil", type = "SHARED_LIBRARY" },
        })

        local targets = cmake.parse_targets(tmp_dir)
        assert.is_not_nil(targets)
        assert.are.same({ "libcore", "libutil" }, targets.app.dependencies)
        assert.are.same({ "libutil" }, targets.libcore.dependencies)
        assert.is_nil(targets.libutil.dependencies)
    end)

    it("extracts artifact path from target detail", function()
        write_file_api(tmp_dir, {
            { name = "app", type = "EXECUTABLE", artifact = "app.exe" },
            { name = "libcore", type = "STATIC_LIBRARY", artifact = "libs/core/libcore.a" },
            { name = "libutil", type = "SHARED_LIBRARY" }, -- no artifact
        })

        local targets = cmake.parse_targets(tmp_dir)
        assert.is_not_nil(targets)
        assert.equals("app.exe", targets.app.artifact)
        assert.equals("libs/core/libcore.a", targets.libcore.artifact)
        assert.is_nil(targets.libutil.artifact)
    end)

    it("normalizes absolute artifact paths to relative", function()
        -- cmake sometimes emits absolute paths for artifacts
        local abs_artifact = tmp_dir:gsub("\\", "/") .. "/bin/app.exe"
        write_file_api(tmp_dir, {
            { name = "app", type = "EXECUTABLE", artifact = abs_artifact },
        })

        local targets = cmake.parse_targets(tmp_dir)
        assert.is_not_nil(targets)
        assert.equals("bin/app.exe", targets.app.artifact)
    end)

    it("excludes utility targets", function()
        write_file_api(tmp_dir, {
            { name = "app", type = "EXECUTABLE" },
            { name = "install", type = "UTILITY" },
            { name = "uninstall", type = "UTILITY" },
        })

        local targets = cmake.parse_targets(tmp_dir)
        assert.is_not_nil(targets)
        assert.is_not_nil(targets.app)
        assert.is_nil(targets.install)
        assert.is_nil(targets.uninstall)
    end)

    it("excludes non-project-owned targets from results", function()
        write_file_api(tmp_dir, {
            { name = "app", type = "EXECUTABLE" },
            { name = "imported_lib", type = "STATIC_LIBRARY" },
        }, "", { "app" }) -- only "app" is project-owned

        local targets = cmake.parse_targets(tmp_dir)
        assert.is_not_nil(targets)
        assert.is_not_nil(targets.app)
        assert.is_nil(targets.imported_lib)
    end)

    it("excludes non-project-owned targets from dependencies", function()
        write_file_api(tmp_dir, {
            { name = "app", type = "EXECUTABLE", dependencies = { "libcore", "external_lib" } },
            { name = "libcore", type = "STATIC_LIBRARY" },
            { name = "external_lib", type = "SHARED_LIBRARY" },
        }, "", { "app", "libcore" }) -- external_lib is not project-owned

        local targets = cmake.parse_targets(tmp_dir)
        assert.is_not_nil(targets)
        -- Only project-owned deps should be listed
        assert.are.same({ "libcore" }, targets.app.dependencies)
    end)

    it("handles all library types", function()
        write_file_api(tmp_dir, {
            { name = "mod_lib", type = "MODULE_LIBRARY" },
            { name = "obj_lib", type = "OBJECT_LIBRARY" },
            { name = "iface_lib", type = "INTERFACE_LIBRARY" },
        })

        local targets = cmake.parse_targets(tmp_dir)
        assert.is_not_nil(targets)
        assert.equals("module_library", targets.mod_lib.type)
        assert.equals("object_library", targets.obj_lib.type)
        assert.equals("interface_library", targets.iface_lib.type)
    end)

    it("selects correct configuration for multi-config", function()
        local reply_dir = tmp_dir .. "/.cmake/api/v1/reply"
        vim.fn.mkdir(reply_dir, "p")

        -- Write target detail files
        local debug_detail = { name = "app", type = "EXECUTABLE", id = "t-1" }
        local fd = assert(io.open(reply_dir .. "/target-app-debug.json", "w"))
        fd:write(vim.json.encode(debug_detail))
        fd:close()

        local release_detail = { name = "app", type = "EXECUTABLE", id = "t-2" }
        fd = assert(io.open(reply_dir .. "/target-app-release.json", "w"))
        fd:write(vim.json.encode(release_detail))
        fd:close()

        -- Write codemodel with two configurations
        local codemodel = {
            kind = "codemodel",
            version = { major = 2, minor = 0 },
            configurations = {
                {
                    name = "Debug",
                    targets = { { name = "app", id = "t-1", jsonFile = "target-app-debug.json" } },
                    projects = { { name = "P", targetIndexes = { 0 } } },
                },
                {
                    name = "Release",
                    targets = { { name = "app", id = "t-2", jsonFile = "target-app-release.json" } },
                    projects = { { name = "P", targetIndexes = { 0 } } },
                },
            },
        }
        fd = assert(io.open(reply_dir .. "/codemodel-v2-abc.json", "w"))
        fd:write(vim.json.encode(codemodel))
        fd:close()

        local index = {
            objects = { { kind = "codemodel", version = { major = 2, minor = 0 }, jsonFile = "codemodel-v2-abc.json" } },
        }
        fd = assert(io.open(reply_dir .. "/index-2025-01-01.json", "w"))
        fd:write(vim.json.encode(index))
        fd:close()

        -- Should select Release configuration
        local targets = cmake.parse_targets(tmp_dir, "Release")
        assert.is_not_nil(targets)
        assert.is_not_nil(targets.app)
    end)

    it("returns nil when reply dir is empty", function()
        vim.fn.mkdir(tmp_dir .. "/.cmake/api/v1/reply", "p")
        assert.is_nil(cmake.parse_targets(tmp_dir))
    end)
end)

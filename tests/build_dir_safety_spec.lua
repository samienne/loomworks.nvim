--- Tests for build directory safety: reverse index, shared dir deletion,
--- and per-build-dir operation queuing.

local workspace = require("loomworks.workspace")
local merge = require("loomworks.merge")
local cache_mod = require("loomworks.cache")
local h = require("tests.helpers")

local Workspace = workspace.Workspace

--- Mock modules for test workspaces.
local mock_modules = {
    cmake = {
        has_keyed_tools = true,
        map_variant = function(variant_type, available_configs)
            for _, name in ipairs(available_configs) do
                if name:lower() == variant_type then return name end
            end
            return nil
        end,
        tool_key = function(tool_data) return tool_data.id end,
        tool_label = function(tool_data) return tool_data.display end,
        detect_tools_async = function(callback) callback({}) end,
        info = function()
            return { configurations = { Debug = {}, Release = {} } }
        end,
    },
}

--- Create a workspace with the given overrides.
local function make_ws(config_overrides, user_overrides, cache_overrides)
    local config_json = h.make_config_json(config_overrides)
    local user_json = user_overrides and h.make_user_json(user_overrides) or nil
    local cache_json = cache_overrides and h.make_cache_json(cache_overrides) or nil

    local data = workspace.assemble("/root", config_json, user_json, cache_json)
    assert(data, "assemble failed")

    local events_log = {}
    local notifications = {}
    local mock_core = {
        _deps = {
            merge = merge,
            cache = cache_mod,
            events = {
                emit = function(event, ev_data)
                    events_log[#events_log + 1] = { event = event, data = ev_data }
                end,
            },
            user = { save = function() return true end },
            io = {
                write_json = function() return true end,
                ensure_dir = function() return true end,
                rm_rf_async = function(_, cb) cb(true, nil) end,
            },
            normalize = function(p) return p end,
            modules = { get = function(id) return mock_modules[id] end },
            notify = function(msg, level)
                notifications[#notifications + 1] = { msg = msg, level = level }
            end,
            schedule = function(fn) fn() end,
        },
        _events_log = events_log,
    }

    local ws = Workspace.new(mock_core, data)
    ws:_cleanup_orphaned_skeletons()
    ws:remerge()
    return ws, events_log, notifications
end


-- =========================================================================
-- Part 1: Build dir reverse index (_sync_build_dir_refs)
-- =========================================================================

describe("build dir refs", function()
    it("builds reverse index from cache entries", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        }, nil, {
            configurations = {
                ["App/Debug:ninja-gcc"] = {
                    project_key = "App", config_key = "Debug:ninja-gcc",
                    type = "cmake", variant = "Debug", tool_key = "ninja-gcc",
                    state = "configured", build_dir = "/root/.nvim/build/App/ninja-gcc",
                },
                ["App/Release:ninja-gcc"] = {
                    project_key = "App", config_key = "Release:ninja-gcc",
                    type = "cmake", variant = "Release", tool_key = "ninja-gcc",
                    state = "configured", build_dir = "/root/.nvim/build/App/ninja-gcc/Release",
                },
            },
        })

        local refs1 = ws:get_build_dir_refs("/root/.nvim/build/App/ninja-gcc")
        assert.equals(1, #refs1)
        assert.equals("Debug:ninja-gcc", refs1[1]._cached.config_key)

        local refs2 = ws:get_build_dir_refs("/root/.nvim/build/App/ninja-gcc/Release")
        assert.equals(1, #refs2)
        assert.equals("Release:ninja-gcc", refs2[1]._cached.config_key)
    end)

    it("returns empty table for unknown build dirs", function()
        local ws = make_ws()
        local refs = ws:get_build_dir_refs("/nonexistent")
        assert.same({}, refs)
    end)

    it("multi-config shared build dir has multiple refs", function()
        local shared_dir = "/root/.nvim/build/App/ninja-gcc"
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        }, nil, {
            configurations = {
                ["App/Debug:ninja-gcc"] = {
                    project_key = "App", config_key = "Debug:ninja-gcc",
                    type = "cmake", variant = "Debug", tool_key = "ninja-gcc",
                    state = "configured", build_dir = shared_dir,
                },
                ["App/Release:ninja-gcc"] = {
                    project_key = "App", config_key = "Release:ninja-gcc",
                    type = "cmake", variant = "Release", tool_key = "ninja-gcc",
                    state = "configured", build_dir = shared_dir,
                },
            },
        })

        local refs = ws:get_build_dir_refs(shared_dir)
        assert.equals(2, #refs)
    end)

    it("rebuilds on remerge", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        }, nil, {
            configurations = {
                ["App/Debug:ninja-gcc"] = {
                    project_key = "App", config_key = "Debug:ninja-gcc",
                    type = "cmake", variant = "Debug", tool_key = "ninja-gcc",
                    state = "configured", build_dir = "/root/.nvim/build/App/ninja-gcc",
                },
            },
        })

        -- Add a new cache entry
        ws.cache.configurations["App/Release:ninja-gcc"] = {
            project_key = "App", config_key = "Release:ninja-gcc",
            type = "cmake", variant = "Release", tool_key = "ninja-gcc",
            state = "configured", build_dir = "/root/.nvim/build/App/ninja-gcc",
        }
        ws:remerge()

        local refs = ws:get_build_dir_refs("/root/.nvim/build/App/ninja-gcc")
        assert.equals(2, #refs)
    end)
end)


-- =========================================================================
-- Part 2: Deletion safety with shared build dirs
-- =========================================================================

describe("deletion safety with shared dirs", function()
    it("skips deleting dir still referenced by other configs", function()
        local shared_dir = "/root/.nvim/build/App/ninja-gcc"
        local deleted_dirs = {}

        local ws, events_log, notifications = make_ws({
            projects = { App = { cmake = {} } },
        }, nil, {
            configurations = {
                ["App/Debug:ninja-gcc"] = {
                    project_key = "App", config_key = "Debug:ninja-gcc",
                    type = "cmake", variant = "Debug", tool_key = "ninja-gcc",
                    state = "configured", build_dir = shared_dir,
                },
                ["App/Release:ninja-gcc"] = {
                    project_key = "App", config_key = "Release:ninja-gcc",
                    type = "cmake", variant = "Release", tool_key = "ninja-gcc",
                    state = "configured", build_dir = shared_dir,
                },
            },
        })

        -- Override rm_rf_async to track deletions
        ws._core._deps.io.rm_rf_async = function(dir, cb)
            deleted_dirs[#deleted_dirs + 1] = dir
            cb(true, nil)
        end

        -- Delete only Debug config — Release still references the dir
        local done = false
        ws:_run_deletion({
            { project_key = "App", config_key = "Debug:ninja-gcc", build_dir = shared_dir },
        }, function(items)
            ws:delete_cached_configs(items)
        end, function()
            done = true
        end)

        assert.is_true(done)
        -- Dir should NOT have been deleted
        assert.equals(0, #deleted_dirs)
        -- Should have notification about skipping
        local found_skip = false
        for _, n in ipairs(notifications) do
            if n.msg:find("skipped deleting") then found_skip = true end
        end
        assert.is_true(found_skip)
    end)

    it("deletes dir when all referencing configs are in the batch", function()
        local shared_dir = "/root/.nvim/build/App/ninja-gcc"
        local deleted_dirs = {}

        local ws = make_ws({
            projects = { App = { cmake = {} } },
        }, nil, {
            configurations = {
                ["App/Debug:ninja-gcc"] = {
                    project_key = "App", config_key = "Debug:ninja-gcc",
                    type = "cmake", variant = "Debug", tool_key = "ninja-gcc",
                    state = "configured", build_dir = shared_dir,
                },
                ["App/Release:ninja-gcc"] = {
                    project_key = "App", config_key = "Release:ninja-gcc",
                    type = "cmake", variant = "Release", tool_key = "ninja-gcc",
                    state = "configured", build_dir = shared_dir,
                },
            },
        })

        ws._core._deps.io.rm_rf_async = function(dir, cb)
            deleted_dirs[#deleted_dirs + 1] = dir
            cb(true, nil)
        end

        -- Delete both configs — dir should be deleted
        local done = false
        ws:_run_deletion({
            { project_key = "App", config_key = "Debug:ninja-gcc", build_dir = shared_dir, unit = ws:find_config_unit_for_cached(ws.cache.configurations["App/Debug:ninja-gcc"]) },
            { project_key = "App", config_key = "Release:ninja-gcc", build_dir = shared_dir, unit = ws:find_config_unit_for_cached(ws.cache.configurations["App/Release:ninja-gcc"]) },
        }, function(items)
            ws:delete_cached_configs(items)
        end, function()
            done = true
        end)

        assert.is_true(done)
        assert.equals(1, #deleted_dirs)
        assert.equals(shared_dir, deleted_dirs[1])
    end)

    it("deletes dir when only one config references it", function()
        local build_dir = "/root/.nvim/build/App/ninja-gcc/Debug"
        local deleted_dirs = {}

        local ws = make_ws({
            projects = { App = { cmake = {} } },
        }, nil, {
            configurations = {
                ["App/Debug:ninja-gcc"] = {
                    project_key = "App", config_key = "Debug:ninja-gcc",
                    type = "cmake", variant = "Debug", tool_key = "ninja-gcc",
                    state = "configured", build_dir = build_dir,
                },
            },
        })

        ws._core._deps.io.rm_rf_async = function(dir, cb)
            deleted_dirs[#deleted_dirs + 1] = dir
            cb(true, nil)
        end

        local done = false
        ws:_run_deletion({
            { project_key = "App", config_key = "Debug:ninja-gcc", build_dir = build_dir, unit = ws:find_config_unit_for_cached(ws.cache.configurations["App/Debug:ninja-gcc"]) },
        }, function(items)
            ws:delete_cached_configs(items)
        end, function()
            done = true
        end)

        assert.is_true(done)
        assert.equals(1, #deleted_dirs)
    end)
end)


-- =========================================================================
-- Part 3: Build dir operation queue
-- =========================================================================

describe("build dir operation queue", function()
    local ws

    before_each(function()
        ws = make_ws()
    end)

    describe("acquire_build_dir_lock", function()
        it("acquires exclusive lock immediately when free", function()
            local called = false
            local acquired = ws:acquire_build_dir_lock("/build", "exclusive", function()
                called = true
            end)
            assert.is_true(acquired)
            assert.is_true(called)
        end)

        it("acquires shared lock immediately when free", function()
            local called = false
            local acquired = ws:acquire_build_dir_lock("/build", "shared", function()
                called = true
            end)
            assert.is_true(acquired)
            assert.is_true(called)
        end)

        it("queues exclusive when exclusive is held", function()
            local calls = {}
            ws:acquire_build_dir_lock("/build", "exclusive", function()
                calls[#calls + 1] = "first"
            end)
            local acquired = ws:acquire_build_dir_lock("/build", "exclusive", function()
                calls[#calls + 1] = "second"
            end)
            assert.is_false(acquired)
            assert.same({ "first" }, calls)
        end)

        it("queues shared when exclusive is held", function()
            local calls = {}
            ws:acquire_build_dir_lock("/build", "exclusive", function()
                calls[#calls + 1] = "exclusive"
            end)
            local acquired = ws:acquire_build_dir_lock("/build", "shared", function()
                calls[#calls + 1] = "shared"
            end)
            assert.is_false(acquired)
            assert.same({ "exclusive" }, calls)
        end)

        it("queues exclusive when shared is held", function()
            local calls = {}
            ws:acquire_build_dir_lock("/build", "shared", function()
                calls[#calls + 1] = "shared"
            end)
            local acquired = ws:acquire_build_dir_lock("/build", "exclusive", function()
                calls[#calls + 1] = "exclusive"
            end)
            assert.is_false(acquired)
            assert.same({ "shared" }, calls)
        end)

        it("allows multiple concurrent shared locks", function()
            local calls = {}
            ws:acquire_build_dir_lock("/build", "shared", function()
                calls[#calls + 1] = "shared1"
            end)
            local acquired = ws:acquire_build_dir_lock("/build", "shared", function()
                calls[#calls + 1] = "shared2"
            end)
            assert.is_true(acquired)
            assert.same({ "shared1", "shared2" }, calls)
        end)
    end)

    describe("release_build_dir_lock", function()
        it("dequeues exclusive after exclusive release", function()
            local calls = {}
            ws:acquire_build_dir_lock("/build", "exclusive", function()
                calls[#calls + 1] = "first"
            end)
            ws:acquire_build_dir_lock("/build", "exclusive", function()
                calls[#calls + 1] = "second"
            end)
            assert.same({ "first" }, calls)

            ws:release_build_dir_lock("/build", "exclusive")
            assert.same({ "first", "second" }, calls)
        end)

        it("dequeues shared after exclusive release", function()
            local calls = {}
            ws:acquire_build_dir_lock("/build", "exclusive", function()
                calls[#calls + 1] = "exclusive"
            end)
            ws:acquire_build_dir_lock("/build", "shared", function()
                calls[#calls + 1] = "shared"
            end)
            assert.same({ "exclusive" }, calls)

            ws:release_build_dir_lock("/build", "exclusive")
            assert.same({ "exclusive", "shared" }, calls)
        end)

        it("dequeues exclusive after all shared release", function()
            local calls = {}
            ws:acquire_build_dir_lock("/build", "shared", function()
                calls[#calls + 1] = "shared1"
            end)
            ws:acquire_build_dir_lock("/build", "shared", function()
                calls[#calls + 1] = "shared2"
            end)
            ws:acquire_build_dir_lock("/build", "exclusive", function()
                calls[#calls + 1] = "exclusive"
            end)
            assert.same({ "shared1", "shared2" }, calls)

            -- Release first shared — exclusive still can't run
            ws:release_build_dir_lock("/build", "shared")
            assert.same({ "shared1", "shared2" }, calls)

            -- Release second shared — now exclusive can run
            ws:release_build_dir_lock("/build", "shared")
            assert.same({ "shared1", "shared2", "exclusive" }, calls)
        end)

        it("batches consecutive shared ops on dequeue", function()
            local calls = {}
            ws:acquire_build_dir_lock("/build", "exclusive", function()
                calls[#calls + 1] = "exclusive"
            end)
            ws:acquire_build_dir_lock("/build", "shared", function()
                calls[#calls + 1] = "shared1"
            end)
            ws:acquire_build_dir_lock("/build", "shared", function()
                calls[#calls + 1] = "shared2"
            end)
            assert.same({ "exclusive" }, calls)

            ws:release_build_dir_lock("/build", "exclusive")
            -- Both shared ops should run together
            assert.same({ "exclusive", "shared1", "shared2" }, calls)
        end)

        it("cleans up lock entry when fully released with empty queue", function()
            ws:acquire_build_dir_lock("/build", "shared", function() end)
            ws:release_build_dir_lock("/build", "shared")
            assert.is_nil(ws._build_dir_locks["/build"])
        end)
    end)

    describe("has_queued_operations", function()
        it("returns false when no lock", function()
            assert.is_false(ws:has_queued_operations("/build"))
        end)

        it("returns false when lock held but no queue", function()
            ws:acquire_build_dir_lock("/build", "exclusive", function() end)
            assert.is_false(ws:has_queued_operations("/build"))
        end)

        it("returns true when operations are queued", function()
            ws:acquire_build_dir_lock("/build", "exclusive", function() end)
            ws:acquire_build_dir_lock("/build", "exclusive", function() end)
            assert.is_true(ws:has_queued_operations("/build"))
        end)
    end)

    describe("is_build_dir_locked", function()
        it("returns false when no lock", function()
            local locked, lt = ws:is_build_dir_locked("/build")
            assert.is_false(locked)
            assert.is_nil(lt)
        end)

        it("returns exclusive when exclusive lock held", function()
            ws:acquire_build_dir_lock("/build", "exclusive", function() end)
            local locked, lt = ws:is_build_dir_locked("/build")
            assert.is_true(locked)
            assert.equals("exclusive", lt)
        end)

        it("returns shared when shared lock held", function()
            ws:acquire_build_dir_lock("/build", "shared", function() end)
            local locked, lt = ws:is_build_dir_locked("/build")
            assert.is_true(locked)
            assert.equals("shared", lt)
        end)
    end)

    describe("queue ordering", function()
        it("exclusive -> shared -> exclusive runs in correct order", function()
            local calls = {}

            ws:acquire_build_dir_lock("/build", "exclusive", function()
                calls[#calls + 1] = "ex1"
            end)
            ws:acquire_build_dir_lock("/build", "shared", function()
                calls[#calls + 1] = "sh1"
            end)
            ws:acquire_build_dir_lock("/build", "exclusive", function()
                calls[#calls + 1] = "ex2"
            end)

            assert.same({ "ex1" }, calls)

            -- Release ex1 -> sh1 runs (shared)
            ws:release_build_dir_lock("/build", "exclusive")
            assert.same({ "ex1", "sh1" }, calls)

            -- Release sh1 -> ex2 runs
            ws:release_build_dir_lock("/build", "shared")
            assert.same({ "ex1", "sh1", "ex2" }, calls)
        end)

        it("shared ops don't batch across an exclusive boundary", function()
            local calls = {}

            ws:acquire_build_dir_lock("/build", "exclusive", function()
                calls[#calls + 1] = "ex1"
            end)
            ws:acquire_build_dir_lock("/build", "shared", function()
                calls[#calls + 1] = "sh1"
            end)
            ws:acquire_build_dir_lock("/build", "exclusive", function()
                calls[#calls + 1] = "ex2"
            end)
            ws:acquire_build_dir_lock("/build", "shared", function()
                calls[#calls + 1] = "sh2"
            end)

            -- Release ex1 -> only sh1 runs (stops at ex2)
            ws:release_build_dir_lock("/build", "exclusive")
            assert.same({ "ex1", "sh1" }, calls)

            -- Release sh1 -> ex2 runs
            ws:release_build_dir_lock("/build", "shared")
            assert.same({ "ex1", "sh1", "ex2" }, calls)

            -- Release ex2 -> sh2 runs
            ws:release_build_dir_lock("/build", "exclusive")
            assert.same({ "ex1", "sh1", "ex2", "sh2" }, calls)
        end)
    end)

    describe("independent dirs don't interfere", function()
        it("locks on different dirs are independent", function()
            local calls = {}

            ws:acquire_build_dir_lock("/build/a", "exclusive", function()
                calls[#calls + 1] = "a_exclusive"
            end)
            local acquired = ws:acquire_build_dir_lock("/build/b", "exclusive", function()
                calls[#calls + 1] = "b_exclusive"
            end)

            assert.is_true(acquired)
            assert.same({ "a_exclusive", "b_exclusive" }, calls)
        end)
    end)
end)

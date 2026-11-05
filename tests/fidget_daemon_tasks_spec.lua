--- fidget progress for daemon tasks (spec §19.16 "Editor operations"): the
--- observer's `daemon_task_started` / `daemon_task_progress` /
--- `daemon_task_stopped` events are the one source of build/configure
--- progress entries.

local remote_task = require("loomworks.daemon.remote_task")

local function with_fake_fidget(fn)
    local prev_progress = package.loaded["fidget.progress"]
    local prev_lw = package.loaded["loomworks.fidget"]
    local handles = {}
    package.loaded["fidget.progress"] = {
        handle = {
            create = function(o)
                local h = { opts = o, reports = {}, finished = false, cancelled = false }
                function h:report(r) self.reports[#self.reports + 1] = r end
                function h:finish() self.finished = true end
                function h:cancel() self.cancelled = true end
                handles[#handles + 1] = h
                return h
            end,
        },
    }
    package.loaded["loomworks.fidget"] = nil
    local ok, err = pcall(fn, handles)
    require("loomworks.fidget").clear()
    package.loaded["fidget.progress"] = prev_progress
    package.loaded["loomworks.fidget"] = prev_lw
    if not ok then error(err) end
end

describe("loomworks.fidget with daemon tasks", function()
    it("a daemon task's start, progress and stop drive one progress entry", function()
        with_fake_fidget(function(handles)
            require("loomworks.fidget").setup({})
            local lw = require("loomworks")
            local task = remote_task.new(41, { name = "dev", kind = "configure", profile = "dev",
                origin = "editor", units = { { project = "app", configuration = "Debug" } } }, 0)
            task.owned = true -- the editor's own task: no origin marker
            lw._emit("daemon_task_started", { task = task })
            assert.equals(1, #handles)
            assert.equals("Configuring", handles[1].opts.message)
            assert.equals("dev", handles[1].opts.title)

            task.pct = 40
            lw._emit("daemon_task_progress", { task = task })
            assert.equals(40, handles[1].reports[#handles[1].reports].percentage)

            task:finish(0, nil, nil, 3)
            lw._emit("daemon_task_stopped", { task = task })
            assert.is_true(handles[1].finished)
            assert.equals("configured in 3s", handles[1].reports[#handles[1].reports].message)
            -- The entry is gone: nothing is left for the recovery hatch.
            assert.equals(0, require("loomworks.fidget").clear())
        end)
    end)

    it("a CLI task's entry carries the origin marker", function()
        with_fake_fidget(function(handles)
            require("loomworks.fidget").setup({})
            local task = remote_task.new(42, { name = "dev", kind = "build", profile = "dev", origin = "cli" }, 0)
            require("loomworks")._emit("daemon_task_started", { task = task })
            assert.equals("Building (lw)", handles[1].opts.message)
        end)
    end)
end)

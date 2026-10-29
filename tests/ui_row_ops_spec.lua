-- Step 5o C2d-2: the rest of the Profiles section's actions by row id —
-- cancel, task output, options, the device choice and the progress overlay
-- match tasks to rows by the `start` meta's ids (API.md §4.2) and name rows
-- by their ids; nothing reaches the editor's model through a `ref`.

local model = require("loomworks.ui.model_calls")
local remote_task = require("loomworks.daemon.remote_task")

--- A fake observer carrying every method: records owned calls, plain
--- requests and cancels; `tasks` / `ended` its observed tasks.
local function fake_obs()
    local obs = { state = "connected", owned = {}, cancelled = {}, requests = {}, carried = true,
        running = {}, ended = {} }
    function obs:can_call() return self.carried end
    function obs:refusal(method) return "the daemon does not carry " .. method end
    function obs:start_owned(method, args, h)
        self.owned[#self.owned + 1] = { method = method, args = args, h = h, id = #self.owned + 100 }
    end
    function obs:request(method, args, cb)
        self.requests[#self.requests + 1] = { method = method, args = args, cb = cb }
    end
    function obs:owned_calls()
        local out = {}
        for _, o in ipairs(self.owned) do
            if not o.ended then
                out[#out + 1] = { id = o.id, task = o.task, unit_ids = o.h.unit_ids, profile_id = o.h.profile_id }
            end
        end
        return out
    end
    function obs:cancel_owned_id(id, on_ended)
        self.cancelled[#self.cancelled + 1] = id
        if on_ended then on_ended(true) end
    end
    function obs:cancel_owned(task, on_ended)
        if not task.owned then
            if on_ended then on_ended(false, "started by lw (cli) — cancel it there") end
            return
        end
        self:cancel_owned_id(task.id, on_ended)
    end
    function obs:tasks() return self.running end
    function obs:ended_tasks() return self.ended end
    function obs:_clock() return 10 end
    return obs
end

local function task(id, meta, owned)
    local t = remote_task.new(nil, id, meta, 0)
    t.owned = owned or nil
    return t
end

describe("Profiles section by row id (step 5o C2d-2)", function()
    local obs, ws, saved_notify, notes
    before_each(function()
        obs = fake_obs()
        ws = { root = "/w", _daemon_observer = obs }
        saved_notify = vim.notify
        notes = {}
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    end)
    after_each(function() vim.notify = saved_notify end)

    describe("editor_ops replies", function()
        it("only a clean's refusal on stdout is its nothing-to-clean INFO; any other operation's is an error", function()
            local got
            local eo = require("loomworks.daemon.editor_ops")
            eo.run_ids(ws, "build", { unit_ids = { "u:1" } }, { force = true }, {
                resolve = function() got = "resolved" end,
                reject = function() got = "rejected" end,
            })
            obs.owned[1].h.on_reply({ outcome = "refused", stream = "out", exit_code = 1, message = "no" })
            assert.equals("rejected", got)
            assert.equals(vim.log.levels.ERROR, notes[#notes].level)
            got = nil
            eo.run_ids(ws, "clean", { unit_ids = { "u:1" } }, {}, {
                resolve = function() got = "resolved" end,
                reject = function() got = "rejected" end,
            })
            obs.owned[2].h.on_reply({ outcome = "refused", stream = "out", exit_code = 1, message = "nothing" })
            assert.equals("resolved", got)
            assert.equals(vim.log.levels.INFO, notes[#notes].level)
        end)
    end)
end)

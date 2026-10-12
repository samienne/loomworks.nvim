-- A minimal overseer for specs (CI has no overseer): the parts of its Task /
-- strategy contract the daemon task-runner bridge relies on
-- (loomworks.daemon.task_runner): strategy.load → `new(conf)`; `start` →
-- strategy:start, RUNNING; `stop` → CANCELED, then strategy:stop;
-- `restart(force)` → stop, reset, start; `on_exit(code)` → SUCCESS/FAILURE
-- while running. tests/daemon_task_runner_spec.lua checks the same flow
-- against the real overseer when it is installed.
--
-- Returns (overseer, overseer.strategy); `created` collects the tasks (and
-- `created.opened` counts `open` calls).

return function(created)
    local Task = {}
    Task.__index = Task
    function Task:is_running() return self.status == "RUNNING" end
    function Task:get_bufnr() return self.strategy:get_bufnr() end
    function Task:finalize(status)
        if not self:is_running() then return end
        self.status = status
    end
    function Task:start()
        if self:is_running() then return false end
        self.strategy:start(self)
        self.status = "RUNNING"
        return true
    end
    function Task:stop()
        if not self:is_running() then return false end
        self:finalize("CANCELED")
        self.strategy:stop()
        return true
    end
    function Task:reset()
        self.status = "PENDING"
        self.strategy:reset()
    end
    function Task:restart(force)
        if self:is_running() then
            if not force then return false end
            self:stop()
        end
        self:reset()
        return self:start()
    end
    function Task:on_exit(code)
        if not self:is_running() then return end
        self:finalize(code == 0 and "SUCCESS" or "FAILURE")
    end
    function Task:dispose()
        self.status = "DISPOSED"
        self.strategy:dispose()
    end
    local strategy = {
        load = function(defn)
            local s = require("overseer.strategy." .. defn[1]).new(defn)
            s.name = defn[1]
            return s
        end,
    }
    local ov = {
        new_task = function(opts)
            local t = setmetatable({ name = opts.name, status = "PENDING", metadata = opts.metadata,
                strategy = strategy.load(opts.strategy) }, Task)
            created[#created + 1] = t
            return t
        end,
        open = function() created.opened = (created.opened or 0) + 1 end,
    }
    return ov, strategy
end


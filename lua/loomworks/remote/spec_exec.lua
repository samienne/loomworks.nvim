--- loomworks/remote/spec_exec.lua — the command-spec executor for device
--- runners (spec §18.2, §18.8).
---
--- A device runner only BUILDS command specs `{ cmd, args, env?, check_output? }`;
--- core executes every one of them here, so spawning, timeouts, cancellation,
--- output normalisation and failure detection are uniform across runners:
---
---   * `cmd` must be an absolute path (derived from the SDK installation, spec
---     §17.7) and is resolved with the existing executable rules
---     (loomworks.exe: existence, PATHEXT on Windows) — never a PATH search;
---   * `args` is an argument vector passed with no host command interpreter;
---   * `env` extends the parent environment;
---   * output is split into lines with CRLF normalised to LF;
---   * a hard timeout kills the host-side process and fails the step, naming it;
---   * `check_output(lines) → string|nil` catches connector failures that are
---     printed with a success status (applied by the caller-chosen line subset);
---   * a job can be cancelled (killed) at any time.
---
--- Output handlers run from the main loop (via `vim.schedule`), never from a
--- libuv callback, so runner-supplied parsers may call any editor API.
---
--- The process backend is injectable (`opts.backend`): tests drive an
--- in-memory device through the same executor. A backend is
---   `{ spawn(path, args, { env, cwd }, handlers) → handle|nil, err,
---      resolve?(cmd) → path|nil, err }`
--- where `handlers = { on_stdout(chunk), on_stderr(chunk), on_exit(code, signal) }`
--- and `handle = { kill(signal?) }`.

local M = {}

local function uv() return vim.uv or vim.loop end

--- Default transport timeouts, in seconds (spec §18.8).
M.DEFAULT_TIMEOUTS = { query = 120, transfer = 600 }

--- Grace period after a process exits for its pipes to drain before they are
--- closed anyway (a grandchild holding the pipe must not hang the run).
M.DRAIN_MS = 1500

-- ---------------------------------------------------------------------------
-- libuv backend
-- ---------------------------------------------------------------------------

local function env_list(env)
    if not env or next(env) == nil then return nil end
    local merged = uv().os_environ()
    local win = package.config:sub(1, 1) == "\\"
    for k, v in pairs(env) do
        if win then
            local lk = k:lower()
            for ek in pairs(merged) do
                if ek ~= k and ek:lower() == lk then merged[ek] = nil end
            end
        end
        merged[k] = v
    end
    local list = {}
    for k, v in pairs(merged) do list[#list + 1] = k .. "=" .. tostring(v) end
    return list
end

--- The real process backend (libuv, captured pipes, hidden window).
M.uv_backend = {
    resolve = function(cmd)
        local exe = require("loomworks.exe")
        if not exe.is_absolute(cmd) then
            return nil, "program '" .. tostring(cmd) .. "' is not an absolute path"
        end
        return exe.resolve(cmd)
    end,
    spawn = function(path, args, o, h)
        local so, se = uv().new_pipe(false), uv().new_pipe(false)
        local handle, pid
        local exited, open, finished = false, 2, false
        local code, sig
        local function finish()
            if finished then return end
            finished = true
            h.on_exit(code, sig)
        end
        local function closer(pipe)
            if not pipe:is_closing() then pcall(pipe.read_stop, pipe); pipe:close() end
        end
        local ok, spawn_err
        handle, pid = uv().spawn(path, {
            args = args,
            stdio = { nil, so, se },
            env = env_list(o.env),
            cwd = o.cwd,
            hide = true,
        }, function(c, s)
            code, sig = c, s
            exited = true
            if handle and not handle:is_closing() then handle:close() end
            if open == 0 then return finish() end
            -- Pipes still open (a grandchild inherited them): give them a
            -- moment, then close them and report.
            local t = uv().new_timer()
            t:start(M.DRAIN_MS, 0, function()
                t:stop(); t:close()
                closer(so); closer(se)
                finish()
            end)
        end)
        if not handle then
            so:close(); se:close()
            spawn_err = pid
            return nil, tostring(spawn_err)
        end
        ok = true
        local function reader(pipe, cb)
            pipe:read_start(function(_, data)
                if data then cb(data); return end
                closer(pipe)
                open = open - 1
                if exited and open == 0 then finish() end
            end)
        end
        reader(so, h.on_stdout)
        reader(se, h.on_stderr)
        return {
            pid = pid,
            kill = function(signal)
                if ok and handle and not handle:is_closing() then
                    pcall(uv().process_kill, handle, signal or "sigterm")
                end
            end,
        }
    end,
}

-- ---------------------------------------------------------------------------
-- Spec validation
-- ---------------------------------------------------------------------------

--- Validate a runner-built spec. Returns the normalised
--- `{ cmd, args, env, check_output }` or nil + reason.
--- @param spec any
--- @return table|nil spec, string|nil err
function M.normalize_spec(spec)
    if type(spec) ~= "table" then return nil, "runner returned no command spec" end
    if type(spec.cmd) ~= "string" or spec.cmd == "" then
        return nil, "command spec has no program"
    end
    local args = {}
    for i, a in ipairs(spec.args or {}) do
        if type(a) == "number" then a = tostring(a) end
        if type(a) ~= "string" then return nil, "command spec argument " .. i .. " is not a string" end
        if a:find("%z") then return nil, "command spec argument " .. i .. " contains a NUL" end
        args[i] = a
    end
    local env
    if spec.env ~= nil then
        if type(spec.env) ~= "table" then return nil, "command spec env must be a table" end
        env = {}
        for k, v in pairs(spec.env) do
            if type(k) ~= "string" or (type(v) ~= "string" and type(v) ~= "number") then
                return nil, "command spec env must map names to strings"
            end
            env[k] = tostring(v)
        end
    end
    if spec.check_output ~= nil and type(spec.check_output) ~= "function" then
        return nil, "command spec check_output must be a function"
    end
    return { cmd = spec.cmd, args = args, env = env, check_output = spec.check_output }
end

-- ---------------------------------------------------------------------------
-- Jobs
-- ---------------------------------------------------------------------------

--- @class loomworks.SpecJob
--- @field label string step name used in messages
--- @field spec table normalised spec
--- @field lines string[] stdout lines (LF-normalised)
--- @field err_lines string[] stderr lines
--- @field done boolean
--- @field code integer|nil exit status (128+N for a signal)
--- @field timed_out boolean
--- @field cancelled boolean
--- @field killed_reason string|nil
--- @field spawn_error string|nil
local Job = {}
Job.__index = Job

local function splitter(job, stream, on_line)
    local buf = ""
    local store = stream == "stdout" and job.lines or job.err_lines
    local function emit(line)
        line = line:gsub("\r+$", "")
        store[#store + 1] = line
        if on_line then on_line(stream, line) end
    end
    return function(chunk)
        buf = buf .. chunk
        while true do
            local nl = buf:find("\n", 1, true)
            if not nl then break end
            emit(buf:sub(1, nl - 1))
            buf = buf:sub(nl + 1)
        end
    end, function()
        if buf ~= "" then emit(buf); buf = "" end
    end
end

--- Start a spec asynchronously.
--- opts:
---   label    string   step name for messages ("push foo.so")
---   timeout  number|nil seconds (hard timeout; nil = none)
---   on_line  fun(stream: "stdout"|"stderr", line: string)|nil live lines
---   on_exit  fun(job)|nil
---   cwd      string|nil host working directory for the connector
---   backend  table|nil process backend (default: libuv)
--- @param spec table runner-built spec
--- @param opts? table
--- @return loomworks.SpecJob
function M.start(spec, opts)
    opts = opts or {}
    local job = setmetatable({
        label = opts.label or "device command",
        lines = {}, err_lines = {}, done = false,
        timed_out = false, cancelled = false,
    }, Job)
    local backend = opts.backend or M.uv_backend
    local nspec, serr = M.normalize_spec(spec)
    local function fail_now(msg)
        job.spawn_error = msg
        job.done = true
        job.code = nil
        if opts.on_exit then opts.on_exit(job) end
        return job
    end
    if not nspec then return fail_now(serr) end
    job.spec = nspec
    local path, rerr
    if backend.resolve then
        path, rerr = backend.resolve(nspec.cmd)
    else
        path = nspec.cmd
    end
    if not path then return fail_now(tostring(rerr)) end

    local out_feed, out_flush = splitter(job, "stdout", opts.on_line)
    local err_feed, err_flush = splitter(job, "stderr", opts.on_line)
    local timer
    local handle, sp_err = backend.spawn(path, nspec.args, { env = nspec.env, cwd = opts.cwd }, {
        on_stdout = function(chunk) vim.schedule(function() out_feed(chunk) end) end,
        on_stderr = function(chunk) vim.schedule(function() err_feed(chunk) end) end,
        on_exit = function(code, signal)
            vim.schedule(function()
                out_flush(); err_flush()
                if timer then pcall(function() timer:stop(); timer:close() end); timer = nil end
                if (code == nil or code == 0) and signal and signal ~= 0 then
                    code = 128 + signal
                end
                job.code = code
                job.done = true
                if opts.on_exit then opts.on_exit(job) end
            end)
        end,
    })
    if not handle then return fail_now(tostring(sp_err)) end
    job._handle = handle
    if opts.timeout and opts.timeout > 0 then
        uv().update_time()
        timer = uv().new_timer()
        timer:start(math.floor(opts.timeout * 1000), 0, function()
            if timer then pcall(function() timer:stop(); timer:close() end); timer = nil end
            if not job.done then
                job.timed_out = true
                job.timeout = opts.timeout
                job.killed_reason = job.killed_reason or "timeout"
                handle.kill("sigkill")
            end
        end)
    end
    return job
end

--- Kill the job's host-side process (cancellation / transport failure).
--- @param reason? string "cancel"|"transport"|...
function Job:kill(reason)
    if self.done then return end
    self.killed_reason = self.killed_reason or reason or "cancel"
    if reason == "cancel" then self.cancelled = true end
    if self._handle then self._handle.kill("sigkill") end
end

--- Block (pumping the event loop) until the job is done.
--- @return loomworks.SpecJob
function Job:wait()
    while not self.done do
        vim.wait(1000, function() return self.done end, 5)
    end
    return self
end

--- The failure message for a finished job, or nil when it succeeded.
--- `check_lines` (default: every stdout + stderr line) are the lines the
--- spec's `check_output` inspects.
--- @param check_lines? string[]
--- @param opts? { allow_nonzero?: boolean }
--- @return string|nil
function Job:failure(check_lines, opts)
    if self.spawn_error then
        return self.label .. ": cannot run: " .. self.spawn_error
    end
    if self.timed_out then
        return string.format("%s timed out after %ss (the connector was killed)",
            self.label, tostring(self.timeout))
    end
    if self.cancelled then return self.label .. ": cancelled" end
    if self.killed_reason then return self.label .. ": " .. self.killed_reason end
    if self.code ~= 0 and not (opts and opts.allow_nonzero) then
        local tail = {}
        local all = {}
        for _, l in ipairs(self.lines) do all[#all + 1] = l end
        for _, l in ipairs(self.err_lines) do all[#all + 1] = l end
        for i = math.max(1, #all - 4), #all do tail[#tail + 1] = all[i] end
        return string.format("%s failed (exit %s)%s", self.label, tostring(self.code),
            #tail > 0 and (":\n    " .. table.concat(tail, "\n    ")) or "")
    end
    if self.spec and self.spec.check_output then
        local lines = check_lines
        if not lines then
            lines = {}
            for _, l in ipairs(self.lines) do lines[#lines + 1] = l end
            for _, l in ipairs(self.err_lines) do lines[#lines + 1] = l end
        end
        local ok, msg = pcall(self.spec.check_output, lines)
        if ok and type(msg) == "string" and msg ~= "" then
            return self.label .. ": " .. msg
        elseif not ok then
            return self.label .. ": check_output failed: " .. tostring(msg)
        end
    end
    return nil
end

--- Run a spec to completion. Returns the finished job and its failure (nil on
--- success).
--- @param spec table
--- @param opts? table as for `start`
--- @return loomworks.SpecJob job, string|nil failure
function M.run(spec, opts)
    local job = M.start(spec, opts):wait()
    return job, job:failure()
end

--- Resolve the effective transport timeouts: per-invocation overrides win over
--- the runner's, which win over core's defaults (spec §18.8).
--- @param runner loomworks.Runner|nil
--- @param overrides? { query?: number, transfer?: number }
--- @return { query: number, transfer: number }
function M.timeouts(runner, overrides)
    local t = { query = M.DEFAULT_TIMEOUTS.query, transfer = M.DEFAULT_TIMEOUTS.transfer }
    local rt = runner and type(runner.timeouts) == "table" and runner.timeouts or {}
    for _, k in ipairs({ "query", "transfer" }) do
        if type(rt[k]) == "number" and rt[k] > 0 then t[k] = rt[k] end
        if overrides and type(overrides[k]) == "number" and overrides[k] > 0 then t[k] = overrides[k] end
    end
    return t
end

return M

--- loomworks/remote/transport.lua — one device, one runner: core's typed
--- operations over the runner's command-spec builders (spec §18.2).
---
--- Every operation builds a spec with the runner and executes it through
--- remote/spec_exec (hard timeouts: query for listing / device commands,
--- transfer per file). Execution requests are validated BEFORE any spec is
--- built: env names must be portable identifiers, and no argv / env / cwd /
--- path element may contain a NUL or a line break.
---
--- Device-side housekeeping (create directories, mark the program executable,
--- remove staged files, unpack an archive, digest files) runs through the
--- runner's `exec` with POSIX utility argv: `mkdir -p`, `chmod 755`, `rm -f` /
--- `rm -rf`, `tar -xf <archive> -C <dir>`, and the runner's `digest` prefix
--- (spec §18.4). The exit status of every exec comes from the runner's
--- nonce-tagged sentinel (`parse_exit`), never from the connector.

local spec_exec = require("loomworks.remote.spec_exec")

local M = {}

local Transport = {}
Transport.__index = Transport

--- @param o { runner: loomworks.Runner, serial: string, backend?: table, timeouts?: table }
--- @return table transport
function M.new(o)
    return setmetatable({
        runner = o.runner,
        serial = o.serial,
        backend = o.backend,
        timeouts = spec_exec.timeouts(o.runner, o.timeouts),
        jobs = {},
    }, Transport)
end

--- An unpredictable alphanumeric token for one execution.
--- @return string
function M.nonce()
    local uv = vim.uv or vim.loop
    local ok, bytes = pcall(function() return uv.random and uv.random(12) end)
    if ok and type(bytes) == "string" and #bytes == 12 then
        return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    end
    math.randomseed(os.time() + math.floor((uv.hrtime() % 1e9)))
    local t = {}
    for i = 1, 24 do t[i] = string.format("%x", math.random(0, 15)) end
    return table.concat(t)
end

local function bad_text(s)
    return type(s) ~= "string" or s:find("[%z\r\n]") ~= nil
end

--- Validate an exec request (spec §18.2). Returns true or nil + reason.
--- @param req table
--- @return boolean|nil ok, string|nil err
function M.validate_request(req)
    if type(req) ~= "table" or type(req.argv) ~= "table" or #req.argv == 0 then
        return nil, "exec request has no argv"
    end
    for i, a in ipairs(req.argv) do
        if bad_text(a) then return nil, "argument " .. i .. " contains a NUL or a line break" end
    end
    if bad_text(req.cwd) or not req.cwd:match("^/") then
        return nil, "working directory must be an absolute device path without NUL/line breaks"
    end
    for name, value in pairs(req.env or {}) do
        if type(name) ~= "string" or not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
            return nil, "environment name '" .. tostring(name) .. "' is not a portable identifier"
        end
        if bad_text(value) then
            return nil, "environment value of " .. name .. " contains a NUL or a line break"
        end
    end
    for _, d in ipairs(req.library_dirs or {}) do
        if bad_text(d) or not d:match("^/") then
            return nil, "library directory '" .. tostring(d) .. "' is not an absolute device path"
        end
    end
    if type(req.nonce) ~= "string" or not req.nonce:match("^%w+$") then
        return nil, "invalid nonce"
    end
    return true
end

--- Build a spec through a runner builder, guarding against builder errors.
local function build(label, fn, ...)
    local ok, spec = pcall(fn, ...)
    if not ok then return nil, label .. ": runner builder failed: " .. tostring(spec) end
    return spec
end

--- Push one host file to the device (transfer timeout).
--- @return boolean|nil ok, string|nil err
function Transport:push(local_path, remote)
    if bad_text(local_path) or bad_text(remote) then return nil, "push: invalid path" end
    local label = "push " .. remote
    local spec, err = build(label, self.runner.push, self.serial, local_path, remote)
    if not spec then return nil, err end
    local _, fail = spec_exec.run(spec, { label = label, timeout = self.timeouts.transfer, backend = self.backend })
    if fail then return nil, fail end
    return true
end

--- Pull one device file to the host (transfer timeout). Verifies the host file
--- exists afterwards.
--- @return boolean|nil ok, string|nil err
function Transport:pull(remote, local_path)
    if bad_text(local_path) or bad_text(remote) then return nil, "pull: invalid path" end
    local label = "pull " .. remote
    local spec, err = build(label, self.runner.pull, self.serial, remote, local_path)
    if not spec then return nil, err end
    local _, fail = spec_exec.run(spec, { label = label, timeout = self.timeouts.transfer, backend = self.backend })
    if fail then return nil, fail end
    if not (vim.uv or vim.loop).fs_stat(local_path) then
        return nil, label .. ": no file arrived at " .. local_path
    end
    return true
end

--- Classify one exec output line: "pid", "exit" or nil (program output).
--- @return string|nil kind, integer|nil value
function Transport:classify_line(line, nonce)
    local r = self.runner
    local ok, st = pcall(r.parse_exit, line, nonce)
    if ok and type(st) == "number" then return "exit", st end
    if r.parse_pid then
        local okp, pid = pcall(r.parse_pid, line, nonce)
        if okp and type(pid) == "number" then return "pid", pid end
    end
    return nil
end

--- Start an execution (spec §18.2 `exec`). Lines are classified: the pid and
--- sentinel lines are consumed (never program output); `handlers.on_output`
--- receives program lines as (stream, line); `handlers.on_pid(pid)` and
--- `handlers.on_exit_status(status)` fire when recognised. Returns the job
--- and a state table `{ status, pid, pre = {}, post = {}, output = {} }`, or
--- nil + err when the request is refused.
--- @param req table exec request (argv, cwd, env, library_dirs, nonce)
--- @param handlers? table
--- @param timeout? number seconds (nil = none)
--- @return table|nil job, table|string state_or_err
function Transport:start_exec(req, handlers, timeout)
    handlers = handlers or {}
    local ok, verr = M.validate_request(req)
    if not ok then return nil, "refused device execution: " .. verr end
    local label = handlers.label or ("exec " .. req.argv[1])
    local spec, err = build(label, self.runner.exec, self.serial, req)
    if not spec then return nil, err end
    local state = { pre = {}, post = {}, output = {}, status = nil, pid = nil }
    local has_pid = self.runner.parse_pid ~= nil
    local job = spec_exec.start(spec, {
        label = label, timeout = timeout, backend = self.backend,
        on_line = function(stream, line)
            if stream == "stdout" then
                local kind, v = self:classify_line(line, req.nonce)
                if kind == "exit" and state.status == nil then
                    state.status = v
                    if handlers.on_exit_status then handlers.on_exit_status(v) end
                    return
                elseif kind == "pid" and state.pid == nil then
                    state.pid = v
                    if handlers.on_pid then handlers.on_pid(v) end
                    return
                end
                -- Connector lines: before the program starts (pid line not
                -- yet seen, when the runner announces one) or after the
                -- sentinel. Only these are subject to check_output.
                if state.status ~= nil then
                    state.post[#state.post + 1] = line
                    return
                end
                if has_pid and state.pid == nil then
                    state.pre[#state.pre + 1] = line
                    return
                end
            elseif state.status ~= nil then
                state.post[#state.post + 1] = line
                return
            end
            state.output[#state.output + 1] = line
            if handlers.on_output then handlers.on_output(stream, line) end
        end,
    })
    self.jobs[#self.jobs + 1] = job
    return job, state
end

--- The failure of a finished exec at the transport level (spawn error,
--- timeout, cancellation, connector-reported failure, or a lost status).
--- Program exit statuses are NOT failures here.
--- @return string|nil
function Transport:exec_failure(job, state)
    local lines = {}
    for _, l in ipairs(state.pre) do lines[#lines + 1] = l end
    for _, l in ipairs(state.post) do lines[#lines + 1] = l end
    local fail = job:failure(lines, { allow_nonzero = true })
    if fail then return fail end
    if state.status == nil then
        return job.label .. ": the connector ended without reporting the program's exit status"
            .. (job.code and job.code ~= 0 and (" (connector exit " .. tostring(job.code) .. ")") or "")
    end
    return nil
end

--- Run a short device command (housekeeping) to completion under the query
--- timeout. Returns the program status, its output lines, or nil + err on a
--- transport failure.
--- @param argv string[]
--- @param cwd? string device-side working directory (default "/")
--- @return integer|nil status, string[]|string lines_or_err
function Transport:shell(argv, cwd)
    local req = { argv = argv, cwd = cwd or "/", env = {}, library_dirs = {}, nonce = M.nonce() }
    local job, state = self:start_exec(req, { label = "device: " .. table.concat(argv, " "):sub(1, 80) },
        self.timeouts.query)
    if not job then return nil, state end
    job:wait()
    local fail = self:exec_failure(job, state)
    if fail then return nil, fail end
    return state.status, state.output
end

--- Cancel every running job of this transport.
function Transport:cancel_all()
    for _, j in ipairs(self.jobs) do j:kill("cancel") end
end

return M

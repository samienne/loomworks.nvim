--- loomworks/task_launch.lua — the editor's own overseer tasks: a launched
--- program (loomworks.daemon.launch_ref) and a streamed device log
--- (loomworks.device_log). Builds, configures, cleans and tests are daemon
--- tasks (loomworks.daemon.task_runner), never started here.

local M = {}

M.is_windows = package.config:sub(1, 1) == "\\"

--- Windows: a cmd.exe / .bat the task runs never searches its cwd for a bare
--- command.
M.NO_CWD_ENV = "NoDefaultCurrentDirectoryInExePath"

--- @param p any
--- @return boolean
local function is_absolute(p)
    if type(p) ~= "string" or p == "" then return false end
    if M.is_windows then
        return p:match("^%a:[/\\]") ~= nil or p:match("^[/\\][/\\][^/\\]") ~= nil
    end
    return p:sub(1, 1) == "/"
end

--- Resolve a task's program before overseer spawns it: a bare `cmd[1]` is
--- looked up in the ABSOLUTE PATH entries only (the task env's, else the
--- editor's; loomworks.lsp_server_cmd) — never the current directory; a
--- relative path is joined to an absolute cwd, else refused. On Windows the
--- env gains `NoDefaultCurrentDirectoryInExePath=1`. Returns the spec, or
--- nil + err: an unresolvable program is reported, never spawned.
--- @param spec { cmd: string[], cwd?: string, env?: table }
--- @return table|nil spec, string|nil err
function M.harden(spec)
    local name = type(spec) == "table" and type(spec.cmd) == "table" and spec.cmd[1] or nil
    if type(name) ~= "string" or name == "" then return nil, "no command" end
    local env = type(spec.env) == "table" and spec.env or nil
    if not name:find("[/\\]") then
        local p, err = require("loomworks.lsp_server_cmd").resolve(name, env)
        if not p then return nil, err end
        name = p
    elseif not is_absolute(name) then
        if not is_absolute(spec.cwd) then
            return nil, "relative program path '" .. name .. "' is not allowed here (use an absolute path)"
        end
        name = spec.cwd:gsub("[/\\]+$", "") .. "/" .. name:gsub("^%.[/\\]", "")
    end
    local cmd = vim.list_extend({ name }, spec.cmd, 2)
    spec.cmd = cmd
    if M.is_windows then
        local out = {}
        for k, v in pairs(env or {}) do out[k] = v end
        out[M.NO_CWD_ENV] = "1"
        spec.env = out
    end
    return spec
end

--- Launch a run/launch task via overseer (a resolved `Launch/1` program,
--- loomworks.daemon.launch_ref). Opens the overseer window.
--- @param opts { name: string, cmd: string[], cwd?: string, env?: table }
--- @return number|nil task_id
function M.launch_run_task(opts)
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        return nil
    end

    -- overseer expects cmd as a list (argv) for direct execution
    local cmd = opts.cmd
    if type(cmd) == "string" then
        cmd = { cmd }
    end
    if opts.args then
        cmd = vim.list_extend(vim.deepcopy(cmd), opts.args)
    end
    local spec, h_err = M.harden({ cmd = cmd, cwd = opts.cwd, env = opts.env })
    if not spec then
        vim.notify("loomworks: " .. tostring(opts.name) .. ": " .. tostring(h_err), vim.log.levels.ERROR)
        return nil
    end
    local task = overseer.new_task({
        name = opts.name,
        cmd = spec.cmd,
        cwd = opts.cwd,
        env = spec.env,
        components = { "default" },
    })
    task:start()
    overseer.open({ enter = false })
    return task.id
end

--- Run a long-running streaming task: every line of stdout is
--- forwarded to `opts.on_line` instead of displayed via overseer's
--- default output buffer. The overseer task itself still exists
--- (shows up in the task list, killable there) so the user has a
--- unified "what's running" view, but actual rendering happens in a
--- caller-owned surface (e.g. the device-log view).
---
--- Streaming tasks don't have a meaningful "done" value; the caller holds
--- the task handle and tears it down when the owning session ends.
---
--- `on_complete(status)` fires when the task finishes (process exit,
--- user-stop, or error) — useful for the caller to invalidate its
--- own state, not for chaining.
--- @param opts { name: string, cmd: string|string[], args?: string[], cwd?: string, env?: table, on_line: fun(line: string), on_complete?: fun(status: string) }
--- @return table|nil overseer task handle
function M.run_streaming_task(opts)
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        return nil
    end

    local cmd = opts.cmd
    if type(cmd) == "string" then cmd = { cmd } end
    if opts.args then
        cmd = vim.list_extend(vim.deepcopy(cmd), opts.args)
    end

    -- Minimal component set: we want the task lifecycle (on_start /
    -- on_output_lines / on_complete hooks) but don't want the default
    -- output-to-buffer rendering — the caller is rendering lines
    -- somewhere else and duplicating them into a hidden task buffer
    -- is wasted memory for a firehose log tail.
    --
    -- `use_terminal = false` is CRITICAL for log tailing. Overseer's
    -- default jobstart strategy runs the process under a pty sized
    -- to the current nvim window, which hard-wraps long stdout lines
    -- at `vim.o.columns - 4` and emits ANSI cursor-positioning
    -- sequences between records. For line-oriented log output —
    -- lines routinely >200 chars — that turns every record into two or three
    -- fragments, none of which parse. A non-terminal jobstart uses
    -- a plain stdout pipe and gives us raw newline-separated output.
    local spec, h_err = M.harden({ cmd = cmd, cwd = opts.cwd, env = opts.env })
    if not spec then
        vim.notify("loomworks: " .. tostring(opts.name) .. ": " .. tostring(h_err), vim.log.levels.ERROR)
        return nil
    end
    local task = overseer.new_task({
        name = opts.name,
        cmd = spec.cmd,
        cwd = opts.cwd,
        env = spec.env,
        strategy = { "jobstart", use_terminal = false },
        components = { "on_output_summarize", "on_exit_set_status" },
    })

    task:subscribe("on_output_lines", function(_, lines)
        for _, line in ipairs(lines or {}) do
            if opts.on_line then
                local ok_cb, err = pcall(opts.on_line, line)
                if not ok_cb then
                    vim.notify("loomworks: streaming on_line error: " .. tostring(err),
                        vim.log.levels.WARN)
                end
            end
        end
    end)

    if opts.on_complete then
        task:subscribe("on_complete", function(_, status)
            pcall(opts.on_complete, status)
        end)
    end

    task:start()
    return task
end

return M

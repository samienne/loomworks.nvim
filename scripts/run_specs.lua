-- Spec-suite runner with per-file exit codes.
--
--   nvim -l scripts/run_specs.lua [--timeout MS] [--jobs N] [--init FILE] [DIR|FILE ...]
--
-- Runs every *_spec.lua the way plenary's PlenaryBustedDirectory does — one
-- headless child nvim per file, same arguments, same minimal_init, all files
-- started at once (plenary has no concurrency limit; --jobs N caps it) under
-- ONE whole-suite budget (--timeout, default 600000 ms) — but records each
-- file's exit code, duration and whether it printed its busted summary.
--
-- PlenaryBustedDirectory fails the run when any child exits non-zero without
-- saying which; this runner ends with a table of every file that exited
-- non-zero, printed no summary, or was still running at the deadline, and
-- exits non-zero only then. It also reports a file whose child exited but
-- whose stdout/stderr stayed open (a leaked descendant process holding the
-- pipes — plenary would wait for it), the slowest files, and the files slow
-- to exit after their summary (RUN_SPECS_SLOW_EXIT_MS, default 1000).
--
-- A child that exits 1 after a clean summary is typically Nvim's own exit
-- path: when its event loop does not close within 2 s at exit (a libuv
-- handle still open, or a callback blocking during teardown) Nvim logs
-- "uv_loop_close() hang?" with the open handles and turns exit 0 into 1.
-- Every child logs to its own NVIM_LOG_FILE; a failing child's log tail is
-- printed with the table.

local uv = vim.uv or vim.loop

local opts = { timeout = 600000, jobs = 0, init = "tests/minimal_init.lua", paths = {} }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--timeout" then
            i = i + 1
            opts.timeout = assert(tonumber(arg[i]), "--timeout needs a number (ms)")
        elseif a == "--jobs" or a == "-j" then
            i = i + 1
            opts.jobs = assert(tonumber(arg[i]), "--jobs needs a number")
        elseif a == "--init" then
            i = i + 1
            opts.init = assert(arg[i], "--init needs a file")
        else
            table.insert(opts.paths, a)
        end
        i = i + 1
    end
    if #opts.paths == 0 then
        opts.paths = { "tests" }
    end
end

-- How long a child's pipes may stay open after it exited before the runner
-- stops waiting for them (a descendant inherited them and is still alive).
local PIPE_GRACE_MS = 15000

local function abs(p)
    return (vim.fn.fnamemodify(p, ":p"):gsub("\\", "/"):gsub("/$", ""))
end

local files = {}
for _, p in ipairs(opts.paths) do
    if vim.fn.isdirectory(p) == 1 then
        local found = vim.fs.find(function(name)
            return name:match("_spec%.lua$") ~= nil
        end, { path = p, type = "file", limit = math.huge })
        for _, f in ipairs(found) do
            table.insert(files, abs(f))
        end
    else
        table.insert(files, abs(p))
    end
end
table.sort(files)
if #files == 0 then
    io.stderr:write("run_specs: no *_spec.lua files under " .. table.concat(opts.paths, " ") .. "\n")
    os.exit(2)
end

local plenary_dir = vim.env.PLENARY_DIR or (vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
local cwd = abs(".")
local root = cwd .. "/"
local function rel(f)
    return f:sub(1, #root) == root and f:sub(#root + 1) or f
end

-- Exactly what plenary's test_harness passes each child (minimal mode).
local function child_args(file)
    return {
        "--headless",
        "-c",
        "set rtp+=.," .. vim.fn.escape(plenary_dir, " ") .. " | runtime plugin/plenary.vim",
        "--noplugin",
        "-u",
        opts.init,
        "-c",
        string.format('lua require("plenary.busted").run("%s")', file),
    }
end

-- Children read the suite budget from here, as under PlenaryBustedDirectory.
vim.env.PLENARY_TEST_TIMEOUT = tostring(opts.timeout)

local function now()
    return uv.hrtime() / 1e6
end

-- Each child logs to its own NVIM_LOG_FILE: Nvim's exit path records why it
-- turned a requested exit 0 into 1 there ("uv_loop_close() hang?" plus the
-- libuv handles still open, when the event loop did not close within 2 s).
local log_dir = vim.fn.tempname()
vim.fn.mkdir(log_dir, "p")
local base_env = {}
for k, v in pairs(vim.fn.environ()) do
    if k ~= "NVIM_LOG_FILE" and not k:match("^=") then
        base_env[#base_env + 1] = k .. "=" .. v
    end
end
local function child_env(log_file)
    local e = vim.list_extend({}, base_env)
    e[#e + 1] = "NVIM_LOG_FILE=" .. log_file
    return e
end

local runs = {}
local queue = {}
for i, f in ipairs(files) do
    runs[i] = { file = f, out = {}, err = {}, log = string.format("%s/%03d.log", log_dir, i) }
    queue[i] = runs[i]
end
local running, finished = 0, 0
local t0 = now()

local function strip_ansi(s)
    return (s:gsub("\27%[[%d;]*m", ""))
end

local function report(r)
    -- Same order as plenary: stderr first, then stdout.
    local text = table.concat(r.err) .. table.concat(r.out)
    text = text:gsub("\r\n", "\n")
    io.stdout:write(text)
    if not text:match("\n$") then
        io.stdout:write("\n")
    end
    local plain = strip_ansi(text)
    r.pass = tonumber(plain:match("Success:%s*(%d+)"))
    r.fail = tonumber(plain:match("Failed :%s*(%d+)"))
    r.errs = tonumber(plain:match("Errors :%s*(%d+)"))
    io.stdout:flush()
end

local start_next

local function finish(r)
    if r.done then
        return
    end
    r.done = true
    if r.grace then
        r.grace:stop()
        r.grace:close()
    end
    for _, p in ipairs({ r.stdout, r.stderr }) do
        if not p:is_closing() then
            p:close()
        end
    end
    report(r)
    running = running - 1
    finished = finished + 1
    start_next()
end

local function maybe_finish(r)
    if r.code ~= nil and r.stdout_eof and r.stderr_eof then
        finish(r)
    end
end

local function start(r)
    r.stdout = uv.new_pipe(false)
    r.stderr = uv.new_pipe(false)
    r.started = now()
    local handle, pid_or_err
    handle, pid_or_err = uv.spawn(vim.v.progpath, {
        args = child_args(r.file),
        stdio = { nil, r.stdout, r.stderr },
        cwd = cwd,
        env = child_env(r.log),
    }, function(code, signal)
        r.code, r.signal = code, signal
        r.exited = now()
        handle:close()
        if not (r.stdout_eof and r.stderr_eof) then
            -- A descendant still holds the pipes: give it a grace period, then
            -- stop waiting and report the leak.
            r.grace = uv.new_timer()
            r.grace:start(PIPE_GRACE_MS, 0, function()
                r.pipes_held = true
                vim.schedule(function()
                    finish(r)
                end)
            end)
        end
        vim.schedule(function()
            maybe_finish(r)
        end)
    end)
    if not handle then
        r.code, r.spawn_error = -1, tostring(pid_or_err)
        r.stdout_eof, r.stderr_eof = true, true
        r.exited = now()
        vim.schedule(function()
            finish(r)
        end)
        return
    end
    r.handle = handle
    local function reader(buf, key)
        return function(err, data)
            if data then
                table.insert(buf, data)
                -- When the busted summary's last line arrived: the child's
                -- exit should follow at once.
                if not r.summary_at and data:find("Errors :", 1, true) then
                    r.summary_at = now()
                end
            else
                r[key] = true
                vim.schedule(function()
                    maybe_finish(r)
                end)
            end
        end
    end
    r.stdout:read_start(reader(r.out, "stdout_eof"))
    r.stderr:read_start(reader(r.err, "stderr_eof"))
end

start_next = function()
    while #queue > 0 and (opts.jobs <= 0 or running < opts.jobs) do
        local r = table.remove(queue, 1)
        running = running + 1
        start(r)
    end
end

io.stdout:write(string.format("Running %d spec files (%s)...\n", #files, opts.jobs > 0 and (opts.jobs .. " at a time") or "all at once"))
start_next()

local completed = vim.wait(opts.timeout, function()
    return finished == #runs
end, 50)

local elapsed = (now() - t0) / 1000

-- Anything still running at the deadline: kill it (as plenary's cq would by
-- exiting) and report it.
if not completed then
    for _, r in ipairs(runs) do
        if not r.done then
            r.timed_out = true
            io.stdout:write("\n[run_specs] still running at the deadline: " .. rel(r.file) .. " -- output so far:\n")
            report(r)
            if r.handle and not r.handle:is_closing() then
                pcall(r.handle.kill, r.handle, "sigkill")
            end
        end
    end
    vim.wait(2000, function()
        for _, r in ipairs(runs) do
            if r.timed_out and r.started and not (r.code ~= nil) then
                return false
            end
        end
        return true
    end, 50)
end

local function fmt_code(c)
    if c == nil then
        return "-"
    end
    if c > 255 or c < 0 then
        -- Windows NTSTATUS-style codes (0xC0000005 access violation, …).
        return string.format("%d (0x%08X)", c, c % 0x100000000)
    end
    return tostring(c)
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local t = f:read("*a")
    f:close()
    return t
end

-- Exit latency: from the summary's last line to the child's exit. A child
-- that needs seconds to exit after its tests (nvim waits up to 2 s for its
-- event loop to close, then exits 1) is flagged even when it got away with 0.
local SLOW_EXIT_MS = tonumber(vim.env.RUN_SPECS_SLOW_EXIT_MS or "") or 1000

local problems, warnings, slow_exits = {}, {}, {}
local tot_pass, tot_fail, tot_err = 0, 0, 0
for _, r in ipairs(runs) do
    tot_pass = tot_pass + (r.pass or 0)
    tot_fail = tot_fail + (r.fail or 0)
    tot_err = tot_err + (r.errs or 0)
    r.lag = (r.summary_at and r.exited) and (r.exited - r.summary_at) or nil
    local nvim_log = read_file(r.log) or ""
    r.loop_hang = nvim_log:find("uv_loop_close() hang?", 1, true) ~= nil
    local why
    if r.timed_out then
        why = "still running at the suite deadline (" .. opts.timeout .. " ms)"
    elseif r.spawn_error then
        why = "spawn failed: " .. r.spawn_error
    elseif r.code ~= 0 or (r.signal or 0) ~= 0 then
        if r.pass and (r.fail or 0) == 0 and (r.errs or 0) == 0 then
            why = "exited non-zero AFTER a clean summary"
            if r.loop_hang then
                why = why .. " (nvim: uv_loop_close() hang? -- libuv handles left open at exit)"
            end
        elseif r.pass then
            why = "test failures/errors"
        else
            why = "exited non-zero without a summary"
        end
    elseif not r.pass then
        why = "exited 0 but printed no busted summary"
    end
    if why then
        table.insert(problems, { r = r, why = why, nvim_log = nvim_log })
    end
    if r.pipes_held then
        table.insert(warnings, r)
    end
    if r.lag and r.lag > SLOW_EXIT_MS then
        table.insert(slow_exits, r)
    end
end

local function dur(r)
    if not r.started then
        return "-"
    end
    return string.format("%.1fs", ((r.exited or now()) - r.started) / 1000)
end

io.stdout:write("\n" .. string.rep("=", 72) .. "\n")
io.stdout:write(string.format(
    "%d spec files in %.1fs: %d passed, %d failed, %d errors\n",
    #runs, elapsed, tot_pass, tot_fail, tot_err
))

local by_time = vim.tbl_filter(function(r)
    return r.exited ~= nil
end, runs)
table.sort(by_time, function(a, b)
    return (a.exited - a.started) > (b.exited - b.started)
end)
io.stdout:write("Slowest files:\n")
for i = 1, math.min(5, #by_time) do
    io.stdout:write(string.format("  %8s  %s\n", dur(by_time[i]), rel(by_time[i].file)))
end

if #slow_exits > 0 then
    table.sort(slow_exits, function(a, b)
        return a.lag > b.lag
    end)
    io.stdout:write(string.format("\nSlow to exit after their summary (> %d ms):\n", SLOW_EXIT_MS))
    for _, r in ipairs(slow_exits) do
        io.stdout:write(string.format("  %6.1fs  %s  (exit %s%s)\n", r.lag / 1000, rel(r.file), tostring(r.code),
            r.loop_hang and ", uv_loop_close() hang?" or ""))
    end
end

if #warnings > 0 then
    io.stdout:write(string.format(
        "\nWARNING: %d file(s) exited but their stdout/stderr stayed open > %d ms (a leaked descendant process holds them):\n",
        #warnings, PIPE_GRACE_MS
    ))
    for _, r in ipairs(warnings) do
        io.stdout:write("  " .. rel(r.file) .. "\n")
    end
end

local function cleanup_logs()
    vim.fn.delete(log_dir, "rf")
end

if #problems == 0 then
    cleanup_logs()
    io.stdout:write("All spec files exited 0 with a clean summary.\n")
    io.stdout:flush()
    os.exit(0)
end

-- The tail of each failing child's Nvim log (its exit-path diagnostics).
for _, p in ipairs(problems) do
    local lines = vim.split(p.nvim_log, "\r?\n", { trimempty = true })
    if #lines > 0 then
        io.stdout:write(string.format("\n--- nvim log of %s (last %d lines) ---\n", rel(p.r.file), math.min(25, #lines)))
        for i = math.max(1, #lines - 24), #lines do
            io.stdout:write(lines[i] .. "\n")
        end
    end
end
cleanup_logs()

io.stdout:write(string.format("\nFAILED: %d spec file(s):\n", #problems))
io.stdout:write(string.format("  %-44s %-22s %-8s %-8s %-12s %s\n", "file", "exit code", "time", "exit lag", "pass/fail/err", "reason"))
for _, p in ipairs(problems) do
    local r = p.r
    local counts = r.pass and string.format("%d/%d/%d", r.pass, r.fail or 0, r.errs or 0) or "-"
    local code = fmt_code(r.code)
    if (r.signal or 0) ~= 0 then
        code = code .. " sig " .. r.signal
    end
    local lag = r.lag and string.format("%.1fs", r.lag / 1000) or "-"
    io.stdout:write(string.format("  %-44s %-22s %-8s %-8s %-12s %s\n", rel(r.file), code, dur(r), lag, counts, p.why))
end
io.stdout:flush()
os.exit(1)

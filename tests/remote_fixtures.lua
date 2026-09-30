-- Shared fixtures for the remote-execution tests (spec §18): fake executable
-- headers, fake units/SDKs, and a FAKE device runner that implements the full
-- runner contract against an in-memory "device" (files, processes that emit
-- lines + the exit sentinel, crash reports, a log stream). The runner only
-- builds specs; the fake process backend (`FakeDevice:backend()`) interprets
-- them, so every spec still goes through core's executor. Nothing here touches
-- a real device or a host PATH tool.

local M = {}

local uv = vim.uv or vim.loop

-- ---------------------------------------------------------------------------
-- Executable headers
-- ---------------------------------------------------------------------------

local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end

--- A 64-byte little-endian ELF64 header with the given e_machine.
function M.elf_header(machine)
    return "\127ELF\2\1\1" .. string.rep("\0", 9) .. "\2\0" .. le16(machine) .. string.rep("\0", 44)
end

--- A minimal PE: MZ stub with e_lfanew = 0x40, then "PE\0\0" + Machine.
function M.pe_header(machine)
    return "MZ" .. string.rep("\0", 0x3A) .. "\64\0\0\0" .. "PE\0\0" .. le16(machine) .. string.rep("\0", 18)
end

--- Thin 64-bit little-endian Mach-O arm64.
function M.macho_header()
    return "\207\250\237\254" .. "\12\0\0\1" .. string.rep("\0", 56)
end

local function write(path, data)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then vim.fn.mkdir(dir, "p") end
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
    return path
end
M.write = write

function M.read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

--- Write an executable this host can NOT run (format differs from the host).
function M.write_foreign_exe(path)
    local host = require("loomworks.remote.probe").host()
    local data = host.format == "elf" and M.pe_header(0x8664) or M.elf_header(183)
    return write(path, data .. "payload")
end

--- Write an executable in the host's own format and architecture.
function M.write_host_exe(path)
    local host = require("loomworks.remote.probe").host()
    local codes = { x86_64 = { elf = 62, pe = 0x8664 }, aarch64 = { elf = 183, pe = 0xAA64 },
        x86 = { elf = 3, pe = 0x14c }, arm = { elf = 40, pe = 0x1c4 } }
    local c = codes[host.arch or "x86_64"] or codes.x86_64
    local data
    if host.format == "pe" then data = M.pe_header(c.pe)
    elseif host.format == "macho" then data = "\202\254\186\190" .. string.rep("\0", 60)
    else data = M.elf_header(c.elf) end
    return write(path, data)
end

--- A fresh canonical temp directory (8.3 short paths on Windows CI resolved
--- through fs_realpath so path assertions compare like with like).
function M.mkroot()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    local real = uv.fs_realpath(d) or d
    return (real:gsub("\\", "/"))
end

-- ---------------------------------------------------------------------------
-- Fake domain objects
-- ---------------------------------------------------------------------------

--- A fake SDK whose provider supplies `runner`.
function M.fake_sdk(runner, key)
    return {
        key = key or "fakesdk-1",
        _provider = { device_runner = function() return runner end },
        is_resolved = function() return true end,
    }
end

--- A fake Tool.
function M.fake_tool(o)
    o = o or {}
    return {
        key = o.tool_key or "kit",
        label = o.tool_key or "kit",
        data = {},
        execution_platform = function() return o.token end,
        sdk = function() return o.sdk end,
    }
end

--- A fake ConfigUnit (enough for foreign classification + staging).
function M.fake_unit(o)
    o = o or {}
    local tool = M.fake_tool(o)
    local unit = {
        id = o.id or "build/App/Debug",
        targets = o.targets,
        _project = o.project,
        tool_object = function() return tool end,
        build_dir = function() return o.build_dir end,
        configured_here = function() return true end,
        run_env = function() return nil end,
    }
    return unit
end

-- ---------------------------------------------------------------------------
-- The fake runner (pure builders + parsers)
-- ---------------------------------------------------------------------------

M.CONNECTOR = "/fake/sdk/bin/connector"

--- A fake runner table implementing the full contract. `o`:
---   combined_output, archive (default true), digest (default {"fakesum"}),
---   runtime_file (host path staged as `librt.so` beside the artifact),
---   no_pid, no_log, no_crash, timeouts
function M.fake_runner_table(o)
    o = o or {}
    local C = M.CONNECTOR
    local r = {
        id = "fake",
        platforms = { "fake-arm64", "fake-arm" },
        staging_base = "/data/stage",
        archive = o.archive ~= false,
        digest = { "fakesum" },
        combined_output = o.combined_output,
        timeouts = o.timeouts,
    }
    if o.digest == false then r.digest = nil elseif o.digest then r.digest = o.digest end
    local function fail_check(lines)
        for _, l in ipairs(lines) do
            if l:match("^%[Fail%]") then return l end
        end
        return nil
    end
    function r.list_devices() return { cmd = C, args = { "list" } } end
    function r.parse_devices(lines)
        local out = {}
        for _, l in ipairs(lines) do
            local serial, state, name = l:match("^(%S+)\t(%S+)\t(.*)$")
            if serial and serial ~= "[Empty]" then
                out[#out + 1] = { serial = serial, state = state == "Connected" and "online" or "offline",
                    display_name = name, properties = {} }
            end
        end
        return out
    end
    function r.push(serial, lp, rp)
        return { cmd = C, args = { "-t", serial, "push", lp, rp }, check_output = fail_check }
    end
    function r.pull(serial, rp, lp)
        return { cmd = C, args = { "-t", serial, "pull", rp, lp }, check_output = fail_check }
    end
    function r.exec(serial, req)
        return { cmd = C, args = { "-t", serial, "exec", vim.json.encode(req) }, check_output = fail_check }
    end
    function r.parse_exit(line, nonce)
        -- Anchored at the END: unterminated program output shares the line
        -- and is returned as the second value (spec §18.2).
        local pre, n = line:match("^(.-)__EXIT_" .. nonce .. "=(%d+)$")
        if not n then return nil end
        return tonumber(n), pre ~= "" and pre or nil
    end
    if not o.no_pid then
        function r.parse_pid(line, nonce)
            local n = line:match("^__PID_" .. nonce .. "=(%d+)$")
            return n and tonumber(n) or nil
        end
    end
    function r.terminate(serial, nonce, pid)
        return { cmd = C, args = { "-t", serial, "kill", tostring(pid or 0), nonce } }
    end
    if not o.no_crash then
        function r.crash_snapshot(serial)
            return { cmd = C, args = { "-t", serial, "crashes" } }, function(lines)
                local set = {}
                for _, l in ipairs(lines) do if l:match("^cppcrash%-") then set[l] = true end end
                return set
            end
        end
        function r.crash_collect(before, after, ctx)
            r.crash_ctx_seen = ctx
            local out = {}
            for name in pairs(after) do
                if not before[name] then out[#out + 1] = "/crash/" .. name end
            end
            table.sort(out)
            return out
        end
    end
    if o.describe then
        -- Optional per-device description (spec §18.2 `describe_device`).
        function r.describe_device(serial)
            return { cmd = C, args = { "-t", serial, "describe" } }, function(lines)
                local props = {}
                for _, l in ipairs(lines) do
                    local k, v = l:match("^([%w_]+)=(.*)$")
                    if k then props[k] = v end
                end
                if not next(props) then return nil end
                return { display_name = props.market_name or props.model, properties = props }
            end
        end
    end
    if o.runtime_file then
        function r.runtime_files(tool)
            r.runtime_tool_seen = tool
            return { { ["local"] = o.runtime_file, relative = "librt.so" } }
        end
    end
    if not o.no_log then
        local KNOWN = { show = { stdout = true, both = true, log = true }, level = true }
        function r.log_session(serial, options, program)
            r.log_options_seen = options
            r.log_program_seen = program
            for k, v in pairs(options) do
                if KNOWN[k] == nil then
                    return nil, "device_log: unknown option '" .. k .. "' (known: level, show)"
                end
                if type(KNOWN[k]) == "table" and not KNOWN[k][v] then
                    return nil, "device_log: invalid show '" .. tostring(v) .. "'"
                end
            end
            local show = ({
                stdout = { program = "live", log = "on_failure", tail = 2 },
                both = { program = "live", log = "live" },
                log = { program = "off", log = "live" },
            })[options.show or "stdout"]
            return {
                clear = { cmd = C, args = { "-t", serial, "logclear" } },
                stream = function(pid)
                    return { cmd = C, args = { "-t", serial, "logstream", tostring(pid or "all") } }
                end,
                receive = function(line)
                    if line:match("^noise") then return nil end
                    return line
                end,
                display = function(line)
                    if options.level == "E" and not line:match("^E ") then return nil end
                    return "LOG " .. line
                end,
                show = show,
            }
        end
    end
    return r
end

-- ---------------------------------------------------------------------------
-- The in-memory device + process backend
-- ---------------------------------------------------------------------------

local FakeDevice = {}
FakeDevice.__index = FakeDevice

--- @param o? { serials?: table<string,string>, combined?: boolean }
function M.device(o)
    o = o or {}
    local self = setmetatable({
        -- serial -> { state = "Connected"|"Offline", name, files = { path -> {data, mode} },
        --            crashes = { name -> path }, online = true }
        boards = {},
        calls = {},         -- every spec run: { op, serial, args... }
        behaviors = {},     -- program basename -> fun(ctx) (see run_program)
        log_lines = {},     -- lines the log stream emits
        combined = o.combined,
        next_pid = 4000,
        killed = {},
        live = {},          -- running fake processes
    }, FakeDevice)
    for serial, name in pairs(o.serials or { SER1 = "Board One" }) do
        self:add(serial, name)
    end
    return self
end

function FakeDevice:add(serial, name, state)
    self.boards[serial] = { state = state or "Connected", name = name or serial, files = {},
        crashes = {}, dirs = {} }
end

function FakeDevice:file(serial, path)
    local b = self.boards[serial]
    return b and b.files[path] or nil
end

function FakeDevice:ops(op)
    local out = {}
    for _, c in ipairs(self.calls) do if c.op == op then out[#out + 1] = c end end
    return out
end

-- Minimal ustar/pax reader for the device-side `tar -xf`.
local function tar_entries(data)
    local out, pos, pax_path = {}, 1, nil
    while pos + 511 <= #data do
        local hdr = data:sub(pos, pos + 511)
        if hdr == string.rep("\0", 512) then break end
        local name = hdr:sub(1, 100):gsub("%z.*$", "")
        local size = tonumber((hdr:sub(125, 136):gsub("[%z ]", "")), 8) or 0
        local typ = hdr:sub(157, 157)
        local prefix = hdr:sub(346, 500):gsub("%z.*$", "")
        if prefix ~= "" then name = prefix .. "/" .. name end
        local body = data:sub(pos + 512, pos + 512 + size - 1)
        pos = pos + 512 + math.ceil(size / 512) * 512
        if typ == "x" then
            pax_path = body:match("%d+ path=([^\n]*)\n")
        elseif typ == "0" or typ == "\0" then
            out[#out + 1] = { name = pax_path or name, data = body }
            pax_path = nil
        end
    end
    return out
end
M.tar_entries = tar_entries

--- Run a device-side program request. Returns an emission plan:
--- { out = {lines}, err = {lines}, exit = n|nil (nil = never sentinel),
---   hang = bool, pid = n }
function FakeDevice:run_program(serial, req, nonce)
    local b = self.boards[serial]
    local argv = req.argv
    local prog = argv[1]
    local plan = { out = {}, err = {}, exit = 0 }
    if prog == "mkdir" then
        for i = 3, #argv do b.dirs[argv[i]] = true end
    elseif prog == "rmdir" then
        -- rmdir semantics: only an empty directory is removed.
        for i = 2, #argv do
            local p = argv[i]
            local busy = false
            for fp in pairs(b.files) do
                if fp:sub(1, #p + 1) == p .. "/" then busy = true end
            end
            if busy then
                plan.err[#plan.err + 1] = "rmdir: " .. p .. ": Directory not empty"
                plan.exit = 1
            else
                b.dirs[p] = nil
                b.removed_dirs = b.removed_dirs or {}
                b.removed_dirs[#b.removed_dirs + 1] = p
            end
        end
    elseif prog == "chmod" then
        for i = 3, #argv do
            if b.files[argv[i]] then b.files[argv[i]].mode = argv[2] end
        end
    elseif prog == "rm" then
        for i = 3, #argv do
            local p = argv[i]
            for fp in pairs(b.files) do
                if fp == p or fp:sub(1, #p + 1) == p .. "/" then b.files[fp] = nil end
            end
        end
    elseif prog == "tar" then
        -- tar -xf <archive> -C <dir>
        local arch, dir = argv[3], argv[5]
        local f = b.files[arch]
        if not f then
            plan.err[1] = "tar: " .. tostring(arch) .. ": No such file"
            plan.exit = 1
        else
            for _, e in ipairs(tar_entries(f.data)) do
                b.files[dir .. "/" .. e.name] = { data = e.data, mode = "644" }
            end
        end
    elseif prog == "fakesum" then
        for i = 2, #argv do
            local f = b.files[argv[i]]
            if f then
                plan.out[#plan.out + 1] = vim.fn.sha256(f.data) .. "  " .. argv[i]
            else
                plan.err[#plan.err + 1] = "fakesum: " .. argv[i] .. ": No such file"
                plan.exit = 1
            end
        end
    else
        local f = b.files[prog]
        if not f then
            plan.err[1] = "sh: " .. prog .. ": not found"
            plan.exit = 127
        else
            local name = prog:match("([^/]+)$")
            local beh = self.behaviors[name]
            local ctx = { serial = serial, req = req, board = b, device = self, nonce = nonce }
            if beh then
                local r = beh(ctx) or {}
                plan.out = r.out or {}
                plan.err = r.err or {}
                plan.exit = r.exit == nil and 0 or r.exit
                plan.no_sentinel = r.no_sentinel
                plan.hang = r.hang
                plan.after = r.after
                plan.connector_tail = r.connector_tail
                plan.delay_ms = r.delay_ms
                plan.unterminated = r.unterminated
            end
        end
        plan.program = true
    end
    return plan
end

--- The process backend interpreting the fake runner's specs.
function FakeDevice:backend()
    local dev = self
    return {
        resolve = function(cmd) return cmd end,
        spawn = function(path, args, o, h)
            local a = {}
            for i, v in ipairs(args) do a[i] = v end
            local call = { op = nil, args = a, env = o.env }
            local serial
            if a[1] == "-t" then serial = a[2]; call.serial = serial; table.remove(a, 1); table.remove(a, 1) end
            call.op = a[1]
            dev.calls[#dev.calls + 1] = call
            local steps = {}  -- { stream, text } then exit
            local exit_code, hang = 0, false
            local board = serial and dev.boards[serial]
            local proc = { killed = false }
            local function emit(stream, line) steps[#steps + 1] = { stream, line } end
            if serial and (not board or board.state ~= "Connected") then
                emit("stderr", "[Fail]device " .. tostring(serial) .. " not found")
                exit_code = 0 -- connector prints failure with success status
            elseif call.op == "list" then
                local serials = {}
                for s in pairs(dev.boards) do serials[#serials + 1] = s end
                table.sort(serials)
                local any = false
                for _, s in ipairs(serials) do
                    local bb = dev.boards[s]
                    if not bb.hidden then
                        any = true
                        emit("stdout", s .. "\t" .. bb.state .. "\t" .. bb.name .. "\r")
                    end
                end
                if not any then emit("stdout", "[Empty]") end
            elseif call.op == "push" then
                local lp, rp = a[2], a[3]
                if dev.fail_push and rp:match(dev.fail_push) then
                    emit("stdout", "[Fail]transfer rejected")
                else
                    local data = M.read(lp)
                    if not data then
                        emit("stdout", "[Fail]no local file " .. lp)
                    else
                        board.files[rp] = { data = data, mode = "644" }
                    end
                end
            elseif call.op == "pull" then
                local rp, lp = a[2], a[3]
                local f = board.files[rp]
                if not f then emit("stdout", "[Fail]remote file not found " .. rp)
                else write(lp, f.data) end
            elseif call.op == "crashes" then
                local names = {}
                for n in pairs(board.crashes) do names[#names + 1] = n end
                table.sort(names)
                for _, n in ipairs(names) do emit("stdout", n) end
            elseif call.op == "describe" then
                if board.describe_fails then
                    emit("stderr", "describe: failed")
                    exit_code = 1
                else
                    for k, v in pairs(board.describe or {}) do emit("stdout", k .. "=" .. v) end
                end
            elseif call.op == "logclear" then
                dev.log_cleared = (dev.log_cleared or 0) + 1
            elseif call.op == "logstream" then
                call.pid = a[2]
                if dev.log_fails then
                    emit("stderr", "log: cannot start")
                    exit_code = 1
                else
                    for _, l in ipairs(dev.log_lines) do emit("stdout", l) end
                    hang = true -- follows until killed
                end
            elseif call.op == "kill" then
                dev.killed[#dev.killed + 1] = { pid = a[2], nonce = a[3] }
                -- `kill_hangs`: the stop request never completes (a stuck
                -- connector) — the program is not released either.
                if dev.kill_hangs then
                    hang = true
                else
                    -- the device-side program stops: release any hung exec
                    for _, p in ipairs(dev.live) do
                        if p.nonce == a[3] and not p.finished then p.release() end
                    end
                end
            elseif call.op == "exec" then
                local req = vim.json.decode(a[2])
                call.req = req
                -- The request env/argv reach the program verbatim (fake).
                local nonce = req.nonce
                local plan = dev:run_program(serial, req, nonce)
                local pid = dev.next_pid
                dev.next_pid = dev.next_pid + 1
                -- The runner contract: the pid line precedes any program output
                -- for EVERY exec (utilities included).
                if dev.pid_lines ~= false then
                    emit("stdout", "__PID_" .. nonce .. "=" .. pid)
                end
                for _, l in ipairs(plan.out) do emit("stdout", l .. "\r") end
                for _, l in ipairs(plan.err) do
                    emit(dev.combined and "stdout" or "stderr", l)
                end
                if plan.hang then
                    hang = true
                    proc.nonce = nonce
                    proc.after = plan.after
                elseif not plan.no_sentinel then
                    emit("stdout", (plan.unterminated or "") .. "__EXIT_" .. nonce .. "=" .. tostring(plan.exit))
                end
                for _, l in ipairs(plan.connector_tail or {}) do emit("stdout", l) end
                proc.delay_ms = plan.delay_ms
                proc.after_fn = not plan.hang and plan.after or nil
            else
                emit("stderr", "unknown op " .. tostring(call.op))
                exit_code = 2
            end

            -- Asynchronous emission, one step per tick.
            local i = 0
            local timer = uv.new_timer()
            local finished = false
            local function done(code, sig)
                if finished then return end
                finished = true
                proc.finished = true
                pcall(function() timer:stop(); timer:close() end)
                h.on_exit(code, sig)
            end
            proc.release = function()
                -- device-side program stopped (terminate): connector ends
                done(0, 0)
            end
            dev.live[#dev.live + 1] = proc
            local interval = proc.delay_ms or 1
            timer:start(interval, interval, function()
                if finished then return end
                i = i + 1
                local s = steps[i]
                if s then
                    if s[1] == "stdout" then h.on_stdout(s[2] .. "\n") else h.on_stderr(s[2] .. "\n") end
                    return
                end
                if proc.after then local f = proc.after; proc.after = nil; f(dev) end
                if hang then return end
                if proc.after_fn then local f = proc.after_fn; proc.after_fn = nil; f(dev) end
                done(exit_code, 0)
            end)
            return {
                kill = function()
                    proc.killed = true
                    done(nil, 9)
                end,
            }
        end,
    }
end

return M

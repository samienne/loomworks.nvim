-- REAL end-to-end: an ACTUAL cmake + ninja build driven THROUGH the daemon
-- (not the injected fake runner). Stands up the daemon service in-process
-- against a real workspace (built via the real `lw` CLI so its profile pins a
-- genuinely-detected toolchain), sends a real `build` command over the pipe, and
-- asserts the toolchain configured+compiled (artifact on disk), the task stream
-- reported real build output, and the built STATE persisted through the daemon's
-- workspace (cache write-back).
--
-- Gated on a usable cmake toolchain (cmake + ninja on PATH + a detected cmake
-- tool). Anywhere else — the lean daemon-specs CI job, a toolchain-less runner —
-- it is a pending() skip, never a failure.

local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local protocol = require("loomworks.daemon.protocol")
local uv = vim.uv or vim.loop

local function have(exe) return vim.fn.executable(exe) == 1 end

local function write(path, body)
    local f = assert(io.open(path, "w")); f:write(body); f:close()
end

--- Recursively find a file by basename under dir.
local function find_file(dir, name)
    local h = uv.fs_scandir(dir); if not h then return nil end
    while true do
        local entry, etype = uv.fs_scandir_next(h)
        if not entry then break end
        local full = dir .. "/" .. entry
        if etype == "directory" then
            local f = find_file(full, name); if f then return f end
        elseif entry == name then return full end
    end
    return nil
end

--- Run the real `lw` CLI (this nvim, headless) in `cwd`; return the result.
local function lw(cli, cwd, args)
    -- Module ids resolve on the runtime path only (plugin_loader, spec §17), so
    -- an `-u NONE` host must be given the repo on its runtimepath explicitly.
    local repo = vim.fn.fnamemodify(cli, ":h:h:h")
    local argv = { vim.v.progpath, "--headless", "-u", "NONE",
        "--cmd", "set rtp^=" .. vim.fn.fnameescape(repo), "-l", cli }
    vim.list_extend(argv, args)
    return vim.system(argv, {
        cwd = cwd, text = true,
        env = { LW_ROOT = cwd, LW_NO_INPUT = "1", PATH = vim.env.PATH, LOOMWORKS_RUNTIME = "in-process" },
    }):wait()
end

--- Parse `lw tools` output for a cmake tool key, preferring in order: a
--- self-contained ninja gcc/clang (no VS env needed), then any ninja-based tool
--- (single-config, predictable — e.g. ninja-clang-cl on a VS runner), then the
--- first key. Ninja is preferred over VS multi-config generators for a stable
--- artifact layout across platforms.
local function pick_tool(out)
    local keys = {}
    for line in (out .. "\n"):gmatch("([^\n]*)\n") do
        local key = line:match("^%s+([%w][%w%.%-]*)%s")
        if key then keys[#keys + 1] = key end
    end
    for _, k in ipairs(keys) do
        if k:match("^ninja%-") and (k:match("gcc") or k:match("clang")) and not k:match("clang%-cl") then
            return k
        end
    end
    for _, k in ipairs(keys) do
        if k:match("^ninja%-") then return k end
    end
    return keys[1]
end

--- Load a REAL workspace in-process the way the daemon does (singleton core,
--- real tool detection).
local function load_real_workspace(root)
    local loomworks = require("loomworks")
    local core = loomworks._core()
    core._deps.scan_targets = false
    core:setup({ root = root })
    vim.wait(30000, function()
        return core._state == "initialized" or core._state == "uninitialized"
    end, 25)
    local ws = loomworks.get_workspace()
    if ws then vim.wait(60000, function() return ws._tool_state == "scanned" end, 25) end
    return ws, core
end

--- A raw pipe client that collects every message.
local function connect(addr)
    local c = { pipe = uv.new_pipe(false), messages = {}, connected = false,
                decoder = protocol.new_decoder() }
    c.pipe:connect(addr, function(err)
        if err then c.error = err; return end
        c.connected = true
        c.pipe:read_start(function(rerr, chunk)
            if rerr or not chunk then return end
            for _, p in ipairs(c.decoder:push(chunk)) do
                local m = protocol.decode(p); if m then c.messages[#c.messages + 1] = m end
            end
        end)
    end)
    function c.send(m) c.pipe:write(protocol.encode(m)) end
    function c.close() pcall(function() if not c.pipe:is_closing() then c.pipe:close() end end) end
    return c
end

local function task_done(messages, task_id)
    for _, m in ipairs(messages) do
        if m.kind == protocol.KIND.task and m.phase == "done"
            and (task_id == nil or m.task_id == task_id) then return m end
    end
    return nil
end

--- The text a task streamed (stdout + stderr, in order).
local function task_output(messages, task_id)
    local out = {}
    for _, m in ipairs(messages) do
        if m.kind == protocol.KIND.task and m.phase == "output" and m.text
            and m.task_id == task_id then out[#out + 1] = m.text end
    end
    return table.concat(out)
end

--- The build-dir entries of a workspace's (signed) cache.json, keyed by build
--- dir relative to the root — comparable across two roots.
local function cached_build_dirs(root)
    local f = io.open(root .. "/.nvim/loomworks.cache.json", "r")
    if not f then return {} end
    local text = f:read("*a"); f:close()
    local status, body = require("loomworks.trust").verify("cache", text)
    assert.equals("valid", status, "cache.json is not signed by this machine")
    return require("loomworks.cache").parse(body).build_dirs or {}
end

--- Create the fixture cmake project and a profile pinning a detected
--- toolchain at `root`. Returns the profile key, or nil when no toolchain.
local function make_project(cli, root)
    vim.fn.mkdir(root .. "/app", "p")
    write(root .. "/app/CMakeLists.txt",
        "cmake_minimum_required(VERSION 3.16)\nproject(app CXX)\nadd_executable(app main.cpp)\n")
    write(root .. "/app/main.cpp", "int main(){ return 0; }\n")
    assert.equals(0, lw(cli, root, { "init" }).code, "lw init failed")
    assert.equals(0, lw(cli, root, { "project", "add", "./app", "cmake" }).code, "project add failed")
    local tool = pick_tool(lw(cli, root, { "tools" }).stdout or "")
    if not tool then return nil end
    assert.equals(0, lw(cli, root, { "configset", "create", "Debug", "app=variant:Debug" }).code,
        "configset create failed")
    local pc = lw(cli, root, { "profile", "create", "Debug", tool })
    assert.equals(0, pc.code, "profile create failed:\n" .. tostring(pc.stderr))
    return "Debug:" .. tool
end

describe("daemon real cmake build (end-to-end)", function()
    local server
    after_each(function()
        if server and not server:is_stopped() then server:stop("cleanup") end
        server = nil
    end)

    it("configures + compiles a real cmake project through the daemon and persists state", function()
        if not (have("cmake") and have("ninja")) then
            pending("real daemon build needs cmake + ninja on PATH"); return
        end

        -- ---- Fixture project ----
        local root = vim.fn.tempname()
        vim.fn.mkdir(root .. "/app", "p")
        write(root .. "/app/CMakeLists.txt",
            "cmake_minimum_required(VERSION 3.16)\nproject(app CXX)\nadd_executable(app main.cpp)\n")
        write(root .. "/app/main.cpp",
            "#include <cstdio>\nint main(){ printf(\"APP-RAN\\n\"); return 0; }\n")

        local cli = vim.fn.getcwd() .. "/lua/loomworks/cli.lua"

        -- ---- Detect a usable toolchain (skip, not fail, when none) ----
        assert.equals(0, lw(cli, root, { "init" }).code, "lw init failed")
        assert.equals(0, lw(cli, root, { "project", "add", "./app", "cmake" }).code, "project add failed")
        local tools = lw(cli, root, { "tools" })
        local tool = pick_tool(tools.stdout or "")
        if not tool then
            pending("real daemon build needs a detected cmake toolchain"); return
        end

        -- ---- Create a real profile pinning that toolchain ----
        assert.equals(0, lw(cli, root, { "configset", "create", "Debug", "app=variant:Debug" }).code,
            "configset create failed")
        local pc = lw(cli, root, { "profile", "create", "Debug", tool })
        assert.equals(0, pc.code, "profile create failed:\n" .. tostring(pc.stderr))
        local prof_key = "Debug:" .. tool

        -- ---- Load that workspace the way the daemon does, stand up the server ----
        local ws, core = load_real_workspace(root)
        assert.is_not_nil(ws, "workspace failed to load")
        local profile
        for _, p in ipairs(ws._profiles or {}) do if p.key == prof_key then profile = p end end
        assert.is_not_nil(profile, "profile '" .. prof_key .. "' not resolved in the loaded workspace")

        server = server_mod.new(root)
        assert.is_not_nil(service.attach(server, { workspace = ws, core = core }))
        assert.is_true((server:start()))

        -- ---- Send a REAL build command over the pipe ----
        local client = connect(server.address)
        assert.is_true(vim.wait(2000, function() return client.connected end, 10), "client connect")
        client.send({ kind = "command", name = "build", args = { profile_key = prof_key }, req_id = 1 })

        -- A real configure+compile; give it plenty of time.
        assert.is_true(vim.wait(180000, function() return task_done(client.messages) ~= nil end, 100),
            "daemon build never completed")
        local done = task_done(client.messages)
        assert.equals(0, done.exit_code, "daemon build reported a nonzero exit")

        -- ---- The task stream carried real build output ----
        local out = {}
        for _, m in ipairs(client.messages) do
            if m.kind == protocol.KIND.task and m.phase == "output" and m.text then out[#out + 1] = m.text end
        end
        local blob = table.concat(out)
        assert.is_truthy(blob:match("%[%d+/%d+%]") or blob:lower():find("building") or blob:lower():find("linking"),
            "task stream did not carry real build output:\n" .. blob:sub(1, 800))

        -- ---- The artifact really landed on disk ----
        local exe_name = (vim.fn.has("win32") == 1) and "app.exe" or "app"
        assert.is_truthy(find_file(root .. "/.nvim/build", exe_name),
            "no " .. exe_name .. " produced under the build tree")

        -- ---- The built STATE persisted through the daemon's workspace ----
        -- (record_task_result → state=built + _save_cache). This is what the fake
        -- runner never exercised.
        local built = false
        for _, u in ipairs(ws._config_units or {}) do
            if u.state_value == "built" then built = true end
        end
        assert.is_true(built, "daemon build did not persist a 'built' unit state (cache write-back missing)")

        -- Persisted to cache.json on disk too (a fresh reader would see 'built').
        local cache_path = root .. "/.nvim/loomworks.cache.json"
        local cf = io.open(cache_path, "r")
        assert.is_not_nil(cf, "cache.json missing")
        local cache_body = cf:read("*a"); cf:close()
        assert.is_truthy(cache_body:find("\"built\""), "cache.json did not persist a built state")

        client.close()
    end)

    -- Parity (spec §19.12/§19.13): the same project built twice in-process and
    -- twice through the daemon. The daemon must keep the configure record the
    -- in-process path keeps, so its second build is a no-op compile exactly like
    -- the in-process one (no reconfigure), and both caches agree.
    it("builds twice like in-process: no reconfigure on the rebuild, matching cache", function()
        if not (have("cmake") and have("ninja")) then
            pending("real daemon build needs cmake + ninja on PATH"); return
        end
        local cli = vim.fn.getcwd() .. "/lua/loomworks/cli.lua"

        -- ---- In-process reference ----
        local root_ip = (vim.fn.tempname():gsub("\\", "/"))
        local key = make_project(cli, root_ip)
        if not key then pending("real daemon build needs a detected cmake toolchain"); return end
        local b1 = lw(cli, root_ip, { "build", key })
        assert.equals(0, b1.code, "in-process build failed:\n" .. tostring(b1.stderr))
        local b2 = lw(cli, root_ip, { "build", key })
        assert.equals(0, b2.code, "in-process rebuild failed:\n" .. tostring(b2.stderr))
        assert.is_nil((b2.stdout or ""):find("==> [configure]", 1, true),
            "in-process rebuild reconfigured:\n" .. tostring(b2.stdout))

        -- ---- Daemon ----
        local root_d = (vim.fn.tempname():gsub("\\", "/"))
        assert.equals(key, make_project(cli, root_d))
        local ws, core = load_real_workspace(root_d)
        assert.is_not_nil(ws, "workspace failed to load")
        server = server_mod.new(root_d)
        assert.is_not_nil(service.attach(server, { workspace = ws, core = core }))
        assert.is_true((server:start()))
        local client = connect(server.address)
        assert.is_true(vim.wait(2000, function() return client.connected end, 10), "client connect")
        for id = 1, 2 do
            client.send({ kind = "command", name = "build", args = { profile_key = key }, req_id = id })
            assert.is_true(vim.wait(180000, function() return task_done(client.messages, id) ~= nil end, 100),
                "daemon build " .. id .. " never completed")
            assert.equals(0, task_done(client.messages, id).exit_code,
                "daemon build " .. id .. " failed:\n" .. task_output(client.messages, id))
        end
        local first, second = task_output(client.messages, 1), task_output(client.messages, 2)
        assert.is_truthy(first:find("==> [configure]", 1, true), "first daemon build did not configure")
        assert.is_nil(second:find("==> [configure]", 1, true),
            "daemon rebuild reconfigured (configure record lost):\n" .. second)
        client.close()

        -- ---- Same persisted state both ways ----
        local a, d = cached_build_dirs(root_ip), cached_build_dirs(root_d)
        assert.is_true(next(a) ~= nil, "in-process cache has no build dirs")
        for rel, ea in pairs(a) do
            local ed = d[rel]
            assert.is_not_nil(ed, "daemon cache lacks build dir " .. rel)
            assert.equals(ea.state, ed.state, rel .. " state")
            local ka, kd = vim.tbl_keys(ea.module_info or {}), vim.tbl_keys(ed.module_info or {})
            table.sort(ka); table.sort(kd)
            assert.same(ka, kd, rel .. " module_info keys")
            assert.same((ea.module_info or {}).passed_options, (ed.module_info or {}).passed_options,
                rel .. " passed_options")
        end
    end)
end)

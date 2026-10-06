--- Workspace trust (spec §17): machine signatures on `.nvim` state, refusal of
--- unsigned / modified files, program-bearing fields only from the signed
--- working copy, executable paths only from detection, the environment
--- denylist, and passive scans only on build dirs configured here.
---
--- Every fixture is benign: "program" fields point at harmless paths, and the
--- assertions check that loomworks does NOT use / spawn them (stubs fail the
--- test when called) — never what such a program could do.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local h = require("tests.helpers")
local trust = require("loomworks.trust")
local Core = require("loomworks.core")
local uv = vim.uv or vim.loop

local function tmpdir()
    local d = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(d, "p")
    return d
end

local function write(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

describe("workspace trust (spec §17)", function()

-- Every test signs with a throwaway key (never the user's real one).
local key_dir
before_each(function()
    key_dir = tmpdir()
    trust._set_key_path(key_dir .. "/trust.key")
end)
after_each(function()
    trust._set_key_path(nil)
    vim.fn.delete(key_dir, "rf")
end)

-- Run `fn` with io.write / io.stderr / os.exit captured (CLI die paths).
local function capture(fn)
    local out_buf, err_buf = {}, {}
    local rw, rs, rex = io.write, io.stderr, os.exit
    io.write = function(s) out_buf[#out_buf + 1] = s end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
    local exit_code
    os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
    local ok, ret = pcall(fn)
    io.write, io.stderr, os.exit = rw, rs, rex
    if not ok and not (type(ret) == "table" and ret.__exit) then error(ret, 0) end
    return { exit_code = exit_code, ret = ok and ret or nil,
        stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

-- ===========================================================================
describe("machine signature (§17.2–§17.3)", function()
    it("HMAC-SHA256 matches RFC 4231 vectors (pure Lua, binary-safe)", function()
        assert.equals("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
            trust.hmac_sha256_hex(string.rep("\11", 20), "Hi There"))
        assert.equals("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
            trust.hmac_sha256_hex("Jefe", "what do ya want for nothing?"))
        assert.equals("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
            trust.hmac_sha256_hex(string.rep("\170", 131),
                "Test Using Larger Than Block-Size Key - Hash Key First"))
    end)

    it("produces the host-neutral vector the standalone host also checks", function()
        -- Same key + content → same signature in both hosts (tests/standalone
        -- asserts this exact value under luvi/OpenSSL).
        write(key_dir .. "/trust.key",
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\n")
        trust._reset()
        local content = '{\n  "_meta": {\n    "version": 2\n  },\n  "name": "fixture"\n}\n'
        local signed = assert(trust.sign("user", content))
        assert.equals("c127ba0466fe01f413302d041f7f58b60aabba5b43a5ff8ed3bfd214934415f1",
            (trust.split(signed)))
    end)

    it("round-trips, binds the file role, and detects edits and missing signatures", function()
        local content = trust.encode({ _meta = { version = 2 }, active_profile = "debug" })
        local signed = assert(trust.sign("user", content))
        assert.matches('^{\n  "_sig": "%x+",\n', signed)
        local st, body = trust.verify("user", signed)
        assert.equals("valid", st)
        assert.equals(content, body)
        assert.same({ _meta = { version = 2 }, active_profile = "debug" }, vim.json.decode(body))
        -- A signed working copy is not a valid cache.
        assert.equals("invalid", (trust.verify("cache", signed)))
        -- Edited after signing.
        assert.equals("invalid", (trust.verify("user", (signed:gsub("debug", "release")))))
        -- No signature member at all (hand-written / earlier loomworks).
        assert.equals("unsigned", (trust.verify("user", content)))
    end)

    it("a file signed with another machine's key is invalid here", function()
        local content = trust.encode({ _meta = { version = 8 }, build_dirs = vim.empty_dict() })
        local signed_here = assert(trust.sign("cache", content))
        trust._set_key_path(key_dir .. "/other/trust.key") -- "another machine"
        assert.equals("invalid", (trust.verify("cache", signed_here)))
    end)

    it("creates the key once, owner-only where the OS has modes, and never overwrites it", function()
        local path = key_dir .. "/sub/trust.key"
        trust._set_key_path(path)
        assert.is_nil(uv.fs_stat(path))
        local k1 = assert(trust.key())
        assert.equals(32, #k1)
        local st = assert(uv.fs_stat(path))
        if vim.fn.has("win32") == 0 then
            assert.equals(0, bit.band(st.mode, 63), "no group/other permission bits") -- 0077
        end
        local text = read(path)
        trust._reset()
        assert.equals(k1, trust.key())
        assert.equals(text, read(path))
    end)

    it("io.write_json_signed writes a signed file user.load accepts; a hand edit is refused", function()
        local root = tmpdir()
        assert.is_true((require("loomworks.user").save(root, { active_profile = "debug" })))
        local data = require("loomworks.user").load(root)
        assert.equals("debug", data.active_profile)
        local path = require("loomworks.user").filepath(root)
        write(path, (read(path):gsub('"debug"', '"release"')))
        local d2, st = require("loomworks.user").load(root)
        assert.is_nil(d2)
        assert.equals("invalid", st)
        vim.fn.delete(root, "rf")
    end)
end)

-- ===========================================================================
describe("refusing unsigned / modified .nvim files (§17.4)", function()
    local function core_with(files, extra)
        local deps = h.make_test_deps(files, vim.tbl_extend("force", {
            trust = trust, -- the REAL gate
        }, extra or {}))
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        return core, deps
    end

    local USER = { _meta = { version = 2 }, active_profile = "debug" }

    it("an unsigned working copy refuses the load and reads nothing from it", function()
        local core = core_with({
            ["loomworks.json"] = h.make_config_json(),
            ["loomworks.user.json"] = vim.json.encode(USER),
        })
        assert.is_nil(core:get_workspace())
        local e = assert(core:get_setup_error())
        assert.same({ kind = "user", status = "unsigned", path = "/root/.nvim/loomworks.user.json" }, e.trust)
        assert.matches("not signed by this machine", e.message, 1, true)
    end)

    it("a working copy modified after signing is refused as modified", function()
        local signed = h.signed("user", USER)
        local core = core_with({
            ["loomworks.json"] = h.make_config_json(),
            ["loomworks.user.json"] = (signed:gsub('"debug"', '"other"')),
        })
        assert.is_nil(core:get_workspace())
        assert.equals("invalid", core:get_setup_error().trust.status)
        assert.matches("modified outside loomworks", core:get_setup_error().message, 1, true)
    end)

    it("a signed working copy loads", function()
        local core = core_with({
            ["loomworks.json"] = h.make_config_json(),
            ["loomworks.user.json"] = h.signed("user", USER),
        })
        assert.is_nil(core:get_setup_error())
        assert.is_not_nil(core:get_workspace())
    end)

    it("an unsigned (pre-trust) cache is ignored unread; loading does not rewrite it", function()
        local saved = {}
        local core = core_with({
            ["loomworks.json"] = h.make_config_json(),
            ["loomworks.user.json"] = h.signed("user", USER),
            ["loomworks.cache.json"] = h.make_cache_json({ build_dirs = {
                ["build/App/Debug"] = { project_key = "App", variant = "Debug", state = "built",
                    config_key = "Debug", type = "cmake", build_dir = "/root/.nvim/build/App/Debug" },
            } }),
        }, { cache = { save = function(_, data) saved[#saved + 1] = data; return true end } })
        local ws = assert(core:get_workspace())
        for _, u in pairs(ws._config_units) do
            assert.is_nil(u.state_value, "no build state comes from an unsigned cache")
        end
        assert.equals(0, #saved, "loading never writes the cache (read-only commands must not)")
        -- The first real cache write replaces it (no stale-save refusal).
        assert.is_true((ws:_save_cache()))
        assert.equals(1, #saved)
    end)

    it("a cache signed elsewhere refuses the load and is not overwritten", function()
        local cache_text = h.signed("cache", vim.json.decode(h.make_cache_json()))
        trust._set_key_path(key_dir .. "/this-machine/trust.key")
        local saved = 0
        local core = core_with({
            ["loomworks.json"] = h.make_config_json(),
            ["loomworks.user.json"] = h.signed("user", USER),
            ["loomworks.cache.json"] = cache_text,
        }, { cache = { save = function() saved = saved + 1; return true end } })
        assert.is_nil(core:get_workspace())
        local e = core:get_setup_error()
        assert.equals("cache", e.trust.kind)
        assert.matches("not written on this machine", e.message, 1, true)
        assert.equals(0, saved)
    end)

    it("an unsigned health cache is ignored", function()
        local root = tmpdir()
        local hc = require("loomworks.health_cache")
        write(hc.path(root), vim.json.encode({ _meta = { version = hc.SCHEMA_VERSION },
            local_tier = { items = { { kind = "x", title = "planted" } }, computed_at = 1 } }))
        assert.is_nil(hc.read(require("loomworks.io"), root).local_tier)
        -- Written by loomworks → signed → read back.
        hc.write(require("loomworks.io"), root, { local_tier = { items = {}, computed_at = 2 } })
        assert.is_not_nil(hc.read(require("loomworks.io"), root).local_tier)
        vim.fn.delete(root, "rf")
    end)

    it("an SDK path in an unsigned working copy is never probed", function()
        local called = false
        local real = package.loaded["loomworks.sdks"]
        package.loaded["loomworks.sdks"] = {
            get = function() return {
                validate = function() called = true; error("must not probe an untrusted SDK path") end,
                detect_all = function() return {} end,
            } end,
            list = function() return {} end,
        }
        local ok, err = pcall(core_with, {
            ["loomworks.json"] = h.make_config_json(),
            ["loomworks.user.json"] = vim.json.encode({ _meta = { version = 2 },
                sdks = { planted = { type = "cpp_compiler", path = "C:/benign/sdk" } } }),
        })
        package.loaded["loomworks.sdks"] = real
        assert.is_true(ok, tostring(err))
        assert.is_false(called)
    end)
end)

-- ===========================================================================
describe("a refused working copy that becomes valid loads again (§17.4)", function()
    local USER = { _meta = { version = 2 }, active_profile = "debug" }

    -- Test deps whose FileTracker records each tracker (its watched paths,
    -- whether it was stopped) and lets a test deliver a change by hand.
    local function setup_core(files)
        local trackers = {}
        local deps = h.make_test_deps(files, {
            trust = trust,
            FileTracker = { new = function(o)
                local t = { opts = o, paths = {}, stopped = false, paused = false }
                function t:watch(p) self.paths[#self.paths + 1] = p end
                function t:unwatch() end
                function t:stop() self.stopped = true end
                function t:content(p) return files[p] end
                function t:mark_written() end
                function t:pause() self.paused = true end
                function t:resume() self.paused = false end
                trackers[#trackers + 1] = t
                return t
            end },
        })
        local core = Core.new(deps)
        return core, trackers
    end
    -- The live tracker watching `path` (not stopped), if any.
    local function watcher_of(trackers, path)
        for _, t in ipairs(trackers) do
            if not t.stopped then
                for _, p in ipairs(t.paths) do if p == path then return t end end
            end
        end
    end
    local UPATH = "/root/.nvim/loomworks.user.json"

    local function refused(files)
        local signed = h.signed("user", USER)
        files["loomworks.json"] = h.make_config_json()
        files["loomworks.user.json"] = (signed:gsub('"debug"', '"other"'))
        local core, trackers = setup_core(files)
        core:setup({ root = "/root" })
        assert.is_nil(core:get_workspace())
        assert.equals("invalid", core:get_setup_error().trust.status)
        return core, trackers, signed
    end

    it(":LoomworksTrust on a working copy restored valid loads the refused workspace", function()
        local files = {}
        local core, _, signed = refused(files)
        files["loomworks.json"] = h.make_config_json()
        files["loomworks.user.json"] = signed -- restored byte-identical
        local lw = require("loomworks")
        local gc = lw._core()
        local saved = { gc._deps, gc._workspace, gc._setup_error, gc._state, gc._pending_root }
        gc._deps, gc._workspace, gc._setup_error, gc._state =
            core._deps, nil, core:get_setup_error(), "uninitialized"
        local ok, res = pcall(lw.trust_user_prefs, "/root", {
            confirm = function() error("no prompt for a valid file") end })
        local ws, serr = gc._workspace, gc._setup_error
        gc:shutdown()
        gc._deps, gc._workspace, gc._setup_error, gc._state, gc._pending_root =
            saved[1], saved[2], saved[3], saved[4], saved[5]
        assert.is_true(ok, tostring(res))
        assert.equals("valid", res)
        assert.is_nil(serr)
        assert.is_not_nil(ws)
    end)

    it("a refused working copy restored on disk loads without user action", function()
        local files = {}
        local core, trackers, signed = refused(files)
        local w = assert(watcher_of(trackers, UPATH), "the refused file is watched")
        -- Still invalid: another edit does not reload (no repeated refusal).
        w.opts.callback(UPATH, (signed:gsub('"debug"', '"third"')))
        assert.is_nil(core:get_workspace())
        assert.equals(w, watcher_of(trackers, UPATH))
        -- Restored with its original signature: the workspace loads.
        files["loomworks.user.json"] = signed
        w.opts.callback(UPATH, signed)
        assert.is_nil(core:get_setup_error())
        assert.is_not_nil(core:get_workspace())
        assert.is_true(w.stopped, "the refusal watch stops once the workspace loads")
        core:shutdown()
    end)

    it("the refusal watch stops on shutdown and on a new setup", function()
        local files = {}
        local core, trackers = refused(files)
        local w = assert(watcher_of(trackers, UPATH))
        core:shutdown()
        assert.is_true(w.stopped)

        core:setup({ root = "/root" }) -- refused again: a new watch
        local w2 = assert(watcher_of(trackers, UPATH))
        assert.are_not.equal(w, w2)
        core:setup({ root = "/other" }) -- another workspace (cwd change)
        assert.is_true(w2.stopped)
        core:shutdown()
    end)

    it("the CLI keeps no watch on a refused file", function()
        local files = {}
        local signed = h.signed("user", USER)
        files["loomworks.json"] = h.make_config_json()
        files["loomworks.user.json"] = (signed:gsub('"debug"', '"other"'))
        local core, trackers = setup_core(files)
        core._deps.quiet_trust_errors = true
        core:setup({ root = "/root" })
        assert.is_nil(core:get_workspace())
        assert.is_nil(watcher_of(trackers, UPATH))
    end)
end)

-- ===========================================================================
describe("trust / discard / nuke from the CLI (§17.10)", function()
    local cli = require("loomworks.cli")
    local root

    local function load_ws()
        return capture(function() return cli._load_workspace(root, false) end)
    end

    before_each(function()
        root = tmpdir()
        write(root .. "/loomworks.json", vim.json.encode({ projects = { App = { cmake = vim.empty_dict() } } }))
        -- A hand-written (unsigned) working copy carrying a benign program field.
        write(root .. "/.nvim/loomworks.user.json", vim.json.encode({
            _meta = { version = 2 },
            projects = { App = { cmake = { clangd = "C:/benign/clangd.exe" } } },
        }))
        require("loomworks")._core()._workspace = nil
    end)
    after_each(function() vim.fn.delete(root, "rf") end)

    it("a command on the untrusted workspace exits with the trust instructions", function()
        local r = load_ws()
        assert.equals(1, r.exit_code)
        assert.matches("not signed by this machine", r.stderr, 1, true)
        assert.matches("lw trust", r.stderr, 1, true)
        assert.matches("lw trust --discard", r.stderr, 1, true)
    end)

    it("lw health on the untrusted workspace reports the refusal as an item and exits 0 (§16.36)", function()
        local orig = cli._probe_inventory
        cli._probe_inventory = function() return { results = {}, declared = {}, key = "k", computed_at = 1 } end
        local r = capture(function() return cli.cmd_health(root, {}) end)
        cli._probe_inventory = orig
        assert.is_nil(r.exit_code, r.stderr)
        assert.equals(0, r.ret)
        assert.matches("* working copy not trusted", r.stdout, 1, true)
        assert.matches("[workspace]", r.stdout, 1, true)
        assert.matches("lw trust", r.stdout, 1, true)
        -- Nothing of the refused file was read, and nothing was cached.
        assert.is_nil(uv.fs_stat(root .. "/.nvim/loomworks.health.json"))
        local j = capture(function() return cli.cmd_health(root, { json = true }) end)
        local doc = vim.json.decode(j.stdout)
        assert.equals(root, doc.workspace.root)
        assert.equals("refused", doc.workspace.trust)
        assert.equals("workspace", doc.suggestions[1].area)
    end)

    it("lw trust shows the program settings and refuses without --yes when non-interactive", function()
        local r = capture(function() return cli.cmd_trust(root, { "trust" }) end)
        assert.equals(1, r.exit_code)
        assert.matches("projects.App.cmake.clangd = C:/benign/clangd.exe", r.stdout, 1, true)
        assert.matches("re-run with --yes", r.stderr, 1, true)
        assert.equals("unsigned", (trust.verify("user", read(root .. "/.nvim/loomworks.user.json"))))
    end)

    it("lw trust --yes re-signs; the workspace then loads; a later hand edit is refused again", function()
        local r = capture(function() return cli.cmd_trust(root, { "trust", "--yes" }) end)
        assert.equals(0, r.ret)
        assert.matches("TRUSTED", r.stdout, 1, true)
        local path = root .. "/.nvim/loomworks.user.json"
        assert.equals("valid", (trust.verify("user", read(path))))
        local l = load_ws()
        assert.is_nil(l.exit_code, l.stderr)
        -- Hand edit → modified outside loomworks.
        write(path, (read(path):gsub("benign", "benign2")))
        require("loomworks")._core()._workspace = nil
        local l2 = load_ws()
        assert.equals(1, l2.exit_code)
        assert.matches("modified outside loomworks", l2.stderr, 1, true)
    end)

    it("lw trust --discard --yes deletes the working copy", function()
        local r = capture(function() return cli.cmd_trust(root, { "trust", "--discard", "--yes" }) end)
        assert.equals(0, r.ret)
        assert.is_nil(uv.fs_stat(root .. "/.nvim/loomworks.user.json"))
    end)

    it("lw nuke -y removes build state only", function()
        write(root .. "/.nvim/loomworks.cache.json", "{}")
        write(root .. "/.nvim/loomworks.health.json", "{}")
        write(root .. "/.nvim/build/App/marker.txt", "x")
        local r = capture(function() return cli.cmd_nuke(root, { "nuke", "-y" }) end)
        assert.equals(0, r.ret, r.stderr)
        assert.is_nil(uv.fs_stat(root .. "/.nvim/loomworks.cache.json"))
        assert.is_nil(uv.fs_stat(root .. "/.nvim/loomworks.health.json"))
        assert.is_nil(uv.fs_stat(root .. "/.nvim/build"))
        assert.is_not_nil(uv.fs_stat(root .. "/.nvim/loomworks.user.json"))
        assert.is_not_nil(uv.fs_stat(root .. "/loomworks.json"))
    end)

    it("lw nuke refuses without -y when non-interactive", function()
        write(root .. "/.nvim/loomworks.cache.json", "{}")
        local r = capture(function() return cli.cmd_nuke(root, { "nuke" }) end)
        assert.equals(1, r.exit_code)
        assert.is_not_nil(uv.fs_stat(root .. "/.nvim/loomworks.cache.json"))
    end)

    it("lw pull refuses an unsigned source working copy", function()
        local src = tmpdir()
        write(src .. "/.nvim/loomworks.user.json", vim.json.encode({ _meta = { version = 2 } }))
        local plan, err = cli._plan_pull({ source = src, cwd = root, git = function() return nil end })
        assert.is_nil(plan)
        assert.matches("not signed by this machine", err, 1, true)
        vim.fn.delete(src, "rf")
    end)
end)

-- ===========================================================================
describe("program-bearing fields only from the signed working copy (§17.6)", function()
    local pf = require("loomworks.program_fields")
    local real_modules = require("loomworks.modules")

    local SHARED = {
        projects = {
            App = {
                cmake = {
                    clangd = "C:/benign/clangd.exe",
                    configurations = { Debug = { variant = "Debug", env = { MARKER = "1" } } },
                },
                launch = {
                    serve = { command = "C:/benign/tool.exe", args = { "--x" } },
                    plain = { target = "app" },
                },
                deploy = {
                    ["out/lib.dll"] = { project = "App", path = "a.dll" },
                    ["C:/outside/lib.dll"] = { project = "App", path = "a.dll" },
                },
            },
        },
        configuration_sets = { debug = { App = "Debug" } },
    }

    it("strip removes them from a parsed loomworks.json and keeps the rest", function()
        local cfg = require("loomworks.config").parse(vim.json.encode(SHARED), "/root")
        local ignored = pf.strip(cfg, real_modules)
        local labels = {}
        for _, e in ipairs(ignored) do labels[#labels + 1] = e.label end
        table.sort(labels)
        assert.same({
            "projects.App.cmake.clangd",
            "projects.App.cmake.configurations.Debug.env",
            "projects.App.deploy",
            "projects.App.launch.serve",
        }, labels)
        local app = cfg.projects.App
        assert.is_nil(app.type_config.clangd)
        assert.is_nil(app.type_config.configurations.Debug.env)
        assert.is_nil(app.launch.serve)
        assert.same({ target = "app" }, app.launch.plain)
        assert.is_not_nil(app.deploy["out/lib.dll"])
        assert.is_nil(app.deploy["C:/outside/lib.dll"])
    end)

    it("statically-local deploy destinations are kept, anything else is not", function()
        assert.is_true(pf.dest_is_local("out/lib.dll"))
        assert.is_true(pf.dest_is_local("${workspace_root}/out/"))
        assert.is_false(pf.dest_is_local("/abs/x"))
        assert.is_false(pf.dest_is_local("C:/x"))
        assert.is_false(pf.dest_is_local("${HOME}/x"))
        assert.is_false(pf.dest_is_local("out/${target_dir}/x"))
        assert.is_false(pf.dest_is_local("../x"))
    end)

    local function load(user_extra)
        local user = vim.tbl_deep_extend("force", {
            _meta = { version = 2 },
            profiles = { debug = { configuration_set = "debug" } },
            active_profile = "debug",
        }, user_extra or {})
        local written = {}
        local deps = h.make_test_deps({
            ["loomworks.json"] = vim.json.encode(SHARED),
            ["loomworks.user.json"] = vim.json.encode(user),
        }, {
            modules = real_modules,
            io = { write_json = function(p, d) written[p] = vim.deepcopy(d); return true end },
        })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        return assert(core:get_workspace(), vim.inspect(core:get_setup_error())), written
    end

    it("an ignored shared value shows a diagnostic and never reaches the clangd entry", function()
        local ws = load()
        local msgs = {}
        for _, d in ipairs(ws:diagnostics()) do msgs[#msgs + 1] = d.message end
        local all = table.concat(msgs, "\n")
        assert.matches("loomworks.json sets projects.App.cmake.clangd", all, 1, true)
        assert.matches("lw help trust", all, 1, true)
        local project = h.find_project_in(ws._projects, "App")
        assert.is_nil(project.type_config.clangd)
        for _, e in ipairs(require("loomworks.modules.cmake").lsp_configs(project) or {}) do
            assert.are_not.equal("C:/benign/clangd.exe", e.binary)
        end
    end)

    it("the same value from the signed working copy is honored (no diagnostic)", function()
        local ws = load({ projects = { App = { cmake = { clangd = "C:/benign/clangd.exe" } } } })
        local project = h.find_project_in(ws._projects, "App")
        assert.equals("C:/benign/clangd.exe", project.type_config.clangd)
        for _, d in ipairs(ws:diagnostics()) do
            assert.is_nil(d.message:find("cmake.clangd", 1, true))
        end
    end)

    it("materializing a shared item into the working copy never copies an ignored value", function()
        local ws = load()
        local project = h.find_project_in(ws._projects, "App")
        project:_mark_user_owned()
        local user = ws:_serialize_user()
        local text = vim.json.encode(user)
        assert.is_nil(text:find("benign", 1, true), text)
        assert.is_nil(text:find("MARKER", 1, true), text)
    end)

    it("publishing writes the ignored values back to loomworks.json", function()
        local ws, written = load()
        local project = h.find_project_in(ws._projects, "App")
        project._intent = "local+shared"
        assert.is_true(ws:publish())
        local raw = written["/root/loomworks.json"]
        assert.is_not_nil(raw)
        assert.equals("C:/benign/clangd.exe", raw.projects.App.cmake.clangd)
        assert.equals("C:/benign/tool.exe", raw.projects.App.launch.serve.command)
        assert.same({ MARKER = "1" }, raw.projects.App.cmake.configurations.Debug.env)
        assert.is_not_nil(raw.projects.App.deploy["C:/outside/lib.dll"])
    end)
end)

-- ===========================================================================
describe("executable paths come from detection (§17.7)", function()
    local real_modules = require("loomworks.modules")
    local DETECTED = { compiler_id = "gcc-13", generator = "Ninja", cmake_path = "C:/detected/cmake.exe" }
    local CACHED = { compiler_id = "gcc-13", generator = "Ninja", cmake_path = "C:/benign/cached/cmake.exe" }

    local function load(detect)
        local deps = h.make_test_deps({
            ["loomworks.json"] = h.make_config_json({
                projects = { App = { cmake = vim.empty_dict() } },
                configuration_sets = { debug = { App = "Debug" } },
            }),
            ["loomworks.user.json"] = h.make_user_json({
                active_profile = "debug:ninja-gcc-13",
                profiles = { debug = { configuration_set = "debug",
                    tools = { cmake = { key = "ninja-gcc-13" } } } },
            }),
            ["loomworks.cache.json"] = h.make_cache_json({ build_dirs = {
                ["build/App/ninja-gcc-13/Debug"] = {
                    project_key = "App", config_key = "Debug:ninja-gcc-13", type = "cmake",
                    variant = "Debug", state = "built", tool_key = "ninja-gcc-13", tool_data = CACHED,
                    build_dir = "/root/.nvim/build/App/ninja-gcc-13/Debug",
                },
            } }),
        }, {
            modules = real_modules,
            detect_tools_async = function(_, _, cb)
                cb(detect and { cmake = { { tool_key = "ninja-gcc-13", tool_data = DETECTED,
                    tool_label = "gcc" } } } or { cmake = {} }) -- scanned, nothing found
            end,
        })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        return assert(core:get_workspace())
    end

    it("detection wins over cached tool data for the same key", function()
        local ws = load(true)
        local tool = ws:find_module("cmake"):find_tool("ninja-gcc-13")
        assert.is_true(tool._detected)
        assert.equals("C:/detected/cmake.exe", tool.data.cmake_path)
    end)

    it("a host that detected nothing for the module does not call the tool 'not detected'", function()
        -- `lw status` with no machine tool cache serves no tool list at all.
        local ws = load(false)
        ws._tools_by_type = {}
        local ok, reasons = ws._profiles[1]:is_valid()
        assert.is_nil(table.concat(reasons or {}, "\n"):find("not detected", 1, true))
        -- ...yet running is still refused.
        local unit = ws._profiles[1]:projects()[1]._config_unit
        assert.is_nil(require("loomworks.overseer")._exec_tool_data(unit))
        local _ = ok
    end)

    it("a key only the cache knows is not available: nothing runs with its data", function()
        local ws = load(false)
        local tool = ws:find_module("cmake"):find_tool("ninja-gcc-13")
        assert.is_false(tool._detected)
        assert.is_nil(tool:exec_data())
        local profile = ws._profiles[1]
        local ok, reasons = profile:is_valid()
        assert.is_false(ok)
        assert.matches("not detected on this machine", table.concat(reasons, "\n"), 1, true)
        local unit = profile:projects()[1]._config_unit
        local ov = require("loomworks.overseer")
        assert.is_nil(ov._exec_tool_data(unit))
        local notify = vim.notify
        vim.notify = function() end
        local spec = ov.build_spec_for(unit)
        vim.notify = notify
        assert.is_nil(spec, "no build spec from cached tool data")
    end)
end)

-- ===========================================================================
describe("environment denylist (§17.9)", function()
    local policy = require("loomworks.env_policy")

    it("matches loader / interpreter hijack variables case-insensitively", function()
        for _, n in ipairs({ "LD_PRELOAD", "ld_preload", "LD_LIBRARY_PATH", "LD_AUDIT",
                "DYLD_INSERT_LIBRARIES", "NODE_OPTIONS", "npm_config_script_shell",
                "PYTHONPATH", "PythonHome", "PYTHONSTARTUP", "BASH_ENV", "ENV", "ComSpec",
                "PATHEXT", "GIT_SSH_COMMAND", "GIT_CONFIG_COUNT", "CMAKE_TOOLCHAIN_FILE",
                "CCACHE_PREFIX" }) do
            assert.is_true(policy.is_denied(n), n)
        end
        for _, n in ipairs({ "PATH", "Path", "SCCACHE_DIR", "CFLAGS", "ENVIRONMENT", "MY_ENV" }) do
            assert.is_false(policy.is_denied(n), n)
        end
    end)

    it("drops denied names from every composed layer", function()
        local ce = require("loomworks.config_env")
        local out = ce.compose({ TOOL = "t", LD_PRELOAD = "x.so" },
            { SCCACHE_DIR = "d", NODE_OPTIONS = "--require=x" }, false)
        assert.same({ TOOL = "t", SCCACHE_DIR = "d" }, out)
    end)

    it("a configuration env drops them at resolution, with a diagnostic", function()
        local Configuration = require("loomworks.configuration")
        local cfg = setmetatable({ name = "Debug", env = { PYTHONPATH = "C:/benign", KEEP = "1" },
            _inherits = {} }, Configuration)
        local env = require("loomworks.config_env").resolve(nil, cfg, nil, nil, "/root")
        assert.same({ KEEP = "1" }, env)
    end)

    it("a compiler-cache policy never names a program: an unknown value resolves nothing", function()
        local cc = require("loomworks.compiler_cache")
        local looked_up = {}
        local lookup = function(name) looked_up[#looked_up + 1] = name; return "C:/found/" .. name end
        assert.is_nil(cc.resolve("C:/benign/launcher.exe", "gcc", lookup))
        assert.is_nil(cc.resolve("benign-launcher", "gcc", lookup))
        assert.same({}, looked_up)
        assert.same({ tool = "ccache", path = "C:/found/ccache" }, cc.resolve("ccache", "gcc", lookup))
    end)

    it("edit paths refuse to set one", function()
        local ws = h.make_mock_workspace()
        local Project = require("loomworks.project")
        local ok, err = Project.save_launch_config(setmetatable({ key = "App", _workspace = ws }, Project),
            "run", { command = "app", env = { NODE_OPTIONS = "x" } })
        assert.is_false(ok)
        assert.matches("NODE_OPTIONS cannot be set", err, 1, true)
    end)
end)

-- ===========================================================================
describe("passive scans only on build dirs configured here (§17.8)", function()
    local ConfigUnit = require("loomworks.config_unit")

    it("test discovery never builds a test unit for a build dir this machine did not configure", function()
        local created = 0
        local unit = setmetatable({
            _project = { _module = { impl = { create_test_unit = function()
                created = created + 1
                return { discover = function() error("must not run discovery") end }
            end } } },
            state_value = nil,
        }, ConfigUnit)
        assert.same({}, unit:test_units())
        assert.is_nil(unit:discover_tests())
        assert.equals(0, created)
        unit.state_value = "built"
        assert.equals(1, #unit:test_units())
    end)

    it("the background target scan skips unconfigured build dirs", function()
        local scanned = {}
        local mod = { parse_targets_async = function(ctx) scanned[#scanned + 1] = ctx.build_dir end }
        local ws = setmetatable({
            root = "/root", _config_units = {}, _active_profile = nil,
            _core = { _deps = { scan_targets = true, events = { emit = function() end } } },
        }, { __index = require("loomworks.workspace").Workspace })
        local proj = { key = "App", path = "App", _module = { impl = mod } }
        ws._config_units = {
            setmetatable({ _project = proj, build_dir_value = "/root/.nvim/build/a" }, ConfigUnit),
        }
        pcall(ws._scan_targets_async, ws)
        assert.same({}, scanned)
    end)
end)

-- ===========================================================================
describe("version-control queries disable repository hooks (§17.8)", function()
    it("every git call carries core.fsmonitor/core.hooksPath overrides", function()
        local cmd = require("loomworks.cli")._git_base_cmd()
        assert.same({ "git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=" }, cmd)
    end)
end)

-- ===========================================================================
-- What the status page and a build say about trust (§17.3, §17.6, §17.10).
-- Field report: a working copy copied from another workspace on this machine
-- loaded and built, and the status title read "loomworks — untrusted" — the
-- workspace's NAME (its directory), not a trust state. These pin that a
-- same-machine copy is trusted by design (the root is not bound) and that the
-- page and a build say plainly what is trusted and what is ignored.
describe("trust on the status page and in a build (§17.10)", function()
    local cli = require("loomworks.cli")
    local roots = {}
    local function root_dir()
        local r = tmpdir(); roots[#roots + 1] = r; return r
    end
    before_each(function() require("loomworks")._core()._workspace = nil end)
    after_each(function()
        require("loomworks")._core()._workspace = nil
        for _, r in ipairs(roots) do vim.fn.delete(r, "rf") end
        roots = {}
    end)

    local SHARED = {
        projects = { App = {
            path = ".",
            shell = {
                build_dir = "${workspace_root}/out",
                configure_cmd = { "configure-it" }, build_cmd = { "build-it" },
                env = { MARKER = "from-shared" },
                configurations = { Debug = { env = { MARKER2 = "from-shared" } } },
            },
            launch = { serve = { command = "C:/benign/tool.exe" } },
        } },
        configuration_sets = { dev = { App = "Debug" } },
    }
    local function signed_user(extra)
        local user = { _meta = { version = 2 }, profiles = { dev = { configuration_set = "dev" } } }
        for k, v in pairs(extra or {}) do user[k] = v end
        return assert(trust.sign("user", trust.encode(user)))
    end
    local function profile_of(ws, key)
        for _, p in ipairs(ws._profiles or {}) do if p.key == key then return p end end
    end
    local function status(root)
        return capture(function() return cli.cmd_status(root, { can_pull = false }) end)
    end

    it("a working copy signed here stays valid when copied to another workspace (root not bound, §17.3)", function()
        local a, b = root_dir(), root_dir()
        local text = signed_user({ projects = { App = { shell = vim.empty_dict(), launch = {
            serve = { command = "C:/benign/tool.exe" } } } } })
        write(a .. "/loomworks.json", vim.json.encode(SHARED))
        write(b .. "/loomworks.json", vim.json.encode(SHARED))
        write(a .. "/.nvim/loomworks.user.json", text)
        write(b .. "/.nvim/loomworks.user.json", text)
        assert.equals("valid", (trust.verify("user", read(b .. "/.nvim/loomworks.user.json"))))
        local l = capture(function() return cli._load_workspace(b, false) end)
        assert.is_nil(l.exit_code, l.stderr)
        -- Its program settings are used: no "ignored" diagnostic for the launch
        -- the working copy supplies.
        for _, d in ipairs(l.ret:diagnostics()) do
            assert.is_nil(d.message:find("launch.serve", 1, true), d.message)
        end
    end)

    it("the Trust row: a signed working copy is used; no working copy says so", function()
        local a = root_dir()
        write(a .. "/loomworks.json", vim.json.encode(SHARED))
        write(a .. "/.nvim/loomworks.user.json", signed_user())
        local r = status(a)
        assert.is_nil(r.exit_code, r.stderr)
        assert.matches("Trust%s+local config signed on this machine", r.stdout)

        require("loomworks")._core()._workspace = nil
        local b = root_dir()
        write(b .. "/loomworks.json", vim.json.encode(SHARED))
        local r2 = status(b)
        assert.is_nil(r2.exit_code, r2.stderr)
        assert.matches("Trust%s+no local config", r2.stdout)
    end)

    it("the Trust row counts the program settings ignored in loomworks.json", function()
        local a = root_dir()
        write(a .. "/loomworks.json", vim.json.encode(SHARED))
        local r = status(a)
        assert.is_nil(r.exit_code, r.stderr)
        -- shell.env, configurations.Debug.env, launch.serve
        assert.matches("3 program settings in loomworks.json ignored", r.stdout, 1, true)
        assert.matches("lw help trust", r.stdout, 1, true)
    end)

    it("a build notice names the ignored program settings of the profile's projects", function()
        local a = root_dir()
        write(a .. "/loomworks.json", vim.json.encode(SHARED))
        write(a .. "/.nvim/loomworks.user.json", signed_user())
        local l = capture(function() return cli._load_workspace(a, false) end)
        assert.is_nil(l.exit_code, l.stderr)
        local ws = l.ret
        local profile = assert(profile_of(ws, "dev"))
        local line = require("loomworks.build_run").trust_notice(ws, profile)
        assert.equals("lw: 3 program settings in loomworks.json ignored — only your local config "
            .. "may name programs or environment (`lw status` lists them; lw help trust)", line)
        -- The working copy supplying one: it is used, and no longer counted.
        require("loomworks")._core()._workspace = nil
        write(a .. "/.nvim/loomworks.user.json", signed_user({ projects = { App = { shell = vim.empty_dict(), launch = {
            serve = { command = "C:/benign/tool.exe" } } } } }))
        local l2 = capture(function() return cli._load_workspace(a, false) end)
        assert.is_nil(l2.exit_code, l2.stderr)
        line = require("loomworks.build_run").trust_notice(l2.ret, assert(profile_of(l2.ret, "dev")))
        assert.matches("^lw: 2 program settings", line)
    end)
end)

end)

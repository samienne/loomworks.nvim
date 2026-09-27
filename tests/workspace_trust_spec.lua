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

    it("an unsigned (pre-trust) cache is discarded unread and replaced by a signed one", function()
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
        assert.is_true(#saved >= 1, "the migration rewrites the cache")
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


end)

-- loomworks.LspConfig/1 in the workspace daemon (spec §19.20 `LspConfig/1`,
-- §19.16 "LSP configuration", step 5l part B), beyond the golden transcripts
-- (spec/protocol/transcripts/loomworks/LspConfig.1.json), which cannot
-- activate a profile, write an owned database or refuse a load: the shell
-- fixture with the profile `dev` active, a stubbed owned database (the test
-- plays a module with `refresh_lsp_database`, §8.4), and the refused and
-- error states.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
_G.LW_CONFORMANCE_LIB = true
local engine = require("loomworks.proto.conformance")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")

local runner = dofile(H.REPO .. "/scripts/conformance.lua")

require("loomworks.daemon.client").TIMEOUT_MS = 30000

local LSP = { object = "/lsp", iface = "loomworks.LspConfig", v = 1 }

local function call(req_id, object, iface, method, args, no_env)
    return { send = { kind = "call", req_id = req_id, object = object, iface = iface, v = 1, method = method,
        args = args or vim.empty_dict(), env = (not no_env) and { ["$var"] = "env" } or nil } }
end
local function lsp(req_id, method, args) return call(req_id, LSP.object, LSP.iface, method, args) end
local function ok(req_id, result) return { expect = { kind = "ok", req_id = req_id, result = result } } end
local function changed()
    return { expect = { kind = "signal", object = LSP.object, iface = LSP.iface, v = 1, name = "changed",
        sub_id = { ["$var"] = "sub" }, args = { seq = { ["$type"] = "integer" } } }, timeout_ms = 60000 }
end
local SUBSCRIBE = {
    call(1, "/", "loomworks.Root", "subscribe", { object = LSP.object, iface = LSP.iface, v = 1,
        signals = { "changed" } }, true),
    ok(1, { sub_id = { ["$bind"] = "sub" } }),
}
local function steps(...)
    local out = {}
    for _, list in ipairs({ ... }) do
        for _, s in ipairs(list) do out[#out + 1] = s end
    end
    return out
end
local function op(req_id, method)
    local task = "task" .. req_id
    return {
        call(req_id, "/build", "loomworks.Build", method, { profile = { key = "dev" } }),
        ok(req_id, { outcome = "accepted", task_id = { ["$bind"] = task } }),
        { expect = { kind = "task", task_id = { ["$var"] = task }, phase = "done", exit_code = 0 }, timeout_ms = 120000 },
    }
end

--- The shell fixture with `dev` active in its working copy, signed with `key`.
local function fixture(key)
    local root = runner.fixture("shell", key)
    trust._set_key_path(key)
    local cfg = vim.json.decode(table.concat(vim.fn.readfile(root .. "/loomworks.json"), string.char(10)))
    -- (The fixture's compile database is honored only from the working copy.)
    cfg.projects.app.shell.compile_commands = "${build_dir}/compile_commands.json"
    local user = { _meta = { version = 2 }, active_profile = "dev",
        profiles = { dev = { configuration_set = "dev" } }, projects = { app = cfg.projects.app } }
    local signed = assert(trust.sign("user", trust.encode(user)))
    local f = assert(io.open(root .. "/.nvim/loomworks.user.json", "wb"))
    f:write(signed)
    f:close()
    return root
end

--- Run `case` against a loopback daemon on `root`, its working copy verified
--- with `key`.
local function run(case, root, key)
    trust._set_key_path(key)
    local d = runner.loopback_driver(root)
    local vars = { lw_version = require("loomworks.daemon.version").identity(), root = root,
        env = runner.wire_env((vim.uv or vim.loop).os_environ()) }
    local okc, a, b = pcall(engine.run_case, case, d, { vars = vars })
    pcall(d.close)
    trust._set_key_path(nil)
    assert(okc, a)
    return a, b
end

describe("LspConfig/1 in the daemon (§19.20)", function()
    local shell = require("loomworks.modules.shell")
    local writes
    before_each(function() writes = 0 end)
    after_each(function()
        shell.refresh_lsp_database = nil
        trust._set_key_path(nil)
    end)

    it("an active configured unit's entry is ready with its db_dir; each owned database written raises db_rev and sends changed", function()
        -- A module that owns its database (§8.4): every refresh (re)writes it.
        shell.refresh_lsp_database = function(ctx, done)
            writes = writes + 1
            vim.fn.mkdir(ctx.build_dir, "p")
            local f = assert(io.open(ctx.build_dir .. "/compile_commands.json", "w"))
            f:write("[]")
            f:close()
            vim.schedule(function() done(true) end)
        end
        local key = H.tmp() .. "/trust.key"
        local root = fixture(key)
        local entry = function(rev)
            return { server = "clangd", db_state = "ready", db_rev = rev,
                db_dir = { ["$pattern"] = "Debug$" }, compile_commands_dir = { ["$pattern"] = "Debug$" } }
        end
        local a, b = run({
            name = "ready entry, db_rev and changed", allow = { { kind = "task" }, { kind = "model_change" },
                { kind = "signal", object = "/lsp", name = "changed" } },
            steps = steps(SUBSCRIBE, {
                lsp(2, "get"),
                ok(2, { state = "unloaded", ready = false, projects = {} }),
            }, op(3, "configure"), {
                changed(),
                lsp(4, "get"),
                ok(4, { state = "loaded", ready = true,
                    projects = { { project = "app", path = "app", entries = { entry(1) } } } }),
            }, op(5, "build"), {
                -- The build changed nothing the state shows but the written
                -- database: changed for the raised db_rev alone.
                changed(),
                lsp(6, "get"),
                ok(6, { state = "loaded", projects = { { project = "app", entries = { entry(2) } } } }),
            }),
        }, root, key)
        assert.is_true(a, b)
        assert.equals(2, writes, "the daemon generated the owned database after the configure and the build")
    end)

    it("a refused load: get reports state refused with nothing else; set_option is refused and writes nothing", function()
        local root = fixture(H.tmp() .. "/trust.key")
        local user_path = root .. "/.nvim/loomworks.user.json"
        local before = table.concat(vim.fn.readfile(user_path, "b"), "\n")
        -- Another machine's key: the working copy is not trusted here (§17.4).
        local a, b = run({
            name = "refused",
            steps = {
                lsp(1, "set_option", { server = "clangd", key = "clang_tidy", value = false }),
                ok(1, { outcome = "refused", message = { ["$type"] = "string" } }),
                lsp(2, "get"),
                ok(2, { ["$exact"] = { state = "refused", ready = false, projects = {},
                    options = { ["$exact"] = vim.empty_dict() } } }),
            },
        }, root, H.tmp() .. "/other.key")
        assert.is_true(a, b)
        assert.equals(before, table.concat(vim.fn.readfile(user_path, "b"), "\n"))
    end)
end)

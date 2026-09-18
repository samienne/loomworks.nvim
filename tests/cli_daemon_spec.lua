-- `lw daemon [status|stop]` — the Phase-0 client-stub CLI surface, plus the
-- `runtime-mode` settings validation. detect/stop are injected so no real
-- daemon or process is involved; io.write/os.exit are captured so a die() path
-- is observable instead of terminating busted.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local function capture(fn)
    local out_buf, err_buf = {}, {}
    local real_write, real_stderr, real_exit = io.write, io.stderr, os.exit
    io.write = function(s) out_buf[#out_buf + 1] = s end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
    local exit_code
    os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
    local ok, ret = pcall(fn)
    io.write, io.stderr, os.exit = real_write, real_stderr, real_exit
    return {
        ok = ok, ret = ret, exit_code = exit_code,
        stdout = table.concat(out_buf), stderr = table.concat(err_buf),
    }
end

describe("lw daemon status", function()
    it("reports the runtime mode and 'no workspace' outside a workspace", function()
        local r = capture(function()
            return cli.cmd_daemon(nil, { "daemon", "status" }, { config = {} })
        end)
        assert.equals(0, r.ret)
        assert.is_truthy(r.stdout:find("runtime mode: in%-process"))
        assert.is_truthy(r.stdout:find("no loomworks workspace here"))
    end)

    it("reports 'not running' when detect finds no daemon", function()
        local r = capture(function()
            return cli.cmd_daemon("/ws", { "daemon", "status" }, {
                config = {},
                detect = function() return { present = false } end,
            })
        end)
        assert.equals(0, r.ret)
        assert.is_truthy(r.stdout:find("daemon: not running"))
    end)

    it("renders details for a detected daemon", function()
        local r = capture(function()
            return cli.cmd_daemon("/ws", { "daemon", "status" }, {
                config = {},
                detect = function()
                    return {
                        present = true, live = true, compatible = true,
                        info = { pid = 77, pipe = "P", protocol_version = 1,
                                 lw_version = "0.1.0", session_generation = 2, age = 3 },
                    }
                end,
            })
        end)
        assert.equals(0, r.ret)
        assert.is_truthy(r.stdout:find("daemon: running"))
        assert.is_truthy(r.stdout:find("pid:%s+77"))
    end)

    it("reports a stale daemon (heartbeat lapsed)", function()
        local r = capture(function()
            return cli.cmd_daemon("/ws", { "daemon", "status" }, {
                config = {},
                detect = function()
                    return { present = true, live = false, compatible = true,
                             info = { pid = 5, pipe = "P", protocol_version = 1, age = 99 } }
                end,
            })
        end)
        assert.equals(0, r.ret)
        assert.is_truthy(r.stdout:find("stale %(no heartbeat%)"))
    end)

    it("reports a present-but-unreadable (corrupt) handle honestly", function()
        local r = capture(function()
            return cli.cmd_daemon("/ws", { "daemon", "status" }, {
                config = {},
                -- present, but decode produced no durable fields (pid nil).
                detect = function() return { present = true, live = true, info = {} } end,
            })
        end)
        assert.equals(0, r.ret)
        assert.is_truthy(r.stdout:find("unreadable"))
        assert.is_nil(r.stdout:find("daemon: running"))
    end)

    it("surfaces the effective mode from injected config", function()
        local r = capture(function()
            return cli.cmd_daemon(nil, { "daemon", "status" }, { config = { ["runtime-mode"] = "auto" } })
        end)
        assert.is_truthy(r.stdout:find("runtime mode: auto"))
    end)
end)

describe("lw daemon stop", function()
    it("reports nothing to stop outside a workspace", function()
        local r = capture(function()
            return cli.cmd_daemon(nil, { "daemon", "stop" }, { config = {} })
        end)
        assert.equals(0, r.ret)
        assert.is_truthy(r.stdout:find("nothing to stop"))
    end)

    it("drives client.stop and reports the outcome", function()
        local stopped_root
        local r = capture(function()
            return cli.cmd_daemon("/ws", { "daemon", "stop" }, {
                config = {},
                stop = function(root, _opts, cb)
                    stopped_root = root
                    cb({ stopped = true, method = "shutdown" })
                end,
            })
        end)
        assert.equals(0, r.ret)
        assert.equals("/ws", stopped_root)
        assert.is_truthy(r.stdout:find("daemon: stopped %(shutdown%)"))
    end)

    it("reports the reason when there was nothing to stop", function()
        local r = capture(function()
            return cli.cmd_daemon("/ws", { "daemon", "stop" }, {
                config = {},
                stop = function(_root, _opts, cb)
                    cb({ stopped = false, method = "none", reason = "no daemon running" })
                end,
            })
        end)
        assert.is_truthy(r.stdout:find("no daemon running"))
    end)
end)

describe("lw daemon unknown subcommand", function()
    it("dies with usage", function()
        local r = capture(function()
            return cli.cmd_daemon("/ws", { "daemon", "frobnicate" }, { config = {} })
        end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("unknown daemon subcommand"))
    end)
end)

describe("lw settings runtime-mode", function()
    it("rejects an invalid runtime-mode", function()
        local r = capture(function()
            return cli.cmd_settings("set", "runtime-mode", "bogus")
        end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("invalid runtime%-mode"))
    end)
end)

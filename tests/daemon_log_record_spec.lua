-- Normalized device-log record schema (§6.2 scaffold): normalize / validate /
-- format, plus streaming a record from the daemon to a client.

local log_record = require("loomworks.daemon.log_record")
local server_mod = require("loomworks.daemon.server")
local protocol = require("loomworks.daemon.protocol")
local uv = vim.uv or vim.loop

local function fresh_root() local d = vim.fn.tempname(); vim.fn.mkdir(d, "p"); return d end

describe("daemon.log_record schema", function()
    it("normalizes a raw record, defaulting level/ts and keeping fields", function()
        local r = log_record.normalize({ level = "warn", tag = "App", pid = 42, message = "hi",
            fields = { domain = 0x1234 } })
        assert.equals("warn", r.level)
        assert.equals("App", r.tag)
        assert.equals(42, r.pid)
        assert.equals("hi", r.message)
        assert.equals(0x1234, r.fields.domain)
        assert.is_number(r.ts)
    end)

    it("folds unknown top-level keys into fields (the platform escape hatch)", function()
        local r = log_record.normalize({ message = "m", buffer = "kernel", seq = 9 })
        assert.equals("kernel", r.fields.buffer)
        assert.equals(9, r.fields.seq)
    end)

    it("coerces an unknown level to info and validates", function()
        local r = log_record.normalize({ level = "bogus", message = "m" })
        assert.equals("info", r.level)
        assert.is_true((log_record.validate(r)))
    end)

    it("ranks and formats records", function()
        assert.is_true(log_record.rank("error") > log_record.rank("info"))
        local line = log_record.format(log_record.normalize({ ts = 100, level = "error",
            tag = "T", pid = 7, message = "boom" }))
        assert.is_truthy(line:find("ERROR"))
        assert.is_truthy(line:find("%[7%]"))
        assert.is_truthy(line:find("boom"))
    end)
end)

describe("daemon device-log stream", function()
    it("broadcasts a normalized log record to a connected client", function()
        local root = fresh_root()
        local server = server_mod.new(root)
        assert.is_true((server:start()))

        local got
        local c = uv.new_pipe(false)
        local dec = protocol.new_decoder()
        c:connect(server.address, function()
            c:read_start(function(_e, chunk)
                if not chunk then return end
                for _, p in ipairs(dec:push(chunk)) do
                    local m = protocol.decode(p)
                    if m and m.kind == protocol.KIND.log then got = m.record end
                end
            end)
        end)
        assert.is_true(vim.wait(1000, function() return server:client_count() > 0 end, 10))

        server:emit_log({ level = "info", tag = "App", pid = 1, message = "started",
            extra = "x" }) -- raw producer record

        assert.is_true(vim.wait(1000, function() return got ~= nil end, 10))
        assert.equals("info", got.level)
        assert.equals("started", got.message)
        assert.equals("x", got.fields.extra) -- unknown key folded into fields

        pcall(function() c:close() end)
        server:stop("done")
    end)
end)

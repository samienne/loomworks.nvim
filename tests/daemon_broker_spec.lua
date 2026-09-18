-- Runtime broker: the §5.2 resolution precedence chain (decision-only).

local broker = require("loomworks.daemon.broker")

-- A probe bundle that resolves nothing, so each test opts into exactly the rung
-- it exercises. Precedence is asserted by adding higher rungs on top.
local function probes(over)
    local base = {
        getenv = function() return nil end,
        pin_read = function() return nil end,
        which = function() return nil end,
        data_runtime = function() return nil end,
    }
    for k, v in pairs(over or {}) do base[k] = v end
    return base
end

describe("daemon.broker resolve", function()
    it("falls through to bundled-dev (in-process) when nothing resolves", function()
        local r = broker.resolve("/ws", probes())
        assert.equals(broker.KIND.bundled_dev, r.kind)
        assert.is_true(r.in_process)
    end)

    it("honors LOOMWORKS_LW above everything", function()
        local r = broker.resolve("/ws", probes({
            getenv = function(n) return n == "LOOMWORKS_LW" and "/opt/lw" or nil end,
            pin_read = function() return { version = "9.9.9" } end,
            which = function() return "/usr/bin/lw" end,
        }))
        assert.equals(broker.KIND.env_override, r.kind)
        assert.equals("/opt/lw", r.path)
        assert.is_false(r.in_process)
    end)

    it("uses the repo pin above PATH and data-cache", function()
        local r = broker.resolve("/ws", probes({
            pin_read = function() return { version = "1.2.3" } end,
            which = function() return "/usr/bin/lw" end,
            data_runtime = function() return "/data/lw" end,
        }))
        assert.equals(broker.KIND.pin, r.kind)
        assert.equals("1.2.3", r.version)
    end)

    it("uses system lw on PATH above the data cache", function()
        local r = broker.resolve("/ws", probes({
            which = function(exe) return exe == "lw" and "/usr/bin/lw" or nil end,
            data_runtime = function() return "/data/lw" end,
        }))
        assert.equals(broker.KIND.system, r.kind)
        assert.equals("/usr/bin/lw", r.path)
        assert.is_true(r.needs_protocol_probe)
    end)

    it("uses a provisioned data-cache runtime when present", function()
        local r = broker.resolve("/ws", probes({
            data_runtime = function() return "/data/loomworks/lw-1.0" end,
        }))
        assert.equals(broker.KIND.data_cache, r.kind)
        assert.equals("/data/loomworks/lw-1.0", r.path)
    end)

    it("never resolves to a fetch (never auto-installs)", function()
        -- With nothing present the chain must NOT surface a fetch action; it
        -- falls straight through to the in-process fallback.
        local r = broker.resolve("/ws", probes())
        assert.are_not.equal("fetch", r.kind)
        assert.is_true(r.in_process)
    end)
end)

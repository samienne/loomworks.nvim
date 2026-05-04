--- Tests for harmony.device_log filter args (specification.md
--- spec/modules/harmony.md §6.1) — `-t app` always present, `-L`
--- defaults to `I`, level overridable, and pid/tag still optional.

local harmony = require("loomworks.modules.harmony")

local function args_to_str(args)
    return table.concat(args, " ")
end

local function find_pair(args, flag)
    for i = 1, #args - 1 do
        if args[i] == flag then return args[i + 1] end
    end
    return nil
end

--- Find the value of a flag that occurs *after* the `shell hilog`
--- subcommand boundary. The hdc top-level shares some flags with
--- hilog (notably `-t`), so we have to skip hdc's args first.
local function find_hilog_pair(args, flag)
    local in_hilog = false
    for i = 1, #args - 1 do
        if args[i] == "hilog" then in_hilog = true
        elseif in_hilog and args[i] == flag then return args[i + 1] end
    end
    return nil
end

local function contains(args, value)
    for _, a in ipairs(args) do
        if a == value then return true end
        end
    return false
end

describe("harmony.device_log", function()
    local tool_data = { hdc = "/usr/bin/hdc" }

    it("emits hdc shell hilog -L I by default, no -t filter", function()
        local spec = harmony.device_log(tool_data, "SERIAL123", {})
        assert.equals("/usr/bin/hdc", spec.cmd)
        local s = args_to_str(spec.args)
        assert.is_truthy(s:find("-t SERIAL123"), "has device serial: " .. s)
        assert.is_truthy(s:find("shell hilog"), "invokes shell hilog: " .. s)
        assert.equals("I", find_hilog_pair(spec.args, "-L"),
            "default hilog level is I")
        assert.is_nil(find_hilog_pair(spec.args, "-t"),
            "no -t type filter by default — native LOG_CORE traffic must pass through")
    end)

    it("applies -t when opts.type is given and valid", function()
        local spec = harmony.device_log(tool_data, "S", { type = "app" })
        assert.equals("app", find_hilog_pair(spec.args, "-t"))
    end)

    it("ignores invalid opts.type", function()
        local spec = harmony.device_log(tool_data, "S", { type = "bogus" })
        assert.is_nil(find_hilog_pair(spec.args, "-t"))
    end)

    it("respects opts.level when valid", function()
        local spec = harmony.device_log(tool_data, "S", { level = "W" })
        assert.equals("W", find_hilog_pair(spec.args, "-L"))
    end)

    it("falls back to default level on invalid input", function()
        local spec = harmony.device_log(tool_data, "S", { level = "garbage" })
        assert.equals(harmony.HILOG_DEFAULT_LEVEL, find_hilog_pair(spec.args, "-L"))
    end)

    it("appends -P pid when pid given", function()
        local spec = harmony.device_log(tool_data, "S", { level = "I", pid = 4321 })
        assert.is_true(contains(spec.args, "-P"))
        assert.is_true(contains(spec.args, "4321"))
    end)

    it("appends -T tag when tag given", function()
        local spec = harmony.device_log(tool_data, "S", { level = "I", tag = "MyTag" })
        assert.is_true(contains(spec.args, "-T"))
        assert.is_true(contains(spec.args, "MyTag"))
    end)

    it("does not append -P / -T when not given", function()
        local spec = harmony.device_log(tool_data, "S", { level = "I" })
        assert.is_false(contains(spec.args, "-P"))
        assert.is_false(contains(spec.args, "-T"))
    end)
end)

describe("loomworks.set_device_log_strict_pid", function()
    local lw = require("loomworks")

    it("get_device_log_strict_pid defaults to true", function()
        assert.is_true(lw.get_device_log_strict_pid())
    end)
end)

describe("loomworks.set_device_log_level", function()
    local lw = require("loomworks")

    it("rejects invalid levels", function()
        local ok, err = lw.set_device_log_level("X")
        assert.is_false(ok)
        assert.is_truthy(err and err:find("invalid level"))
    end)

    it("accepts D|I|W|E|F", function()
        for _, level in ipairs({ "D", "I", "W", "E", "F" }) do
            local ok = lw.set_device_log_level(level)
            assert.is_true(ok, "should accept level " .. level)
            assert.equals(level, lw.get_device_log_level())
        end
    end)
end)

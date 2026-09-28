-- Command-spec executor for device runners (spec §18.2, §18.8): core spawns
-- every runner-built spec with no host shell, from an absolute program path,
-- normalises CRLF, detects connector failures printed with exit 0
-- (check_output), enforces hard timeouts naming the step, and cancels.
-- Real processes are the running nvim executable with `-l <script>`.

local se = require("loomworks.remote.spec_exec")
local fx = require("tests.remote_fixtures")

local function script(root, name, body)
    return fx.write(root .. "/" .. name .. ".lua", body)
end

local NVIM = vim.v.progpath

describe("remote.spec_exec (real processes)", function()
    local root
    before_each(function() root = fx.mkroot() end)
    after_each(function() require("loomworks.io").rm_rf(root) end)

    it("passes argv verbatim (no host shell), normalises CRLF and splits streams", function()
        local s = script(root, "echo", [[
            for i = 1, #arg do io.stdout:write("A[" .. arg[i] .. "]\r\n") end
            io.stderr:write("to-err\r\n")
            io.stdout:write("partial-no-newline")
            os.exit(3)
        ]])
        local job, fail = se.run({ cmd = NVIM, args = { "-l", s, "a b", "$(x);'\"", "&|>" } },
            { label = "echo" })
        assert.same({ "A[a b]", "A[$(x);'\"]", "A[&|>]", "partial-no-newline" }, job.lines)
        assert.same({ "to-err" }, job.err_lines)
        assert.equals(3, job.code)
        assert.truthy(fail:find("echo failed (exit 3)", 1, true))
    end)

    it("streams lines live through on_line in order", function()
        local s = script(root, "tick", [[
            for i = 1, 3 do io.stdout:write("tick " .. i .. "\n"); io.stdout:flush() end
        ]])
        local seen = {}
        local job, fail = se.run({ cmd = NVIM, args = { "-l", s } }, {
            on_line = function(stream, line) seen[#seen + 1] = stream .. ":" .. line end,
        })
        assert.is_nil(fail)
        assert.same({ "stdout:tick 1", "stdout:tick 2", "stdout:tick 3" }, seen)
        assert.equals(0, job.code)
    end)

    it("check_output fails a step that printed a failure with exit 0", function()
        local s = script(root, "fail0", [[ io.stdout:write("[Fail] rejected\n") ]])
        local _, fail = se.run({
            cmd = NVIM, args = { "-l", s },
            check_output = function(lines)
                for _, l in ipairs(lines) do if l:match("^%[Fail%]") then return l end end
            end,
        }, { label = "push x" })
        assert.equals("push x: [Fail] rejected", fail)
    end)

    it("a hard timeout kills the connector and names the step", function()
        local s = script(root, "hang", [[ vim.uv.sleep(20000) ]])
        local t0 = vim.uv.hrtime()
        local job, fail = se.run({ cmd = NVIM, args = { "-l", s } },
            { label = "list devices", timeout = 0.5 })
        local elapsed = (vim.uv.hrtime() - t0) / 1e9
        assert.is_true(job.timed_out)
        assert.truthy(fail:find("list devices timed out after 0.5s", 1, true))
        assert.is_true(elapsed < 10)
    end)

    it("cancellation kills the process", function()
        local s = script(root, "hang2", [[ vim.uv.sleep(20000) ]])
        local job = se.start({ cmd = NVIM, args = { "-l", s } }, { label = "exec" })
        vim.wait(200)
        job:kill("cancel")
        job:wait()
        assert.is_true(job.cancelled)
        assert.equals("exec: cancelled", job:failure())
    end)

    it("refuses a relative / PATH-searched program and malformed specs", function()
        local job, fail = se.run({ cmd = "nvim", args = {} }, { label = "x" })
        assert.truthy(job.spawn_error)
        assert.truthy(fail:find("not an absolute path", 1, true))
        _, fail = se.run({ cmd = NVIM, args = { "a\0b" } })
        assert.truthy(fail:find("NUL", 1, true))
        _, fail = se.run({ cmd = NVIM, args = { {} } })
        assert.truthy(fail:find("not a string", 1, true))
        _, fail = se.run(nil)
        assert.truthy(fail:find("no command spec", 1, true))
    end)

    it("env extends the parent environment", function()
        local s = script(root, "env", [[ io.stdout:write((os.getenv("LW_T1") or "-") .. " "
            .. (os.getenv("PATH") and "path" or "nopath") .. "\n") ]])
        local job = se.run({ cmd = NVIM, args = { "-l", s }, env = { LW_T1 = "v1" } })
        assert.same({ "v1 path" }, job.lines)
    end)
end)

describe("remote.spec_exec timeouts precedence", function()
    it("invocation > runner > core defaults", function()
        assert.same({ query = 120, transfer = 600 }, se.timeouts(nil))
        assert.same({ query = 30, transfer = 600 }, se.timeouts({ timeouts = { query = 30 } }))
        assert.same({ query = 5, transfer = 7 },
            se.timeouts({ timeouts = { query = 30 } }, { query = 5, transfer = 7 }))
    end)
end)

describe("remote.spec_exec (fake backend)", function()
    it("drives the fake device through the same executor", function()
        local dev = fx.device()
        local runner = fx.fake_runner_table()
        local job, fail = se.run(runner.list_devices(), { backend = dev:backend(), label = "list" })
        assert.is_nil(fail)
        local devs = runner.parse_devices(job.lines)
        assert.equals(1, #devs)
        assert.equals("SER1", devs[1].serial)
        assert.equals("online", devs[1].state)
    end)
end)

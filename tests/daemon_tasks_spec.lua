-- Task stream: progress coalescing, output bounding, done, notify.

local tasks = require("loomworks.daemon.tasks")

local function fake_server()
    local s = { broadcasts = {} }
    s.broadcast = function(self, msg) self.broadcasts[#self.broadcasts + 1] = msg end
    return s
end

local function phases(s) local t = {}; for _, m in ipairs(s.broadcasts) do t[#t + 1] = m.phase or m.kind end; return t end

describe("daemon.tasks TaskStream", function()
    it("coalesces progress to integer-percent changes", function()
        local s = fake_server()
        local ts = tasks.new(s)
        ts:progress(1, 0.50)   -- 50% ⇒ broadcast
        ts:progress(1, 0.502)  -- 50% ⇒ skip
        ts:progress(1, 0.509)  -- 51% ⇒ broadcast
        ts:progress(1, 0.51)   -- 51% ⇒ skip
        local n = 0
        for _, m in ipairs(s.broadcasts) do if m.phase == "progress" then n = n + 1 end end
        assert.equals(2, n)
        assert.equals(51, s.broadcasts[#s.broadcasts].pct)
    end)

    it("bounds output per task and emits one truncation notice", function()
        local s = fake_server()
        local ts = tasks.new(s)
        local saved = tasks.OUTPUT_CAP
        tasks.OUTPUT_CAP = 3
        for _ = 1, 10 do ts:output(7, "stdout", "line\n") end
        tasks.OUTPUT_CAP = saved
        local outs, trunc = 0, false
        for _, m in ipairs(s.broadcasts) do
            if m.phase == "output" then
                outs = outs + 1
                if m.text:find("truncated") then trunc = true end
            end
        end
        assert.equals(4, outs) -- 3 real + 1 truncation notice
        assert.is_true(trunc)
    end)

    it("emits start / output / done and a notify", function()
        local s = fake_server()
        local ts = tasks.new(s)
        ts:start(2, { name = "p" })
        ts:output(2, "stdout", "hi\n")
        ts:done(2, 0)
        ts:notify("error", "build", "boom", 2)
        assert.same({ "start", "output", "done", "notify" }, phases(s))
        assert.equals(0, s.broadcasts[3].exit_code)
        assert.equals("error", s.broadcasts[4].level)
    end)
end)

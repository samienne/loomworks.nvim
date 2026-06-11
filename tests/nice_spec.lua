--- Tests for the nice/ionice cmd wrapper. The platform/executable
--- probe is cached on first call, so most tests reset that cache
--- explicitly and stub vim.fn.has / vim.fn.executable to simulate
--- each scenario without depending on what's actually on PATH.

package.loaded["loomworks.nice"] = nil
local nice = require("loomworks.nice")

--- Capture the originals so each test can restore them.
local orig_has = vim.fn.has
local orig_exe = vim.fn.executable

local function stub(has_map, exe_map)
    vim.fn.has = function(feat) return has_map[feat] or 0 end
    vim.fn.executable = function(name) return exe_map[name] or 0 end
    nice._reset_cache()
end

local function restore()
    vim.fn.has = orig_has
    vim.fn.executable = orig_exe
    nice._reset_cache()
end

describe("loomworks.nice", function()
    after_each(restore)

    describe("on Linux with both binaries available", function()
        before_each(function()
            stub({ linux = 1 }, { nice = 1, ionice = 1 })
        end)

        it("prepends ionice + nice to the cmd", function()
            local wrapped = nice.wrap_cmd({ "ninja", "-C", "build" })
            assert.are.same(
                { "ionice", "-c", "3", "nice", "-n", "10",
                  "ninja", "-C", "build" },
                wrapped
            )
        end)

        it("is_active returns true", function()
            assert.is_true(nice.is_active())
        end)

        it("preserves single-element cmd", function()
            local wrapped = nice.wrap_cmd({ "make" })
            assert.are.equal("make", wrapped[#wrapped])
            assert.are.equal(7, #wrapped)
        end)

        it("does not mutate the input cmd", function()
            local input = { "ninja" }
            nice.wrap_cmd(input)
            assert.are.same({ "ninja" }, input)
        end)
    end)

    describe("on Linux with nice missing", function()
        before_each(function()
            stub({ linux = 1 }, { nice = 0, ionice = 1 })
        end)

        it("returns cmd unchanged", function()
            local cmd = { "ninja", "-C", "build" }
            assert.are.same(cmd, nice.wrap_cmd(cmd))
        end)

        it("is_active returns false", function()
            assert.is_false(nice.is_active())
        end)
    end)

    describe("on Linux with ionice missing", function()
        before_each(function()
            stub({ linux = 1 }, { nice = 1, ionice = 0 })
        end)

        it("returns cmd unchanged", function()
            local cmd = { "ninja" }
            assert.are.same(cmd, nice.wrap_cmd(cmd))
        end)
    end)

    describe("on Windows", function()
        before_each(function()
            stub({ win32 = 1 }, { nice = 1, ionice = 1 })
        end)

        it("returns cmd unchanged even if binaries claim to exist", function()
            local cmd = { "ninja", "-C", "build" }
            assert.are.same(cmd, nice.wrap_cmd(cmd))
        end)

        it("is_active returns false", function()
            assert.is_false(nice.is_active())
        end)
    end)

    describe("on macOS", function()
        before_each(function()
            stub({ mac = 1 }, { nice = 1, ionice = 0 })
        end)

        it("returns cmd unchanged (ionice is Linux-only)", function()
            local cmd = { "make" }
            assert.are.same(cmd, nice.wrap_cmd(cmd))
        end)
    end)

    describe("caching", function()
        it("only probes once across many calls", function()
            local has_calls, exe_calls = 0, 0
            vim.fn.has = function(_) has_calls = has_calls + 1; return 1 end
            vim.fn.executable = function(_) exe_calls = exe_calls + 1; return 1 end
            nice._reset_cache()

            for _ = 1, 50 do nice.wrap_cmd({ "x" }) end

            assert.are.equal(1, has_calls)
            assert.are.equal(2, exe_calls)   -- nice + ionice
        end)
    end)
end)

-- CLI step spawning (cli.lua run_spec): build/clean/test/run steps attach to
-- the invoking terminal (inherited stdio) so output streams live instead of
-- being buffered and dumped at exit.

-- Require the CLI module without running its main() entry point.
_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

describe("cli step spawning", function()
    local real_system, captured

    before_each(function()
        real_system = vim.system
        captured = nil
        vim.system = function(cmd, opts)
            captured = { cmd = cmd, opts = opts }
            return { wait = function() return { code = 0, stdout = "", stderr = "" } end }
        end
    end)

    after_each(function()
        vim.system = real_system
    end)

    it("attaches the child to the terminal (streams, does not capture)", function()
        cli._run_spec({ cmd = { "ninja" } }, "/root")
        assert.is_truthy(captured)
        assert.equals("inherit", captured.opts.stdio)
        -- Not forcing text-mode capture — nothing is buffered for later printing.
        assert.is_nil(captured.opts.text)
        assert.is_false(captured.opts.hide)
    end)

    it("uses the step cwd, falling back to root", function()
        cli._run_spec({ cmd = { "make" }, cwd = "/proj" }, "/root")
        assert.equals("/proj", captured.opts.cwd)
        cli._run_spec({ cmd = { "make" } }, "/root")
        assert.equals("/root", captured.opts.cwd)
    end)

    it("propagates the child's exit code", function()
        vim.system = function()
            return { wait = function() return { code = 3, stdout = "", stderr = "" } end }
        end
        assert.equals(3, cli._run_spec({ cmd = { "false" } }, "/root"))
    end)
end)

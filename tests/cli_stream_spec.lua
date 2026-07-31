-- CLI step spawning (cli.lua run_spec): output handling per host. The
-- standalone shim host streams (child inherits the terminal); the real Neovim
-- host has no stdio option, so run_spec captures and writes the tool output.

-- Require the CLI module without running its main() entry point.
_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

describe("cli step spawning", function()
    local real_system, real_shim, captured

    before_each(function()
        real_system = vim.system
        real_shim = vim._loomworks_shim
        captured = nil
        vim.system = function(cmd, opts)
            captured = { cmd = cmd, opts = opts }
            return { wait = function() return { code = 0, stdout = "", stderr = "" } end }
        end
    end)

    after_each(function()
        vim.system = real_system
        vim._loomworks_shim = real_shim
    end)

    describe("shim host (streaming)", function()
        before_each(function() vim._loomworks_shim = true end)

        it("attaches the child to the terminal, capturing nothing", function()
            cli._run_spec({ cmd = { "ninja" } }, "/root")
            assert.is_truthy(captured)
            assert.equals("inherit", captured.opts.stdio)
            assert.is_nil(captured.opts.text)
            assert.is_false(captured.opts.hide)
        end)
    end)

    describe("real Neovim host (captured)", function()
        before_each(function() vim._loomworks_shim = nil end)

        it("captures and writes the child's stdout/stderr itself", function()
            vim.system = function(cmd, opts)
                captured = { cmd = cmd, opts = opts }
                return { wait = function()
                    return { code = 0, stdout = "HELLO\n", stderr = "OOPS\n" }
                end }
            end
            local wrote_out, wrote_err = {}, {}
            local real_write = io.write
            local real_stderr = io.stderr
            io.write = function(s) wrote_out[#wrote_out + 1] = s end
            io.stderr = { write = function(_, s) wrote_err[#wrote_err + 1] = s end }
            local ok, err = pcall(cli._run_spec, { cmd = { "ninja" } }, "/root")
            io.write = real_write
            io.stderr = real_stderr
            assert.is_true(ok, err)
            -- No stdio inherit on this host: capture via text mode, then emit.
            assert.is_nil(captured.opts.stdio)
            assert.is_true(captured.opts.text)
            assert.equals("HELLO\n", table.concat(wrote_out))
            assert.equals("OOPS\n", table.concat(wrote_err))
        end)
    end)

    it("uses the step cwd, falling back to root", function()
        vim._loomworks_shim = true
        cli._run_spec({ cmd = { "make" }, cwd = "/proj" }, "/root")
        assert.equals("/proj", captured.opts.cwd)
        cli._run_spec({ cmd = { "make" } }, "/root")
        assert.equals("/root", captured.opts.cwd)
    end)

    it("propagates the child's exit code on both hosts", function()
        vim.system = function()
            return { wait = function() return { code = 3, stdout = "", stderr = "" } end }
        end
        vim._loomworks_shim = true
        assert.equals(3, cli._run_spec({ cmd = { "false" } }, "/root"))
        vim._loomworks_shim = nil
        assert.equals(3, cli._run_spec({ cmd = { "false" } }, "/root"))
    end)
end)

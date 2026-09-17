-- `lw run --prefix` (launch wrapper) and `--print`/`--dry-run` (command
-- inspection), spec §16.17. Covers the pure seams (shell-word split, POSIX-sh
-- quoting, env-overrides-only, argv assembly, the report emitter) plus cmd_run's
-- flag parsing and the shared dispatch tail (`_run_launch_target`): argv
-- assembly prefix+cmd+args, cwd/env preservation, device-target refusal,
-- unresolved-artifact reporting, and the --no-build path.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

--- Run `fn` with io.write / io.stderr / os.exit captured, so a die() path is
--- observable (exit_code set, no process kill) instead of terminating busted.
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
        ok = ok,
        ret = ret,
        exit_code = exit_code,
        stdout = table.concat(out_buf),
        stderr = table.concat(err_buf),
    }
end

-- ---------------------------------------------------------------------------
-- shell_split — the --prefix tokenizer
-- ---------------------------------------------------------------------------

describe("cli._shell_split", function()
    it("splits on whitespace", function()
        assert.same({ "gdb", "--args" }, cli._shell_split("gdb --args"))
        assert.same({ "valgrind", "--leak-check=full" },
            cli._shell_split("valgrind --leak-check=full"))
    end)

    it("keeps a single-quoted run as one literal token", function()
        assert.same({ "a", "b c", "d" }, cli._shell_split("a 'b c' d"))
    end)

    it("keeps a double-quoted run as one token, with backslash escapes", function()
        assert.same({ "a", 'b "c', "d" }, cli._shell_split([[a "b \"c" d]]))
    end)

    it("honors a backslash escape outside quotes", function()
        assert.same({ "a b" }, cli._shell_split([[a\ b]]))
    end)

    it("yields one empty token for a quoted empty string", function()
        assert.same({ "" }, cli._shell_split("''"))
    end)

    it("returns no tokens for blank/whitespace input", function()
        assert.same({}, cli._shell_split(""))
        assert.same({}, cli._shell_split("   "))
    end)
end)

-- ---------------------------------------------------------------------------
-- posix_sh_quote — the --print=sh quoter
-- ---------------------------------------------------------------------------

describe("cli._posix_sh_quote", function()
    it("leaves shell-safe tokens bare", function()
        assert.equals("abc", cli._posix_sh_quote("abc"))
        assert.equals("--leak-check=full", cli._posix_sh_quote("--leak-check=full"))
        assert.equals("/usr/bin/app.exe", cli._posix_sh_quote("/usr/bin/app.exe"))
    end)

    it("single-quote wraps tokens with spaces / specials", function()
        assert.equals("'a b'", cli._posix_sh_quote("a b"))
        assert.equals("'a;b|c'", cli._posix_sh_quote("a;b|c"))
        assert.equals("'$HOME'", cli._posix_sh_quote("$HOME"))
    end)

    it("escapes an embedded single quote as '\\''", function()
        assert.equals([['it'\''s']], cli._posix_sh_quote("it's"))
    end)

    it("renders the empty string as ''", function()
        assert.equals("''", cli._posix_sh_quote(""))
    end)
end)

-- ---------------------------------------------------------------------------
-- launch_env_overrides — report only the launch's contribution
-- ---------------------------------------------------------------------------

describe("cli._launch_env_overrides", function()
    it("returns {} for a nil env", function()
        assert.same({}, cli._launch_env_overrides(nil))
    end)

    it("keeps vars not present in the inherited environment", function()
        local ov = cli._launch_env_overrides({ LW_UNSET_XYZ = "1" })
        assert.equals("1", ov.LW_UNSET_XYZ)
    end)

    it("drops a var whose value equals the inherited one, keeps a changed one", function()
        vim.env.LW_ENVOV_TEST = "same"
        -- equal to inherited → dropped; a different value → kept.
        assert.same({}, cli._launch_env_overrides({ LW_ENVOV_TEST = "same" }))
        assert.same({ LW_ENVOV_TEST = "changed" },
            cli._launch_env_overrides({ LW_ENVOV_TEST = "changed" }))
        vim.env.LW_ENVOV_TEST = nil
    end)
end)

-- ---------------------------------------------------------------------------
-- emit_run_print — the read-only report (sh + json)
-- ---------------------------------------------------------------------------

describe("cli._emit_run_print", function()
    it("sh mode: a single POSIX-sh-quoted line, args with spaces quoted", function()
        local res = capture(function()
            return cli._emit_run_print(
                { cmd = "prog", args = { "a b", "x" } }, "sh", "/w")
        end)
        assert.equals("prog 'a b' x\n", res.stdout)
    end)

    it("json mode: cmd argv array + cwd + env overrides only", function()
        local res = capture(function()
            return cli._emit_run_print(
                { cmd = "prog", args = { "a b" }, cwd = "/w/app",
                  env = { LW_UNSET_XYZ = "bar" } }, "json", "/w")
        end)
        local payload = vim.json.decode(res.stdout)
        assert.same({ "prog", "a b" }, payload.cmd)
        assert.equals("/w/app", payload.cwd)
        assert.same({ LW_UNSET_XYZ = "bar" }, payload.env)
    end)

    it("json mode: empty env serializes as an object {}", function()
        local res = capture(function()
            return cli._emit_run_print({ cmd = "prog", args = {}, cwd = "/w" }, "json", "/w")
        end)
        assert.is_truthy(res.stdout:find('"env":{}', 1, true), "empty env is {} not []")
    end)
end)

-- ---------------------------------------------------------------------------
-- build_run_argv — prefix + cmd + args
-- ---------------------------------------------------------------------------

describe("cli._build_run_argv", function()
    it("prepends prefix tokens, then cmd, then args", function()
        assert.same({ "valgrind", "--leak-check=full", "app", "x" },
            cli._build_run_argv({ "valgrind", "--leak-check=full" },
                { cmd = "app", args = { "x" } }))
    end)

    it("no prefix → cmd then args", function()
        assert.same({ "app", "x" },
            cli._build_run_argv(nil, { cmd = "app", args = { "x" } }))
        assert.same({ "app" }, cli._build_run_argv({}, { cmd = "app" }))
    end)
end)

-- ---------------------------------------------------------------------------
-- cmd_run flag parsing — options do not consume operands / forwarded args
-- ---------------------------------------------------------------------------

describe("cli.cmd_run — --prefix / --print / --no-build parsing", function()
    -- Stub _run_selection (return a fake profile whose default_target is a stub)
    -- and _run_launch_target (capture the parsed opts, then halt) so we observe
    -- exactly what cmd_run parsed without touching build/launch machinery.
    local STUB_LT = {}
    local function parse(argv)
        local seen = {}
        local real_sel, real_disp = cli._run_selection, cli._run_launch_target
        cli._run_selection = function(ws, positionals)
            seen.positionals = positionals
            return {
                key = "p",
                projects = function() return {} end,
                default_target = function() return STUB_LT end,
            }, nil, ws
        end
        cli._run_launch_target = function(lt, ws, opts)
            seen.lt, seen.opts = lt, opts
            error({ __stop = true }, 0)
        end
        capture(function() return cli.cmd_run({ root = "/w" }, argv) end)
        cli._run_selection, cli._run_launch_target = real_sel, real_disp
        return seen
    end

    it("shell-splits a single --prefix string and keeps the operand out of it", function()
        local s = parse({ "run", "--no-build", "--prefix", "valgrind --leak-check=full", "app" })
        assert.same({ "app" }, s.positionals)
        assert.same({ "valgrind", "--leak-check=full" }, s.opts.prefix_tokens)
    end)

    it("accumulates a repeatable --prefix and forwards post-`--` args", function()
        local s = parse({ "run", "--no-build", "--prefix", "gdb", "--prefix", "--args",
            "app", "--", "--flag", "file" })
        assert.same({ "app" }, s.positionals)
        assert.same({ "gdb", "--args" }, s.opts.prefix_tokens)
        assert.same({ "--flag", "file" }, s.opts.extra_args)
    end)

    it("parses --print (sh), --print=json, and --dry-run", function()
        assert.equals("sh", parse({ "run", "--no-build", "--print", "app" }).opts.print_mode)
        assert.equals("json", parse({ "run", "--no-build", "--print=json", "app" }).opts.print_mode)
        assert.equals("sh", parse({ "run", "--no-build", "--dry-run", "app" }).opts.print_mode)
    end)

    it("parses --no-build", function()
        assert.is_true(parse({ "run", "--no-build", "app" }).opts.no_build)
    end)

    it("rejects an unknown --print format", function()
        local res = capture(function() return cli.cmd_run({ root = "/w" }, { "run", "--print=xml", "app" }) end)
        assert.equals(1, res.exit_code)
        assert.is_truthy(res.stderr:find("sh", 1, true))
    end)

    it("rejects --print combined with --prefix", function()
        local res = capture(function()
            return cli.cmd_run({ root = "/w" }, { "run", "--print", "--prefix", "gdb", "app" })
        end)
        assert.equals(1, res.exit_code)
        assert.is_truthy(res.stderr:find("mutually exclusive", 1, true))
    end)

    it("errors when --prefix has no argument", function()
        local res = capture(function() return cli.cmd_run({ root = "/w" }, { "run", "--prefix" }) end)
        assert.equals(1, res.exit_code)
        assert.is_truthy(res.stderr:find("requires a wrapper command", 1, true))
    end)
end)

-- ---------------------------------------------------------------------------
-- _run_launch_target — the shared deploy → resolve → (report | exec) tail
-- ---------------------------------------------------------------------------

describe("cli._run_launch_target — dispatch tail", function()
    local WS = { root = "/w" }

    --- A stub launch target. `spec`/`spec_err` drive resolve_launch_spec; flags
    --- record what the tail invoked.
    local function stub_lt(o)
        o = o or {}
        local lt = { _deployed = false }
        function lt:is_valid() return o.invalid ~= true, o.reasons or {} end
        function lt:requires_device() return o.device == true end
        function lt:display_name() return o.name or "app: run" end
        function lt:deploy_sync() self._deployed = true; return true end
        function lt:resolve_launch_spec(opts)
            self._resolve_opts = opts
            if o.spec_err then return nil, o.spec_err end
            return o.spec or { cmd = "/b/app.exe", args = {}, cwd = "/b", env = nil, name = "app: run" }
        end
        return lt
    end

    it("runs prefix + cmd + args in the resolved cwd/env (exit code passthrough)", function()
        local captured
        local lt = stub_lt({ spec = {
            cmd = "/b/app.exe", args = { "in.txt" }, cwd = "/b/app",
            env = { FOO = "bar" }, name = "app: run" } })
        local res = capture(function()
            return cli._run_launch_target(lt, WS,
                { prefix_tokens = { "valgrind", "--leak-check=full" }, extra_args = {} },
                { run_spec = function(step) captured = step; return 42 end })
        end)
        assert.is_true(res.ok)
        assert.equals(42, res.ret)
        assert.same({ "valgrind", "--leak-check=full", "/b/app.exe", "in.txt" }, captured.cmd)
        assert.equals("/b/app", captured.cwd)
        assert.same({ FOO = "bar" }, captured.env)
    end)

    it("refuses --prefix on a device target with a clear message", function()
        local ran = false
        local lt = stub_lt({ device = true, name = "app: dev" })
        local res = capture(function()
            return cli._run_launch_target(lt, WS, { prefix_tokens = { "gdb" } },
                { run_spec = function() ran = true; return 0 end })
        end)
        assert.equals(1, res.exit_code)
        assert.is_false(ran)
        assert.is_truthy(res.stderr:find("device target", 1, true))
    end)

    it("--print reports without executing (sh) and skips deploy under --no-build", function()
        local ran = false
        local lt = stub_lt({ spec = { cmd = "prog", args = { "a b" }, cwd = "/w", env = nil } })
        local res = capture(function()
            return cli._run_launch_target(lt, WS,
                { print_mode = "sh", no_build = true, extra_args = {} },
                { run_spec = function() ran = true; return 0 end })
        end)
        assert.is_false(ran)                         -- report only, no exec
        assert.is_false(lt._deployed)               -- --no-build skips deploy
        assert.equals("prog 'a b'\n", res.stdout)
    end)

    it("deploys by default (build path)", function()
        local lt = stub_lt({ spec = { cmd = "app", args = {}, cwd = "/w" } })
        capture(function()
            return cli._run_launch_target(lt, WS, { extra_args = {} },
                { run_spec = function() return 0 end })
        end)
        assert.is_true(lt._deployed)
    end)

    it("reports an unresolved build-target artifact, never guesses (exit non-zero)", function()
        local ran = false
        local lt = stub_lt({ spec_err = "target 'app' has no built artifact" })
        local res = capture(function()
            return cli._run_launch_target(lt, WS, { extra_args = {} },
                { run_spec = function() ran = true; return 0 end })
        end)
        assert.equals(1, res.exit_code)
        assert.is_false(ran)
        assert.is_truthy(res.stderr:find("no built artifact", 1, true))
        assert.is_truthy(res.stderr:find("cannot resolve launch", 1, true))
    end)

    it("forwards extra_args + cwd_override into resolve_launch_spec", function()
        local lt = stub_lt({})
        capture(function()
            return cli._run_launch_target(lt, WS,
                { extra_args = { "x" }, cwd_override = "/tmp" },
                { run_spec = function() return 0 end })
        end)
        assert.same({ "x" }, lt._resolve_opts.extra_args)
        assert.equals("/tmp", lt._resolve_opts.working_dir)
    end)
end)

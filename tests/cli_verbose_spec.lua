-- `-v` / `--verbose` on lw build, run, test and clean (spec §16.4 *Verbose*):
-- an option among the command's own arguments (before the command `-v` is the
-- version). With it every command a step runs is printed under the step's
-- header — `    $ <command>`, `    (in <dir>)`, `    env: NAME=value` — plus a
-- clean's `remove <dir>`, deploy `copy` / `up to date` lines and a device
-- run's device commands, all of the `command` role (§16.7, dim). Without it
-- none of these lines appear.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local cc = require("loomworks.cli_color")
local overseer = require("loomworks.overseer")
local build_run = require("loomworks.build_run")

local ESC = "\27["

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end, flush = function() end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, ret = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  if not ok and not (type(ret) == "table" and ret.__exit) then error(ret, 0) end
  return { exit_code = exit_code, ret = ret, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function make_root()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local t = assert(io.open(root .. "/App/tsconfig.json", "w")); t:write("{}"); t:close()
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  return root
end

-- ---------------------------------------------------------------------------
-- Option parsing through the real dispatcher
-- ---------------------------------------------------------------------------

describe("-v / --verbose parsing", function()
  local root = make_root()
  local HANDLERS = { "cmd_run", "cmd_build", "cmd_test", "cmd_clean" }

  local function run(...)
    local argv = { ... }
    local saved, called = {}, {}
    for _, nm in ipairs(HANDLERS) do
      saved[nm] = cli[nm]
      cli[nm] = function(_, a) called.name = nm; called.args = a; return 0 end
    end
    local saved_arg, saved_root = _G.arg, vim.env.LW_ROOT
    _G.arg, vim.env.LW_ROOT = argv, root
    local r = capture(function() cli.main() end)
    _G.arg, vim.env.LW_ROOT = saved_arg, saved_root
    for _, nm in ipairs(HANDLERS) do cli[nm] = saved[nm] end
    r.called, r.args = called.name, called.args
    return r
  end

  it("is accepted among the own arguments of build, run, test and clean", function()
    for _, cmd in ipairs({ "build", "run", "test", "clean" }) do
      for _, flag in ipairs({ "-v", "--verbose" }) do
        local r = run(cmd, "Dev", flag)
        assert.equals(0, r.exit_code, cmd .. " " .. flag .. ": " .. r.stderr)
        assert.equals("cmd_" .. cmd, r.called)
        assert.same({ cmd, "Dev", flag }, r.args)
      end
    end
  end)

  it("is an unknown option on other commands", function()
    local r = run("reset", "Dev", "-v")
    assert.equals(2, r.exit_code)
    assert.truthy(r.stderr:find("unknown option '-v'", 1, true), r.stderr)
  end)

  it("before the command it is still the version, never a build", function()
    for _, argv in ipairs({ { "-v", "build" }, { "-v" }, { "--version", "build" } }) do
      local r = run(unpack(argv))
      assert.is_nil(r.called, table.concat(argv, " ") .. " reached " .. tostring(r.called))
      -- The nvim-hosted fallback names it a host command (the version).
      assert.truthy(r.stderr:find("provided by the standalone", 1, true), r.stderr)
    end
  end)

  it("after -- it is the program's argument, not lw's", function()
    local r = run("run", "Dev", "demo", "--", "-v")
    assert.equals("cmd_run", r.called)
    assert.same({ "run", "Dev", "demo", "--", "-v" }, r.args)
  end)
end)

-- ---------------------------------------------------------------------------
-- What is printed
-- ---------------------------------------------------------------------------

describe("verbose lines", function()
  it("command_lines: $ command, (in dir), sorted env overrides", function()
    assert.same({ "    $ make -j 4", "    (in /r/b)", '    env: A=1 "B=x y"' },
      build_run.command_lines({ cmd = { "make", "-j", "4" }, env = { B = "x y", A = "1" } }, "/r/b"))
    assert.same({ "    $ ctest" }, build_run.command_lines({ cmd = { "ctest" }, env = {} }))
  end)

  describe("env: never the inherited environment", function()
    local exe = require("loomworks.exe")
    local SEP = exe.is_windows and ";" or ":"
    -- The env line quotes each NAME=value like a command argument.
    local function line(arg) return "    env: " .. require("loomworks.term").format_argv({ arg }) end
    local saved
    before_each(function()
      saved = vim.env.LW_VERBOSE_SECRET
      vim.env.LW_VERBOSE_SECRET = "s3cret-value"
    end)
    after_each(function() vim.env.LW_VERBOSE_SECRET = saved end)

    it("leaves out a variable whose value equals the inherited one", function()
      local path = assert(exe.getenv("PATH"))
      assert.equals("    env: CC=gcc", build_run.env_line({
        PATH = path, LW_VERBOSE_SECRET = "s3cret-value", CC = "gcc",
      }))
      -- Nothing added at all: no env line.
      assert.is_nil(build_run.env_line({ PATH = path }))
    end)

    it("leaves out an inherited empty value, which is a value (a whole run environment copies it)", function()
      local uv = vim.uv or vim.loop
      uv.os_setenv("LW_VERBOSE_EMPTY", "")
      -- (Where the platform keeps an empty variable at all.)
      if uv.os_environ().LW_VERBOSE_EMPTY == "" then
        assert.is_nil(build_run.env_line({ LW_VERBOSE_EMPTY = "" }))
      end
      uv.os_unsetenv("LW_VERBOSE_EMPTY")
      assert.equals("    env: LW_VERBOSE_EMPTY=", build_run.env_line({ LW_VERBOSE_EMPTY = "" }))
    end)

    it("shows a value that extends the inherited one as the added part plus $NAME", function()
      local path = assert(exe.getenv("PATH"))
      assert.equals(line("PATH=/opt/gcc/bin" .. SEP .. "$PATH"),
        build_run.env_line({ PATH = "/opt/gcc/bin" .. SEP .. path }))
      assert.equals(line("PATH=$PATH" .. SEP .. "/opt/tail"),
        build_run.env_line({ PATH = path .. SEP .. "/opt/tail" }))
    end)

    if exe.is_windows then
      it("matches names case-insensitively on Windows", function()
        local path = assert(exe.getenv("PATH"))
        assert.is_nil(build_run.env_line({ Path = path }))
        assert.equals(line("Path=C:/gcc/bin;$Path"),
          build_run.env_line({ Path = "C:/gcc/bin;" .. path }))
      end)
    end
  end)

  it("a wrapped command shows the command the wrapper runs (display_cmd)", function()
    assert.same("    $ cmake -S .",
      build_run.command_lines({ cmd = { "cmd", "/c", "x.bat" }, display_cmd = { "cmake", "-S", "." } })[1])
  end)

  it("deploy and remove lines", function()
    assert.equals("    copy /b/a.dll -> /o/a.dll",
      build_run.deploy_line({ action = "copy", source = "/b/a.dll", dest = "/o/a.dll" }))
    assert.equals("    up to date /o/a.dll",
      build_run.deploy_line({ action = "fresh", source = "/b/a.dll", dest = "/o/a.dll" }))
    assert.equals("    remove /r/build", build_run.remove_line("/r/build"))
  end)
end)

describe("lw build -v", function()
  local orig_plan, orig_spawn
  before_each(function() orig_plan, orig_spawn = overseer.plan_profile_build, cli._run_spec end)
  after_each(function()
    overseer.plan_profile_build, cli._run_spec = orig_plan, orig_spawn
    cc.mode = "auto"
  end)

  local function build(opts)
    overseer.plan_profile_build = function()
      return { { kind = "build", name = "App", cmd = { "make" }, cwd = "/r/b", env = { CC = "gcc" } } }
    end
    cli._run_spec = function() return 0 end
    return capture(function() cli._run_build_steps({ key = "p" }, { root = "/r" }, opts or {}) end)
  end

  it("prints nothing extra without -v", function()
    cc.mode = "never"
    assert.equals("building profile: p\n==> [build] App\n", build().stdout)
  end)

  it("prints the command, its directory and env overrides under the header", function()
    cc.mode = "never"
    assert.equals("building profile: p\n==> [build] App\n    $ make\n    (in /r/b)\n    env: CC=gcc\n",
      build({ verbose = true }).stdout)
  end)

  it("the printed command lines have the command role (dim)", function()
    cc.mode = "always"
    local out = build({ verbose = true }).stdout
    assert.truthy(out:find(ESC .. "2m    $ make" .. ESC .. "0m\n", 1, true), out)
    assert.truthy(out:find(ESC .. "2m    (in /r/b)" .. ESC .. "0m\n", 1, true), out)
    assert.truthy(out:find(ESC .. "2m    env: CC=gcc" .. ESC .. "0m\n", 1, true), out)
  end)

  it("under --print (quiet) they go to stderr with the status lines", function()
    cc.mode = "never"
    local r = build({ verbose = true, quiet = true })
    assert.equals("", r.stdout)
    assert.truthy(r.stderr:find("    $ make\n", 1, true), r.stderr)
  end)
end)

describe("-v reaches the dependency build of lw run and lw test", function()
  local saved = {}
  local profile = { key = "p", projects = function() return {} end }
  before_each(function()
    saved.plan, saved.spawn = overseer.plan_profile_build, cli._run_spec
    saved.sel, saved.build, saved.named = cli._run_selection, cli._run_build_steps, cli._run_named_tests
    overseer.plan_profile_build = function()
      return { { kind = "build", name = "App", cmd = { "make" }, cwd = "/r/b", env = { CC = "gcc" } } }
    end
    cli._run_spec = function() return 0 end
    cc.mode = "never"
  end)
  after_each(function()
    overseer.plan_profile_build, cli._run_spec = saved.plan, saved.spawn
    cli._run_selection, cli._run_build_steps, cli._run_named_tests = saved.sel, saved.build, saved.named
    cc.mode = "auto"
  end)

  -- `lw run` hands its own -v (and --print's quiet) to the build it runs first.
  local function run_build_opts(args)
    local seen
    cli._run_selection = function(ws) return profile, nil, ws end
    cli._run_build_steps = function(_, _, o) seen = o; error({ __exit = true }, 0) end
    capture(function() cli.cmd_run({ root = "/r" }, args) end)
    return seen
  end

  it("lw run -v builds verbosely", function()
    local o = run_build_opts({ "run", "-v" })
    assert.is_true(o.verbose)
    assert.is_false(o.quiet)
    assert.is_false(run_build_opts({ "run" }).verbose)
  end)

  it("lw run -v --print builds verbosely and quietly (lines on stderr)", function()
    local o = run_build_opts({ "run", "-v", "--print" })
    assert.is_true(o.verbose)
    assert.is_true(o.quiet)
  end)

  it("lw test -v --target: the build's commands are printed", function()
    cli._run_named_tests = function() return 0 end
    local r = capture(function()
      return cli._test_targets({ root = "/r" }, profile, { "t" }, { verbose = true }, {})
    end)
    assert.equals(0, r.ret)
    assert.truthy(r.stdout:find("==> [build] App\n    $ make\n    (in /r/b)\n    env: CC=gcc\n", 1, true), r.stdout)
  end)

  it("lw test -v (the test plan): the build's commands are printed", function()
    local r = capture(function()
      local ok, err = pcall(cli._test_plan, { root = "/r" }, profile, { verbose = true }, {})
      -- What follows the build (an empty plan) does not matter here.
      if not ok and not (type(err) == "table" and err.__exit) then return err end
    end)
    assert.truthy(r.stdout:find("==> [build] App\n    $ make\n    (in /r/b)\n    env: CC=gcc\n", 1, true), r.stdout)
  end)

  it("without -v the dependency build prints no command", function()
    cli._run_named_tests = function() return 0 end
    local r = capture(function()
      return cli._test_targets({ root = "/r" }, profile, { "t" }, {}, {})
    end)
    assert.is_nil(r.stdout:find("$ make", 1, true), r.stdout)
  end)
end)

describe("lw clean -v", function()
  local orig_plan, orig_spawn, orig_dirs, orig_groups, orig_wipe
  before_each(function()
    orig_plan, orig_spawn, orig_dirs, orig_groups, orig_wipe = overseer.plan_profile_clean, cli._run_spec,
      build_run.profile_build_dirs, build_run.wipe_groups, build_run.wipe_step
    cc.mode = "never"
  end)
  after_each(function()
    overseer.plan_profile_clean, cli._run_spec, build_run.profile_build_dirs, build_run.wipe_groups,
      build_run.wipe_step = orig_plan, orig_spawn, orig_dirs, orig_groups, orig_wipe
    cc.mode = "auto"
  end)

  local function clean(args)
    overseer.plan_profile_clean = function()
      return {
        { kind = "clean", name = "App", cmd = { "make", "clean" }, cwd = "/r/b" },
        { kind = "clean", name = "Web", wipe_build_dir = true, build_dir = "/r/w" },
      }
    end
    cli._run_spec = function() return 0 end
    build_run.profile_build_dirs = function() return {} end
    -- The core-performed wipe (build_run.wipe_step, under the workspace
    -- operation lock) is stubbed: these cases are about what is printed.
    local removed = {}
    build_run.wipe_groups = function() return {} end
    build_run.wipe_step = function(_, step, _, _, done) removed[#removed + 1] = step.build_dir; done(0) end
    local ws = { root = "/r", _profiles = { { key = "p" } }, _op_lock = function() return { released = true } end }
    local r = capture(function() cli.cmd_clean(ws, args) end)
    r.removed = removed
    return r
  end

  it("prints nothing extra without -v", function()
    local r = clean({ "clean", "p" })
    assert.equals("cleaning profile: p\n==> [clean] App\n==> [clean] Web\nCLEAN OK: p\n", r.stdout)
    assert.same({ "/r/w" }, r.removed)
  end)

  it("prints each clean command and what a wipe removes", function()
    local r = clean({ "clean", "p", "--verbose" })
    assert.equals("cleaning profile: p\n==> [clean] App\n    $ make clean\n    (in /r/b)\n"
      .. "==> [clean] Web\n    remove /r/w\nCLEAN OK: p\n", r.stdout)
  end)

  it("refuses a second operand", function()
    local r = clean({ "clean", "p", "q" })
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("unexpected argument 'q'", 1, true), r.stderr)
  end)
end)

describe("lw run -v: deploy steps", function()
  local function lt()
    return {
      is_valid = function() return true end,
      requires_device = function() return false end,
      deploy_sync = function(_, o)
        if o and o.on_step then
          o.on_step({ action = "copy", source = "/b/a.dll", dest = "/o/a.dll" })
          o.on_step({ action = "fresh", source = "/b/c.dll", dest = "/o/c.dll" })
        end
        return true
      end,
      resolve_launch_spec = function() return { name = "app", cmd = "/o/app", args = {}, cwd = "/o" } end,
    }
  end
  local function run(opts)
    cc.mode = "never"
    local r = capture(function()
      return cli._run_launch_target(lt(), { root = "/r" }, opts, { run_spec = function() return 0 end })
    end)
    cc.mode = "auto"
    return r
  end

  it("prints each deploy copy / up-to-date step with -v", function()
    local r = run({ verbose = true })
    assert.truthy(r.stdout:find("    copy /b/a.dll -> /o/a.dll\n    up to date /o/c.dll\n", 1, true), r.stdout)
  end)

  it("prints none without -v", function()
    local r = run({})
    assert.is_nil(r.stdout:find("copy", 1, true), r.stdout)
    assert.is_nil(r.stdout:find("up to date", 1, true), r.stdout)
  end)

  it("under --print they go to stderr, keeping stdout for the report", function()
    local r = run({ verbose = true, print_mode = "sh" })
    assert.truthy(r.stderr:find("    copy /b/a.dll -> /o/a.dll\n    up to date /o/c.dll\n", 1, true), r.stderr)
    assert.is_nil(r.stdout:find("copy", 1, true), r.stdout)
    assert.is_nil(r.stdout:find("up to date", 1, true), r.stdout)
  end)
end)

describe("deploy.execute_deploy_steps on_step", function()
  it("reports a copy, then up to date once fresh", function()
    local deploy = require("loomworks.deploy")
    local orig = deploy.resolve_deploy_step
    local dir = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(dir, "p")
    local src = dir .. "/a.txt"
    local f = assert(io.open(src, "w")); f:write("x"); f:close()
    deploy.resolve_deploy_step = function()
      return { source_path = src, dest_path = dir .. "/out/a.txt", source_build_dir_id = "b",
        source_rel_path = "a.txt" }
    end
    local records, events = {}, {}
    local ctx = { on_step = function(ev) events[#events + 1] = ev.action .. " " .. ev.dest end }
    local norm = function(p) return p end
    local ok1 = pcall(deploy.execute_deploy_steps, { ["out/a.txt"] = { path = "a.txt" } }, ctx, records, norm)
    local ok2 = pcall(deploy.execute_deploy_steps, { ["out/a.txt"] = { path = "a.txt" } }, ctx, records, norm)
    deploy.resolve_deploy_step = orig
    vim.fn.delete(dir, "rf")
    assert.is_true(ok1 and ok2)
    assert.same({ "copy " .. dir .. "/out/a.txt", "fresh " .. dir .. "/out/a.txt" }, events)
  end)
end)

describe("lw test -v: the test program invocation", function()
  local gtest = require("loomworks.gtest")
  local orig_probe
  before_each(function() orig_probe = gtest.probe_sync; gtest.probe_sync = function() return nil end end)
  after_each(function() gtest.probe_sync = orig_probe; cc.mode = "auto" end)

  local function step(verbose)
    cc.mode = "never"
    local lt = {
      is_valid = function() return true end,
      requires_device = function() return false end,
      resolve_launch_spec = function()
        return { name = "t", cmd = "/b/t", args = { "--x" }, cwd = "/w", env = { T = "1" } }
      end,
    }
    return capture(function()
      return cli._run_test_executable({ root = "/r" }, lt, { label = "t", verbose = verbose },
        { run_spec = function() return 0 end })
    end)
  end

  it("prints the program command, directory and env under the step header", function()
    local r = step(true)
    assert.truthy(r.stdout:find("==> [test] t\n    $ /b/t --x\n    (in /w)\n    env: T=1\n", 1, true), r.stdout)
  end)

  it("prints none without -v", function()
    local r = step(false)
    assert.is_nil(r.stdout:find("$ ", 1, true), r.stdout)
  end)
end)

describe("lw run -v on a device: device commands", function()
  local runners = require("loomworks.remote.runners")
  local Target = require("loomworks.target")
  local fx = require("tests.remote_fixtures")
  local root, lockdir, saved_lock, dev, unit, target

  before_each(function()
    runners._reset()
    root = fx.mkroot()
    lockdir = fx.mkroot()
    saved_lock = vim.env.LOOMWORKS_DEVICE_LOCK_DIR
    vim.env.LOOMWORKS_DEVICE_LOCK_DIR = lockdir
    fx.write_foreign_exe(root .. "/test/unit/Runner")
    dev = fx.device()
    local runner = fx.fake_runner_table()
    local sdk = fx.fake_sdk(runner)
    local targets = { Runner = { type = "executable", artifact = "test/unit/Runner" } }
    unit = fx.fake_unit({ build_dir = root, targets = targets, token = "fake-arm64", sdk = sdk,
      tool_key = "fake-kit" })
    target = Target.new(unit, "Runner", targets.Runner)
    dev.behaviors.Runner = function() return { out = { "hello" } } end
  end)
  after_each(function()
    vim.env.LOOMWORKS_DEVICE_LOCK_DIR = saved_lock
    require("loomworks.io").rm_rf(root)
    require("loomworks.io").rm_rf(lockdir)
    runners._reset()
    cc.mode = "auto"
  end)

  local function run(verbose, extra)
    cc.mode = "never"
    local lt = {
      _target = target, _config_unit = unit, _project = { key = "App" }, _profile = { key = "Debug:fake-kit" },
      is_valid = function() return true end,
      requires_device = function() return false end,
      deploy_sync = function() return true end,
      display_name = function() return "Runner" end,
    }
    local ws = { name = "ws", _device_sync = {}, _devices = {}, _save_cache = function() end }
    local deps = { backend = dev:backend(), liveness_ms = 100000,
      write_out = function() end, write_err = function() end }
    local opts = { verbose = verbose }
    for k, v in pairs(extra or {}) do opts[k] = v end
    return capture(function() return cli._run_launch_target(lt, ws, opts, deps) end)
  end

  it("prints the device listing, staging and the program invocation on the device", function()
    local r = run(true)
    assert.equals(0, r.ret, r.stderr)
    -- The connector commands (listing, transfers) …
    assert.truthy(r.stdout:find("    $ " .. fx.CONNECTOR, 1, true), r.stdout)
    -- … and the program invocation, as run on the device, with its directory.
    local program = r.stdout:match("    %$ (/[^\n ]*/test/unit/Runner)\n")
    assert.is_not_nil(program, r.stdout)
    assert.truthy(r.stdout:find("    $ " .. program .. "\n    (in /", 1, true), r.stdout)
  end)

  it("prints none without -v", function()
    local r = run(false)
    assert.equals(0, r.ret, r.stderr)
    assert.is_nil(r.stdout:find("    $ ", 1, true), r.stdout)
  end)

  it("under --print they go to stderr, keeping stdout for the report", function()
    local r = run(true, { print_mode = "sh" })
    assert.equals(0, r.ret, r.stderr)
    assert.truthy(r.stderr:find("    $ " .. fx.CONNECTOR, 1, true), r.stderr)
    assert.is_nil(r.stdout:find("    $ ", 1, true), r.stdout)
  end)
end)

-- ---------------------------------------------------------------------------
-- The two hosts of the daemon line (spec §19.15 "Roles and verbose"): the
-- shared line producer computes the env line against this process's
-- environment (the in-process host) or the one it is given (the daemon: the
-- requesting client's), the test plan's in-process host prints its
-- commands, and a clean / run / test with `-v` is routed, its request
-- carrying `verbose`.
-- ---------------------------------------------------------------------------

describe("-v on the in-process host of the daemon line", function()
  it("step_lines gives the env line only with `env` (the in-process host)", function()
    local step = { kind = "build", name = "App", cmd = { "make" }, cwd = "/b", env = { LW_VERBOSE_SPEC = "1" } }
    local lines = build_run.step_lines({ root = "/ws" }, step, { verbose = true })
    assert.same({ "==> [build] App", "    $ make", "    (in /b)" }, lines)
    local with_env, roles = build_run.step_lines({ root = "/ws" }, step, { verbose = true, env = true })
    assert.same({ "==> [build] App", "    $ make", "    (in /b)", "    env: LW_VERBOSE_SPEC=1" }, with_env)
    assert.same({ "phase", "command", "command", "command" }, roles)
  end)

  it("the env line against a given inherited environment, never this process's", function()
    local SEP = require("loomworks.exe").is_windows and ";" or ":"
    -- This process has LW_VERBOSE_SPEC_P unset; the client's has it.
    assert.is_nil(vim.env.LW_VERBOSE_SPEC_P)
    local client = { LW_VERBOSE_SPEC_P = "/c/bin", LW_VERBOSE_SPEC_SAME = "x", PATH = "/client/path" }
    local step = { kind = "build", name = "App", cmd = { "make" }, cwd = "/b", env = {
      LW_VERBOSE_SPEC_P = "/add" .. SEP .. "/c/bin", LW_VERBOSE_SPEC_SAME = "x", PATH = "/client/path",
      LW_VERBOSE_SPEC_NEW = "1" } }
    local lines = build_run.step_lines({ root = "/ws" }, step, { verbose = true, env = client })
    assert.same({ "==> [build] App", "    $ make", "    (in /b)",
      "    env: " .. require("loomworks.term").format_argv({ "LW_VERBOSE_SPEC_NEW=1",
        "LW_VERBOSE_SPEC_P=/add" .. SEP .. "$LW_VERBOSE_SPEC_P" }) }, lines)
    -- This process's PATH is not the baseline: the client's PATH unchanged is no override.
    assert.is_nil(build_run.env_line({ PATH = "/client/path" }, client))
    assert.equals("    env: PATH=/client/path", build_run.env_line({ PATH = "/client/path" }, {}))
    if require("loomworks.exe").is_windows then
      assert.is_nil(build_run.env_line({ Path = "/client/path" }, client))
    end
  end)

  it("two spellings of one variable inherited (Path and PATH): the exact-case one is the baseline", function()
    local SEP = require("loomworks.exe").is_windows and ";" or ":"
    local function line(arg) return "    env: " .. require("loomworks.term").format_argv({ arg }) end
    local client = { Path = "/p/lower", PATH = "/p/upper" }
    -- Whichever order the table yields them in.
    assert.is_nil(build_run.env_line({ PATH = "/p/upper" }, client))
    assert.is_nil(build_run.env_line({ Path = "/p/lower" }, client))
    assert.equals(line("PATH=/x" .. SEP .. "$PATH"), build_run.env_line({ PATH = "/x" .. SEP .. "/p/upper" }, client))
    assert.equals(line("Path=/x" .. SEP .. "$Path"), build_run.env_line({ Path = "/x" .. SEP .. "/p/lower" }, client))
  end)

  it("the lead and success lines carry their roles from one place (both hosts)", function()
    assert.same({ "building profile: p", "lead" }, { build_run.lead_line("build", "profile: p") })
    assert.same({ "cleaning a (Debug)", "lead" }, { build_run.lead_line("clean", "a (Debug)") })
    assert.same({ "configuring profile: p", "lead" }, { build_run.lead_line("configure", "profile: p") })
    assert.same({ "BUILD OK: p", "ok" }, { build_run.ok_line("build", "p") })
    assert.same({ "CLEAN OK: p", "ok" }, { build_run.ok_line("clean", "p") })
    assert.same({ "CONFIGURE OK: p", "ok" }, { build_run.ok_line("configure", "p") })
    assert.same({ "RESET OK: p", "ok" }, { require("loomworks.reset_plan").ok_line({ label = "p" }) })
  end)

  it("the test host prints a runner's command lines before it runs, only with -v", function()
    cc.mode = "never"
    local ran = 0
    local deps = { run_spec = function() ran = ran + 1; return 0 end }
    local spec = { cmd = { "ctest", "--output-on-failure" }, cwd = "/r/b" }
    local r = capture(function()
      cli._test_host({ root = "/r" }, deps, true).spawn(spec, function(code) return code end)
    end)
    assert.equals("    $ ctest --output-on-failure\n    (in /r/b)\n", r.stdout)
    r = capture(function()
      cli._test_host({ root = "/r" }, deps, false).spawn(spec, function(code) return code end)
    end)
    assert.equals("", r.stdout)
    assert.equals(2, ran)
    cc.mode = "auto"
  end)

  it("the test host reports a launch's deploy steps only with -v", function()
    local seen
    local lt = { deploy_sync = function(_, o) seen = o; return true end }
    assert.is_nil(cli._test_host({ root = "/r" }, {}, false).deploy)
    local ok = cli._test_host({ root = "/r" }, {}, true).deploy(lt, function(dok) return dok end)
    assert.is_true(ok)
    assert.is_function(seen.on_step)
  end)

  it("a clean, run or test with -v is routed, its request carrying verbose", function()
    assert.same({ profile = "p", verbose = true }, cli._clean_request({ "clean", "p", "-v" }))
    assert.same({ verbose = true }, cli._clean_request({ "clean", "--verbose" }))
    assert.is_nil(cli._clean_request({ "clean", "p", "q" }))
    assert.same({ profile = "p" }, cli._clean_request({ "clean", "p" }))
    assert.is_true((cli._run_request({ "run", "--verbose" })).verbose)
    assert.is_nil((cli._run_request({ "run", "app" })).verbose)
    assert.same({ extra = {}, verbose = true }, cli._test_request({ "test", "-v" }))
    assert.same({ extra = { "-v" }, profile = "dev", verbose = true },
      cli._test_request({ "test", "dev", "--verbose", "--", "-v" }))
    assert.is_nil(cli._test_request({ "test", "dev" }).verbose)
    for _, a in ipairs({ { "clean", "-v" }, { "test", "-v" }, { "run", "-v" } }) do
      assert.is_true(cli._routed_command(a), a[1])
    end
  end)
end)

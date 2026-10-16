-- Highlighting of lw's own lines (spec §16.7 *Highlighting*): roles → SGR,
-- the per-stream `auto` decision (terminal test, NO_COLOR non-empty only),
-- `--color=auto|always|never` / `--no-color`, and relayed tool output never
-- painted.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cc = require("loomworks.cli_color")
local term = require("loomworks.term")
local cli = require("loomworks.cli")
local overseer = require("loomworks.overseer")

local ESC = "\27["

--- Reset the module state and its test seams.
local function reset()
  cc.mode = "auto"
  cc._isatty, cc._getenv, cc._enable_vt = nil, nil, nil
end

--- Fake environment: `tty` = set of fds that are terminals, `env` = vars.
local function fake(tty, env)
  cc._isatty = function(fd) return tty[fd] == true end
  cc._getenv = function(name) return env[name] end
  cc._enable_vt = function() return true end
end

describe("cli_color role painting", function()
  after_each(reset)

  it("maps each role to its SGR parameters", function()
    local want = {
      lead = "1", reason = "2", command = "2", ok = "32", fail = "31", warn = "33",
    }
    for role, code in pairs(want) do
      assert.equals(ESC .. code .. "m" .. "text" .. ESC .. "0m",
        term.render(cc.paint(role, "text", "stdout", true)), role)
    end
  end)

  it("paints a step header's arrow bold cyan and the rest bold", function()
    local line = cc.header("build", "App")
    assert.equals("==> [build] App", line)
    assert.equals(ESC .. "1;36m==>" .. ESC .. "0m" .. ESC .. "1m [build] App" .. ESC .. "0m",
      term.render(cc.paint("phase", line, "stdout", true)))
  end)

  it("wraps each line of a multi-line text on its own", function()
    assert.equals(ESC .. "31ma" .. ESC .. "0m\n" .. ESC .. "31mb" .. ESC .. "0m\n",
      term.render(cc.paint("fail", "a\nb\n", "stderr", true)))
  end)

  it("leaves the text unchanged with color off, without a role, or for an unknown role", function()
    assert.equals("lw: x", cc.paint("fail", "lw: x", "stderr", false))
    assert.equals("x", cc.paint(nil, "x", "stdout", true))
    assert.equals("x", cc.paint("bogus", "x", "stdout", true))
  end)

  it("still escapes control characters in data inside a painted line", function()
    local s = term.render(cc.paint("ok", "BUILD OK: a\27]0;t\7", "stdout", true))
    assert.equals(ESC .. "32mBUILD OK: a^[]0;t^G" .. ESC .. "0m", s)
  end)
end)

describe("cli_color.enabled", function()
  after_each(reset)

  it("auto tests stdout and stderr separately", function()
    fake({ [2] = true }, {})
    assert.is_false(cc.enabled("stdout"))
    assert.is_true(cc.enabled("stderr"))
    fake({ [1] = true }, {})
    assert.is_true(cc.enabled("stdout"))
    assert.is_false(cc.enabled("stderr"))
  end)

  it("auto enables VT processing on the handle of the stream it colors", function()
    local probed = {}
    fake({ [1] = true, [2] = true }, {})
    cc._enable_vt = function(fd) probed[#probed + 1] = fd; return fd == 1 end
    local stdout, stderr = cc.enabled("stdout"), cc.enabled("stderr")
    if package.config:sub(1, 1) == "\\" then
      assert.same({ 1, 2 }, probed)
      assert.is_true(stdout)
      assert.is_false(stderr) -- VT could not be enabled on stderr: stays plain
    else
      assert.same({}, probed) -- never on a non-Windows host
      assert.is_true(stdout and stderr)
    end
  end)

  it("auto: a non-empty NO_COLOR turns color off, an empty one counts as unset", function()
    fake({ [1] = true, [2] = true }, { NO_COLOR = "1" })
    assert.is_false(cc.enabled("stdout"))
    assert.is_false(cc.enabled("stderr"))
    fake({ [1] = true, [2] = true }, { NO_COLOR = "" })
    assert.is_true(cc.enabled("stdout"))
    assert.is_true(cc.enabled("stderr"))
  end)

  it("auto ignores CI", function()
    fake({ [1] = true }, { CI = "true" })
    assert.is_true(cc.enabled("stdout"))
  end)

  it("always overrides NO_COLOR and a non-terminal", function()
    fake({}, { NO_COLOR = "1" })
    cc.mode = "always"
    assert.is_true(cc.enabled("stdout"))
    assert.is_true(cc.enabled("stderr"))
  end)

  it("never colors even a terminal without NO_COLOR", function()
    fake({ [1] = true, [2] = true }, {})
    cc.mode = "never"
    assert.is_false(cc.enabled("stdout"))
    assert.is_false(cc.enabled("stderr"))
  end)

  it("drives the status palette gate", function()
    fake({}, {})
    cc.mode = "always"
    assert.is_true(cli._stdout_supports_color())
    cc.mode = "never"
    assert.is_false(cli._stdout_supports_color())
  end)

  it("set_from_option accepts auto|always|never and --no-color only", function()
    assert.is_true(cc.set_from_option("--color=always"))
    assert.equals("always", cc.mode)
    assert.is_true(cc.set_from_option("--no-color"))
    assert.equals("never", cc.mode)
    assert.is_true(cc.set_from_option("--color=auto"))
    assert.equals("auto", cc.mode)
    local ok, err = cc.set_from_option("--color=yes")
    assert.is_nil(ok)
    assert.matches("auto, always or never", err)
    assert.equals("auto", cc.mode)
  end)
end)

-- ---------------------------------------------------------------------------
-- The global option through the real dispatcher
-- ---------------------------------------------------------------------------

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, err = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
  return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function make_root()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local t = assert(io.open(root .. "/App/tsconfig.json", "w")); t:write("{}"); t:close()
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  return root
end

--- Run the dispatcher with cmd_build stubbed; return the result + its args.
local function dispatch(root, ...)
  local argv = { ... }
  local saved, args = cli.cmd_build, nil
  cli.cmd_build = function(...)
    for _, v in ipairs({ ... }) do if type(v) == "table" and v[1] then args = v end end
    return 0
  end
  local saved_arg, saved_root = _G.arg, vim.env.LW_ROOT
  _G.arg, vim.env.LW_ROOT = argv, root
  local r = capture(function() cli.main() end)
  _G.arg, vim.env.LW_ROOT = saved_arg, saved_root
  cli.cmd_build = saved
  r.args = args
  return r
end

describe("--color / --no-color global options", function()
  local root = make_root()
  after_each(reset)

  it("--no-color before the command sets never and is not the command's", function()
    local r = dispatch(root, "--no-color", "build", "Dev")
    assert.equals(0, r.exit_code, r.stderr)
    assert.equals("never", cc.mode)
    assert.same({ "build", "Dev" }, r.args)
  end)

  it("--color=<when> among the command's own arguments is recognised", function()
    local r = dispatch(root, "build", "Dev", "--color=always")
    assert.equals(0, r.exit_code, r.stderr)
    assert.equals("always", cc.mode)
    assert.same({ "build", "Dev" }, r.args)
  end)

  it("after -- it is the build tool's argument", function()
    local r = dispatch(root, "build", "Dev", "--", "--color=always")
    assert.equals(0, r.exit_code, r.stderr)
    assert.equals("auto", cc.mode)
    assert.same({ "build", "Dev", "--", "--color=always" }, r.args)
  end)

  it("a bad value is a usage error (exit 2)", function()
    local r = dispatch(root, "--color=sometimes", "build", "Dev")
    assert.equals(2, r.exit_code)
    assert.is_truthy(r.stderr:find("invalid value 'sometimes' for --color", 1, true), r.stderr)
    assert.is_nil(r.args)
  end)

  it("a bare --color is an unknown option (exit 2)", function()
    local r = dispatch(root, "build", "Dev", "--color")
    assert.equals(2, r.exit_code)
    assert.matches("unknown option '%-%-color'", r.stderr)
  end)
end)

-- ---------------------------------------------------------------------------
-- Build output: lw's lines painted by role, relayed tool output untouched
-- ---------------------------------------------------------------------------

describe("build output highlighting", function()
  local orig_plan, orig_spawn
  before_each(function() orig_plan, orig_spawn = overseer.plan_profile_build, cli._run_spec end)
  after_each(function()
    overseer.plan_profile_build, cli._run_spec = orig_plan, orig_spawn
    reset()
  end)

  local TOOL = "[1/2] Building CXX \27[31mobject\27[0m main.o\n"

  local function build(opts)
    overseer.plan_profile_build = function() return { { kind = "build", name = "App", cmd = { "make" } } } end
    cli._run_spec = function() io.write(TOOL); return 0 end
    return capture(function() cli._run_build_steps({ key = "p" }, { root = "/r" }, opts or {}) end)
  end

  it("with --color=always paints lw's lines and relays tool output byte for byte", function()
    cc.mode = "always"
    local r = build()
    assert.equals(ESC .. "1mbuilding profile: p" .. ESC .. "0m\n"
      .. ESC .. "1;36m==>" .. ESC .. "0m" .. ESC .. "1m [build] App" .. ESC .. "0m\n"
      .. TOOL, r.stdout)
  end)

  it("with color off the output is the plain text", function()
    cc.mode = "never"
    local r = build()
    assert.equals("building profile: p\n==> [build] App\n" .. TOOL, r.stdout)
  end)

  it("under --print (quiet) the lines go to stderr and follow stderr's color", function()
    fake({ [1] = true }, {}) -- stdout a terminal, stderr not
    local r = build({ quiet = true })
    assert.equals("building profile: p\n==> [build] App\n", r.stderr)
  end)

  it("a real child's output is relayed unpainted and its environment is not changed", function()
    cc.mode = "always"
    local script = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({
      'io.write("child says \\27[32mhi\\27[0m|" .. tostring(os.getenv("NO_COLOR")) .. "|"',
      '  .. tostring(os.getenv("FORCE_COLOR")) .. "|" .. tostring(os.getenv("CLICOLOR_FORCE")) .. "\\n")',
    }, script)
    local r = capture(function()
      cli._run_spec({ kind = "build", name = "c",
        cmd = { vim.v.progpath, "--clean", "--headless", "-l", script } }, vim.fn.getcwd())
    end)
    local want = "child says \27[32mhi\27[0m|" .. tostring(os.getenv("NO_COLOR")) .. "|"
      .. tostring(os.getenv("FORCE_COLOR")) .. "|" .. tostring(os.getenv("CLICOLOR_FORCE")) .. "\n"
    assert.equals(want, r.stdout:gsub("\r\n", "\n"))
  end)
end)

-- ---------------------------------------------------------------------------
-- Roles beyond the build steps (spec §16.7): plain, per-stream stderr, die,
-- clean and test outcome lines
-- ---------------------------------------------------------------------------

describe("more roles", function()
  local build_run = require("loomworks.build_run")
  local orig_plan, orig_spawn, orig_dirs
  before_each(function()
    orig_plan, orig_spawn, orig_dirs = overseer.plan_profile_clean, cli._run_spec, build_run.profile_build_dirs
  end)
  after_each(function()
    overseer.plan_profile_clean, cli._run_spec, build_run.profile_build_dirs = orig_plan, orig_spawn, orig_dirs
    reset()
  end)

  it("the plain role is never colored", function()
    assert.equals("JUnit: x.xml", cc.paint("plain", "JUnit: x.xml", "stdout", true))
    cc.mode = "always"
    assert.equals("summary", cc.paint("plain", "summary", "stderr"))
  end)

  it("stderr is colored when it is a terminal and stdout is not", function()
    fake({ [2] = true }, {}) -- stderr a terminal, stdout not
    local saved = overseer.plan_profile_build
    overseer.plan_profile_build = function() return { { kind = "build", name = "App", cmd = { "make" } } } end
    cli._run_spec = function() return 0 end
    local r = capture(function() cli._run_build_steps({ key = "p" }, { root = "/r" }, { quiet = true }) end)
    overseer.plan_profile_build = saved
    assert.equals(ESC .. "1mbuilding profile: p" .. ESC .. "0m\n"
      .. ESC .. "1;36m==>" .. ESC .. "0m" .. ESC .. "1m [build] App" .. ESC .. "0m\n", r.stderr)
  end)

  it("die paints its message as a failure on stderr", function()
    cc.mode = "always"
    overseer.plan_profile_clean = function() return {} end
    local ws = { root = "/r", _profiles = { { key = "p" } } }
    local r = capture(function() cli.cmd_clean(ws, { "clean", "p" }) end)
    assert.equals(1, r.exit_code)
    assert.equals(ESC .. "31mlw: nothing to clean for profile 'p' — no configured build directories." .. ESC .. "0m\n",
      r.stderr)
    cc.mode = "never"
    r = capture(function() cli.cmd_clean(ws, { "clean", "p" }) end)
    assert.is_nil(r.stderr:find(ESC, 1, true))
  end)

  it("clean: lead, step header and the CLEAN OK outcome", function()
    cc.mode = "always"
    overseer.plan_profile_clean = function() return { { kind = "clean", name = "App", cmd = { "make", "clean" } } } end
    cli._run_spec = function() return 0 end
    build_run.profile_build_dirs = function() return {} end
    local r = capture(function() cli.cmd_clean({ root = "/r", _profiles = { { key = "p" } } }, { "clean", "p" }) end)
    assert.equals(ESC .. "1mcleaning profile: p" .. ESC .. "0m\n"
      .. ESC .. "1;36m==>" .. ESC .. "0m" .. ESC .. "1m [clean] App" .. ESC .. "0m\n"
      .. ESC .. "32mCLEAN OK: p" .. ESC .. "0m\n", r.stdout)
  end)
end)

describe("a daemon reply's notes (API.md §4.1)", function()
  after_each(reset)

  it("each on stderr, painted by its note_roles entry as in-process; a missing or unknown role is plain", function()
    cc.mode = "always"
    local buf = {}
    local rs = io.stderr
    io.stderr = { write = function(_, s) buf[#buf + 1] = s end }
    local ok, err = pcall(cli._reply_notes, { notes = { "e", "w", "p", "u", "m" },
      note_roles = { "fail", "warn", "plain", "sparkly" } })
    io.stderr = rs
    assert(ok, err)
    assert.equals(ESC .. "31me" .. ESC .. "0m\n" .. ESC .. "33mw" .. ESC .. "0m\np\nu\nm\n", table.concat(buf))
    -- No note_roles at all (an older daemon): every note plain.
    buf = {}
    io.stderr = { write = function(_, s) buf[#buf + 1] = s end }
    ok, err = pcall(cli._reply_notes, { notes = { "a", "b" } })
    io.stderr = rs
    assert(ok, err)
    assert.equals("a\nb\n", table.concat(buf))
  end)
end)

describe("a notification raised while projecting a daemon snapshot", function()
  after_each(reset)

  it("is painted on stderr as the in-process load paints it (fail / warn), info dropped", function()
    cc.mode = "always"
    -- A live daemon of this version that answers the snapshot `ok`; the
    -- projection then raises one notification of each level.
    local seams = {
      { require("loomworks.daemon.runtime"), "select", function()
        return { mode = require("loomworks.daemon.runtime").DAEMON, daemon = true }
      end },
      { cli, "_daemon_workspace_trusted", function() return true end },
      { require("loomworks.daemon.inspect"), "state", function()
        return { kind = "live", handle = { endpoint = "e" } }
      end },
      { require("loomworks.daemon.endpoint"), "check", function() return true end },
      { require("loomworks.daemon.client"), "session", function()
        return { challenge = {}, closed = false, close = function() end }
      end },
      { require("loomworks.daemon.version"), "matches", function() return true end },
      { require("loomworks.daemon.calls"), "request", function(_, _, cb) cb({ outcome = "ok" }) end },
      { require("loomworks.daemon.snapshot"), "project", function(_, _, opts)
        opts.notify("boom", vim.log.levels.ERROR)
        opts.notify("careful", vim.log.levels.WARN)
        opts.notify("chatter", vim.log.levels.INFO)
        return nil
      end },
    }
    local saved = {}
    for i, s in ipairs(seams) do saved[i] = s[1][s[2]]; s[1][s[2]] = s[3] end
    local buf = {}
    local rs = io.stderr
    io.stderr = { write = function(_, s) buf[#buf + 1] = s end }
    local ok, err = pcall(cli._read_projection, "/r", {})
    io.stderr = rs
    for i, s in ipairs(seams) do s[1][s[2]] = saved[i] end
    assert(ok, err)
    assert.equals(ESC .. "31mboom" .. ESC .. "0m\n" .. ESC .. "33mcareful" .. ESC .. "0m\n", table.concat(buf))
  end)
end)

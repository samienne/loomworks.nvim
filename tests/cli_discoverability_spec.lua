-- CLI discoverability (spec §16.7 "Unknown commands", §16.18, §16.38): every
-- everyday command is reachable from inline output — the status footer, the
-- no-workspace page, next-step hints after create/init, empty states — and the
-- `lw help` index lists every command, sub-command and accepted option.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local cli_options = require("loomworks.cli_options")

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(...) for _, s in ipairs({ ... }) do out_buf[#out_buf + 1] = s end end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, err = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
  return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function tempdir()
  local d = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(d, "p")
  return d
end

local function make_root()
  local root = tempdir()
  vim.fn.mkdir(root .. "/App", "p")
  local t = assert(io.open(root .. "/App/tsconfig.json", "w")); t:write("{}"); t:close()
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  return root
end

local function run_main(argv, root)
  local saved_arg, saved_root = _G.arg, vim.env.LW_ROOT
  _G.arg = argv
  vim.env.LW_ROOT = root
  local r = capture(function() cli.main() end)
  _G.arg, vim.env.LW_ROOT = saved_arg, saved_root
  return r
end

local function lines_of(s)
  local t = {}
  for l in (s .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
  return t
end

describe("unknown commands (§16.7)", function()
  local nows, ws
  before_each(function() nows = tempdir(); ws = make_root() end)
  after_each(function() vim.fn.delete(nows, "rf"); vim.fn.delete(ws, "rf") end)

  it("outside a workspace, an unknown command names the typo (exit 2), not a missing workspace", function()
    local r = run_main({ "frobnicate" }, nows)
    assert.equals(2, r.exit_code)
    assert.is_truthy(r.stderr:find("unknown command 'frobnicate' — run `lw help`", 1, true), r.stderr)
    assert.is_nil(r.stderr:find("loomworks.json", 1, true), r.stderr)
  end)

  it("inside a workspace an unknown command also exits 2", function()
    local r = run_main({ "frobnicate" }, ws)
    assert.equals(2, r.exit_code)
    assert.is_truthy(r.stderr:find("unknown command 'frobnicate'", 1, true), r.stderr)
  end)

  it("an option in the command position is an unknown option, inside and outside", function()
    for _, root in ipairs({ nows, ws }) do
      local r = run_main({ "--frob" }, root)
      assert.equals(2, r.exit_code)
      assert.is_truthy(r.stderr:find("unknown option '--frob' — see `lw help`", 1, true), r.stderr)
      assert.is_nil(r.stderr:find("unknown command", 1, true), r.stderr)
    end
  end)

  it("`lw --check` is an unknown option (only `lw status --check` takes it)", function()
    local r = run_main({ "--check" }, ws)
    assert.equals(2, r.exit_code)
    assert.is_truthy(r.stderr:find("unknown option '--check'", 1, true), r.stderr)
  end)

  it("`lw status --check` outside a workspace fails the gate (exit 1), same page as plain status", function()
    -- The no-workspace page's worktree hint comes from a time-bounded (1.5 s)
    -- real git probe; on a loaded CI runner one call can time out while the
    -- next does not, changing the page. Pin the probe's answer ("not a git
    -- repo") so every run renders the same page — what is compared here is
    -- only whether --check changes the rendering.
    local real = cli._main_worktree
    cli._main_worktree = function() return nil, nil, "not-git" end
    local ok, err = pcall(function()
      local plain = run_main({ "status" }, nows)
      assert.equals(0, plain.exit_code)
      local bare = run_main({}, nows)
      assert.equals(0, bare.exit_code)
      assert.equals(plain.stdout, bare.stdout)
      local r = run_main({ "status", "--check" }, nows)
      assert.equals(1, r.exit_code)
      assert.is_truthy(r.stdout:find("no workspace here", 1, true), r.stdout)
      -- --check never changes what is rendered (§16.18).
      assert.equals(plain.stdout, r.stdout)
    end)
    cli._main_worktree = real
    if not ok then error(err, 0) end
  end)

  it("every dispatched command and alias is known; help spellings and host commands too", function()
    for name in pairs(cli_options.COMMANDS) do assert.is_true(cli_options.is_command(name), name) end
    for alias in pairs(cli_options.ALIASES) do assert.is_true(cli_options.is_command(alias), alias) end
    for _, n in ipairs({ "-h", "--help", "-v", "--version", "version", "self-update",
      "install", "bootstrap", "update" }) do
      assert.is_true(cli_options.is_command(n), n)
    end
    assert.is_false(cli_options.is_command("frobnicate"))
    assert.is_false(cli_options.is_command("--frob"))
  end)

  it("`lw <unknown> --help` still prints the general usage, exit 0", function()
    local r = run_main({ "frobnicate", "--help" }, nows)
    assert.equals(0, r.exit_code)
    assert.is_truthy(r.stdout:find("Usage: lw [command] [args]", 1, true))
  end)
end)

describe("status overview (§16.18)", function()
  local root
  before_each(function() root = make_root() end)
  after_each(function() vim.fn.delete(root, "rf") end)

  it("the no-workspace page points at `lw help`; the shared hint (health's lead) does not", function()
    -- Pin the worktree probe (no real, time-bounded git call).
    local real = cli._main_worktree
    cli._main_worktree = function() return nil, nil, "not-git" end
    local ok, r = pcall(capture, function() cli.cmd_status(nil) end)
    cli._main_worktree = real
    assert.is_true(ok, tostring(r))
    assert.is_truthy(r.stdout:find("lw help` for every command.", 1, true), r.stdout)
    local hint = table.concat(cli._worktree_hint({ git = function() return nil end }), "\n")
    assert.is_nil(hint:find("lw help", 1, true), hint)
  end)

  it("ends with the command footer: every everyday command, ≤ 80 columns", function()
    local r = capture(function() cli.cmd_status(root, { can_pull = false }) end)
    local ls = lines_of(r.stdout)
    while ls[#ls] == "" do ls[#ls] = nil end
    local common, index = ls[#ls - 1], ls[#ls]
    assert.equals("Common: build, run, test, clean, reset, health, pull, worktree add, publish", common)
    assert.equals("`lw help` for every command · `lw help <command>` for details.", index)
    for _, l in ipairs({ common, index }) do
      assert.is_true(vim.fn.strdisplaywidth(l) <= 80, l)
    end
    -- Every footer name is a real command.
    for _, n in ipairs(cli.STATUS_COMMON) do
      assert.is_true(cli_options.is_command(n:match("^%S+")), n)
    end
  end)

  it("offers `lw pull` first when there are no profiles and the main checkout has a working copy", function()
    local r = capture(function() cli.cmd_status(root, { can_pull = true }) end)
    assert.is_truthy(r.stdout:find("(no profiles) — `lw pull` copies them from the main checkout", 1, true), r.stdout)
    local pull = r.stdout:find("copy the main checkout's profiles · lw pull", 1, true)
    local create = r.stdout:find("create a profile · lw profile create <set> <tool>  (tools: lw tools)", 1, true)
    assert.is_truthy(pull, r.stdout)
    assert.is_truthy(create, r.stdout)
    assert.is_true(pull < create)
  end)

  it("without a pull source it offers only `lw profile create`", function()
    local r = capture(function() cli.cmd_status(root, { can_pull = false }) end)
    assert.is_truthy(r.stdout:find("(no profiles) — `lw profile create <set> <tool>`", 1, true), r.stdout)
    assert.is_nil(r.stdout:find("lw pull", 1, true) and r.stdout:find("copy the main", 1, true))
  end)
end)

describe("_main_has_working_copy (pull hint detection)", function()
  local function fake_git(top, list)
    return function(_, args)
      if args[1] == "--version" then return "git version 2.40.0" end
      if args[1] == "rev-parse" then return top end
      if args[1] == "worktree" then return list end
    end
  end
  local LIST = "worktree /repo\nHEAD abc\nbranch refs/heads/main\n\n" ..
    "worktree /repo/wt\nHEAD def\nbranch refs/heads/feat\n"

  it("is true in a linked worktree whose main checkout has .nvim/loomworks.user.json", function()
    local seen
    local ok = cli._main_has_working_copy({ dir = "/repo/wt", git = fake_git("/repo/wt", LIST),
      stat = function(p) seen = p; return p == "/repo/.nvim/loomworks.user.json" and {} or nil end })
    assert.is_true(ok)
    assert.equals("/repo/.nvim/loomworks.user.json", seen)
  end)

  it("is false in the main checkout itself, with no working copy, or without git", function()
    assert.is_false(cli._main_has_working_copy({ dir = "/repo", git = fake_git("/repo", LIST),
      stat = function() return {} end }))
    assert.is_false(cli._main_has_working_copy({ dir = "/repo/wt", git = fake_git("/repo/wt", LIST),
      stat = function() return nil end }))
    assert.is_false(cli._main_has_working_copy({ dir = "/repo/wt", git = function() return nil end,
      stat = function() return {} end }))
  end)

  it("a real linked worktree whose main has a working copy gets the pull hint", function()
    if vim.fn.executable("git") ~= 1 then return end
    local main = tempdir()
    local function git(...)
      local out = vim.fn.system(vim.list_extend({ "git", "-C", main }, { ... }))
      assert.equals(0, vim.v.shell_error, out)
    end
    git("init", "-q")
    local f = assert(io.open(main .. "/loomworks.json", "w")); f:write("{}"); f:close()
    git("add", "loomworks.json")
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init")
    local wt = main .. "-wt"
    git("worktree", "add", "-q", wt, "-b", "feat")
    vim.fn.mkdir(main .. "/.nvim", "p")
    local u = assert(io.open(main .. "/.nvim/loomworks.user.json", "w")); u:write("{}"); u:close()
    -- Real git, but with the git-required probe budget (30 s) instead of the
    -- status probe's 1.5 s: on a loaded runner a timed-out probe reads as "no
    -- main checkout" and would fail the positive assertion.
    local git_q = cli._git_query_required
    assert.is_true(cli._main_has_working_copy({ dir = wt, git = git_q }))
    vim.fn.delete(main .. "/.nvim", "rf")
    assert.is_false(cli._main_has_working_copy({ dir = wt, git = git_q }))
    vim.fn.system({ "git", "-C", main, "worktree", "remove", "--force", wt })
    vim.fn.delete(wt, "rf")
    vim.fn.delete(main, "rf")
  end)
end)

describe("next-step and empty-state hints (§16.38)", function()
  local root
  before_each(function() root = make_root() end)
  after_each(function() vim.fn.delete(root, "rf") end)

  it("empty `lw profile list` names create and the listings its operands come from", function()
    local rows = cli._profile_list_rows({ _profiles = {} }, false)
    assert.same({
      "(no profiles defined)",
      "",
      "  create a profile · lw profile create <set> <tool>",
      "  list sets and tools · lw configset list · lw tools",
    }, rows)
  end)

  it("`lw init` names `lw project add` and the quickstart", function()
    local dir = tempdir()
    local saved = vim.env.LW_ROOT
    vim.env.LW_ROOT = dir
    local r = capture(function() cli.cmd_init({ "init" }) end)
    vim.env.LW_ROOT = saved
    vim.fn.delete(dir, "rf")
    assert.is_truthy(r.stdout:find("Next: `lw project add <path>` registers a project", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find("`lw help` has the quickstart", 1, true), r.stdout)
    assert.is_nil(r.stdout:find("editor or manual edit", 1, true))
  end)

  it("`lw project add` names how to map it and where its configurations come from", function()
    vim.fn.mkdir(root .. "/Web", "p")
    local t = assert(io.open(root .. "/Web/tsconfig.json", "w")); t:write("{}"); t:close()
    local r = capture(function() cli.cmd_project("add", root, root .. "/Web", "typescript", nil, { "project", "add" }) end)
    assert.is_truthy(r.stdout:find("Map it into a configuration set to build it:", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find("lw config list Web", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find("lw configset create <name> Web=<config>", 1, true), r.stdout)
  end)

  it("`lw config add` offers `configset map` once a set exists", function()
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } },
      configuration_sets = { S = { App = "variant:default" } } })); f:close()
    local r = capture(function() cli.cmd_configuration("add", root, "App", "Mine", "variant:default") end)
    assert.is_truthy(r.stdout:find("lw configset map <set> App Mine", 1, true), r.stdout)
  end)

  it("`lw configset create` names `lw tools`", function()
    local r = capture(function() cli.cmd_cset("create", root, { "configset", "create", "S", "App=variant:default" }) end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.is_truthy(r.stdout:find("to build it (`lw tools` lists tools).", 1, true), r.stdout)
  end)

  it("`lw profile remove` points at `lw reset --all`, never the dead-end `lw clean`", function()
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } },
      configuration_sets = { S = { App = "variant:default" } } })); f:close()
    capture(function() cli.cmd_profile_create(root, { "profile", "create", "S" }) end)
    local r = capture(function() cli.cmd_profile_remove(root, { "profile", "remove", "S" }) end)
    assert.is_truthy(r.stdout:find("`lw reset --all` deletes them", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find("every other profile's builds", 1, true), r.stdout)
    assert.is_nil(r.stdout:find("lw clean", 1, true), r.stdout)
  end)

  it("`lw profile create` names building it and making it the default", function()
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } },
      configuration_sets = { S = { App = "variant:default" } } })); f:close()
    local r = capture(function() cli.cmd_profile_create(root, { "profile", "create", "S" }) end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.is_truthy(r.stdout:find("build it:          lw build S", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find("make it default:   lw profile select S", 1, true), r.stdout)
  end)

  it("`lw profile create --activate` names a bare `lw build` and no select", function()
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } },
      configuration_sets = { S = { App = "variant:default" } } })); f:close()
    local r = capture(function() cli.cmd_profile_create(root, { "profile", "create", "S", "-a" }) end)
    assert.is_truthy(r.stdout:find("build it:          lw build\n", 1, true), r.stdout)
    assert.is_nil(r.stdout:find("make it default", 1, true), r.stdout)
  end)

  it("`lw profile show` names a non-active profile and offers describe when none is set", function()
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } },
      configuration_sets = { S = { App = "variant:default" } } })); f:close()
    capture(function() cli.cmd_profile_create(root, { "profile", "create", "S" }) end)
    local r = capture(function() cli.cmd_profile_show(root, "S") end)
    assert.is_truthy(r.stdout:find("build / test · lw build S · lw test S", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find("start over (delete its build dirs) · lw reset S", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find("make it the default · lw profile select S", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find('describe it · lw profile describe S -m "<text>"', 1, true), r.stdout)
    assert.is_truthy(r.stdout:find("run a target · lw run S <target>", 1, true), r.stdout)
    assert.is_nil(r.stdout:find("· lw build\n", 1, true), r.stdout)
  end)

  it("`lw profile show` of the active, described profile uses the operand-less forms", function()
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } },
      configuration_sets = { S = { App = "variant:default" } } })); f:close()
    capture(function() cli.cmd_profile_create(root, { "profile", "create", "S", "--activate" }) end)
    capture(function() cli.cmd_profile("describe", root, { "profile", "describe", "S", "Mine." }) end)
    local r = capture(function() cli.cmd_profile_show(root, nil) end)
    assert.is_truthy(r.stdout:find("build / test · lw build · lw test", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find("switch the profile · lw profile select", 1, true), r.stdout)
    assert.is_nil(r.stdout:find("describe it", 1, true), r.stdout)
  end)
end)

describe("`lw help` index completeness (§16.38)", function()
  local index = capture(function() cli.cmd_help(nil) end).stdout
  -- The command list: from "Usage:" up to the Quickstart heading.
  local list = index:match("Usage: lw %[command%] %[args%]\n(.-)\nQuickstart")
  assert(list, "command list not found")
  local entries = {} -- command name -> its text (first line + continuation lines)
  local cur
  for _, l in ipairs(lines_of(list)) do
    local name = l:match("^  ([%w][%w-]*)")
    if name then
      cur = name
      entries[cur] = (entries[cur] or "") .. l .. "\n"
    elseif cur and l:match("^%s%s%s%s+%S") then
      entries[cur] = entries[cur] .. l .. "\n"
    end
  end

  it("lists every command lw dispatches", function()
    for name in pairs(cli_options.COMMANDS) do
      local listed = entries[name] or (name == "profiles" and entries.profile)
      assert.is_truthy(listed, "`lw help` does not list `" .. name .. "`")
    end
    for _, host in ipairs({ "version", "install", "self-update", "bootstrap" }) do
      assert.is_truthy(entries[host], host)
    end
  end)

  it("lists every sub-command of each command", function()
    for name, entry in pairs(cli_options.COMMANDS) do
      if entry.subs then
        local text = entries[name] .. (name == "target" and "" or "")
        for sub in pairs(entry.subs) do
          assert.is_truthy(text:find("%f[%w]" .. sub:gsub("%-", "%%-") .. "%f[^%w]"),
            "`lw help` entry for `" .. name .. "` omits `" .. sub .. "`:\n" .. text)
        end
      end
    end
  end)

  it("indexes the topics that are not commands", function()
    for _, topic in ipairs({ "agent", "ci", "cache", "describe", "launcher", "submodules" }) do
      local line = index:match("Topics %(`lw help <topic>`%):[^\n]*")
      assert.is_truthy(line and line:find("%f[%w]" .. topic .. "%f[^%w]"), topic)
    end
  end)

  it("the quickstart names the set, not a tool, as `profile create`'s operand", function()
    assert.is_truthy(index:find("lw profile create <set> <tool>", 1, true))
    assert.is_nil(index:find("lw profile create <name> <tool>", 1, true))
  end)

  -- Options accepted only for compatibility as no-ops (§16.38 allows them to
  -- stay undocumented).
  local NOOP = { health = { ["--force"] = true, ["--refresh"] = true },
    ["worktree add"] = { ["--pull"] = true } }

  local function options_of(spec)
    local opts = {}
    for o in pairs(spec.flags or {}) do opts[#opts + 1] = o end
    for o in pairs(spec.valued or {}) do opts[#opts + 1] = o end
    for _, p in ipairs(spec.eq or {}) do opts[#opts + 1] = (p:gsub("=$", "")) end
    return opts
  end

  it("documents every accepted option in its command's help topic", function()
    local missing = {}
    -- The describe text sources (and `-m` on create verbs) are documented
    -- once, in `lw help describe`, which every describe entry points at.
    local describe_topic = capture(function() cli.cmd_help("describe") end).stdout
    local function check(cmd, label, spec)
      if not spec or spec.permissive then return end
      local topic = capture(function() cli.cmd_help(cmd) end).stdout
      local seen = {}
      for _, o in ipairs(options_of(spec)) do
        local noop = NOOP[label] and NOOP[label][o]
        local pat = "%f[%w-]" .. o:gsub("%-", "%%-") .. "%f[^%w-]"
        if not noop and not seen[o] and not topic:find(pat) and not describe_topic:find(pat) then
          missing[#missing + 1] = label .. " " .. o
        end
        seen[o] = true
      end
    end
    for name, entry in pairs(cli_options.COMMANDS) do
      if name ~= "profiles" then
        if entry.subs then
          check(name, name, entry.default)
          for sub, s in pairs(entry.subs) do check(name, name .. " " .. sub, s) end
        else
          check(name, name, entry)
        end
      end
    end
    table.sort(missing)
    assert.same({}, missing)
  end)

  it("a usage error listing `config`'s sub-commands lists all of them", function()
    local root = make_root()
    local r = capture(function() cli.cmd_configuration("frob", root) end)
    vim.fn.delete(root, "rf")
    for sub in pairs(cli_options.COMMANDS.config.subs) do
      assert.is_truthy(r.stderr:find("%f[%w]" .. sub .. "%f[^%w]"), sub .. ": " .. r.stderr)
    end
  end)

  it("`lw help settings` lists the release-notes key", function()
    local t = capture(function() cli.cmd_help("settings") end).stdout
    assert.is_truthy(t:find("\n  release-notes ", 1, true), t)
  end)
end)

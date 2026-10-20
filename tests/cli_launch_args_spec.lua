-- How options and arguments reach `lw launch` (spec §16.7 "Unknown options",
-- §16.35). Every case drives the REAL dispatcher (`cli.main`: global-option
-- split, unknown-option check, then the handler) against a fresh workspace and
-- asserts the exit code and the stored launch configs. A failing case must
-- leave every launch config exactly as it was.
--
-- Regressions (tester report, Windows/Git Bash):
--   * `lw launch add P n --from-target T … -- --x=1` stored args `["--","--x=1"]`:
--     a target-backed add has no command token, so its `--` is lw's separator
--     and is dropped.
--   * `lw launch set P n --description text` replaced the args with
--     `["--description","text"]`: an unknown option before `--` on `set` is a
--     usage error (exit 2) and nothing changes.
--
-- Option values (spec §16.7 "Option values"): a valued option takes the next
-- token or `--opt=value`; a missing value, a single-valued option given twice
-- and `--command` with `--from-target` are usage errors (exit 2); every usage
-- error exits 2 and changes nothing.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

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
  return { exit_code = exit_code or 0, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

--- Run `lw <argv…>` through the real dispatcher in `root`.
local function lw(root, argv)
  local saved_arg, saved_root = _G.arg, vim.env.LW_ROOT
  _G.arg, vim.env.LW_ROOT = argv, root
  local r = capture(function() cli.main() end)
  _G.arg, vim.env.LW_ROOT = saved_arg, saved_root
  return r
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a"); f:close()
  return vim.json.decode(c)
end

--- The App project's launch table as stored in the working copy.
local function launches(root)
  local u = read_json(root .. "/.nvim/loomworks.user.json") or {}
  local p = u.projects and u.projects.App
  return (p and p.launch) or {}
end

--- The fields a launch CLI writes, with an empty args/env read as absent.
local FIELDS = { "command", "target", "args", "working_dir", "env", "description" }
local function view(cfg)
  if type(cfg) ~= "table" then return nil end
  local v = {}
  for _, k in ipairs(FIELDS) do
    local x = cfg[k]
    if type(x) == "table" and next(x) == nil then x = nil end
    v[k] = x
  end
  return v
end

-- Seeded before every case: one command-type and one target-backed config.
local SEED = {
  demo = { command = "node", args = { "a.js" }, working_dir = "wd0", env = { K0 = "v0" },
    description = "Seed" },
  tgt = { target = "editor", args = { "--seed" }, working_dir = "wd0", env = { K0 = "v0" },
    description = "Seed" },
}

local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/App/tsconfig.json", "w")); f:write("{}"); f:close()
  f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  local ws = assert(cli._load_workspace(root, false))
  local proj
  for _, p in pairs(ws._projects) do if p.key == "App" then proj = p end end
  for name, cfg in pairs(SEED) do
    assert(proj:save_launch_config(name, vim.deepcopy(cfg)))
  end
  return root
end

--- Expected config: the seed for `base` with `over` applied (vim.NIL clears).
local function seed_with(base, over)
  local c = vim.deepcopy(SEED[base])
  for k, v in pairs(over or {}) do
    if v == vim.NIL then c[k] = nil else c[k] = v end
  end
  return view(c)
end

--- Run one case. `c.argv` is the command line after `lw`; `c.exit` the exit
--- code; `c.refused` an option the unknown-option check must name; `c.name` +
--- `c.cfg` the config expected afterwards (`c.cfg == false`: it must not
--- exist); `c.check(r)` any extra assertion. A non-zero exit means nothing
--- changed.
local function run_case(c)
  local root = make_ws()
  local before = vim.deepcopy(launches(root))
  local r = lw(root, c.argv)
  assert.equals(c.exit or 0, r.exit_code, r.stderr .. r.stdout)
  if c.refused then
    assert.is_truthy(r.stderr:find("unknown option '" .. c.refused .. "'", 1, true), r.stderr)
  end
  if (c.exit or 0) ~= 0 then
    assert.same(before, launches(root))
  end
  if c.name then
    local got = launches(root)[c.name]
    if c.cfg == false then
      assert.is_nil(got)
    else
      assert.same(c.cfg, view(got))
    end
  end
  if c.check then c.check(r, root) end
end

local function cases(title, list)
  describe(title, function()
    for _, c in ipairs(list) do
      if c.pending then
        pending(table.concat(c.argv, " ") .. "  — " .. c.pending)
      else
        it(table.concat(c.argv, " ") .. (c.why and ("  — " .. c.why) or ""), function() run_case(c) end)
      end
    end
  end)
end

local NEW = function(t) return view(t) end

-- ── lw launch add <project> <name> <command> [args…] ────────────────────────
cases("lw launch add (command)", {
  { argv = { "launch", "add", "App", "x", "node", "a.js" },
    name = "x", cfg = NEW({ command = "node", args = { "a.js" } }) },
  { argv = { "launch", "create", "App", "x", "node" }, why = "alias, no args",
    name = "x", cfg = NEW({ command = "node" }) },
  { argv = { "launch", "add", "App", "x", "--working-dir", "w", "--env", "A=1",
      "--description", "D", "node", "a.js" }, why = "flags before the command",
    name = "x", cfg = NEW({ command = "node", args = { "a.js" }, working_dir = "w",
      env = { A = "1" }, description = "D" }) },
  { argv = { "launch", "add", "--no-input", "App", "x", "--cwd", "w", "node" },
    why = "a global between the positionals; --cwd alias",
    name = "x", cfg = NEW({ command = "node", working_dir = "w" }) },
  { argv = { "launch", "add", "App", "x", "--description=D", "node" }, why = "--flag=value",
    name = "x", cfg = NEW({ command = "node", description = "D" }) },
  { argv = { "launch", "add", "App", "x", "--description", "P1", "--description", "P2", "node" },
    why = "repeatable description: paragraphs",
    name = "x", cfg = NEW({ command = "node", description = "P1\n\nP2" }) },
  { argv = { "launch", "add", "App", "x", "--env", "A=1", "--env", "B=2", "--env", "C=x=y", "node" },
    why = "repeated --env; value with '='",
    name = "x", cfg = NEW({ command = "node", env = { A = "1", B = "2", C = "x=y" } }) },
  { argv = { "launch", "add", "App", "x", "node", "a b", "k=v", "-x", "" },
    why = "args with a space, '=', a leading '-', an empty string",
    name = "x", cfg = NEW({ command = "node", args = { "a b", "k=v", "-x", "" } }) },
  { argv = { "launch", "add", "App", "x", "--", "node", "--dev" }, why = "-- before the command ends lw's options",
    name = "x", cfg = NEW({ command = "node", args = { "--dev" } }) },
  { argv = { "launch", "add", "App", "x", "npm", "run", "dev", "--", "--port", "1" },
    why = "-- after the command is kept",
    name = "x", cfg = NEW({ command = "npm", args = { "run", "dev", "--", "--port", "1" } }) },
  { argv = { "launch", "add", "App", "x", "node", "--" }, why = "-- after the command, nothing after it",
    name = "x", cfg = NEW({ command = "node", args = { "--" } }) },
  { argv = { "launch", "add", "App", "x", "node", "--", "--", "--flag" }, why = "-- -- --flag after the command",
    name = "x", cfg = NEW({ command = "node", args = { "--", "--", "--flag" } }) },
  { argv = { "--no-input", "launch", "add", "App", "x", "node" }, why = "global before the subcommand",
    name = "x", cfg = NEW({ command = "node" }) },
  { argv = { "launch", "add", "App", "x", "--non-interactive", "node" }, why = "global before the command is lw's",
    name = "x", cfg = NEW({ command = "node" }) },
  { argv = { "launch", "add", "App", "x", "node", "--no-input", "--bogus" },
    why = "after the command a global / unknown option is the program's",
    name = "x", cfg = NEW({ command = "node", args = { "--no-input", "--bogus" } }) },
  { argv = { "launch", "add", "App", "x", "--bogus", "node" }, exit = 2, refused = "--bogus",
    name = "x", cfg = false },
  { argv = { "launch", "add", "App", "x", "-v", "node" }, exit = 2, refused = "-v",
    why = "a short unknown option", name = "x", cfg = false },
  { argv = { "launch", "add", "App", "x", "--description" }, exit = 2, why = "missing value",
    name = "x", cfg = false },
  { argv = { "launch", "add", "App", "x", "--env" }, exit = 2, why = "missing value",
    name = "x", cfg = false },
  { argv = { "launch", "add", "App", "x", "--env", "NOEQ", "node" }, exit = 2, why = "--env without '='",
    name = "x", cfg = false },
  { argv = { "launch", "add", "App", "x" }, exit = 2, why = "no command", name = "x", cfg = false },
  { argv = { "launch", "add", "App", "x", "--working-dir=w", "--env=K=a=b", "node" }, why = "--opt=value",
    name = "x", cfg = NEW({ command = "node", working_dir = "w", env = { K = "a=b" } }) },
  { argv = { "launch", "add", "App", "x", "--cwd=--w", "node" }, why = "a value starting with -- needs =",
    name = "x", cfg = NEW({ command = "node", working_dir = "--w" }) },
  { argv = { "launch", "add", "App", "x", "--working-dir", "", "node" }, why = "an empty value: no working dir",
    name = "x", cfg = NEW({ command = "node" }) },
  { argv = { "launch", "add", "App", "x", "--working-dir", "a", "--working-dir", "b", "node" }, exit = 2,
    why = "a single-valued option given twice", name = "x", cfg = false },
  { argv = { "launch", "add", "App", "x", "--cwd", "a", "--working-dir", "b", "node" }, exit = 2,
    why = "the alias pair given together", name = "x", cfg = false },
  { argv = { "launch", "add", "App", "x", "node", "a.js", "--env", "A=1" },
    why = "lw options after the command are the program's",
    name = "x", cfg = NEW({ command = "node", args = { "a.js", "--env", "A=1" } }) },
  { argv = { "launch", "add", "App", "x", "--working-dir" }, exit = 2, why = "missing value",
    name = "x", cfg = false },
  { argv = { "launch", "add", "App", "x", "--working-dir", "--env", "A=1", "node" }, exit = 2,
    why = "a value starting with -- is a missing value", name = "x", cfg = false },
  { argv = { "launch", "add", "App", "x", "--working-dir", "--", "node" }, exit = 2,
    why = "-- is not a value", name = "x", cfg = false },
  { argv = { "launch", "add", "App", "x", "--working-dir", "--no-input", "node" }, exit = 2,
    why = "a global option is not a value", name = "x", cfg = false },
})

-- ── lw launch add <project> <name> --from-target <target> ───────────────────
cases("lw launch add --from-target", {
  { argv = { "launch", "add", "App", "t", "--from-target", "editor" },
    name = "t", cfg = NEW({ target = "editor" }) },
  { argv = { "--no-input", "launch", "add", "App", "t", "--from-target", "editor", "--working-dir",
      "EditorQt/bin/windows64", "--description", "Schema", "--", "--use-scene-json-schema=true" },
    why = "tester report: the -- is lw's separator, not an arg",
    name = "t", cfg = NEW({ target = "editor", working_dir = "EditorQt/bin/windows64",
      description = "Schema", args = { "--use-scene-json-schema=true" } }) },
  { argv = { "launch", "add", "App", "t", "--from-target", "editor", "--" }, why = "-- with nothing after it",
    name = "t", cfg = NEW({ target = "editor" }) },
  { argv = { "launch", "add", "App", "t", "--from-target", "editor", "--", "--", "--flag" },
    why = "only the first -- is lw's",
    name = "t", cfg = NEW({ target = "editor", args = { "--", "--flag" } }) },
  { argv = { "launch", "add", "App", "t", "--env", "A=1", "--from-target", "editor", "--env", "B=2",
      "--description=D", "--cwd", "w" }, why = "flags before and after the target; repeated --env; --flag=value",
    name = "t", cfg = NEW({ target = "editor", env = { A = "1", B = "2" }, description = "D",
      working_dir = "w" }) },
  { argv = { "launch", "add", "App", "t", "--from-target", "editor", "--", "a b", "k=v", "-x", "" },
    why = "args with a space, '=', a leading '-', an empty string",
    name = "t", cfg = NEW({ target = "editor", args = { "a b", "k=v", "-x", "" } }) },
  { argv = { "launch", "add", "App", "t", "--from-target", "editor", "--no-input", "--", "--x" },
    why = "a global before -- is lw's",
    name = "t", cfg = NEW({ target = "editor", args = { "--x" } }) },
  { argv = { "launch", "add", "App", "t", "--from-target", "editor", "--", "--no-input", "--bogus" },
    why = "after -- a global / unknown option is the program's",
    name = "t", cfg = NEW({ target = "editor", args = { "--no-input", "--bogus" } }) },
  { argv = { "launch", "add", "App", "t", "--from-target", "editor", "--theme", "demo" }, exit = 2,
    refused = "--theme", why = "unknown option before --", name = "t", cfg = false },
  { argv = { "launch", "add", "App", "t", "--from-target", "editor", "--description", "D",
      "--use-scene-json-schema=true" }, exit = 2, refused = "--use-scene-json-schema=true",
    why = "unknown option before --", name = "t", cfg = false },
  { argv = { "launch", "add", "App", "t", "--from-target" }, exit = 2, why = "missing target",
    name = "t", cfg = false },
  { argv = { "launch", "add", "App", "t", "--from-target", "editor", "a", "b" }, exit = 2,
    why = "a bare token before -- is refused", name = "t", cfg = false,
    check = function(r) assert.is_truthy(r.stderr:find("after `--`", 1, true), r.stderr) end },
  { argv = { "launch", "add", "App", "t", "--from-target", "a", "--from-target", "b" }, exit = 2,
    why = "given twice", name = "t", cfg = false },
  { argv = { "launch", "add", "App", "t", "--from-target=editor", "--", "--x" }, why = "--from-target=",
    name = "t", cfg = NEW({ target = "editor", args = { "--x" } }) },
  { argv = { "launch", "add", "App", "t", "--from-target", "" }, exit = 2, why = "empty target",
    name = "t", cfg = false },
})

-- ── lw launch set ───────────────────────────────────────────────────────────
cases("lw launch set", {
  { argv = { "--no-input", "launch", "set", "App", "demo", "--description", "text" },
    why = "tester report: set takes --description; the args are kept",
    name = "demo", cfg = seed_with("demo", { description = "text" }) },
  { argv = { "launch", "set", "App", "demo", "b.js", "--bogus" }, exit = 2, refused = "--bogus",
    why = "unknown option after bare args", name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "demo", "-x" }, exit = 2, refused = "-x",
    why = "a dash arg needs --", name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "demo", "--working-dir=w", "--env=A=1" }, why = "--opt=value",
    name = "demo", cfg = seed_with("demo", { working_dir = "w", env = { K0 = "v0", A = "1" } }) },
  { argv = { "launch", "set", "App", "demo", "--", "--bogus", "-x" }, why = "unknown options after -- are args",
    name = "demo", cfg = seed_with("demo", { args = { "--bogus", "-x" } }) },
  { argv = { "launch", "set", "App", "demo" }, exit = 2, why = "nothing to change: args kept",
    name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "demo", "--working-dir", "w" }, why = "args kept",
    name = "demo", cfg = seed_with("demo", { working_dir = "w" }) },
  { argv = { "launch", "edit", "App", "demo", "--cwd", "w" }, why = "alias; --cwd",
    name = "demo", cfg = seed_with("demo", { working_dir = "w" }) },
  { argv = { "launch", "set", "App", "demo", "--clear-working-dir" },
    name = "demo", cfg = seed_with("demo", { working_dir = vim.NIL }) },
  { argv = { "launch", "set", "App", "demo", "--env", "A=1", "--env", "B=x=y" }, why = "repeated --env; '=' in value",
    name = "demo", cfg = seed_with("demo", { env = { K0 = "v0", A = "1", B = "x=y" } }) },
  { argv = { "launch", "set", "App", "demo", "--unset-env", "K0" },
    name = "demo", cfg = seed_with("demo", { env = vim.NIL }) },
  { argv = { "launch", "set", "App", "demo", "b.js", "c" }, why = "bare args replace the list",
    name = "demo", cfg = seed_with("demo", { args = { "b.js", "c" } }) },
  { argv = { "launch", "set", "App", "demo", "b.js", "--working-dir", "w", "c" },
    why = "bare args around a flag",
    name = "demo", cfg = seed_with("demo", { args = { "b.js", "c" }, working_dir = "w" }) },
  { argv = { "launch", "set", "App", "demo", "--working-dir", "w", "--", "--x", "-y" },
    why = "flag, then -- args",
    name = "demo", cfg = seed_with("demo", { args = { "--x", "-y" }, working_dir = "w" }) },
  { argv = { "launch", "set", "App", "demo", "b.js", "--", "-x" }, why = "bare args and -- args join",
    name = "demo", cfg = seed_with("demo", { args = { "b.js", "-x" } }) },
  { argv = { "launch", "set", "App", "demo", "--", "--", "--x" }, why = "only the first -- is lw's",
    name = "demo", cfg = seed_with("demo", { args = { "--", "--x" } }) },
  { argv = { "launch", "set", "App", "demo", "--", "a b", "k=v", "" },
    why = "args with a space, '=', an empty string",
    name = "demo", cfg = seed_with("demo", { args = { "a b", "k=v", "" } }) },
  { argv = { "launch", "set", "App", "demo", "--" }, why = "-- with nothing after: no arguments",
    name = "demo", cfg = seed_with("demo", { args = vim.NIL }) },
  { argv = { "launch", "set", "App", "demo", "--clear-args" },
    name = "demo", cfg = seed_with("demo", { args = vim.NIL }) },
  { argv = { "launch", "set", "App", "demo", "--working-dir", "w", "--no-input" },
    why = "a global before -- is lw's, not an arg",
    name = "demo", cfg = seed_with("demo", { working_dir = "w" }) },
  { argv = { "--local", "launch", "set", "App", "demo", "--", "--no-input" },
    why = "a global after -- is an arg",
    name = "demo", cfg = seed_with("demo", { args = { "--no-input" } }) },
  { argv = { "launch", "set", "App", "demo", "--command", "deno" },
    name = "demo", cfg = seed_with("demo", { command = "deno" }) },
  { argv = { "launch", "set", "App", "demo", "--from-target", "editor" }, why = "switch kind",
    name = "demo", cfg = seed_with("demo", { command = vim.NIL, target = "editor" }) },
  { argv = { "launch", "set", "App", "tgt", "--command", "deno" }, why = "switch kind",
    name = "tgt", cfg = seed_with("tgt", { target = vim.NIL, command = "deno" }) },
  { argv = { "launch", "set", "App:demo", "--working-dir", "w" }, why = "<project>:<name>",
    name = "demo", cfg = seed_with("demo", { working_dir = "w" }) },
  { argv = { "launch", "set", "--project", "App", "--launch", "demo", "--working-dir", "w" },
    why = "--project/--launch",
    name = "demo", cfg = seed_with("demo", { working_dir = "w" }) },
  { argv = { "launch", "set", "App", "demo", "--env" }, exit = 2, why = "missing value",
    name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "demo", "--unset-env" }, exit = 2, why = "missing value",
    name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "nope", "--working-dir", "w" }, exit = 1, why = "unknown launch",
    name = "nope", cfg = false },
  { argv = { "launch", "set", "App", "demo", "--working-dir" }, exit = 2, why = "missing value",
    name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "demo", "--command" }, exit = 2, why = "missing value",
    name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "demo", "--from-target", "--", "x" }, exit = 2, why = "-- is not a value",
    name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "demo", "--working-dir", "--env", "A=1" }, exit = 2,
    why = "a value starting with -- is a missing value", name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "demo", "--working-dir", "a", "--working-dir", "b" }, exit = 2,
    why = "given twice", name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "demo", "--cwd", "a", "--working-dir", "b" }, exit = 2,
    why = "the alias pair", name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "demo", "--working-dir", "D", "--clear-working-dir" }, exit = 2,
    why = "a value and its clear", name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "demo", "--command", "a", "--from-target", "t" }, exit = 2,
    why = "--command and --from-target are one choice", name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "demo", "--command", "" }, exit = 2, why = "empty command",
    name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "demo", "--from-target", "" }, exit = 2, why = "empty target",
    name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "set", "App", "demo", "--working-dir", "" }, why = "an empty value clears",
    name = "demo", cfg = seed_with("demo", { working_dir = vim.NIL }) },
  { argv = { "launch", "set", "App", "demo", "--description", "D" },
    name = "demo", cfg = seed_with("demo", { description = "D" }) },
  { argv = { "launch", "set", "App", "demo", "--description", "P1", "--description=P2" },
    why = "repeatable; replaces the whole description",
    name = "demo", cfg = seed_with("demo", { description = "P1\n\nP2" }) },
  { argv = { "launch", "set", "App", "demo", "--description", "" }, why = "an empty value clears",
    name = "demo", cfg = seed_with("demo", { description = vim.NIL }) },
})

-- ── lw launch describe ──────────────────────────────────────────────────────
cases("lw launch describe", {
  { argv = { "launch", "describe", "App", "demo", "New text" },
    name = "demo", cfg = seed_with("demo", { description = "New text" }) },
  { argv = { "launch", "describe", "App", "demo", "-m", "P1", "-m", "P2" }, why = "repeated -m",
    name = "demo", cfg = seed_with("demo", { description = "P1\n\nP2" }) },
  { argv = { "launch", "describe", "App", "demo", "--message=P1", "-m=P2" }, why = "--flag=value",
    name = "demo", cfg = seed_with("demo", { description = "P1\n\nP2" }) },
  { argv = { "launch", "describe", "--project", "App", "--launch", "demo", "-m", "X" },
    name = "demo", cfg = seed_with("demo", { description = "X" }) },
  { argv = { "launch", "describe", "-m", "X", "--project", "App", "--launch", "demo" },
    why = "flags before the address flags",
    name = "demo", cfg = seed_with("demo", { description = "X" }) },
  { argv = { "--no-input", "launch", "describe", "App", "demo", "-m", "X", "--non-interactive" },
    why = "globals before and after",
    name = "demo", cfg = seed_with("demo", { description = "X" }) },
  { argv = { "launch", "describe", "App", "demo", "--clear" },
    name = "demo", cfg = seed_with("demo", { description = vim.NIL }) },
  { argv = { "launch", "describe", "App", "demo", "--json" }, why = "read form changes nothing",
    name = "demo", cfg = seed_with("demo"),
    check = function(r) assert.equals("Seed", vim.json.decode(r.stdout).summary) end },
  { argv = { "launch", "describe", "App", "demo", "--bogus" }, exit = 2, refused = "--bogus",
    name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "describe", "App", "demo", "-m" }, exit = 2, why = "missing value",
    name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "describe", "App", "demo", "a", "b" }, exit = 2, why = "text must be one argument",
    name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "describe", "App", "demo", "-m", "X", "--clear" }, exit = 2,
    why = "--clear with a description", name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "describe", "-m", "X", "App", "demo" }, why = "-m before the positionals",
    name = "demo", cfg = seed_with("demo", { description = "X" }) },
  { argv = { "launch", "describe", "App", "demo", "--", "-starts-with-dash" }, why = "-- ends lw's options",
    name = "demo", cfg = seed_with("demo", { description = "-starts-with-dash" }) },
  { argv = { "launch", "describe", "App", "demo", "--", "--x", "y" }, exit = 2,
    why = "one text operand after --", name = "demo", cfg = seed_with("demo") },
})

-- ── lw launch show / remove / rename / list ─────────────────────────────────
cases("lw launch show / remove / rename / list", {
  { argv = { "launch", "show", "App", "demo", "--json" }, name = "demo", cfg = seed_with("demo"),
    check = function(r) assert.same({ "a.js" }, vim.json.decode(r.stdout).args) end },
  { argv = { "--no-input", "launch", "show", "--project", "App", "--launch", "demo", "--json",
      "--local" }, name = "demo", cfg = seed_with("demo"),
    check = function(r) assert.equals("wd0", vim.json.decode(r.stdout).working_dir) end },
  { argv = { "launch", "show", "App:demo" }, name = "demo", cfg = seed_with("demo"),
    check = function(r) assert.is_truthy(r.stdout:find("command      node", 1, true)) end },
  { argv = { "launch", "show", "App", "demo", "--bogus" }, exit = 2, refused = "--bogus" },
  { argv = { "launch", "remove", "App", "demo" }, name = "demo", cfg = false },
  { argv = { "launch", "rm", "App:demo", "--no-input" }, name = "demo", cfg = false },
  { argv = { "launch", "remove", "--project", "App", "--launch", "demo" }, name = "demo", cfg = false },
  { argv = { "launch", "remove", "App", "demo", "--bogus" }, exit = 2, refused = "--bogus",
    name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "rename", "App", "demo", "d2" }, name = "d2", cfg = seed_with("demo") },
  { argv = { "--no-input", "launch", "mv", "App", "demo", "d2", "--local" }, name = "d2", cfg = seed_with("demo") },
  { argv = { "launch", "rename", "App", "demo", "d2", "--force" }, exit = 2, refused = "--force",
    name = "d2", cfg = false },
  { argv = { "launch", "rename", "App", "demo" }, exit = 2, why = "missing <new>",
    name = "demo", cfg = seed_with("demo") },
  { argv = { "launch", "list", "App" }, name = "demo", cfg = seed_with("demo"),
    check = function(r) assert.is_truthy(r.stdout:find("demo", 1, true)) end },
  { argv = { "launch", "list", "--bogus" }, exit = 2, refused = "--bogus" },
  { argv = { "launch", "show", "--json", "App", "demo" }, why = "--json before the address",
    name = "demo", cfg = seed_with("demo"),
    check = function(r) assert.same({ "a.js" }, vim.json.decode(r.stdout).args) end },
})

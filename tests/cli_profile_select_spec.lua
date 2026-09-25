-- `lw profile select` scripting + the non-interactive profile rule (§16.3):
--   * `lw profile select <name>` works WITHOUT a terminal (explicit name → no
--     prompt); only the bare picker needs one;
--   * `lw profile select --none` clears the active profile (user.json);
--   * re-selecting the active profile / clearing with none active says
--     `(unchanged)` and writes nothing;
--   * a non-interactive build-shaped invocation with no profile is ALWAYS an
--     error — even with exactly one profile — and the error lists the profiles
--     and points at `lw profile query`.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

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

local function user_path(root) return root .. "/.nvim/loomworks.user.json" end

local function read_user(root)
  local f = io.open(user_path(root), "r")
  if not f then return nil end
  local c = f:read("*a"); f:close()
  return vim.json.decode(c)
end

local function mtime(path)
  local st = (vim.uv or vim.loop).fs_stat(path)
  return st and (st.mtime.sec * 1e9 + st.mtime.nsec) or nil
end

--- A typescript workspace with two sets (Dev, Rel) and one profile per set;
--- `names` picks which profiles to create (none activated).
local function make_ws(names)
  local root = (vim.fn.tempname():gsub("\\", "/"))
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({
    projects = { App = { typescript = vim.empty_dict() } },
    configuration_sets = { Dev = { App = "variant:default" }, Rel = { App = "variant:default" } },
  }))
  f:close()
  for _, n in ipairs(names or { "Dev", "Rel" }) do
    capture(function() cli.cmd_profile_create(root, { "profile", "create", n }) end)
  end
  return root
end

describe("lw profile select (non-interactive)", function()
  before_each(function() cli._reset_modes() end)

  local function noninteractive(fn)
    -- `--no-input` is how scripts run; drive it through the global flag.
    local saved = vim.env.LW_NO_INPUT
    vim.env.LW_NO_INPUT = "1"
    local ok, r = pcall(fn)
    vim.env.LW_NO_INPUT = saved
    if not ok then error(r, 0) end
    return r
  end

  local function run_main(argv, root)
    local saved_arg, saved_root = _G.arg, vim.env.LW_ROOT
    _G.arg = argv
    vim.env.LW_ROOT = root
    local r = capture(function() cli.main() end)
    _G.arg, vim.env.LW_ROOT = saved_arg, saved_root
    cli._reset_modes()
    return r
  end

  it("selects a named profile without a terminal and persists it", function()
    local root = make_ws()
    local r = noninteractive(function() return run_main({ "profile", "select", "Rel" }, root) end)
    assert.equals(0, r.exit_code, r.stderr)
    assert.is_truthy(r.stdout:find("active profile: Rel", 1, true), r.stdout)
    assert.equals("Rel", read_user(root).active_profile)
    vim.fn.delete(root, "rf")
  end)

  it("re-selecting the active profile reports (unchanged) and writes nothing", function()
    local root = make_ws()
    noninteractive(function() return run_main({ "profile", "select", "Dev" }, root) end)
    local before = mtime(user_path(root))
    local r = noninteractive(function() return run_main({ "profile", "select", "Dev" }, root) end)
    assert.equals(0, r.exit_code, r.stderr)
    assert.is_truthy(r.stdout:find("Dev (unchanged)", 1, true), r.stdout)
    assert.equals(before, mtime(user_path(root)))
    vim.fn.delete(root, "rf")
  end)

  it("--none clears the active profile; again is (unchanged)", function()
    local root = make_ws()
    noninteractive(function() return run_main({ "profile", "select", "Dev" }, root) end)
    local r = noninteractive(function() return run_main({ "profile", "select", "--none" }, root) end)
    assert.equals(0, r.exit_code, r.stderr)
    assert.is_truthy(r.stdout:find("active profile cleared (was Dev)", 1, true), r.stdout)
    assert.is_nil(read_user(root).active_profile)
    local again = noninteractive(function() return run_main({ "profile", "select", "--none" }, root) end)
    assert.equals(0, again.exit_code)
    assert.is_truthy(again.stdout:find("no active profile (unchanged)", 1, true), again.stdout)
    vim.fn.delete(root, "rf")
  end)

  it("an unknown name errors; --none with a name errors", function()
    local root = make_ws()
    local r = noninteractive(function() return run_main({ "profile", "select", "Nope" }, root) end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("no profile matching 'Nope'", 1, true), r.stderr)
    local r2 = noninteractive(function() return run_main({ "profile", "select", "Dev", "--none" }, root) end)
    assert.equals(1, r2.exit_code)
    vim.fn.delete(root, "rf")
  end)

  it("the bare picker still refuses without a terminal, naming both scriptable forms", function()
    local root = make_ws()
    local r = noninteractive(function() return run_main({ "profile", "select" }, root) end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("lw profile select <profile>", 1, true), r.stderr)
    assert.is_truthy(r.stderr:find("lw profile select --none", 1, true), r.stderr)
    vim.fn.delete(root, "rf")
  end)
end)

describe("non-interactive profile rule (§16.3)", function()
  after_each(function() cli._reset_modes() end)

  it("errors with NO profile even when exactly one exists, listing it and `lw profile query`", function()
    local root = make_ws({ "Dev" })
    local saved_arg, saved_root, saved_ni = _G.arg, vim.env.LW_ROOT, vim.env.LW_NO_INPUT
    _G.arg = { "build" }
    vim.env.LW_ROOT = root
    vim.env.LW_NO_INPUT = "1"
    local r = capture(function() cli.main() end)
    _G.arg, vim.env.LW_ROOT, vim.env.LW_NO_INPUT = saved_arg, saved_root, saved_ni
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("no profile specified", 1, true), r.stderr)
    assert.is_truthy(r.stderr:find("profiles: Dev", 1, true), r.stderr)
    assert.is_truthy(r.stderr:find("lw profile query", 1, true), r.stderr)
    vim.fn.delete(root, "rf")
  end)
end)

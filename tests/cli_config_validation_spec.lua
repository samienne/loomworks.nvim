-- Config/profile set hygiene (v0.1.30 real-project feedback):
--   * env names are case-insensitive for DUPLICATES: setting `env.Path` when
--     `env.PATH` exists replaces it (new spelling kept) and says so — on every
--     host, like the case-insensitive reserved names;
--   * `lw profile set` of the value already set says `(unchanged)` and does not
--     rewrite user.json (same as `lw config set`);
--   * the `cache` policy is validated wherever it can be set (profile set,
--     config set variables.cache / overrides.<family>.cache); a hand-edited
--     invalid value is a diagnostic rather than a silent uncached build;
--   * the PATH warning names the full param the user set.

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
  local f = assert(io.open(user_path(root), "r"))
  local c = f:read("*a"); f:close()
  return vim.json.decode(c)
end

local function mtime(path)
  local st = (vim.uv or vim.loop).fs_stat(path)
  return st and (st.mtime.sec * 1e9 + st.mtime.nsec) or nil
end

--- Typescript workspace: App with a user config `Mine` (local) and a `dev` set
--- + profile mapping it.
local function make_ws()
  local root = (vim.fn.tempname():gsub("\\", "/"))
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } }))
  f:close()
  cli._set_create_intent("local")
  capture(function() cli.cmd_configuration("add", root, "App", "Mine", "variant:default") end)
  capture(function() cli.cmd_cset("create", root, { "configset", "create", "dev", "App=Mine" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "dev" }) end)
  cli._set_create_intent(nil)
  return root
end

local function cfg_env(root)
  return read_user(root).projects.App.typescript.configurations.Mine.env
end

describe("env names: case-insensitive duplicates", function()
  it("`env.Path` replaces an existing `env.PATH`, keeping the new spelling, and says so", function()
    local root = make_ws()
    capture(function() cli.cmd_configuration("set", root, "App", "Mine", "env.PATH", "/a") end)
    local r = capture(function() cli.cmd_configuration("set", root, "App", "Mine", "env.Path", "/b") end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.same({ Path = "/b" }, cfg_env(root))
    assert.is_truthy((r.stdout .. r.stderr):find("replaces env.PATH", 1, true), r.stdout .. r.stderr)
    vim.fn.delete(root, "rf")
  end)

  it("applies to any name, and to a family env sub-block", function()
    local root = make_ws()
    capture(function() cli.cmd_configuration("set", root, "App", "Mine", "env.Foo", "1") end)
    capture(function() cli.cmd_configuration("set", root, "App", "Mine", "env.FOO", "2") end)
    assert.same({ FOO = "2" }, cfg_env(root))
    capture(function() cli.cmd_configuration("set", root, "App", "Mine", "overrides.msvc.env.include", "x") end)
    local r = capture(function()
      cli.cmd_configuration("set", root, "App", "Mine", "overrides.msvc.env.INCLUDE", "y")
    end)
    assert.is_nil(r.exit_code, r.stderr)
    local ov = read_user(root).projects.App.typescript.configurations.Mine.overrides
    assert.same({ INCLUDE = "y" }, ov.msvc.env)
    vim.fn.delete(root, "rf")
  end)

  it("unset matches case-insensitively too", function()
    local root = make_ws()
    capture(function() cli.cmd_configuration("set", root, "App", "Mine", "env.Foo", "1") end)
    local r = capture(function() cli.cmd_configuration("unset", root, "App", "Mine", "env.FOO") end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.is_nil(cfg_env(root))
    vim.fn.delete(root, "rf")
  end)

  it("the PATH warning names the full param that was set", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_configuration("set", root, "App", "Mine", "overrides.msvc.env.path", "/x")
    end)
    assert.is_truthy(r.stderr:find("warning: overrides.msvc.env.path replaces", 1, true), r.stderr)
    vim.fn.delete(root, "rf")
  end)
end)

describe("lw profile set: unchanged + cache policy validation", function()
  it("setting the value already set prints (unchanged) and does not rewrite user.json", function()
    local root = make_ws()
    local r1 = capture(function() cli.cmd_profile_set(root, { "profile", "set", "dev", "App", "cache", "sccache" }) end)
    assert.is_nil(r1.exit_code, r1.stderr)
    local before = mtime(user_path(root))
    local r2 = capture(function() cli.cmd_profile_set(root, { "profile", "set", "dev", "App", "cache", "sccache" }) end)
    assert.is_nil(r2.exit_code, r2.stderr)
    assert.is_truthy(r2.stdout:find("(unchanged)", 1, true), r2.stdout)
    assert.equals(before, mtime(user_path(root)))
    vim.fn.delete(root, "rf")
  end)

  it("rejects an unknown cache policy, listing the valid values; writes nothing", function()
    local root = make_ws()
    local before = mtime(user_path(root))
    local r = capture(function() cli.cmd_profile_set(root, { "profile", "set", "dev", "App", "cache", "bogus" }) end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("bogus", 1, true), r.stderr)
    for _, v in ipairs({ "auto", "off", "ccache", "sccache" }) do
      assert.is_truthy(r.stderr:find(v, 1, true), r.stderr)
    end
    assert.equals(before, mtime(user_path(root)))
    vim.fn.delete(root, "rf")
  end)

  it("accepts every valid policy spelling", function()
    local root = make_ws()
    for _, v in ipairs({ "auto", "off", "false", "ccache", "sccache", "SCCache" }) do
      local r = capture(function() cli.cmd_profile_set(root, { "profile", "set", "dev", "App", "cache", v }) end)
      assert.is_nil(r.exit_code, v .. ": " .. r.stderr)
    end
    vim.fn.delete(root, "rf")
  end)
end)

describe("lw config set: cache policy validation", function()
  it("rejects variables.cache / overrides.<family>.cache with an unknown value", function()
    local root = make_ws()
    for _, param in ipairs({ "variables.cache", "overrides.gcc.cache" }) do
      local r = capture(function() cli.cmd_configuration("set", root, "App", "Mine", param, "bogus") end)
      assert.equals(1, r.exit_code, param)
      assert.is_truthy(r.stderr:find("sccache", 1, true), r.stderr)
    end
    local ok = capture(function() cli.cmd_configuration("set", root, "App", "Mine", "variables.cache", "off") end)
    assert.is_nil(ok.exit_code, ok.stderr)
    vim.fn.delete(root, "rf")
  end)
end)

describe("hand-edited invalid cache policy", function()
  it("surfaces as a workspace diagnostic (configuration and profile fill)", function()
    local root = make_ws()
    local u = read_user(root)
    u.projects.App.typescript.configurations.Mine.variables = { cache = "bogus" }
    u.profile_variables = { dev = { App = { cache = "sccashe" } } }
    local f = assert(io.open(user_path(root), "w"))
    f:write(vim.json.encode(u)); f:close()
    local ws = cli._load_workspace(root, false)
    local msgs = {}
    for _, d in ipairs(ws:diagnostics()) do msgs[#msgs + 1] = d.message end
    local all = table.concat(msgs, "\n")
    assert.is_truthy(all:find("'bogus'", 1, true), all)
    assert.is_truthy(all:find("'sccashe'", 1, true), all)
    vim.fn.delete(root, "rf")
  end)
end)

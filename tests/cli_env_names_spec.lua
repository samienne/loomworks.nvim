-- Configuration-environment NAMES (spec §1.3.3, invariant 13):
--   * the reserved compiler-driver names are matched case-insensitively
--     (Windows environment names are; a config file is shared across hosts),
--     so `env.cc` is refused at set time exactly like `env.CC`;
--   * `env.PATH` (any case) is accepted but warned about — at set time and once
--     at runtime — because it replaces the tool's PATH (e.g. vcvars).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local reserved = require("loomworks.reserved_compiler")
local config_env = require("loomworks.config_env")

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

local function make_ws()
  local root = (vim.fn.tempname():gsub("\\", "/"))
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } }))
  f:close()
  cli._set_create_intent("local")
  capture(function() cli.cmd_configuration("add", root, "App", "Mine", "variant:default") end)
  cli._set_create_intent(nil)
  return root
end

describe("reserved compiler-driver env names are case-insensitive", function()
  it("matches any case of a reserved name", function()
    for _, name in ipairs({ "cc", "Cc", "cxx", "Cxx", "fc", "cudacxx", "objc", "ispc" }) do
      assert.is_true(reserved.is_reserved_env(name), name)
    end
    -- Still only the driver names: flags and CL (MSVC's flag variable) are not.
    assert.is_false(reserved.is_reserved_env("cflags"))
    assert.is_false(reserved.is_reserved_env("CL"))
    assert.is_false(reserved.is_reserved_env("cl"))
    assert.is_false(reserved.is_reserved_env("path"))
  end)

  it("`lw config set … env.cc` is refused at set time like env.CC", function()
    local root = make_ws()
    for _, name in ipairs({ "CC", "cc", "Cxx" }) do
      local r = capture(function()
        cli.cmd_configuration("set", root, "App", "Mine", "env." .. name, "cl")
      end)
      assert.equals(1, r.exit_code, name)
      assert.is_truthy(r.stderr:find(name .. " cannot be set here", 1, true), r.stderr)
    end
    -- Same for a compiler-family env sub-block.
    local r = capture(function()
      cli.cmd_configuration("set", root, "App", "Mine", "overrides.msvc.env.cc", "cl")
    end)
    assert.equals(1, r.exit_code)
    vim.fn.delete(root, "rf")
  end)

  it("a hand-edited lower-case driver name is stripped at runtime", function()
    local cfg = { name = "Mine", env = { cc = "cl", FOO = "1" } }
    local env, stripped = config_env.resolve({ key = "App" }, cfg, nil, nil, "/ws")
    assert.same({ FOO = "1" }, env)
    assert.same({ "cc" }, stripped)
  end)
end)

describe("env.PATH", function()
  local orig_notify
  local notified
  before_each(function()
    notified = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
    config_env._warned = {}
  end)
  after_each(function() vim.notify = orig_notify end)

  it("is accepted with a clear warning at set time, any case", function()
    local root = make_ws()
    for _, name in ipairs({ "PATH", "Path" }) do
      local r = capture(function()
        cli.cmd_configuration("set", root, "App", "Mine", "env." .. name, "/opt/bin")
      end)
      assert.is_nil(r.exit_code, name)
      assert.is_truthy(r.stdout:find("set env." .. name, 1, true), r.stdout)
      assert.is_truthy(r.stderr:find("replaces", 1, true), r.stderr)
      assert.is_truthy(r.stderr:find("tool", 1, true), r.stderr)
    end
    -- Setting an unrelated name carries no warning.
    local r = capture(function()
      cli.cmd_configuration("set", root, "App", "Mine", "env.SCCACHE_DIR", "/c")
    end)
    assert.is_nil(r.stderr:find("replaces", 1, true))
    vim.fn.delete(root, "rf")
  end)

  it("warns once at runtime when a configuration env sets PATH", function()
    local cfg = { name = "Mine", env = { Path = "/opt/bin" } }
    local env = config_env.resolve({ key = "App" }, cfg, nil, nil, "/ws")
    assert.equals("/opt/bin", env.Path)
    config_env.resolve({ key = "App" }, cfg, nil, nil, "/ws")
    vim.wait(50, function() return #notified > 0 end)
    local hits = 0
    for _, n in ipairs(notified) do
      if n.msg:find("PATH", 1, true) and n.msg:find("replaces", 1, true) then hits = hits + 1 end
    end
    assert.equals(1, hits)
  end)
end)

describe("config_env.compose on a case-insensitive host", function()
  it("a configuration name replaces a tool name differing only in case", function()
    local env = config_env.compose({ PATH = "/tool/bin", INCLUDE = "i" }, { Path = "/mine" },
      true)
    assert.same({ Path = "/mine", INCLUDE = "i" }, env)
  end)

  it("keeps both on a case-sensitive host", function()
    local env = config_env.compose({ PATH = "/tool/bin" }, { Path = "/mine" }, false)
    assert.same({ PATH = "/tool/bin", Path = "/mine" }, env)
  end)
end)

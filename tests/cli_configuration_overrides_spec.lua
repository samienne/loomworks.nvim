-- `lw configuration set/get/unset` — compiler-family variable overrides
-- (core §1.3.1) via the `overrides.<family>.<name>` param namespace.
--
-- Two layers: the pure param-grammar seams (`_apply_param` / `_get_param` /
-- `_config_to_data`), and an on-disk round-trip through the real CLI commands
-- (set → reload → get → unset), which exercises save_configuration's
-- validation and working-copy persistence end to end.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

-- Run `fn` with io.write / io.stderr / os.exit captured, so a die() path is
-- observable (exit_code set, no process kill) instead of terminating busted.
local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  return {
    exit_code = exit_code,
    stdout = table.concat(out_buf),
    stderr = table.concat(err_buf),
  }
end

-- ---------------------------------------------------------------------------
-- Param-grammar seams
-- ---------------------------------------------------------------------------
describe("apply_param overrides.<family>.<name>", function()
  it("sets a nested override into data.overrides", function()
    local data = {}
    cli._apply_param(data, "overrides.clang.warn_flags", "-Werror")
    assert.same({ clang = { warn_flags = "-Werror" } }, data.overrides)
  end)

  it("a second family/name coexists", function()
    local data = {}
    cli._apply_param(data, "overrides.clang.warn_flags", "-Wc")
    cli._apply_param(data, "overrides.gcc.warn_flags", "-Wg")
    cli._apply_param(data, "overrides.clang.other", "x")
    assert.same({
      clang = { warn_flags = "-Wc", other = "x" },
      gcc = { warn_flags = "-Wg" },
    }, data.overrides)
  end)

  it("a nil value clears the entry and prunes the emptied family + block", function()
    local data = { overrides = { clang = { warn_flags = "-Wc" } } }
    cli._apply_param(data, "overrides.clang.warn_flags", nil)
    assert.is_nil(data.overrides)
  end)

  it("an empty-string value also clears", function()
    local data = { overrides = { clang = { warn_flags = "-Wc" }, gcc = { warn_flags = "-Wg" } } }
    cli._apply_param(data, "overrides.clang.warn_flags", "")
    assert.same({ gcc = { warn_flags = "-Wg" } }, data.overrides)
  end)

  it("rejects a bare `overrides` param", function()
    local r = capture(function() cli._apply_param({}, "overrides", "x") end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("overrides.<family>.<name>", 1, true))
  end)

  it("rejects a two-segment `overrides.<family>` (no name)", function()
    local r = capture(function() cli._apply_param({}, "overrides.clang", "x") end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("malformed override param", 1, true))
  end)

  it("rejects an unknown compiler family", function()
    local r = capture(function() cli._apply_param({}, "overrides.tcc.warn", "x") end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("unknown compiler family 'tcc'", 1, true))
  end)
end)

describe("get_param overrides", function()
  local cfg = { _overrides = { clang = { warn = "-Wc" }, gcc = { warn = "-Wg" } } }

  it("reads a leaf value overrides.<family>.<name>", function()
    assert.equals("-Wc", cli._get_param(cfg, "overrides.clang.warn"))
  end)

  it("reads a family dict overrides.<family>", function()
    assert.same({ warn = "-Wc" }, cli._get_param(cfg, "overrides.clang"))
  end)

  it("reads the whole overrides dict for the bare name", function()
    assert.same(cfg._overrides, cli._get_param(cfg, "overrides"))
  end)

  it("returns nil for an absent family/name", function()
    assert.is_nil(cli._get_param(cfg, "overrides.msvc.warn"))
    assert.is_nil(cli._get_param(cfg, "overrides.clang.absent"))
    assert.is_nil(cli._get_param({}, "overrides.clang.warn"))
  end)
end)

describe("config_to_data overrides round-trip", function()
  it("copies a live Configuration's _overrides into the edit data", function()
    local cfg = {
      module_config = { variant = "Debug" },
      _overrides = { clang = { warn = "-Wc" } },
    }
    local data = cli._config_to_data(cfg)
    assert.same({ clang = { warn = "-Wc" } }, data.overrides)
    -- A distinct copy (deepcopy), not the live table.
    assert.is_false(rawequal(cfg._overrides, data.overrides))
  end)

  it("omits overrides when the config has none", function()
    local data = cli._config_to_data({ module_config = {}, options = { A = "1" } })
    assert.is_nil(data.overrides)
  end)
end)

-- ---------------------------------------------------------------------------
-- On-disk round-trip through the real CLI commands
-- ---------------------------------------------------------------------------
describe("lw configuration overrides (on-disk round-trip)", function()
  local uv = vim.uv or vim.loop

  --- Create a temp workspace with a typescript project declaring one variable,
  --- plus a user `Debug` config inheriting variant:default. Returns its root.
  local function make_ws()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    local lw = {
      projects = {
        App = {
          typescript = vim.empty_dict(),
          variables = { warn = { type = "string", default = "" } },
        },
      },
    }
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode(lw)); f:close()
    -- The project dir must exist for the module; contents don't matter here.
    vim.fn.mkdir(root .. "/App", "p")
    capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
    return root
  end

  local function read_user(root)
    local f = io.open(root .. "/.nvim/loomworks.user.json", "r")
    if not f then return nil end
    local content = f:read("*a"); f:close()
    return vim.json.decode(content)
  end

  it("set persists into the config's overrides and survives a reload", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_configuration("set", root, "App", "Debug", "overrides.clang.warn", "-Wc")
    end)
    assert.is_nil(r.exit_code)  -- no die()

    -- Persisted to the working copy under the config's `overrides`.
    local user = read_user(root)
    local cfg = user.projects.App.typescript.configurations.Debug
    assert.same({ clang = { warn = "-Wc" } }, cfg.overrides)

    -- A FRESH command reloads the workspace from disk and reads it back.
    local g = capture(function()
      cli.cmd_configuration("get", root, "App", "Debug", "overrides.clang.warn")
    end)
    assert.equals("-Wc", vim.trim(g.stdout))
  end)

  it("unset clears the override and prunes the emptied block", function()
    local root = make_ws()
    capture(function() cli.cmd_configuration("set", root, "App", "Debug", "overrides.clang.warn", "-Wc") end)
    capture(function() cli.cmd_configuration("unset", root, "App", "Debug", "overrides.clang.warn") end)

    local user = read_user(root)
    local cfg = user.projects.App.typescript.configurations.Debug
    assert.is_nil(cfg.overrides)

    local g = capture(function()
      cli.cmd_configuration("get", root, "App", "Debug", "overrides.clang.warn")
    end)
    assert.equals("(unset)", vim.trim(g.stdout))
  end)

  it("setting an override for an UNDECLARED variable fails (save_configuration)", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_configuration("set", root, "App", "Debug", "overrides.clang.nope", "x")
    end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("not declared in project variables", 1, true))
    -- Nothing was written.
    local user = read_user(root)
    local cfg = user.projects.App.typescript.configurations.Debug
    assert.is_nil(cfg.overrides)
  end)

  it("a malformed param shape errors before touching the config", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_configuration("set", root, "App", "Debug", "overrides.clang", "x")
    end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("malformed override param", 1, true))
  end)
end)

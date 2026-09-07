-- `lw project set/unset` — declaring project variables from the CLI
-- (core §1.3.1). Two layers: the pure arg-grammar seam
-- (`_parse_project_set_args`) and an on-disk round-trip through the real CLI
-- commands (set → reload → show → unset), which exercises
-- Project:save_variable / delete_variable and working-copy persistence, plus
-- the declare → fill bootstrap loop end to end.

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
-- Arg-grammar seam: <project> <variable> [<default>] with --type anywhere
-- ---------------------------------------------------------------------------
describe("parse_project_set_args", function()
  local function parse(...)
    return cli._parse_project_set_args({ "project", "set", ... })
  end

  it("takes project + variable, no default, default type nil", function()
    local pos, ty = parse("App", "port")
    assert.same({ "App", "port" }, pos)
    assert.is_nil(ty)
  end)

  it("takes an optional default positional", function()
    local pos, ty = parse("App", "port", "8080")
    assert.same({ "App", "port", "8080" }, pos)
    assert.is_nil(ty)
  end)

  it("--type AFTER the default", function()
    local pos, ty = parse("App", "out", "~/dist", "--type", "path")
    assert.same({ "App", "out", "~/dist" }, pos)
    assert.equals("path", ty)
  end)

  it("--type BEFORE the default", function()
    local pos, ty = parse("App", "out", "--type", "path", "~/dist")
    assert.same({ "App", "out", "~/dist" }, pos)
    assert.equals("path", ty)
  end)

  it("--type with no default (blank)", function()
    local pos, ty = parse("App", "out", "--type", "path")
    assert.same({ "App", "out" }, pos)
    assert.equals("path", ty)
  end)

  it("accepts the --type=<value> inline form", function()
    local pos, ty = parse("App", "out", "--type=path")
    assert.same({ "App", "out" }, pos)
    assert.equals("path", ty)
  end)

  it("dies when --type has no value", function()
    local r = capture(function() parse("App", "out", "--type") end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("--type needs a value", 1, true))
  end)
end)

-- ---------------------------------------------------------------------------
-- On-disk round-trip through the real CLI commands
-- ---------------------------------------------------------------------------
describe("lw project set/unset (on-disk)", function()
  --- A temp workspace with a typescript App, a Debug config, a Dev set
  --- (App=Debug) and an active Dev profile — enough for the fill bootstrap.
  --- App starts with NO declared variables.
  local function make_ws()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    vim.fn.mkdir(root .. "/App", "p")
    local lw = { projects = { App = { typescript = vim.empty_dict() } } }
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode(lw)); f:close()
    capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
    capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" }) end)
    capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
    return root
  end

  local function read_user(root)
    local f = io.open(root .. "/.nvim/loomworks.user.json", "r")
    if not f then return nil end
    local c = f:read("*a"); f:close()
    return vim.json.decode(c)
  end

  --- Invoke `lw project set …` through the dispatcher (exercising argv parse).
  local function project_set(root, ...)
    local argv = { "project", "set", ... }
    return capture(function()
      cli.cmd_project("set", root, nil, nil, nil, argv)
    end)
  end

  it("declares a new string variable with a default; persists + reloads", function()
    local root = make_ws()
    local r = project_set(root, "App", "port", "8080")
    assert.is_nil(r.exit_code)  -- no die()

    local user = read_user(root)
    assert.same({ type = "string", default = "8080" }, user.projects.App.variables.port)

    -- A fresh command reloads from disk and shows the declaration.
    local g = capture(function() cli.cmd_project("show", root, "App") end)
    assert.is_truthy(g.stdout:find("port", 1, true))
    assert.is_truthy(g.stdout:find("default=8080", 1, true))
  end)

  it("declares a path-typed variable", function()
    local root = make_ws()
    project_set(root, "App", "out", "~/dist", "--type", "path")
    local user = read_user(root)
    assert.same({ type = "path", default = "~/dist" }, user.projects.App.variables.out)
  end)

  it("declares a BLANK variable when no default is given", function()
    local root = make_ws()
    project_set(root, "App", "sdk_root", "--type", "path")
    local user = read_user(root)
    assert.same({ type = "path" }, user.projects.App.variables.sdk_root)
    assert.is_nil(user.projects.App.variables.sdk_root.default)
  end)

  it("set again updates type and default in place (upsert)", function()
    local root = make_ws()
    project_set(root, "App", "v", "1")
    project_set(root, "App", "v", "/p", "--type", "path")
    local user = read_user(root)
    assert.same({ type = "path", default = "/p" }, user.projects.App.variables.v)
  end)

  it("rejects an invalid --type", function()
    local root = make_ws()
    local r = project_set(root, "App", "v", "--type", "bogus")
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("invalid --type 'bogus'", 1, true))
    assert.is_nil(read_user(root).projects.App.variables)
  end)

  it("surfaces the reserved-name rejection from save_variable", function()
    local root = make_ws()
    local r = project_set(root, "App", "build_dir", "x")
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("reserved", 1, true))
    assert.is_nil(read_user(root).projects.App.variables)
  end)

  it("unset removes a declaration and persists", function()
    local root = make_ws()
    project_set(root, "App", "port", "8080")
    local r = capture(function() cli.cmd_project("unset", root, "App", "port") end)
    assert.is_nil(r.exit_code)
    local user = read_user(root)
    assert.is_nil(user.projects.App.variables)  -- pruned to nil when empty
  end)

  it("unset of an undeclared variable errors", function()
    local root = make_ws()
    local r = capture(function() cli.cmd_project("unset", root, "App", "nope") end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("declares no variable 'nope'", 1, true))
  end)

  it("show lists a blank declaration as (blank)", function()
    local root = make_ws()
    project_set(root, "App", "sdk_root", "--type", "path")
    local g = capture(function() cli.cmd_project("show", root, "App") end)
    assert.is_truthy(g.stdout:find("Variables:", 1, true))
    assert.is_truthy(g.stdout:find("sdk_root", 1, true))
    assert.is_truthy(g.stdout:find("(blank)", 1, true))
  end)

  it("bootstrap: declare blank -> shows blank -> profile set fills it", function()
    local root = make_ws()
    -- 1. declare a blank path variable
    local d = project_set(root, "App", "sdk_root", "--type", "path")
    assert.is_nil(d.exit_code)

    -- 2. it shows as blank in the visibility surface
    local g = capture(function() cli.cmd_project("show", root, "App") end)
    assert.is_truthy(g.stdout:find("sdk_root", 1, true))
    assert.is_truthy(g.stdout:find("(blank)", 1, true))

    -- 3. the active profile fills it — no error (would fail if undeclared)
    local s = capture(function()
      cli.cmd_profile("set", root, { "profile", "set", "App", "sdk_root", "/opt/sdk" })
    end)
    assert.is_nil(s.exit_code)
    assert.equals("/opt/sdk", read_user(root).profile_variables.Dev.App.sdk_root)

    -- 4. the query resolves the fill value through the blank
    local q = capture(function()
      cli.cmd_profile_query(root, { "profile", "query", "Dev", "App", "variables.sdk_root" })
    end)
    assert.equals("/opt/sdk", vim.trim(q.stdout))
  end)
end)

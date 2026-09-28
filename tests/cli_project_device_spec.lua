-- `lw project set/unset <project> device.<field>` — editing a project's device
-- block (spec §18.9) from the CLI, on disk through the real commands: the block
-- lands in the module section of the working copy, is validated like a loaded
-- block, refuses denied environment variables, and shows in `lw project show`.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } }))
  f:close()
  return root
end

local function read_user(root)
  local f = io.open(root .. "/.nvim/loomworks.user.json", "r")
  if not f then return nil end
  local c = f:read("*a"); f:close()
  return vim.json.decode(c)
end

local function set(root, ...)
  local argv = { "project", "set", ... }
  return capture(function() cli.cmd_project("set", root, nil, nil, nil, argv) end)
end

local function unset(root, field)
  return capture(function() cli.cmd_project("unset", root, "App", field) end)
end

describe("lw project set/unset device.<field>", function()
  local root
  before_each(function() root = make_ws() end)
  after_each(function() vim.fn.delete(root, "rf") end)

  it("sets stage / archive lists, working_dir and env into the module section", function()
    local r = set(root, "App", "device.stage", "bin/*.so", "lib/*.so")
    assert.is_nil(r.exit_code, r.stderr)
    assert.truthy(r.stdout:find("projects.App.typescript.device", 1, true), r.stdout)
    assert.is_nil(set(root, "App", "device.archive", "assets/**").exit_code)
    assert.is_nil(set(root, "App", "device.working_dir", "bin").exit_code)
    assert.is_nil(set(root, "App", "device.env.LOG", "debug").exit_code)
    local p = read_user(root).projects.App
    assert.is_nil(p.device)
    assert.same({ stage = { "bin/*.so", "lib/*.so" }, archive = { "assets/**" },
      working_dir = "bin", env = { LOG = "debug" } }, p.typescript.device)
    -- Setting a list again replaces it.
    set(root, "App", "device.stage", "only/*.so")
    assert.same({ "only/*.so" }, read_user(root).projects.App.typescript.device.stage)
    local show = capture(function() cli.cmd_project("show", root, "App") end)
    assert.truthy(show.stdout:find("Device:", 1, true), show.stdout)
    assert.truthy(show.stdout:find("env.LOG", 1, true), show.stdout)
  end)

  it("validates like a loaded block and refuses denied environment variables", function()
    local r = set(root, "App", "device.stage", "../escape/*")
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("device.stage", 1, true), r.stderr)
    r = set(root, "App", "device.env.LD_PRELOAD", "/x.so")
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("LD_PRELOAD cannot be set", 1, true), r.stderr)
    r = set(root, "App", "device.bogus", "x")
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("usage: lw project set <project> device", 1, true), r.stderr)
    r = set(root, "App", "device.stage")
    assert.equals(1, r.exit_code)
    local user = read_user(root)
    assert.is_true(user == nil or user.projects == nil or user.projects.App == nil
      or user.projects.App.typescript == nil or user.projects.App.typescript.device == nil)
  end)

  it("unsets an env entry, a field, or the whole block", function()
    set(root, "App", "device.stage", "bin/*.so")
    set(root, "App", "device.env.A", "1")
    set(root, "App", "device.env.B", "2")
    assert.is_nil(unset(root, "device.env.A").exit_code)
    assert.same({ B = "2" }, read_user(root).projects.App.typescript.device.env)
    assert.equals(1, unset(root, "device.env.A").exit_code)
    assert.is_nil(unset(root, "device.stage").exit_code)
    assert.is_nil(read_user(root).projects.App.typescript.device.stage)
    assert.is_nil(unset(root, "device").exit_code)
    local tc = read_user(root).projects.App.typescript
    assert.is_true(tc == nil or tc.device == nil)
  end)
end)

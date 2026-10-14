-- The status page header shows the running loomworks version (spec/ui.md:
-- "plugin version"), resolved like `_meta.written_by` (spec §2:
-- save_guard.version()) — never a stale hard-coded constant.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local Tree = require("loomworks.ui.tree")
local save_guard = require("loomworks.save_guard")
local status = require("loomworks.ui.status")
local lw = require("loomworks")
local real_version = save_guard.version()

local function capture(fn)
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function() end
  io.stderr = { write = function() end }
  os.exit = function() error({ __exit = true }, 0) end
  pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
end

local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
  return assert(cli._load_workspace(root, false))
end

local function header(get_ws, get_err)
  local orig_ws, orig_err = lw.get_workspace, lw.get_setup_error
  lw.get_workspace, lw.get_setup_error = get_ws, get_err
  local ok, lines = pcall(function()
    local t = Tree.new(status._render_fn)
    t.width = 100
    return (t:render())
  end)
  lw.get_workspace, lw.get_setup_error = orig_ws, orig_err
  assert(ok, lines)
  for _, l in ipairs(lines) do
    local s = l:match("loomworks%.nvim .*$")
    if s then return vim.trim(s) end
  end
end

describe("status page header version", function()
  after_each(function() save_guard._set_version(real_version) end)

  it("shows the source checkout's CHANGELOG-derived version", function()
    local v = real_version
    assert.is_truthy(v)
    local ws = make_ws()
    local h = header(function() return ws end, function() return nil end)
    assert.equals("loomworks.nvim " .. v, h)
    assert.is_nil(h:find("0.0.1-dev", 1, true))
  end)

  it("shows a release bundle's version", function()
    save_guard._set_version("0.1.43")
    local ws = make_ws()
    assert.equals("loomworks.nvim 0.1.43",
      header(function() return ws end, function() return nil end))
  end)

  it("shows the version on the setup-error page too", function()
    save_guard._set_version("0.1.43")
    assert.equals("loomworks.nvim 0.1.43", header(function() return nil end,
      function() return { root = "/x", message = "boom" } end))
  end)

  it("falls back to 'dev' when no version is known", function()
    save_guard._set_version(nil)
    assert.equals("loomworks.nvim dev", header(function() return nil end,
      function() return { root = "/x", message = "boom" } end))
  end)
end)

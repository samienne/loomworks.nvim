-- The status page header shows the running loomworks version (spec/ui.md:
-- "plugin version"), resolved like `_meta.written_by` (spec §2:
-- save_guard.version()) — never a stale hard-coded constant. The runtime
-- puts it in `loomworks.view.Header/1` as `version` (spec §19.13 "Views"),
-- the plugin prints the view's.

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

-- `hdr`, when given, stands in for the `loomworks.view.Header/1` view the
-- page reads (spec §19.13).
local function header(get_ws, get_err, hdr)
  local orig_ws, orig_err, orig_hdr = lw.get_workspace, lw.get_setup_error, lw.view_header
  lw.get_workspace, lw.get_setup_error = get_ws, get_err
  if hdr then lw.view_header = function() return hdr end end
  -- (A root attached: the editor observes a daemon, it holds no model.)
  local observer = require("loomworks.daemon.observer")
  local orig_root = observer._attached_root
  observer._attached_root = hdr and hdr.root or nil
  local ok, lines = pcall(function()
    local t = Tree.new(status._render_fn)
    t.width = 100
    return (t:render())
  end)
  lw.get_workspace, lw.get_setup_error, lw.view_header = orig_ws, orig_err, orig_hdr
  observer._attached_root = orig_root
  assert(ok, lines)
  for _, l in ipairs(lines) do
    local s = l:match("loomworks%.nvim .*$")
    if s then return vim.trim(s) end
  end
end

--- The header the daemon serves for `ws`: its version save_guard.version()
--- (the daemon's view_state.header, `opts.version`).
local function daemon_header(ws)
  return require("loomworks.view_state").header(ws, nil, { version = save_guard.version() })
end

describe("status page header version", function()
  after_each(function() save_guard._set_version(real_version) end)

  it("shows the source checkout's CHANGELOG-derived version", function()
    local v = real_version
    assert.is_truthy(v)
    local ws = make_ws()
    local h = header(function() return nil end, function() return nil end, daemon_header(ws))
    assert.equals("loomworks.nvim " .. v, h)
    assert.is_nil(h:find("0.0.1-dev", 1, true))
  end)

  it("shows a release bundle's version", function()
    save_guard._set_version("0.1.43")
    local ws = make_ws()
    assert.equals("loomworks.nvim 0.1.43",
      header(function() return nil end, function() return nil end, daemon_header(ws)))
  end)

  it("shows the version on the setup-error page too", function()
    assert.equals("loomworks.nvim 0.1.43", header(function() return nil end,
      function() return { root = "/x", message = "boom" } end,
      { state = "error", root = "/x", error = "boom", version = "0.1.43" }))
  end)

  it("shows the view's version as it is (the daemon's while subscribed)", function()
    local ws = make_ws()
    assert.equals("loomworks.nvim 0.1.50", header(function() return ws end, function() return nil end,
      { state = "loaded", root = ws.root, name = "w", version = "0.1.50" }))
  end)

  it("falls back to 'dev' when the view carries no version", function()
    assert.equals("loomworks.nvim dev", header(function() return nil end,
      function() return { root = "/x", message = "boom" } end,
      { state = "error", root = "/x", error = "boom" }))
  end)
end)

describe("the daemon-mode view header version", function()
  it("daemon mode's unloaded header carries the plugin's own version (loomworks.version)", function()
    local pv = require("loomworks.version")
    pv._set("0.1.43")
    -- (No model in `daemon` mode, step 6b-alpha: the view store's header.)
    local views = require("loomworks.views")
    views.daemon_root("/r")
    local ok, hdr = pcall(views.header)
    views.daemon_root(nil)
    pv._set(nil)
    assert.is_true(ok, tostring(hdr))
    assert.same({ root = "/r", state = "unloaded", version = "0.1.43" }, hdr)
  end)
end)

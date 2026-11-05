-- The status page header shows the running loomworks version (spec/plugin.md UI:
-- "plugin version") — never a stale hard-coded constant. While the daemon's
-- `loomworks.view.Header/1` is held the page prints that view's `version`
-- (spec §19.13 "Views"); before, the unloaded header carries the plugin's own
-- version (loomworks.version, its CHANGELOG).

local Tree = require("loomworks.ui.tree")
local status = require("loomworks.ui.status")
local lw = require("loomworks")
local pv = require("loomworks.version")
local views = require("loomworks.views")

-- `hdr`, when given, stands in for the `loomworks.view.Header/1` view the
-- page reads (spec §19.13); without it the page reads the view store (the
-- unloaded header of the observed `root`).
local function header(hdr, root)
  local orig_hdr = lw.view_header
  if hdr then lw.view_header = function() return hdr end end
  -- (A root attached: the editor observes a daemon, it holds no model.)
  local observer = require("loomworks.daemon.observer")
  local orig_root = observer._attached_root
  observer._attached_root = hdr and hdr.root or root
  if root then views.daemon_root(root) end
  local ok, lines = pcall(function()
    local t = Tree.new(status._render_fn)
    t.width = 100
    return (t:render())
  end)
  lw.view_header = orig_hdr
  observer._attached_root = orig_root
  if root then views.daemon_root(nil) end
  assert(ok, lines)
  for _, l in ipairs(lines) do
    local s = l:match("loomworks%.nvim .*$")
    if s then return vim.trim(s) end
  end
end

describe("status page header version", function()
  after_each(function() pv._set(nil) end)

  it("shows the plugin's CHANGELOG-derived version before the daemon's view is held", function()
    local v = pv.get()
    assert.is_truthy(v)
    local h = header(nil, "/r")
    assert.equals("loomworks.nvim " .. v, h)
    assert.is_nil(h:find("0.0.1-dev", 1, true))
  end)

  it("shows a release bundle's version", function()
    pv._set("0.1.43")
    assert.equals("loomworks.nvim 0.1.43", header(nil, "/r"))
  end)

  it("shows the version on the setup-error page too", function()
    assert.equals("loomworks.nvim 0.1.43",
      header({ state = "error", root = "/x", error = "boom", version = "0.1.43" }))
  end)

  it("shows the view's version as it is (the daemon's while subscribed)", function()
    assert.equals("loomworks.nvim 0.1.50",
      header({ state = "loaded", root = "/w", name = "w", version = "0.1.50" }))
  end)

  it("falls back to 'dev' when the view carries no version", function()
    assert.equals("loomworks.nvim dev", header({ state = "error", root = "/x", error = "boom" }))
  end)
end)

describe("the daemon-mode view header version", function()
  it("daemon mode's unloaded header carries the plugin's own version (loomworks.version)", function()
    pv._set("0.1.43")
    -- (No model in `daemon` mode, step 6b-alpha: the view store's header.)
    views.daemon_root("/r")
    local ok, hdr = pcall(views.header)
    views.daemon_root(nil)
    pv._set(nil)
    assert.is_true(ok, tostring(hdr))
    assert.same({ root = "/r", state = "unloaded", version = "0.1.43" }, hdr)
  end)
end)

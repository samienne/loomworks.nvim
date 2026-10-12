-- The debug-adapter mapping (spec §8.9.6 "Adapter configuration") as the
-- daemon's `loomworks.DebugConfig/1` serves it (§19.20): the host-neutral
-- records and languages (loomworks.debug_config), and the working-copy write
-- of Workspace:set_debug_adapter — set, reset to the default, and a write
-- that fails or is refused leaving user.json and the model untouched.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local Core = require("loomworks.core")
local FileTracker = require("loomworks.file_tracker")
local io_mod = require("loomworks.io")
local trust = require("loomworks.trust")
local user_mod = require("loomworks.user")
local debug_config = require("loomworks.debug_config")

local function capture(fn)
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function() end
  io.stderr = { write = function() end }
  os.exit = function() error({ __exit = true }, 0) end
  local ok, err = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
end

--- A workspace with a working copy (a typescript App, a Dev profile),
--- authored through the CLI.
local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
  capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
  assert(io_mod.read_file(user_mod.filepath(root)), "make_ws: no working copy")
  local lc = require("loomworks")._core()
  if lc._workspace then lc._workspace:_stop_tracking() end
  return root
end

--- Its own Core over the files, the tracker's poll out of reach.
local function open_ws(root)
  local notes = {}
  local core = Core.new({
    notify = function(msg, level) notes[#notes + 1] = { msg = tostring(msg), level = level } end,
    on_save_refused = false,
    FileTracker = { new = function(o) o.interval = 3600 * 1000; return FileTracker.new(o) end },
  })
  core:setup({ root = root })
  assert(vim.wait(15000, function() return core._state ~= "initializing" end, 10))
  return core._workspace, notes
end

local function user_doc(root)
  local text = assert(io_mod.read_file(user_mod.filepath(root)))
  local status, body = trust.verify("user", text)
  assert.equals("valid", status)
  return vim.json.decode(body), text
end

describe("debug_config records (DebugConfig/1)", function()
  it("lists every declared language once, sorted: the defaults' and the modules'", function()
    local ws = { _modules = { { languages = { "c", "c++" } }, { languages = { "rust", "c++" } }, {} } }
    assert.same({ "c", "c++", "rust", "typescript" }, debug_config.workspace_languages(ws))
  end)

  it("reports the adapter in effect, the default, the known adapters and the override", function()
    local ws = { _modules = { { languages = { "c" } } }, _debug_settings = { adapters = { ["c++"] = "cppdbg" } } }
    local by = {}
    for _, r in ipairs(debug_config.adapter_records(ws)) do by[r.language] = r end
    assert.same({ language = "c++", adapter = "cppdbg", default = "codelldb", known = { "codelldb", "cppdbg" },
      overridden = true }, by["c++"])
    assert.same({ language = "typescript", adapter = "pwa-node", default = "pwa-node",
      known = { "pwa-node", "pwa-chrome" }, overridden = false }, by.typescript)
    -- A language with neither an override nor a default: no adapter.
    assert.same({ language = "c", known = {}, overridden = false }, by.c)
  end)
end)

describe("Workspace:set_debug_adapter (§8.9.6, DebugConfig/1.set_adapter)", function()
  it("writes the override to the working copy, and removes it (no empty tables) for the default", function()
    local root = make_ws()
    local ws = open_ws(root)
    assert.is_true((ws:set_debug_adapter("c++", "cppdbg")))
    assert.equals("cppdbg", user_doc(root).debug.adapters["c++"])
    assert.equals("cppdbg", debug_config.resolve_adapter(ws, "c++"))
    -- Never loomworks.json.
    assert.is_nil(vim.json.decode((io_mod.read_file(root .. "/loomworks.json"))).debug)
    assert.is_true((ws:set_debug_adapter("c++", nil)))
    assert.is_nil(user_doc(root).debug)
    assert.is_nil(ws._debug_settings)
    assert.equals("codelldb", debug_config.resolve_adapter(ws, "c++"))
  end)

  it("a failed write leaves user.json and the model as they were", function()
    local root = make_ws()
    local ws = open_ws(root)
    assert.is_true((ws:set_debug_adapter("typescript", "pwa-chrome")))
    local _, before = user_doc(root)
    local deps = ws._core._deps
    local orig = deps.user.save
    deps.user = setmetatable({ save = function() return false, "disk full" end }, { __index = deps.user })
    local ok, err = ws:set_debug_adapter("c++", "cppdbg")
    deps.user = getmetatable(deps.user).__index
    assert.equals(orig, deps.user.save)
    assert.is_false(ok)
    assert.equals("disk full", err)
    assert.equals(before, io_mod.read_file(user_mod.filepath(root)))
    assert.same({ adapters = { typescript = "pwa-chrome" } }, ws._debug_settings)
  end)

  it("a stale working copy is refused, never overwritten, and its re-read settings stand", function()
    local root = make_ws()
    local ws = open_ws(root)
    -- Another process changes the working copy behind this one's back.
    capture(function() cli.cmd_configuration("add", root, "App", "Release", "variant:default") end)
    local lc = require("loomworks")._core()
    if lc._workspace then lc._workspace:_stop_tracking() end
    local _, theirs = user_doc(root)
    local ok, err = ws:set_debug_adapter("c++", "cppdbg")
    assert.is_false(ok)
    assert.is_string(err)
    assert.equals(theirs, io_mod.read_file(user_mod.filepath(root)))
    assert.is_nil(ws._debug_settings)
    assert.equals("codelldb", debug_config.resolve_adapter(ws, "c++"))
  end)
end)

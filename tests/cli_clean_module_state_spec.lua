-- `lw clean` on a module with its own clean (the shell module WITH
-- `clean_cmd`: the build system's artifact clean, spec §16.1 — the build
-- directory and its configuration are kept, only artifacts go). After a
-- successful module clean the units are `configured` (spec ui.md `C`: "Run
-- module clean tasks, reset to configured"; state machine §3: a clean leaves
-- the built state), and that state is PERSISTED, so the next `lw status`
-- (§16.18, read from the cache) no longer shows the profile `(built)`.
-- Regression: the in-process clean recorded nothing for a module clean step,
-- and the cache entry of a unit that has a BuildDir is serialized from the
-- BuildDir, which still said `built`.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local running = require("loomworks.daemon.running")

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, err = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
  return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

--- Run fn with the step spawn stubbed (every step "succeeds" with `code`),
--- the workspace as the current one. Returns capture() + the spawned steps.
local function stubbed(ws, fn, code)
  local spawned = {}
  local loomworks = require("loomworks")
  local orig_spawn, orig_get = cli._run_spec, loomworks.get_workspace
  cli._run_spec = function(step) spawned[#spawned + 1] = step; return code or 0 end
  loomworks.get_workspace = function() return ws end
  local ok, r = pcall(capture, fn)
  cli._run_spec, loomworks.get_workspace = orig_spawn, orig_get
  if not ok then error(r, 0) end
  r.spawned = spawned
  return r
end

--- A shell App (Debug) WITH a module clean; set + profile Dev (active).
local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local lw = { projects = { App = { shell = {
    build_dir = "${workspace_root}/out/${configuration}",
    configure_cmd = { "configure" },
    build_cmd = { "build" },
    clean_cmd = { "clean" },
    configurations = { Debug = vim.empty_dict() },
  } } } }
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode(lw)); f:close()
  capture(function()
    cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" })
    cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" })
  end)
  return root
end

local function load(root)
  local ws = assert(cli._load_workspace(root, false))
  local dev
  for _, p in ipairs(ws._profiles) do
    local cs = p:config_set()
    if cs and cs.name == "Dev" then dev = p end
  end
  return ws, assert(dev, "no Dev profile")
end

local function cached(root)
  local f = assert(io.open(root .. "/.nvim/loomworks.cache.json", "r"))
  local data = vim.json.decode(f:read("*a")); f:close()
  for _, c in pairs(data.build_dirs or {}) do
    if c.project_key == "App" and c.config_key == "Debug" then return c end
  end
  return nil
end

local function status_state(root, key)
  local r = capture(function() cli.cmd_status(root, {}) end)
  local in_profiles = false
  for line in (r.stdout .. "\n"):gmatch("([^\n]*)\n") do
    if line:find("^Profiles") then in_profiles = true
    elseif in_profiles and line:find("^%a") then in_profiles = false end
    local i = in_profiles and line:find(" " .. key .. " ", 1, true)
    if i then
      local s = line:sub(i + #key + 1):match("^%s*%(([^)]*)%)%s*$")
      if s then return s, r.stdout end
    end
  end
  return nil, r.stdout
end

--- `lw build Dev` (stubbed steps) and create the build directory the
--- stubbed configure did not, so the clean has something to clean.
local function build(root)
  local ws, dev = load(root)
  local r = stubbed(ws, function() return cli.cmd_build(ws, { "build", dev.key }) end)
  assert.is_nil(r.exit_code, r.stderr .. r.stdout)
  for _, s in ipairs(r.spawned) do
    if s.build_dir then vim.fn.mkdir(s.build_dir, "p") end
  end
  return dev.key
end

describe("lw clean (module clean) persists the configured state", function()
  local saved_lines
  before_each(function()
    saved_lines = running.lines
    running.lines = function() return {} end -- no daemon
  end)
  after_each(function() running.lines = saved_lines end)

  it("a successful module clean drops the unit from built to configured, on disk", function()
    local root = make_ws()
    local key = build(root)
    assert.equals("built", (cached(root) or {}).state, vim.inspect(cached(root)))
    assert.equals("built", (status_state(root, key)))

    local ws = load(root)
    local r = stubbed(ws, function() return cli.cmd_clean(ws, key) end)
    assert.is_nil(r.exit_code, r.stderr .. r.stdout)
    assert.truthy(r.stdout:find("CLEAN OK: " .. key, 1, true), r.stdout)
    assert.equals(1, #r.spawned)
    assert.equals("clean", r.spawned[1].kind)

    local c = cached(root)
    assert.equals("configured", c and c.state, vim.inspect(c))
    assert.is_nil(c.last_built, vim.inspect(c))
    assert.is_not_nil(c.last_configured, "the configuration is kept: " .. vim.inspect(c))
    local s, text = status_state(root, key)
    assert.equals("configured", s, text)
    -- The module clean keeps the build directory (only a wipe removes it).
    assert.equals(1, vim.fn.isdirectory(r.spawned[1].build_dir), r.spawned[1].build_dir)
    vim.fn.delete(root, "rf")
  end)

  it("a failing module clean records nothing (the failure line, its exit code)", function()
    local root = make_ws()
    local key = build(root)
    local ws = load(root)
    local r = stubbed(ws, function() return cli.cmd_clean(ws, key) end, 2)
    assert.equals(2, r.exit_code, r.stderr .. r.stdout)
    assert.equals("built", (cached(root) or {}).state)
    vim.fn.delete(root, "rf")
  end)
end)

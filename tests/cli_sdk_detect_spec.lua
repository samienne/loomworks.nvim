-- `lw sdk add <type>` without a path declares an auto-detected installation
-- (the provider's `detect_all`, as the editor's SDKs section offers), and
-- `lw sdk detect [<type>]` lists what every provider detects (read-only):
--   * 0 detected → error naming the explicit-path form;
--   * 1 detected → declared, "detected <path>";
--   * several    → an interactive picker, or (non-interactive) an error that
--                  lists every candidate as the explicit command;
--   * an installation already declared is not offered again.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local SDK = require("loomworks.sdk")

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

local function read_user(root)
  local f = io.open(root .. "/.nvim/loomworks.user.json", "r")
  if not f then return nil end
  local c = f:read("*a"); f:close()
  -- The working copy is signed (workspace trust): the JSON is the first part.
  local ok, data = pcall(vim.json.decode, c)
  if ok then return data end
  return vim.json.decode((c:gsub("\n[^\n]*$", "")))
end

--- A fake provider whose `detect_all` returns `installs` (real directories, so
--- `validate` accepts them).
local function fake_provider(installs)
  local P = { id = "fakesdk", api_version = 1, display_name = "Fake SDK" }
  function P.detect_all() return installs end
  function P.validate(path)
    local st = (vim.uv or vim.loop).fs_stat(path)
    if not st then return nil end
    return { version = path:match("(%d+%.%d+)$") or "1.0" }
  end
  function P.derive_key(info, path)
    return "fakesdk-" .. info.version .. "-" .. (path:match("([^/]+)$") or "x")
  end
  function P.create_sdk(key, path, version)
    return SDK.new({ key = key, type = P.id, version = version, path = path,
      resolved = true, provider = P })
  end
  function P.query_capabilities() return nil end
  return P
end

describe("lw sdk add <type> (auto-detect) / lw sdk detect", function()
  local real_registry, root, provider

  local function mkdir(p) vim.fn.mkdir(p, "p"); return p end

  before_each(function()
    cli._reset_modes()
    root = (vim.fn.tempname():gsub("\\", "/"))
    mkdir(root .. "/App")
    -- Canonical (long) path: on Windows CI tempname() can be the 8.3 short
    -- form (RUNNER~1) while lw reports resolved paths.
    root = ((vim.uv or vim.loop).fs_realpath(root) or root):gsub("\\", "/")
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } }))
    f:close()
    real_registry = package.loaded["loomworks.sdks"]
    package.loaded["loomworks.sdks"] = {
      list = function() return { "fakesdk" } end,
      get = function(id) if id == "fakesdk" then return provider end end,
      all = function() return { fakesdk = provider } end,
      rejected = function() return {} end,
    }
  end)

  after_each(function()
    package.loaded["loomworks.sdks"] = real_registry
    cli._test_interactive = nil
    vim.fn.delete(root, "rf")
  end)

  local function sdk_paths()
    local u = read_user(root) or {}
    local paths = {}
    for _, s in pairs(u.sdks or {}) do paths[#paths + 1] = s.path end
    table.sort(paths)
    return paths
  end

  it("0 detected → error naming the explicit path form", function()
    provider = fake_provider({})
    local r = capture(function() cli.cmd_sdk("add", root, { "sdk", "add", "fakesdk" }) end)
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("no fakesdk installation detected", 1, true), r.stderr)
    assert.truthy(r.stderr:find("lw sdk add fakesdk <path>", 1, true), r.stderr)
    assert.same({}, sdk_paths())
  end)

  it("1 detected → declared, and the detected path is reported", function()
    local p = mkdir(root .. "/sdks/fake-2.5")
    provider = fake_provider({ { path = p, version = "2.5" } })
    local r = capture(function() cli.cmd_sdk("add", root, { "sdk", "add", "fakesdk" }) end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.truthy(r.stdout:find("detected " .. p, 1, true), r.stdout)
    assert.truthy(r.stdout:find("declared SDK: fakesdk-2.5-fake-2.5", 1, true), r.stdout)
    assert.same({ p }, sdk_paths())
  end)

  it("several detected, non-interactive → error listing every candidate", function()
    local a = mkdir(root .. "/sdks/fake-1.0")
    local b = mkdir(root .. "/sdks/fake-2.0")
    provider = fake_provider({ { path = a, version = "1.0" }, { path = b, version = "2.0" } })
    local saved = vim.env.LW_NO_INPUT
    vim.env.LW_NO_INPUT = "1"
    local r = capture(function() cli.cmd_sdk("add", root, { "sdk", "add", "fakesdk" }) end)
    vim.env.LW_NO_INPUT = saved
    cli._reset_modes()
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("2 fakesdk installations detected", 1, true), r.stderr)
    assert.truthy(r.stderr:find("lw sdk add fakesdk " .. a, 1, true), r.stderr)
    assert.truthy(r.stderr:find("lw sdk add fakesdk " .. b, 1, true), r.stderr)
    assert.same({}, sdk_paths())
  end)

  it("several detected, interactive → the picked one is declared", function()
    local a = mkdir(root .. "/sdks/fake-1.0")
    local b = mkdir(root .. "/sdks/fake-2.0")
    provider = fake_provider({ { path = a, version = "1.0" }, { path = b, version = "2.0" } })
    cli._test_interactive = true
    local real_read = io.read
    io.read = function() return "2" end
    local r = capture(function() cli.cmd_sdk("add", root, { "sdk", "add", "fakesdk" }) end)
    io.read = real_read
    assert.is_nil(r.exit_code, r.stderr)
    assert.truthy(r.stdout:find("1) Fake SDK 1.0", 1, true), r.stdout)
    assert.same({ b }, sdk_paths())
  end)

  it("an already-declared installation is not offered again", function()
    local a = mkdir(root .. "/sdks/fake-1.0")
    provider = fake_provider({ { path = a, version = "1.0" } })
    capture(function() cli.cmd_sdk("add", root, { "sdk", "add", "fakesdk" }) end)
    local r = capture(function() cli.cmd_sdk("add", root, { "sdk", "add", "fakesdk" }) end)
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("already declared", 1, true), r.stderr)
  end)

  it("sdk detect lists each provider's detected installations (no workspace needed)", function()
    local a = mkdir(root .. "/sdks/fake-1.0")
    provider = fake_provider({ { path = a, version = "1.0" } })
    local r = capture(function() cli.cmd_sdk("detect", nil, { "sdk", "detect" }) end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.truthy(r.stdout:find("fakesdk", 1, true), r.stdout)
    assert.truthy(r.stdout:find("1.0", 1, true), r.stdout)
    assert.truthy(r.stdout:find(a, 1, true), r.stdout)
    provider = fake_provider({})
    r = capture(function() cli.cmd_sdk("detect", nil, { "sdk", "detect", "fakesdk" }) end)
    assert.truthy(r.stdout:find("none detected", 1, true), r.stdout)
    r = capture(function() cli.cmd_sdk("detect", nil, { "sdk", "detect", "nosuch" }) end)
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("unknown SDK type 'nosuch'", 1, true), r.stderr)
  end)
end)

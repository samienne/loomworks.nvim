-- A project whose type has no loadable module — the plugin is missing, or it
-- is installed but refused for an api_version mismatch — keeps its full
-- type_config (configurations, launch, variables, deploy, description, any
-- other module field) through load → model → serialize (spec §8.0). Both the
-- published loomworks.json (`lw publish`) and the user.json working copy must
-- round-trip it verbatim, a configuration set mapping one of its
-- configurations must survive, and once the plugin does load, the preserved
-- configurations are what it sees.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local API = require("loomworks.api_versions")
local helpers = require("tests.helpers")

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex, rn = io.write, io.stderr, os.exit, vim.notify
  io.write = function(...) for _, s in ipairs({ ... }) do out_buf[#out_buf + 1] = s end end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  vim.notify = function() end
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, ret = pcall(fn)
  io.write, io.stderr, os.exit, vim.notify = rw, rs, rex, rn
  if not ok and not (type(ret) == "table" and ret.__exit) then error(ret, 0) end
  return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function run_main(root, ...)
  local saved_arg, saved_root = _G.arg, vim.env.LW_ROOT
  _G.arg = { ... }
  vim.env.LW_ROOT = root
  local r = capture(function() cli.main() end)
  _G.arg, vim.env.LW_ROOT = saved_arg, saved_root
  return r
end

local function ok(r, what)
  assert(r.exit_code == nil or r.exit_code == 0, what .. ": " .. r.stdout .. r.stderr)
end

local function read_json(path)
  local f = assert(io.open(path, "r"))
  local c = f:read("*a"); f:close()
  return vim.json.decode(c)
end

local function write_json(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write(vim.json.encode(data)); f:close()
end

local seq = 0
--- A fresh module id per test: the registry remembers a rejection for the
--- whole session, so ids must not be reused across tests.
local function fresh_type(prefix)
  seq = seq + 1
  return prefix .. "_" .. seq .. "_" .. tostring(vim.uv.hrtime() % 100000)
end

--- The full per-type payload of the module-less project, as it sits in a file.
local function odd_type_config()
  return {
    configurations = {
      Fast = { description = "the fast one", options = { LEVEL = "3" } },
      Slow = { inherits = "Fast" },
      Base = vim.empty_dict(),
    },
    frob_level = 7,
    description = "an odd project",
  }
end

local function odd_entry(type_id)
  return {
    [type_id] = odd_type_config(),
    path = "odd",
    launch = { go = { program = "x" } },
    variables = { thing = { type = "string", default = "v" } },
    deploy = { ["${build_dir}/x"] = { project = "odd", path = "y" } },
  }
end

--- Workspace whose loomworks.json holds a typescript App (so the workspace has
--- something buildable) and the module-less `odd` project, plus a configuration
--- set mapping odd's Fast.
local function make_ws(type_id)
  local root = (vim.fn.tempname():gsub("\\", "/"))
  vim.fn.mkdir(root .. "/App", "p")
  vim.fn.mkdir(root .. "/odd", "p")
  local f = assert(io.open(root .. "/App/tsconfig.json", "w")); f:write("{}"); f:close()
  write_json(root .. "/loomworks.json", {
    projects = {
      App = { typescript = vim.empty_dict() },
      odd = odd_entry(type_id),
    },
    configuration_sets = { S = { odd = "Fast" } },
  })
  return root
end

local function assert_odd_preserved(entry, type_id, where)
  assert.is_table(entry, where .. ": project odd missing")
  assert.same(odd_type_config(), entry[type_id], where .. ": type_config of odd")
  assert.same({ go = { program = "x" } }, entry.launch, where .. ": launch")
  assert.same({ thing = { type = "string", default = "v" } }, entry.variables, where .. ": variables")
  assert.same({ ["${build_dir}/x"] = { project = "odd", path = "y" } }, entry.deploy, where .. ": deploy")
end

--- Install a module under `type_id` with the given api_version — a renamed
--- copy of the typescript module, which builds configurations from the
--- declared `configurations` table.
local function install_module(type_id, api_version)
  local ts = require("loomworks.modules.typescript")
  local mod = {}
  for k, v in pairs(ts) do mod[k] = v end
  mod.id = type_id
  mod.api_version = api_version
  package.loaded["loomworks.modules." .. type_id] = mod
  return mod
end

local function variants()
  return {
    { name = "missing plugin", setup = function(id) return id end },
    { name = "rejected plugin (api_version mismatch)", setup = function(id)
      install_module(id, API.module + 1)
      -- Prime the registry so the rejection is in effect (as on first load).
      local rn = vim.notify
      vim.notify = function() end
      local got = require("loomworks.modules").get(id)
      vim.notify = rn
      assert.is_nil(got)
      return id
    end },
  }
end

for _, v in ipairs(variants()) do
  describe("module-less project (" .. v.name .. ")", function()
    local type_id
    before_each(function()
      type_id = v.setup(fresh_type("frobnicate"))
    end)
    after_each(function()
      package.loaded["loomworks.modules." .. type_id] = nil
    end)

    it("`lw publish` keeps its full type_config and the set mapping", function()
      local root = make_ws(type_id)
      local r = run_main(root, "publish")
      ok(r, "publish")
      local j = read_json(root .. "/loomworks.json")
      assert_odd_preserved(j.projects.odd, type_id, "loomworks.json")
      assert.same({ odd = "Fast" }, j.configuration_sets and j.configuration_sets.S,
        "configuration set S")
      vim.fn.delete(root, "rf")
    end)

    it("the user.json working copy round-trips it on an unrelated save", function()
      local root = make_ws(type_id)
      -- The project lives in user.json too (its working copy).
      vim.fn.mkdir(root .. "/.nvim", "p")
      local f = assert(io.open(root .. "/.nvim/loomworks.user.json", "wb"))
      local trust = require("loomworks.trust")
      local text, err = trust.sign("user", trust.encode({
        _meta = { version = 2 },
        projects = { odd = odd_entry(type_id) },
        configuration_sets = { S = { odd = "Fast" } },
      }))
      assert(text, err)
      f:write(text)
      f:close()
      -- An unrelated mutation rewrites user.json.
      ok(run_main(root, "project", "describe", "App", "the app"), "project describe")
      local u = read_json(root .. "/.nvim/loomworks.user.json")
      assert_odd_preserved(u.projects and u.projects.odd, type_id, "user.json")
      assert.same({ odd = "Fast" }, u.configuration_sets and u.configuration_sets.S,
        "user.json configuration set S")
      -- And publishing from that working copy keeps it as well.
      ok(run_main(root, "publish"), "publish")
      local j = read_json(root .. "/loomworks.json")
      assert_odd_preserved(j.projects.odd, type_id, "loomworks.json")
      vim.fn.delete(root, "rf")
    end)
  end)
end

describe("module-less project, plugin installed later", function()
  it("loads the configurations that survived a publish", function()
    local type_id = fresh_type("frobnicate_late")
    local root = make_ws(type_id)
    ok(run_main(root, "publish"), "publish without the plugin")

    install_module(type_id, API.module)
    local r = run_main(root, "config", "list", "odd")
    package.loaded["loomworks.modules." .. type_id] = nil
    ok(r, "config list")
    for _, name in ipairs({ "Fast", "Slow", "Base" }) do
      assert.is_truthy(r.stdout:find(name, 1, true), name .. " missing from:\n" .. r.stdout)
    end
    assert.is_truthy(r.stdout:find("the fast one", 1, true), "description lost:\n" .. r.stdout)
    vim.fn.delete(root, "rf")
  end)
end)

-- The editor's clean (`Profile:clean` / `ConfigUnit:clean`) of a module with
-- its own clean (the shell module WITH `clean_cmd`: the build system's
-- artifact clean, spec §16.1). Like the headless clean
-- (tests/cli_clean_module_state_spec.lua) the unit's built state drops to
-- `configured` only once the clean task SUCCEEDED (spec §4.7), persisted; a
-- failed clean leaves it `built`, and a state that is not a built one
-- (`failed_configure`, `unknown`) is never turned into `configured`.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local function quiet(fn)
  local rw, rs = io.write, io.stderr
  io.write = function() end
  io.stderr = { write = function() end }
  local ok, err = pcall(fn)
  io.write, io.stderr = rw, rs
  if not ok then error(err, 0) end
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
  quiet(function()
    cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" })
    cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" })
  end)
  return root
end

local function load(root)
  local ws = assert(cli._load_workspace(root, false))
  for _, p in ipairs(ws._profiles) do
    local cs = p:config_set()
    if cs and cs.name == "Dev" then
      local unit = assert(p:projects()[1]._config_unit, "no config unit")
      return ws, p, unit
    end
  end
  error("no Dev profile")
end

--- The unit in `state` with a build directory on disk, persisted.
local function fake_state(ws, unit, root, state)
  local dir = root .. "/out/Debug"
  vim.fn.mkdir(dir, "p")
  unit.build_dir_value = dir
  unit.state_value = state
  unit.last_configured = os.time()
  if state == "built" then unit.last_built = os.time() end
  ws:_sync_build_dir_refs()
  if unit._build_dir then
    unit._build_dir.state = state
    unit._build_dir.last_built = unit.last_built
  end
  ws:_save_cache()
end

local function cached(root)
  local f = assert(io.open(root .. "/.nvim/loomworks.cache.json", "r"))
  local data = vim.json.decode(f:read("*a")); f:close()
  for _, c in pairs(data.build_dirs or {}) do
    if c.project_key == "App" and c.config_key == "Debug" then return c end
  end
  return nil
end

local function wait(f)
  local done, ok = false, nil
  f:next(function() done, ok = true, true end):catch(function() done, ok = true, false end)
  vim.wait(5000, function() return done end, 10)
  return ok, done
end

describe("editor clean (module clean) records the clean after it succeeded", function()
  local exe = require("loomworks.exe")
  local real_overseer, real_harden
  local status, seen_state, unit_under_test

  before_each(function()
    real_overseer = package.loaded["overseer"]
    real_harden = exe.harden_spec
    exe.harden_spec = function(spec) return spec end
    status, seen_state, unit_under_test = "SUCCESS", nil, nil
    -- A fake overseer: the clean task completes on start with `status`,
    -- noting the unit's persisted state while it "runs".
    package.loaded["overseer"] = {
      new_task = function()
        local subs = {}
        local t = { _done = false }
        function t:subscribe(ev, cb) subs[ev] = cb end
        function t:is_complete() return self._done end
        function t:stop() end
        function t:start()
          vim.schedule(function()
            seen_state = unit_under_test and unit_under_test.state_value
            self._done = true
            if subs.on_complete then subs.on_complete(self, status) end
          end)
        end
        return t
      end,
    }
  end)

  after_each(function()
    package.loaded["overseer"] = real_overseer
    exe.harden_spec = real_harden
  end)

  it("Profile:clean: built -> configured only after the task succeeded", function()
    local root = make_ws()
    local ws, dev, unit = load(root)
    fake_state(ws, unit, root, "built")
    unit_under_test = unit
    local ok = wait(dev:clean())
    assert.is_true(ok)
    assert.equals("built", seen_state, "marked cleaned before the clean ran")
    local c = cached(root)
    assert.equals("configured", c and c.state, vim.inspect(c))
    assert.is_nil(c.last_built, vim.inspect(c))
    vim.fn.delete(root, "rf")
  end)

  it("Profile:clean: a failed clean task leaves the unit built", function()
    local root = make_ws()
    local ws, dev, unit = load(root)
    fake_state(ws, unit, root, "built")
    status = "FAILURE"
    wait(dev:clean())
    assert.equals("built", unit.state_value)
    assert.equals("built", (cached(root) or {}).state)
    vim.fn.delete(root, "rf")
  end)

  it("ConfigUnit:clean: failed_build -> configured", function()
    local root = make_ws()
    local ws, _, unit = load(root)
    fake_state(ws, unit, root, "failed_build")
    assert.is_true((wait(unit:clean())))
    assert.equals("configured", (cached(root) or {}).state)
    vim.fn.delete(root, "rf")
  end)

  for _, prior in ipairs({ "failed_configure", "unknown" }) do
    it("Profile:clean keeps a " .. prior .. " unit " .. prior, function()
      local root = make_ws()
      local ws, dev, unit = load(root)
      fake_state(ws, unit, root, prior)
      assert.is_true((wait(dev:clean())))
      assert.equals(prior, unit.state_value)
      assert.equals(prior, (cached(root) or {}).state)
      vim.fn.delete(root, "rf")
    end)
  end
end)

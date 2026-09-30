-- The "`lw publish` to update the shared loomworks.json." reminder (spec §16.9,
-- §16.35) is printed only when a loomworks.json exists AND the edited item's
-- effective intent reaches it. A local-only workspace (no loomworks.json yet)
-- never shows it after describe / rename / set.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local HINT = "`lw publish` to update the shared loomworks.json."

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, ret = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
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

--- A local-only workspace: `lw init` (no loomworks.json), a typescript App
--- with a Debug config, a Dev set, a (local) Dev profile and a launch.
local function make_local_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/App/tsconfig.json", "w")); f:write("{}"); f:close()
  for _, argv in ipairs({
    { "init" },
    { "project", "add", "App" },
    { "config", "add", "App", "Debug", "variant:default" },
    { "configset", "create", "Dev", "App=Debug" },
    { "profile", "create", "Dev" },
    { "launch", "add", "App", "demo", "node", "x.js" },
  }) do
    local r = run_main(root, unpack(argv))
    assert(r.exit_code == 0 or r.exit_code == nil, table.concat(argv, " ") .. ": " .. r.stderr)
  end
  assert(vim.fn.filereadable(root .. "/loomworks.json") == 0)
  return root
end

local EDITS = {
  { "launch", "describe", "App", "demo", "Demo launch" },
  { "project", "describe", "App", "The app" },
  { "config", "describe", "App", "Debug", "Debug build" },
  { "configset", "describe", "Dev", "Dev set" },
  { "profile", "describe", "1", "Dev profile" },
  { "config", "set", "App", "Debug", "description", "Set via config set" },
  { "launch", "rename", "App", "demo", "demo2" },
}

describe("publish hint", function()
  it("never appears in a local-only workspace (no loomworks.json)", function()
    local root = make_local_ws()
    for _, argv in ipairs(EDITS) do
      local r = run_main(root, unpack(argv))
      assert.is_true(r.exit_code == 0 or r.exit_code == nil, table.concat(argv, " ") .. ": " .. r.stderr)
      assert.is_nil(r.stdout:find(HINT, 1, true), table.concat(argv, " ") .. " printed the hint")
    end
  end)

  it("appears once loomworks.json exists and the item reaches it", function()
    local root = make_local_ws()
    assert.equals(0, run_main(root, "publish").exit_code or 0)
    assert.equals(1, vim.fn.filereadable(root .. "/loomworks.json"))
    -- App and Dev are local+shared (CLI default) → reach loomworks.json.
    for _, argv in ipairs({
      { "project", "describe", "App", "The app" },
      { "configset", "describe", "Dev", "Dev set" },
      { "launch", "describe", "App", "demo", "Demo launch" },
      { "launch", "rename", "App", "demo", "demo2" },
    }) do
      local r = run_main(root, unpack(argv))
      assert.is_truthy(r.stdout:find(HINT, 1, true), table.concat(argv, " ") .. " lacks the hint")
    end
    -- The Dev profile stays local → no hint even with loomworks.json present.
    local r = run_main(root, "profile", "describe", "1", "Dev profile")
    assert.is_nil(r.stdout:find(HINT, 1, true))
  end)
end)

-- Remove/rename (and configset map/unmap) suggest `lw publish` only when the
-- item reaches the shared loomworks.json (§2.4 effective intent — its own
-- intent, a published set/profile pulling it in, or an existing published
-- copy the edit changes). A never-published LOCAL item has nothing to publish,
-- the same rule `lw config add/set/unset` already follow.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

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

local HINT = "lw publish"

local function make_ws()
  local root = (vim.fn.tempname():gsub("\\", "/"))
  vim.fn.mkdir(root .. "/App", "p")
  vim.fn.mkdir(root .. "/Lib", "p")
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } }))
  f:close()
  return root
end

--- Run `fn` (a mutating CLI command) and assert it succeeded; returns stdout.
local function run(fn)
  local r = capture(fn)
  assert.is_nil(r.exit_code, r.stderr .. r.stdout)
  return r.stdout
end

describe("publish hint on remove/rename of a LOCAL item", function()
  local root
  before_each(function() root = make_ws() end)
  after_each(function()
    cli._set_create_intent(nil)
    vim.fn.delete(root, "rf")
  end)

  local function local_mode(fn)
    cli._set_create_intent("local")
    local ok, err = pcall(fn)
    cli._set_create_intent(nil)
    if not ok then error(err, 0) end
  end

  it("config remove / rename", function()
    local_mode(function()
      run(function() cli.cmd_configuration("add", root, "App", "Mine", "variant:default") end)
      run(function() cli.cmd_configuration("add", root, "App", "Gone", "variant:default") end)
    end)
    local mv = run(function() cli.cmd_configuration("rename", root, "App", "Mine", "Mine2") end)
    assert.is_truthy(mv:find("renamed configuration", 1, true), mv)
    assert.is_nil(mv:find(HINT, 1, true), mv)
    local rm = run(function() cli.cmd_configuration("remove", root, "App", "Gone") end)
    assert.is_truthy(rm:find("removed configuration", 1, true), rm)
    assert.is_nil(rm:find(HINT, 1, true), rm)
  end)

  it("configset map / unmap / rename / remove", function()
    local_mode(function()
      run(function() cli.cmd_configuration("add", root, "App", "Mine", "variant:default") end)
      run(function() cli.cmd_cset_create(root, { "configset", "create", "loc" }) end)
    end)
    local map = run(function() cli.cmd_cset("map", root, { "configset", "map", "loc", "App", "Mine" }) end)
    assert.is_nil(map:find(HINT, 1, true), map)
    local unmap = run(function() cli.cmd_cset("unmap", root, { "configset", "unmap", "loc", "App" }) end)
    assert.is_nil(unmap:find(HINT, 1, true), unmap)
    local mv = run(function() cli.cmd_cset("rename", root, { "configset", "rename", "loc", "loc2" }) end)
    assert.is_truthy(mv:find("renamed configuration set", 1, true), mv)
    assert.is_nil(mv:find(HINT, 1, true), mv)
    local rm = run(function() cli.cmd_cset("remove", root, { "configset", "remove", "loc2" }) end)
    assert.is_truthy(rm:find("removed configuration set", 1, true), rm)
    assert.is_nil(rm:find(HINT, 1, true), rm)
  end)

  it("profile remove (profiles are created local)", function()
    local_mode(function()
      run(function() cli.cmd_cset_create(root, { "configset", "create", "dev", "App=default" }) end)
    end)
    run(function() cli.cmd_profile_create(root, { "profile", "create", "dev" }) end)
    local rm = run(function() cli.cmd_profile_remove(root, { "profile", "remove", "dev" }) end)
    assert.is_truthy(rm:find("removed profile", 1, true), rm)
    assert.is_nil(rm:find(HINT, 1, true), rm)
  end)

  it("project rename / remove", function()
    local_mode(function()
      run(function() cli.cmd_project_add(root, root .. "/Lib", "typescript", "Lib") end)
    end)
    local mv = run(function() cli.cmd_project_rename(root, "Lib", "Lib2") end)
    assert.is_truthy(mv:find("renamed project", 1, true), mv)
    assert.is_nil(mv:find(HINT, 1, true), mv)
    local rm = run(function() cli.cmd_project_remove(root, "Lib2") end)
    assert.is_truthy(rm:find("removed project", 1, true), rm)
    assert.is_nil(rm:find(HINT, 1, true), rm)
  end)
end)

describe("publish hint on remove/rename of a SHARED item", function()
  local root
  before_each(function() root = make_ws() end)
  after_each(function() vim.fn.delete(root, "rf") end)

  it("config remove / rename of a published configuration", function()
    run(function() cli.cmd_configuration("add", root, "App", "Team", "variant:default") end)
    run(function() cli.cmd_configuration("add", root, "App", "Old", "variant:default") end)
    run(function() cli.cmd_configuration("publish", root, "App", "Team") end)
    run(function() cli.cmd_configuration("publish", root, "App", "Old") end)
    local mv = run(function() cli.cmd_configuration("rename", root, "App", "Team", "Team2") end)
    assert.is_truthy(mv:find(HINT, 1, true), mv)
    local rm = run(function() cli.cmd_configuration("remove", root, "App", "Old") end)
    assert.is_truthy(rm:find(HINT, 1, true), rm)
  end)

  it("configset rename / remove of a shared set", function()
    run(function() cli.cmd_cset_create(root, { "configset", "create", "team", "App=default" }) end)
    run(function() cli.cmd_publish(root) end)
    local mv = run(function() cli.cmd_cset("rename", root, { "configset", "rename", "team", "team2" }) end)
    assert.is_truthy(mv:find(HINT, 1, true), mv)
    local rm = run(function() cli.cmd_cset("remove", root, { "configset", "remove", "team2" }) end)
    assert.is_truthy(rm:find(HINT, 1, true), rm)
  end)

  it("profile remove of a published profile", function()
    run(function() cli.cmd_cset_create(root, { "configset", "create", "dev", "App=default" }) end)
    run(function() cli.cmd_profile_create(root, { "profile", "create", "dev" }) end)
    run(function() cli.cmd_profile_publish(root, "dev") end)
    local rm = run(function() cli.cmd_profile_remove(root, { "profile", "remove", "dev" }) end)
    assert.is_truthy(rm:find(HINT, 1, true), rm)
  end)

  it("project remove of a shared project", function()
    local rm = run(function() cli.cmd_project_remove(root, "App") end)
    assert.is_truthy(rm:find(HINT, 1, true), rm)
  end)
end)

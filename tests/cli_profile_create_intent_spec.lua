-- `lw profile create` sets a profile's intent only when it creates the profile
-- (API.md §11 `Profiles/1.create`: "A new profile's intent is `local`"; the
-- shared model_commands.profile_create does the same). An existing profile of
-- that set and toolchain is returned as it is: its intent — a published one
-- included — is not reset to `local`.

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

local function run(fn)
  local r = capture(fn)
  assert.is_nil(r.exit_code, r.stderr .. r.stdout)
  return r.stdout
end

local function make_ws()
  local root = (vim.fn.tempname():gsub("\\", "/"))
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } }))
  f:close()
  return root
end

describe("lw profile create: intent", function()
  local root
  before_each(function() root = make_ws() end)
  after_each(function()
    cli._set_create_intent(nil)
    vim.fn.delete(root, "rf")
  end)

  it("a new profile is local", function()
    run(function() cli.cmd_cset_create(root, { "configset", "create", "dev", "App=default" }) end)
    local out = run(function() cli.cmd_profile_create(root, { "profile", "create", "dev" }) end)
    assert.is_truthy(out:find("created profile: dev  [local]", 1, true), out)
  end)

  it("an existing (published) profile keeps its intent", function()
    run(function() cli.cmd_cset_create(root, { "configset", "create", "dev", "App=default" }) end)
    run(function() cli.cmd_profile_create(root, { "profile", "create", "dev" }) end)
    run(function() cli.cmd_profile_publish(root, "dev") end)
    local out = run(function() cli.cmd_profile_create(root, { "profile", "create", "dev" }) end)
    assert.is_truthy(out:find("profile already exists: dev  [local+shared]", 1, true), out)
  end)
end)

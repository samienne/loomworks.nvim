-- `lw project show` without a name (spec §16.9): shows the workspace's project
-- when it has exactly one; with several it lists them and the
-- `lw project show <name>` form and exits 2 (usage); with none it says so and
-- exits 2.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex, rstd = io.write, io.stderr, os.exit, io.stdout
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stdout = { write = function(_, s) out_buf[#out_buf + 1] = s end, flush = function() end }
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end, flush = function() end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, ret = pcall(fn)
  io.write, io.stderr, os.exit, io.stdout = rw, rs, rex, rstd
  if not ok and not (type(ret) == "table" and ret.__exit) then error(ret, 0) end
  return { exit_code = exit_code, ret = ok and ret or nil,
    stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

--- Temp workspace with one typescript project per name in `names`.
local function make_ws(names)
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root, "p")
  local projects = vim.empty_dict()
  for _, n in ipairs(names) do
    vim.fn.mkdir(root .. "/" .. n, "p")
    projects[n] = { typescript = vim.empty_dict() }
  end
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = projects })); f:close()
  return root
end

describe("lw project show without a name (§16.9)", function()
  it("shows the only project, as `lw project show <name>` does", function()
    local root = make_ws({ "App" })
    local named = capture(function() return cli.cmd_project_show(root, "App") end)
    assert.equals(0, named.ret, named.stderr)
    local bare = capture(function() return cli.cmd_project("show", root) end)
    assert.is_nil(bare.exit_code, bare.stderr)
    assert.equals(0, bare.ret, bare.stderr)
    assert.equals(named.stdout, bare.stdout)
    assert.truthy(bare.stdout:find("^App  %(typescript%)"), bare.stdout)
  end)

  it("lists the projects and the named form, exit 2, when there are several", function()
    local root = make_ws({ "Beta", "Alpha" })
    local r = capture(function() return cli.cmd_project("show", root) end)
    assert.equals(2, r.exit_code, r.stderr)
    assert.equals("", r.stdout)
    assert.truthy(r.stderr:find("lw project show <name>", 1, true), r.stderr)
    local a = r.stderr:find("\n  Alpha\n", 1, true)
    local b = r.stderr:find("\n  Beta\n", 1, true)
    assert.truthy(a and b and a < b, r.stderr)
  end)

  it("says there are no projects, exit 2, when there are none", function()
    local root = make_ws({})
    local r = capture(function() return cli.cmd_project("show", root) end)
    assert.equals(2, r.exit_code, r.stderr)
    assert.truthy(r.stderr:find("no projects", 1, true), r.stderr)
  end)
end)

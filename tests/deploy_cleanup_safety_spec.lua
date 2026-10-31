-- Deploy cleanup deletion safety (spec §8.8.5 step 2): a deploy record's key
-- comes from loomworks.cache.json, so cleanup unlinks it only when it is an
-- absolute, traversal-free path to a regular file whose canonical path lies
-- strictly under the workspace root with no link on the way. A destination
-- outside the workspace is left in place (record dropped, reported); an
-- invalid key is dropped without touching disk.
local deploy = require("loomworks.deploy")

local uv = vim.uv or vim.loop
local is_win = vim.fn.has("win32") == 1
local ID = "build/Lib/Debug"

local function normalize(p)
  p = vim.fs.normalize(p)
  return is_win and p:lower() or p
end

local function write(path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write("x")
  f:close()
end

local function exists(path) return uv.fs_lstat(path) ~= nil end

local function record() return { source_build_dir = ID, source_rel_path = "f", source_mtime = 1 } end

describe("deploy cleanup safety (§8.8.5)", function()
  local base, root, outside, left, invalid, opts

  before_each(function()
    base = vim.fn.tempname():gsub("\\", "/")
    root = base .. "/ws"
    outside = base .. "/outside"
    vim.fn.mkdir(root, "p")
    vim.fn.mkdir(outside, "p")
    left, invalid = {}, {}
    opts = {
      root = root,
      normalize = normalize,
      on_left = function(dest) left[#left + 1] = dest end,
      on_invalid = function(dest) invalid[#invalid + 1] = dest end,
    }
  end)

  after_each(function() vim.fn.delete(base, "rf") end)

  it("deletes a legitimate destination inside the workspace", function()
    local dest = root .. "/App/Debug/lib.node"
    write(dest)
    local records = { [normalize(dest)] = record() }
    local removed = deploy.clean_deploy_records(records, ID, opts)
    assert.equals(1, #removed)
    assert.is_nil(next(records))
    assert.is_false(exists(dest))
    assert.same({}, left)
  end)

  it("leaves a destination outside the workspace and reports it", function()
    local dest = outside .. "/lib.node"
    write(dest)
    local key = normalize(dest)
    local records = { [key] = record() }
    deploy.clean_deploy_records(records, ID, opts)
    assert.is_nil(records[key])
    assert.is_true(exists(dest))
    assert.same({ key }, left)
  end)

  it("never deletes outside through a link/junction inside the workspace", function()
    local target = outside .. "/lib.node"
    write(target)
    assert(uv.fs_symlink(outside, root .. "/alias", is_win and { junction = true } or nil))
    local key = normalize(root .. "/alias/lib.node")
    local records = { [key] = record() }
    deploy.clean_deploy_records(records, ID, opts)
    assert.is_nil(records[key])
    assert.is_true(exists(target))
  end)

  it("does not delete through a link that points back inside the workspace", function()
    local target = root .. "/real/lib.node"
    write(target)
    assert(uv.fs_symlink(root .. "/real", root .. "/alias", is_win and { junction = true } or nil))
    local key = normalize(root .. "/alias/lib.node")
    local records = { [key] = record() }
    deploy.clean_deploy_records(records, ID, opts)
    assert.is_nil(records[key])
    assert.is_true(exists(target))
  end)

  it("drops a traversal key without touching disk", function()
    local target = outside .. "/lib.node"
    write(target)
    local key = normalize(root) .. "/../outside/lib.node"
    local records = { [key] = record() }
    deploy.clean_deploy_records(records, ID, opts)
    assert.is_nil(records[key])
    assert.is_true(exists(target))
    assert.same({ key }, invalid)
    assert.same({}, left)
  end)

  it("drops a relative key without touching disk", function()
    local records = { ["App/lib.node"] = record() }
    deploy.clean_deploy_records(records, ID, opts)
    assert.is_nil(records["App/lib.node"])
    assert.same({ "App/lib.node" }, invalid)
  end)

  it("drops a directory key without removing the directory", function()
    local dir = root .. "/App/Debug"
    write(dir .. "/keep.txt")
    local key = normalize(dir)
    local records = { [key] = record() }
    deploy.clean_deploy_records(records, ID, opts)
    assert.is_nil(records[key])
    assert.is_true(exists(dir .. "/keep.txt"))
    assert.same({ key }, invalid)
  end)

  it("drops a missing-file key silently", function()
    local key = normalize(root .. "/gone.node")
    local records = { [key] = record() }
    local removed = deploy.clean_deploy_records(records, ID, opts)
    assert.equals(1, #removed)
    assert.is_nil(records[key])
    assert.same({}, left)
  end)

  it("unlinks nothing when no workspace root is given", function()
    local dest = root .. "/App/lib.node"
    write(dest)
    local key = normalize(dest)
    local records = { [key] = record() }
    deploy.clean_deploy_records(records, ID, { normalize = normalize })
    assert.is_nil(records[key])
    assert.is_true(exists(dest))
  end)

  it("keeps records sourced from other build dirs", function()
    local dest = root .. "/App/lib.node"
    write(dest)
    local key = normalize(dest)
    local records = { [key] = { source_build_dir = "other" } }
    deploy.clean_deploy_records(records, ID, opts)
    assert.is_not_nil(records[key])
    assert.is_true(exists(dest))
  end)

  it("Workspace callers pass the root and report outside destinations", function()
    local Workspace = require("loomworks.workspace").Workspace
    local in_dest, out_dest = root .. "/App/lib.node", outside .. "/lib.node"
    write(in_dest)
    write(out_dest)
    local notes = {}
    local ws = setmetatable({
      root = root,
      _deploy_records = { [normalize(in_dest)] = record(), [normalize(out_dest)] = record() },
      _core = { _deps = {
        normalize = normalize,
        notify = function(msg) notes[#notes + 1] = msg end,
        log = { debug = function() end },
      } },
    }, Workspace)
    ws:_clean_deploy_records(ID)
    assert.is_nil(next(ws._deploy_records))
    assert.is_false(exists(in_dest))
    assert.is_true(exists(out_dest))
    assert.equals(1, #notes)
    assert.matches("deploy cleanup: left .* %(outside the workspace%)", notes[1])
  end)
end)

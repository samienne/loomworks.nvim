-- Stray build directory detection + deletion (orphan cleanup) must compare
-- DIRECTORY IDENTITY, not path spelling. The workspace root is canonicalized
-- (long name + real case), but a ConfigUnit's build dir can be recorded in a
-- different spelling of the same location — on a Windows runner the temp dir is
-- an 8.3 short path (`C:\Users\RUNNER~1\...`). A string comparison then misses
-- the live build dir `App/Debug` below `.nvim/build/App`, reports `App` as a
-- stray directory, and orphan cleanup would DELETE a live build dir.
--
-- Two layers: a real 8.3 short-name reproduction (Windows with 8.3 name
-- generation only — skipped elsewhere) and a deterministic variant that injects
-- deps.realpath (the same seam the deletion boundary check uses) so the
-- identity contract is pinned on every platform.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local wv = require("loomworks.workspace_view")
local uv = vim.uv or vim.loop

local function quiet(fn)
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function() end
  io.stderr = { write = function() end }
  os.exit = function() error({ __exit = true }, 0) end
  pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
end

--- A workspace at `root` with a typescript App, a `Debug` config, a `Dev` set
--- and an active `Dev` profile.
local function make_ws(root)
  vim.fn.mkdir(root .. "/App", "p")
  local lw = { projects = { App = { typescript = vim.empty_dict() } } }
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode(lw)); f:close()
  quiet(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
  quiet(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" }) end)
  quiet(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
  local ws = assert(cli._load_workspace(root, false))
  local profile = assert(ws._profiles[1], "workspace has no profile")
  return ws, profile
end

--- Record `dir` (any spelling) as the profile's live build dir; `real_dir` is
--- where it is created on disk.
local function live_build_dir(ws, profile, dir, real_dir)
  local pp = profile:projects()[1]
  local unit = assert(pp and pp._config_unit, "profile project has no config unit")
  vim.fn.mkdir(real_dir, "p")
  local mf = assert(io.open(real_dir .. "/marker.txt", "w")); mf:write("x"); mf:close()
  unit.build_dir_value = dir
  unit.state_value = "built"
  ws:_sync_build_dir_refs()
  return unit
end

--- A fresh temp dir containing one long-named child; returns (long, short) or
--- (long, nil) when no distinct 8.3 short name resolves to it.
local function short_named_root()
  local base = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(base, "p")
  base = assert(uv.fs_realpath(base)):gsub("\\", "/")
  local long = base .. "/loomworksshortnameprobe"
  vim.fn.mkdir(long, "p")
  if vim.fn.has("win32") == 0 then return long, nil end
  -- The sole child of a fresh dir gets the `~1` 8.3 alias when the volume
  -- generates 8.3 names; accept it only if it resolves to the same directory.
  local short = base .. "/LOOMWO~1"
  local rs, rl = uv.fs_realpath(short), uv.fs_realpath(long)
  if not rs or not rl or rs:lower() ~= rl:lower() then return long, nil end
  return long, short
end

describe("find_stray_build_dirs: directory identity, not spelling", function()
  it("does not report a dir containing a live build dir recorded via an 8.3 short path", function()
    local long, short = short_named_root()
    if not short then
      pending("8.3 short names unavailable on this platform/volume")
      return
    end
    local ws, profile = make_ws(long)
    -- The live build dir is recorded in the SHORT spelling (as a runner's
    -- tempname()-derived path would be); ws.root is the canonical LONG form.
    live_build_dir(ws, profile, short .. "/.nvim/build/App/Debug", long .. "/.nvim/build/App/Debug")
    vim.fn.mkdir(long .. "/.nvim/build/Old", "p")

    local stray = wv.find_stray_build_dirs(ws)
    assert.equals(1, #stray, vim.inspect(stray))
    assert.is_truthy(stray[1]:lower():find("/%.nvim/build/old$"), vim.inspect(stray))
  end)

  describe("deterministic (injected realpath)", function()
    local ws, profile, root, alias

    before_each(function()
      root = vim.fn.tempname():gsub("\\", "/")
      vim.fn.mkdir(root, "p")
      ws, profile = make_ws(root)
      root = ws.root
      -- A second spelling of the root that only the injected realpath knows
      -- resolves to the real root — a stand-in for an 8.3 short name.
      alias = root:gsub("/[^/]+$", "/ALIAS~1")
      local real = ws._core._deps.realpath or uv.fs_realpath
      ws._core._deps.realpath = function(p)
        p = p:gsub("\\", "/")
        if p == alias or p:sub(1, #alias + 1) == alias .. "/" then
          p = root .. p:sub(#alias + 1)
        end
        return real(p)
      end
      live_build_dir(ws, profile, alias .. "/.nvim/build/App/Debug", root .. "/.nvim/build/App/Debug")
      vim.fn.mkdir(root .. "/.nvim/build/Old/x", "p")
    end)

    it("reports only the genuinely stray dir", function()
      local stray = wv.find_stray_build_dirs(ws)
      assert.equals(1, #stray, vim.inspect(stray))
      assert.is_truthy(stray[1]:lower():find("/%.nvim/build/old$"), vim.inspect(stray))
    end)

    it("refuses to delete a 'stray' dir that contains a live build dir", function()
      local done, ok_res, err_res = false, nil, nil
      wv.execute_delete_stray_dir(ws, root .. "/.nvim/build/App", function(ok, err)
        done, ok_res, err_res = true, ok, err
      end)
      assert.is_true(vim.wait(5000, function() return done end, 20))
      assert.is_false(ok_res)
      assert.is_truthy(err_res)
      assert.is_not_nil(uv.fs_stat(root .. "/.nvim/build/App/Debug/marker.txt"))
    end)

    it("orphan cleanup skips a listed dir that contains a live build dir", function()
      local done = false
      wv.execute_orphan_cleanup(ws, {}, { root .. "/.nvim/build/App" }, function() done = true end)
      assert.is_true(vim.wait(5000, function() return done end, 20))
      assert.is_not_nil(uv.fs_stat(root .. "/.nvim/build/App/Debug/marker.txt"))
    end)

    it("orphan cleanup keeps an orphaned entry's dir that is a live build dir", function()
      local done = false
      local orphan = { project_key = "Gone", config_key = "Debug", build_dir = root .. "/.nvim/build/App/Debug" }
      wv.execute_orphan_cleanup(ws, { orphan }, {}, function() done = true end)
      assert.is_true(vim.wait(5000, function() return done end, 20))
      assert.is_not_nil(uv.fs_stat(root .. "/.nvim/build/App/Debug/marker.txt"))
    end)

    it("still deletes a genuinely stray dir", function()
      local done = false
      wv.execute_orphan_cleanup(ws, {}, wv.find_stray_build_dirs(ws), function() done = true end)
      assert.is_true(vim.wait(5000, function() return done end, 20))
      assert.is_true(vim.wait(5000, function() return uv.fs_stat(root .. "/.nvim/build/Old") == nil end, 20))
      assert.is_not_nil(uv.fs_stat(root .. "/.nvim/build/App/Debug/marker.txt"))
    end)

    it("refuses to delete a dir lying inside a live build dir under .nvim/build", function()
      vim.fn.mkdir(root .. "/.nvim/build/App/Debug/sub", "p")
      local done, ok_res = false, nil
      wv.execute_delete_stray_dir(ws, root .. "/.nvim/build/App/Debug/sub", function(ok)
        done, ok_res = true, ok
      end)
      assert.is_true(vim.wait(5000, function() return done end, 20))
      assert.is_false(ok_res)
      assert.is_not_nil(uv.fs_stat(root .. "/.nvim/build/App/Debug/sub"))
    end)
  end)

  -- An in-source unit (build_dir == workspace root, allowed by
  -- _pre_configure_reset) is an ancestor of all of .nvim/build. That must not
  -- make every stray dir look like it "lies inside a live build dir".
  describe("in-source live build dir", function()
    local ws, root

    before_each(function()
      root = vim.fn.tempname():gsub("\\", "/")
      vim.fn.mkdir(root, "p")
      local profile
      ws, profile = make_ws(root)
      root = ws.root
      live_build_dir(ws, profile, root, root)
      vim.fn.mkdir(root .. "/.nvim/build/Old/x", "p")
    end)

    it("reports the genuinely stray dir", function()
      local stray = wv.find_stray_build_dirs(ws)
      assert.equals(1, #stray, vim.inspect(stray))
      assert.is_truthy(stray[1]:lower():find("/%.nvim/build/old$"), vim.inspect(stray))
    end)

    it("orphan cleanup deletes the stray dir", function()
      local done = false
      wv.execute_orphan_cleanup(ws, {}, wv.find_stray_build_dirs(ws), function() done = true end)
      assert.is_true(vim.wait(5000, function() return done end, 20))
      assert.is_true(vim.wait(5000, function() return uv.fs_stat(root .. "/.nvim/build/Old") == nil end, 20))
      assert.is_not_nil(uv.fs_stat(root .. "/marker.txt"))
    end)

    it("execute_delete_stray_dir deletes the stray dir", function()
      local done, ok_res, err_res = false, nil, nil
      wv.execute_delete_stray_dir(ws, root .. "/.nvim/build/Old", function(ok, err)
        done, ok_res, err_res = true, ok, err
      end)
      assert.is_true(vim.wait(5000, function() return done end, 20))
      assert.is_true(ok_res, tostring(err_res))
      assert.is_nil(uv.fs_stat(root .. "/.nvim/build/Old"))
    end)
  end)

  -- A live build dir whose path goes through a link/junction canonicalizes
  -- OUTSIDE .nvim/build; its recorded spelling must still protect its parent.
  describe("live build dir behind a link", function()
    local ws, root

    before_each(function()
      root = vim.fn.tempname():gsub("\\", "/")
      vim.fn.mkdir(root, "p")
      local profile
      ws, profile = make_ws(root)
      root = ws.root
      local link = (root .. "/.nvim/build/App/Debug"):lower()
      local target = root:gsub("/[^/]+$", "/linktarget")
      local real = ws._core._deps.realpath or uv.fs_realpath
      ws._core._deps.realpath = function(p)
        p = p:gsub("\\", "/")
        local lp = p:lower()
        if lp == link or lp:sub(1, #link + 1) == link .. "/" then
          return target .. p:sub(#link + 1)
        end
        return real(p)
      end
      live_build_dir(ws, profile, root .. "/.nvim/build/App/Debug", root .. "/.nvim/build/App/Debug")
      vim.fn.mkdir(root .. "/.nvim/build/Old", "p")
    end)

    it("does not report the link's parent as stray", function()
      local stray = wv.find_stray_build_dirs(ws)
      assert.equals(1, #stray, vim.inspect(stray))
      assert.is_truthy(stray[1]:lower():find("/%.nvim/build/old$"), vim.inspect(stray))
    end)

    it("refuses to delete the link's parent", function()
      local done, ok_res = false, nil
      wv.execute_delete_stray_dir(ws, root .. "/.nvim/build/App", function(ok)
        done, ok_res = true, ok
      end)
      assert.is_true(vim.wait(5000, function() return done end, 20))
      assert.is_false(ok_res)
      assert.is_not_nil(uv.fs_stat(root .. "/.nvim/build/App/Debug/marker.txt"))
    end)
  end)
end)

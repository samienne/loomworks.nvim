local workspace = require("loomworks.workspace")
local h = require("tests.helpers")

describe("workspace", function()
  describe("paths", function()
    it("returns all three file paths", function()
      local p = workspace.paths("/my/workspace")
      assert.equals("/my/workspace/loomworks.json", p.config)
      assert.equals("/my/workspace/.nvim/loomworks.user.json", p.user)
      assert.equals("/my/workspace/.nvim/loomworks.cache.json", p.cache)
    end)
  end)

  describe("resolve_root", function()
    it("strips trailing slash", function()
      local root = workspace.resolve_root(nil, function(p) return p .. "/" end)
      assert.is_nil(root:match("/$"))
    end)

    it("uses provided path", function()
      local root = workspace.resolve_root("/my/path", function(p) return p end)
      assert.equals("/my/path", root)
    end)
  end)

  describe("assemble", function()
    it("assembles workspace from raw content", function()
      local config_json = h.make_config_json()
      local ws, err = workspace.assemble("/root", config_json, nil, nil)
      assert.is_nil(err)
      assert.is_not_nil(ws)
      assert.equals("/root", ws.root)
      assert.is_not_nil(ws.config.projects.App)
      assert.equals("cmake", ws.config.projects.App.type)
    end)

    it("returns error when config_content is nil", function()
      local ws, err = workspace.assemble("/root", nil, nil, nil)
      assert.is_nil(ws)
      assert.matches("not found", err)
    end)

    it("returns error on invalid config JSON", function()
      local ws, err = workspace.assemble("/root", "broken", nil, nil)
      assert.is_nil(ws)
      assert.is_not_nil(err)
    end)

    it("uses defaults when user/cache content is nil", function()
      local config_json = h.make_config_json()
      local ws = workspace.assemble("/root", config_json, nil, nil)
      assert.is_not_nil(ws.user)
      assert.is_not_nil(ws.cache)
      assert.equals(1, ws.user._meta.version)
      assert.equals(3, ws.cache._meta.version)
    end)

    it("parses user.json when provided", function()
      local config_json = h.make_config_json()
      local user_json = h.make_user_json({ active_profile = "debug" })
      local ws = workspace.assemble("/root", config_json, user_json, nil)
      assert.equals("debug", ws.user.active_profile)
    end)

    it("parses cache.json when provided", function()
      local config_json = h.make_config_json()
      local cache_json = h.make_cache_json({
        projects = {
          App = {
            type = "cmake",
            configurations = {
              Debug = { state = "built" },
            },
          },
        },
      })
      local ws = workspace.assemble("/root", config_json, nil, cache_json)
      assert.equals("built", ws.cache.projects.App.configurations.Debug.state)
    end)

    it("derives name from directory when not in config", function()
      local config_json = h.make_config_json()
      local ws = workspace.assemble("/home/user/my-project", config_json, nil, nil)
      assert.equals("my-project", ws.name)
    end)

    it("uses config name when provided", function()
      local config_json = h.make_config_json({ name = "CustomName" })
      local ws = workspace.assemble("/root", config_json, nil, nil)
      assert.equals("CustomName", ws.name)
    end)

    it("computes cache hash from config content", function()
      local config_json = h.make_config_json()
      local ws = workspace.assemble("/root", config_json, nil, nil)
      assert.is_not_nil(ws.cache._meta.loomworks_hash)
      assert.are_not.equals("", ws.cache._meta.loomworks_hash)
    end)

    it("produces consistent hash for same content", function()
      local config_json = h.make_config_json()
      local ws1 = workspace.assemble("/root", config_json, nil, nil)
      local ws2 = workspace.assemble("/root", config_json, nil, nil)
      assert.equals(ws1.cache._meta.loomworks_hash, ws2.cache._meta.loomworks_hash)
    end)

    it("sets cache_version_mismatch false when no cache content", function()
      local config_json = h.make_config_json()
      local ws = workspace.assemble("/root", config_json, nil, nil)
      assert.is_false(ws.cache_version_mismatch)
    end)

    it("sets cache_version_mismatch false on matching version", function()
      local config_json = h.make_config_json()
      local cache_json = h.make_cache_json()
      local ws = workspace.assemble("/root", config_json, nil, cache_json)
      assert.is_false(ws.cache_version_mismatch)
    end)

    it("sets cache_version_mismatch true on wrong version", function()
      local config_json = h.make_config_json()
      local cache_json = vim.json.encode({
        _meta = { version = 1 },
        projects = {},
      })
      local ws = workspace.assemble("/root", config_json, nil, cache_json)
      assert.is_true(ws.cache_version_mismatch)
      -- Cache data should be defaults (empty)
      assert.are.same({}, ws.cache.projects)
    end)
  end)
end)

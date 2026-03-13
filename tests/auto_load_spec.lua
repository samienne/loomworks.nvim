local auto_load = require("loomworks.auto_load")

describe("auto_load", function()
  describe("decide", function()
    -- decide(opts) returns an action:
    --   "load"   = load the workspace
    --   "prompt" = ask user before loading
    --   "notify" = notify but don't load
    --   "skip"   = do nothing

    it("returns skip when mode is false", function()
      assert.equals("skip", auto_load.decide({
        mode = false,
        config_exists = true,
        cache_exists = true,
        loaded_root = nil,
      }))
    end)

    it("returns skip when no loomworks.json in cwd", function()
      assert.equals("skip", auto_load.decide({
        mode = "auto",
        config_exists = false,
        cache_exists = false,
        loaded_root = nil,
      }))
    end)

    it("returns skip when already loaded at same root", function()
      assert.equals("skip", auto_load.decide({
        mode = "auto",
        config_exists = true,
        cache_exists = true,
        loaded_root = "/project",
        cwd_root = "/project",
      }))
    end)

    it("returns prompt when switching to a different workspace", function()
      assert.equals("prompt_switch", auto_load.decide({
        mode = "auto",
        config_exists = true,
        cache_exists = true,
        loaded_root = "/old-project",
        cwd_root = "/new-project",
      }))
    end)

    it("returns prompt_switch when switching even with mode cached_only", function()
      assert.equals("prompt_switch", auto_load.decide({
        mode = "cached_only",
        config_exists = true,
        cache_exists = true,
        loaded_root = "/old-project",
        cwd_root = "/new-project",
      }))
    end)

    -- mode = "auto": always load
    it("auto mode loads with cache", function()
      assert.equals("load", auto_load.decide({
        mode = "auto",
        config_exists = true,
        cache_exists = true,
        loaded_root = nil,
        cwd_root = "/project",
      }))
    end)

    it("auto mode loads without cache", function()
      assert.equals("load", auto_load.decide({
        mode = "auto",
        config_exists = true,
        cache_exists = false,
        loaded_root = nil,
        cwd_root = "/project",
      }))
    end)

    -- mode = "cached_only": load if cache exists, notify otherwise
    it("cached_only mode loads when cache exists", function()
      assert.equals("load", auto_load.decide({
        mode = "cached_only",
        config_exists = true,
        cache_exists = true,
        loaded_root = nil,
        cwd_root = "/project",
      }))
    end)

    it("cached_only mode notifies when no cache", function()
      assert.equals("notify", auto_load.decide({
        mode = "cached_only",
        config_exists = true,
        cache_exists = false,
        loaded_root = nil,
        cwd_root = "/project",
      }))
    end)

    -- mode = "prompt": load if cache exists, prompt otherwise
    it("prompt mode loads when cache exists", function()
      assert.equals("load", auto_load.decide({
        mode = "prompt",
        config_exists = true,
        cache_exists = true,
        loaded_root = nil,
        cwd_root = "/project",
      }))
    end)

    it("prompt mode prompts when no cache", function()
      assert.equals("prompt", auto_load.decide({
        mode = "prompt",
        config_exists = true,
        cache_exists = false,
        loaded_root = nil,
        cwd_root = "/project",
      }))
    end)
  end)
end)

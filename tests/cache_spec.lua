local cache = require("loomworks.cache")

describe("cache", function()
  describe("default", function()
    it("returns table with version 4 and empty configurations", function()
      local d = cache.default()
      assert.equals(4, d._meta.version)
      assert.are.same({}, d.configurations)
    end)
  end)

  describe("parse", function()
    it("parses valid cache.json", function()
      local json = vim.json.encode({
        _meta = { version = 4, loomworks_hash = "abc", cached_at = "2025-01-01" },
        configurations = {
          ["App/Debug"] = {
            project_key = "App",
            config_key = "Debug",
            type = "cmake",
            state = "built",
            last_built = "2025-01-01",
          },
        },
      })
      local result = cache.parse(json)
      assert.equals(4, result._meta.version)
      assert.equals("built", result.configurations["App/Debug"].state)
    end)

    it("returns no version mismatch on valid parse", function()
      local json = vim.json.encode({
        _meta = { version = 4, loomworks_hash = "abc", cached_at = "2025-01-01" },
        configurations = {},
      })
      local _, mismatch = cache.parse(json)
      assert.is_false(mismatch)
    end)

    it("returns defaults on invalid JSON without version mismatch", function()
      local result, mismatch = cache.parse("broken {{{")
      assert.equals(4, result._meta.version)
      assert.are.same({}, result.configurations)
      assert.is_false(mismatch)
    end)

    it("returns defaults and version mismatch on wrong version", function()
      local json = vim.json.encode({
        _meta = { version = 999 },
        configurations = {},
      })
      local result, mismatch = cache.parse(json)
      assert.are.same({}, result.configurations)
      assert.is_true(mismatch)
    end)

    it("returns version mismatch on old version", function()
      local json = vim.json.encode({
        _meta = { version = 2 },
        configurations = {},
      })
      local _, mismatch = cache.parse(json)
      assert.is_true(mismatch)
    end)

    it("returns version mismatch on v3", function()
      local json = vim.json.encode({
        _meta = { version = 3 },
        projects = {},
      })
      local result, mismatch = cache.parse(json)
      assert.are.same({}, result.configurations)
      assert.is_true(mismatch)
    end)

    it("ensures configurations field exists", function()
      local json = vim.json.encode({
        _meta = { version = 4 },
      })
      local result = cache.parse(json)
      assert.are.same({}, result.configurations)
    end)
  end)

  describe("config_cache_key", function()
    it("combines project_key and config_key with slash", function()
      assert.equals("App/Debug", cache.config_cache_key("App", "Debug"))
    end)

    it("works with tool-qualified config keys", function()
      assert.equals("App/Debug:ninja-gcc-12", cache.config_cache_key("App", "Debug:ninja-gcc-12"))
    end)
  end)

  describe("compute_hash", function()
    it("returns a 12-character string", function()
      local hash = cache.compute_hash('{"projects": {}}')
      assert.equals(12, #hash)
    end)

    it("returns different hashes for different content", function()
      local h1 = cache.compute_hash('{"projects": {"A": {}}}')
      local h2 = cache.compute_hash('{"projects": {"B": {}}}')
      assert.are_not.equals(h1, h2)
    end)

    it("returns same hash for same content", function()
      local content = '{"projects": {}}'
      assert.equals(cache.compute_hash(content), cache.compute_hash(content))
    end)
  end)

  describe("filepath", function()
    it("returns path under .nvim", function()
      local p = cache.filepath("/workspace")
      assert.equals("/workspace/.nvim/loomworks.cache.json", p)
    end)
  end)
end)

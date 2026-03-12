local cache = require("loomworks.cache")

describe("cache", function()
  describe("default", function()
    it("returns table with version 3 and empty projects", function()
      local d = cache.default()
      assert.equals(3, d._meta.version)
      assert.are.same({}, d.projects)
    end)
  end)

  describe("parse", function()
    it("parses valid cache.json", function()
      local json = vim.json.encode({
        _meta = { version = 3, loomworks_hash = "abc", cached_at = "2025-01-01" },
        projects = {
          App = {
            type = "cmake",
            configurations = {
              Debug = { state = "built", last_built = "2025-01-01" },
            },
          },
        },
      })
      local result = cache.parse(json)
      assert.equals(3, result._meta.version)
      assert.equals("built", result.projects.App.configurations.Debug.state)
    end)

    it("returns no version mismatch on valid parse", function()
      local json = vim.json.encode({
        _meta = { version = 3, loomworks_hash = "abc", cached_at = "2025-01-01" },
        projects = {},
      })
      local _, mismatch = cache.parse(json)
      assert.is_false(mismatch)
    end)

    it("returns defaults on invalid JSON without version mismatch", function()
      local result, mismatch = cache.parse("broken {{{")
      assert.equals(3, result._meta.version)
      assert.are.same({}, result.projects)
      assert.is_false(mismatch)
    end)

    it("returns defaults and version mismatch on wrong version", function()
      local json = vim.json.encode({
        _meta = { version = 999 },
        projects = { App = {} },
      })
      local result, mismatch = cache.parse(json)
      assert.are.same({}, result.projects)
      assert.is_true(mismatch)
    end)

    it("returns version mismatch on old version", function()
      local json = vim.json.encode({
        _meta = { version = 2 },
        projects = {},
      })
      local _, mismatch = cache.parse(json)
      assert.is_true(mismatch)
    end)

    it("ensures projects field exists", function()
      local json = vim.json.encode({
        _meta = { version = 2 },
      })
      local result = cache.parse(json)
      assert.are.same({}, result.projects)
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

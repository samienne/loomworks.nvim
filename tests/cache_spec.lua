local cache = require("loomworks.cache")

describe("cache", function()
  describe("default", function()
    it("returns table with version 2 and empty projects", function()
      local d = cache.default()
      assert.equals(2, d._meta.version)
      assert.are.same({}, d.projects)
    end)
  end)

  describe("parse", function()
    it("parses valid cache.json", function()
      local json = vim.json.encode({
        _meta = { version = 2, loomworks_hash = "abc", cached_at = "2025-01-01" },
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
      assert.equals(2, result._meta.version)
      assert.equals("built", result.projects.App.configurations.Debug.state)
    end)

    it("returns defaults on invalid JSON", function()
      local result = cache.parse("broken {{{")
      assert.equals(2, result._meta.version)
      assert.are.same({}, result.projects)
    end)

    it("returns defaults on wrong version", function()
      local json = vim.json.encode({
        _meta = { version = 999 },
        projects = { App = {} },
      })
      local result = cache.parse(json)
      assert.are.same({}, result.projects)
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

local config = require("loomworks.config")

describe("config", function()
  describe("parse", function()
    it("parses valid loomworks.json", function()
      local json = vim.json.encode({
        projects = {
          MyApp = { cmake = {} },
        },
      })
      local result, err = config.parse(json, "/fake/root")
      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.equals("cmake", result.projects.MyApp.type)
      assert.equals("MyApp", result.projects.MyApp.path)
    end)

    it("returns error on invalid JSON", function()
      local result, err = config.parse("not json {{{", "/fake/root")
      assert.is_nil(result)
      assert.is_not_nil(err)
    end)

    it("returns error when projects field is missing", function()
      local result, err = config.parse("{}", "/fake/root")
      assert.is_nil(result)
      assert.matches("projects", err)
    end)

    it("extracts project type from inner key", function()
      local json = vim.json.encode({
        projects = {
          A = { cmake = {} },
          B = { ets = {} },
          C = { typescript = {} },
        },
      })
      local result = config.parse(json, "/fake/root")
      assert.equals("cmake", result.projects.A.type)
      assert.equals("ets", result.projects.B.type)
      assert.equals("typescript", result.projects.C.type)
    end)

    it("uses key as default path", function()
      local json = vim.json.encode({
        projects = { MyApp = { cmake = {} } },
      })
      local result = config.parse(json, "/fake/root")
      assert.equals("MyApp", result.projects.MyApp.path)
    end)

    it("uses explicit path when provided", function()
      local json = vim.json.encode({
        projects = {
          MyApp = { path = "packages/my-app", cmake = {} },
        },
      })
      local result = config.parse(json, "/fake/root")
      assert.equals("packages/my-app", result.projects.MyApp.path)
    end)

    it("preserves configuration_sets", function()
      local json = vim.json.encode({
        projects = { A = { cmake = {} } },
        configuration_sets = {
          debug = { A = "Debug" },
          release = { A = "Release" },
        },
      })
      local result = config.parse(json, "/fake/root")
      assert.is_not_nil(result.configuration_sets)
      assert.equals("Debug", result.configuration_sets.debug.A)
      assert.equals("Release", result.configuration_sets.release.A)
    end)

    it("preserves workspace name", function()
      local json = vim.json.encode({
        name = "MyWorkspace",
        projects = { A = { cmake = {} } },
      })
      local result = config.parse(json, "/fake/root")
      assert.equals("MyWorkspace", result.name)
    end)

    it("stores type_config from inner key value", function()
      local json = vim.json.encode({
        projects = {
          A = {
            cmake = {
              configurations = { Debug = {}, Release = {} },
              compile_commands_from = "ninja-debug",
            },
          },
        },
      })
      local result = config.parse(json, "/fake/root")
      assert.is_not_nil(result.projects.A.type_config)
      assert.equals("ninja-debug", result.projects.A.type_config.compile_commands_from)
      assert.is_not_nil(result.projects.A.type_config.configurations)
    end)

    it("preserves depends_on", function()
      local json = vim.json.encode({
        projects = {
          A = { cmake = {}, depends_on = { "B" } },
          B = { cmake = {} },
        },
      })
      local result = config.parse(json, "/fake/root")
      assert.are.same({ "B" }, result.projects.A.depends_on)
    end)

    it("rejects project with multiple type keys", function()
      local json = vim.json.encode({
        projects = {
          A = { cmake = {}, ets = {} },
        },
      })
      local result, err = config.parse(json, "/fake/root")
      assert.is_nil(result)
      assert.matches("multiple type keys", err)
    end)

    it("rejects project with no type key", function()
      local json = vim.json.encode({
        projects = {
          A = { path = "some/path" },
        },
      })
      local result, err = config.parse(json, "/fake/root")
      assert.is_nil(result)
      assert.matches("no type key", err)
    end)

    it("parses explicit profiles", function()
      local json = vim.json.encode({
        projects = { A = { cmake = {} } },
        profiles = {
          custom = {
            configuration_set = "debug",
            cmake = { kit_id = "ninja-gcc-14" },
          },
        },
      })
      local result = config.parse(json, "/fake/root")
      assert.is_not_nil(result.profiles)
      assert.equals("debug", result.profiles.custom.configuration_set)
      assert.equals("ninja-gcc-14", result.profiles.custom.cmake.kit_id)
    end)
  end)

  describe("_extract_type", function()
    it("ignores path and depends_on keys", function()
      local ptype, cfg = config._extract_type({
        path = "foo",
        depends_on = {},
        cmake = { x = 1 },
      })
      assert.equals("cmake", ptype)
      assert.are.same({ x = 1 }, cfg)
    end)

    it("returns empty table for nil type_config", function()
      -- When inner key value is explicitly true/nil-ish, should still work
      local ptype, cfg = config._extract_type({ cmake = {} })
      assert.equals("cmake", ptype)
      assert.are.same({}, cfg)
    end)
  end)
end)

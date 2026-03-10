local progress = require("loomworks.progress")

describe("progress", function()
  describe("ninja parser", function()
    local parse

    before_each(function()
      parse = progress.get("ninja")
      assert.is_not_nil(parse)
    end)

    it("parses standard ninja output", function()
      local result = parse("[2/10] Building CXX object src/main.cpp.o")
      assert.is_not_nil(result)
      assert.equals(2, result.current)
      assert.equals(10, result.total)
      assert.equals("Building CXX object src/main.cpp.o", result.message)
    end)

    it("parses ninja output without message", function()
      local result = parse("[1/1]")
      assert.is_not_nil(result)
      assert.equals(1, result.current)
      assert.equals(1, result.total)
    end)

    it("parses large step counts", function()
      local result = parse("[142/1337] Linking CXX executable bin/app")
      assert.is_not_nil(result)
      assert.equals(142, result.current)
      assert.equals(1337, result.total)
    end)

    it("returns nil for non-ninja output", function()
      assert.is_nil(parse("-- Configuring done"))
      assert.is_nil(parse("make[1]: Entering directory"))
      assert.is_nil(parse(""))
      assert.is_nil(parse("Building CXX object without bracket prefix"))
    end)

    it("returns nil for bracket at non-start position", function()
      assert.is_nil(parse("  [2/10] indented"))
    end)
  end)

  describe("registry", function()
    it("returns nil for unknown tool", function()
      assert.is_nil(progress.get("nonexistent_tool"))
    end)

    it("allows manual registration", function()
      local called = false
      progress.register("test_tool", function(line)
        called = true
        return { current = 1, total = 1 }
      end)
      local parser = progress.get("test_tool")
      assert.is_not_nil(parser)
      parser("test")
      assert.is_true(called)
    end)
  end)
end)

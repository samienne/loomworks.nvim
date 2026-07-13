--- Tests for the standalone-host JSON shim (lua/loomworks/shim/json.lua).
--- Pure Lua, no `vim` dependency, so it runs fine under the nvim plenary host.
--- Fidelity target: nvim's vim.json semantics for the shapes loomworks uses.

local json = require("loomworks.shim.json")

describe("shim json", function()
  it("encodes an empty empty_dict as an object", function()
    assert.are.equal("{}", json.encode(json.empty_dict()))
  end)

  it("encodes an empty plain table as an array", function()
    assert.are.equal("[]", json.encode({}))
  end)

  -- Regression: a table created as empty_dict and later given keys must encode
  -- as a normal object, not silently collapse to "{}". This is exactly what
  -- happens when a decoded `{}` (e.g. type_config) is deepcopied and extended
  -- with `.configurations` during serialization. The old encoder shortcut keyed
  -- on the metatable alone and dropped the added keys.
  it("encodes an empty_dict that later gained keys as a full object", function()
    local t = json.empty_dict()
    t.configurations = { ["Debug-asan"] = { variant = "Debug" } }
    local encoded = json.encode(t)
    local decoded = json.decode(encoded)
    assert.are.equal("Debug", decoded.configurations["Debug-asan"].variant)
  end)

  it("round-trips a nested object with null and empty dict", function()
    local original = {
      name = "x",
      value = json.NIL,
      opts = json.empty_dict(),
      list = { 1, 2, 3 },
    }
    local decoded = json.decode(json.encode(original))
    assert.are.equal("x", decoded.name)
    assert.are.equal(json.NIL, decoded.value)
    assert.are.equal("table", type(decoded.opts))
    assert.are.same({ 1, 2, 3 }, decoded.list)
  end)

  it("decodes an empty object to an empty_dict-marked table", function()
    local decoded = json.decode("{}")
    assert.are.equal("{}", json.encode(decoded))
  end)
end)

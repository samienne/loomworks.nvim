describe("env expansion", function()
  -- Test the ${ENV_VAR} pattern used in lsp.lua and cmake.lua.
  -- The function is local in those modules, so we verify the pattern directly.
  local function expand_env(s)
    return (s:gsub("%${([^}]+)}", function(var)
      return os.getenv(var) or "${" .. var .. "}"
    end))
  end

  it("expands known env var", function()
    -- PATH should be set on every system
    local result = expand_env("${PATH}/bin")
    assert.is_not_nil(result:match("/bin$"))
    assert.is_nil(result:match("%${PATH}"))
  end)

  it("preserves unknown env var", function()
    local result = expand_env("${LOOMWORKS_NONEXISTENT_VAR_12345}/bin")
    assert.equals("${LOOMWORKS_NONEXISTENT_VAR_12345}/bin", result)
  end)

  it("expands multiple vars", function()
    local s = "${PATH}:${PATH}"
    local result = expand_env(s)
    assert.is_nil(result:match("%${PATH}"))
  end)

  it("handles strings without vars", function()
    assert.equals("hello world", expand_env("hello world"))
  end)

  it("handles empty string", function()
    assert.equals("", expand_env(""))
  end)
end)

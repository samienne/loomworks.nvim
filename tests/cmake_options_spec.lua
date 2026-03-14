--- Tests for cmake module's get_options function.

local cmake = require("loomworks.modules.cmake")
local uv = vim.uv or vim.loop

--- Remove a directory tree.
local function rm_rf(path)
  local handle = uv.fs_scandir(path)
  if not handle then return end
  while true do
    local name, ftype = uv.fs_scandir_next(handle)
    if not name then break end
    local full = path .. "/" .. name
    if ftype == "directory" then
      rm_rf(full)
    else
      uv.fs_unlink(full)
    end
  end
  uv.fs_rmdir(path)
end

--- Write a file-api cache-v2 reply with given entries.
--- @param build_dir string
--- @param entries table[] { name, value, type, properties? }
local function write_cache_reply(build_dir, entries)
  local reply_dir = build_dir .. "/.cmake/api/v1/reply"
  vim.fn.mkdir(reply_dir, "p")

  local cache_data = {
    kind = "cache",
    version = { major = 2, minor = 0 },
    entries = entries,
  }
  local cache_name = "cache-v2-abc123.json"
  local fd = assert(io.open(reply_dir .. "/" .. cache_name, "w"))
  fd:write(vim.json.encode(cache_data))
  fd:close()

  local index = {
    objects = {
      { kind = "cache", version = { major = 2, minor = 0 }, jsonFile = cache_name },
    },
  }
  fd = assert(io.open(reply_dir .. "/index-2025-01-01.json", "w"))
  fd:write(vim.json.encode(index))
  fd:close()
end

--- Write a minimal CMakeCache.txt.
--- @param build_dir string
--- @param lines string[]
local function write_cmake_cache_txt(build_dir, lines)
  vim.fn.mkdir(build_dir, "p")
  local fd = assert(io.open(build_dir .. "/CMakeCache.txt", "w"))
  fd:write(table.concat(lines, "\n") .. "\n")
  fd:close()
end

describe("cmake get_options", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    if tmp_dir then rm_rf(tmp_dir) end
  end)

  it("returns nil when no build data exists", function()
    assert.is_nil(cmake.get_options(tmp_dir))
  end)

  it("parses file-api cache-v2 reply", function()
    write_cache_reply(tmp_dir, {
      {
        name = "BUILD_TESTING",
        value = "ON",
        type = "BOOL",
        properties = {
          { name = "HELPSTRING", value = "Enable testing" },
        },
      },
      {
        name = "CMAKE_BUILD_TYPE",
        value = "Debug",
        type = "STRING",
        properties = {
          { name = "HELPSTRING", value = "Build type" },
        },
      },
    })

    local options = cmake.get_options(tmp_dir)
    assert.is_not_nil(options)
    assert.equals(2, #options)

    -- Sort by name for deterministic checks
    table.sort(options, function(a, b) return a.name < b.name end)
    assert.equals("BUILD_TESTING", options[1].name)
    assert.equals("bool", options[1].type)
    assert.equals("ON", options[1].value)
    assert.equals("Enable testing", options[1].helpstring)

    assert.equals("CMAKE_BUILD_TYPE", options[2].name)
    assert.equals("string", options[2].type)
    assert.equals("Debug", options[2].value)
  end)

  it("extracts choices from STRINGS property", function()
    write_cache_reply(tmp_dir, {
      {
        name = "CMAKE_BUILD_TYPE",
        value = "Debug",
        type = "STRING",
        properties = {
          { name = "HELPSTRING", value = "Build type" },
          { name = "STRINGS", value = { "Debug", "Release", "RelWithDebInfo", "MinSizeRel" } },
        },
      },
    })

    local options = cmake.get_options(tmp_dir)
    assert.is_not_nil(options)
    assert.equals(1, #options)
    assert.are.same(
      { "Debug", "Release", "RelWithDebInfo", "MinSizeRel" },
      options[1].choices
    )
  end)

  it("excludes INTERNAL and STATIC entries", function()
    write_cache_reply(tmp_dir, {
      { name = "BUILD_TESTING", value = "ON", type = "BOOL", properties = {} },
      { name = "some_internal", value = "x", type = "INTERNAL", properties = {} },
      { name = "some_static", value = "y", type = "STATIC", properties = {} },
    })

    local options = cmake.get_options(tmp_dir)
    assert.is_not_nil(options)
    assert.equals(1, #options)
    assert.equals("BUILD_TESTING", options[1].name)
  end)

  it("filters out 'Value Computed by CMake' helpstrings", function()
    write_cache_reply(tmp_dir, {
      {
        name = "CMAKE_CXX_COMPILER",
        value = "/usr/bin/g++",
        type = "FILEPATH",
        properties = {
          { name = "HELPSTRING", value = "Value Computed by CMake" },
        },
      },
    })

    local options = cmake.get_options(tmp_dir)
    assert.is_not_nil(options)
    assert.is_nil(options[1].helpstring)
  end)

  it("falls back to CMakeCache.txt when no file-api reply", function()
    write_cmake_cache_txt(tmp_dir, {
      "# CMakeCache",
      "",
      "//Enable testing",
      "BUILD_TESTING:BOOL=ON",
      "",
      "//Build type",
      "CMAKE_BUILD_TYPE:STRING=Debug",
      "",
      "//Value Computed by CMake",
      "some_internal:INTERNAL=foo",
    })

    local options = cmake.get_options(tmp_dir)
    assert.is_not_nil(options)
    assert.equals(2, #options)

    table.sort(options, function(a, b) return a.name < b.name end)
    assert.equals("BUILD_TESTING", options[1].name)
    assert.equals("bool", options[1].type)
    assert.equals("ON", options[1].value)
    assert.equals("Enable testing", options[1].helpstring)

    assert.equals("CMAKE_BUILD_TYPE", options[2].name)
    assert.equals("string", options[2].type)
  end)

  it("CMakeCache.txt fallback filters 'Value Computed by CMake'", function()
    write_cmake_cache_txt(tmp_dir, {
      "//Value Computed by CMake",
      "CMAKE_CXX_COMPILER:STRING=/usr/bin/g++",
    })

    local options = cmake.get_options(tmp_dir)
    assert.is_not_nil(options)
    assert.is_nil(options[1].helpstring)
  end)

  it("handles all user-facing types", function()
    write_cache_reply(tmp_dir, {
      { name = "A", value = "ON", type = "BOOL", properties = {} },
      { name = "B", value = "hello", type = "STRING", properties = {} },
      { name = "C", value = "/usr/local", type = "PATH", properties = {} },
      { name = "D", value = "/usr/bin/gcc", type = "FILEPATH", properties = {} },
    })

    local options = cmake.get_options(tmp_dir)
    assert.is_not_nil(options)
    assert.equals(4, #options)
    local types = {}
    for _, opt in ipairs(options) do types[opt.name] = opt.type end
    assert.equals("bool", types.A)
    assert.equals("string", types.B)
    assert.equals("path", types.C)
    assert.equals("filepath", types.D)
  end)
end)

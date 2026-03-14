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

--- Collect all leaf options from an option tree (recursively).
--- @param tree (loomworks.OptionGroup | loomworks.Option)[]
--- @return loomworks.Option[]
local function collect_options(tree)
  local result = {}
  for _, node in ipairs(tree) do
    if node.children then
      for _, opt in ipairs(collect_options(node.children)) do
        result[#result + 1] = opt
      end
    else
      result[#result + 1] = node
    end
  end
  return result
end

--- Find a group node by label in the top level of a tree.
--- @param tree (loomworks.OptionGroup | loomworks.Option)[]
--- @param label string
--- @return loomworks.OptionGroup|nil
local function find_group(tree, label)
  for _, node in ipairs(tree) do
    if node.children and node.label == label then
      return node
    end
  end
  return nil
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

  it("parses file-api cache-v2 reply into tree", function()
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

    local tree = cmake.get_options(tmp_dir)
    assert.is_not_nil(tree)

    -- Should have two groups: Project Options and CMake Options
    local proj_group = find_group(tree, "Project Options")
    local cmake_group = find_group(tree, "CMake Options")
    assert.is_not_nil(proj_group)
    assert.is_not_nil(cmake_group)

    -- Project Options contains BUILD_TESTING
    assert.equals(1, #proj_group.children)
    assert.equals("BUILD_TESTING", proj_group.children[1].key)
    assert.equals("bool", proj_group.children[1].value_type)
    assert.equals("ON", proj_group.children[1].value)
    assert.equals("Enable testing", proj_group.children[1].helpstring)

    -- CMake Options contains CMAKE_BUILD_TYPE
    assert.equals(1, #cmake_group.children)
    assert.equals("CMAKE_BUILD_TYPE", cmake_group.children[1].key)
    assert.equals("string", cmake_group.children[1].value_type)
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

    local tree = cmake.get_options(tmp_dir)
    local all = collect_options(tree)
    assert.equals(1, #all)
    assert.are.same(
      { "Debug", "Release", "RelWithDebInfo", "MinSizeRel" },
      all[1].choices
    )
  end)

  it("excludes INTERNAL and STATIC entries", function()
    write_cache_reply(tmp_dir, {
      { name = "BUILD_TESTING", value = "ON", type = "BOOL", properties = {} },
      { name = "some_internal", value = "x", type = "INTERNAL", properties = {} },
      { name = "some_static", value = "y", type = "STATIC", properties = {} },
    })

    local tree = cmake.get_options(tmp_dir)
    local all = collect_options(tree)
    assert.equals(1, #all)
    assert.equals("BUILD_TESTING", all[1].key)
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

    local tree = cmake.get_options(tmp_dir)
    local all = collect_options(tree)
    assert.is_nil(all[1].helpstring)
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

    local tree = cmake.get_options(tmp_dir)
    assert.is_not_nil(tree)

    local proj_group = find_group(tree, "Project Options")
    local cmake_group = find_group(tree, "CMake Options")
    assert.is_not_nil(proj_group)
    assert.is_not_nil(cmake_group)

    assert.equals("BUILD_TESTING", proj_group.children[1].key)
    assert.equals("bool", proj_group.children[1].value_type)
    assert.equals("Enable testing", proj_group.children[1].helpstring)

    assert.equals("CMAKE_BUILD_TYPE", cmake_group.children[1].key)
    assert.equals("string", cmake_group.children[1].value_type)
  end)

  it("CMakeCache.txt fallback filters 'Value Computed by CMake'", function()
    write_cmake_cache_txt(tmp_dir, {
      "//Value Computed by CMake",
      "CMAKE_CXX_COMPILER:STRING=/usr/bin/g++",
    })

    local tree = cmake.get_options(tmp_dir)
    local all = collect_options(tree)
    assert.is_nil(all[1].helpstring)
  end)

  it("handles all user-facing types", function()
    write_cache_reply(tmp_dir, {
      { name = "A", value = "ON", type = "BOOL", properties = {} },
      { name = "B", value = "hello", type = "STRING", properties = {} },
      { name = "C", value = "/usr/local", type = "PATH", properties = {} },
      { name = "D", value = "/usr/bin/gcc", type = "FILEPATH", properties = {} },
    })

    local tree = cmake.get_options(tmp_dir)
    local all = collect_options(tree)
    assert.equals(4, #all)
    local types = {}
    for _, opt in ipairs(all) do types[opt.key] = opt.value_type end
    assert.equals("bool", types.A)
    assert.equals("string", types.B)
    assert.equals("path", types.C)
    assert.equals("filepath", types.D)
  end)
end)

describe("cmake get_options with option_groups", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    if tmp_dir then rm_rf(tmp_dir) end
  end)

  it("groups options by prefix from config", function()
    write_cache_reply(tmp_dir, {
      { name = "GFX_ENABLE_VULKAN", value = "ON", type = "BOOL", properties = {} },
      { name = "GFX_ENABLE_OPENGL", value = "OFF", type = "BOOL", properties = {} },
      { name = "NET_USE_TLS", value = "OFF", type = "BOOL", properties = {} },
      { name = "STANDALONE_FLAG", value = "ON", type = "BOOL", properties = {} },
      { name = "CMAKE_BUILD_TYPE", value = "Debug", type = "STRING", properties = {} },
    })

    local tree = cmake.get_options(tmp_dir, {
      option_groups = {
        GFX = { "Graphics" },
        NET = { "Networking" },
      },
    })
    assert.is_not_nil(tree)

    local gfx = find_group(tree, "Graphics")
    local net = find_group(tree, "Networking")
    local other = find_group(tree, "Other")
    local cmake_group = find_group(tree, "CMake Options")

    assert.is_not_nil(gfx)
    assert.equals(2, #gfx.children)
    assert.equals("GFX_ENABLE_OPENGL", gfx.children[1].key)
    assert.equals("GFX_ENABLE_VULKAN", gfx.children[2].key)

    assert.is_not_nil(net)
    assert.equals(1, #net.children)
    assert.equals("NET_USE_TLS", net.children[1].key)

    assert.is_not_nil(other)
    assert.equals(1, #other.children)
    assert.equals("STANDALONE_FLAG", other.children[1].key)

    assert.is_not_nil(cmake_group)
    assert.equals(1, #cmake_group.children)
  end)

  it("creates nested groups from multi-level paths", function()
    write_cache_reply(tmp_dir, {
      { name = "GFX_ENABLE_VULKAN", value = "ON", type = "BOOL", properties = {} },
      { name = "AUDIO_ENABLE_ALSA", value = "ON", type = "BOOL", properties = {} },
    })

    local tree = cmake.get_options(tmp_dir, {
      option_groups = {
        GFX = { "Media", "Graphics" },
        AUDIO = { "Media", "Audio" },
      },
    })

    -- Should create nested Media -> Graphics and Media -> Audio
    local media = find_group(tree, "Media")
    assert.is_not_nil(media, "should create Media parent group")

    local gfx = find_group(media.children, "Graphics")
    local audio = find_group(media.children, "Audio")
    assert.is_not_nil(gfx)
    assert.is_not_nil(audio)
    assert.equals("GFX_ENABLE_VULKAN", gfx.children[1].key)
    assert.equals("AUDIO_ENABLE_ALSA", audio.children[1].key)
  end)

  it("longest prefix wins when multiple prefixes could match", function()
    write_cache_reply(tmp_dir, {
      { name = "GFX3D_SHADOWS", value = "ON", type = "BOOL", properties = {} },
      { name = "GFX_VSYNC", value = "ON", type = "BOOL", properties = {} },
    })

    local tree = cmake.get_options(tmp_dir, {
      option_groups = {
        GFX3D = { "3D Renderer" },
        GFX = { "Graphics" },
      },
    })

    local renderer = find_group(tree, "3D Renderer")
    local gfx = find_group(tree, "Graphics")
    assert.is_not_nil(renderer)
    assert.is_not_nil(gfx)
    -- GFX3D_SHADOWS should match GFX3D (longer), not GFX
    assert.equals("GFX3D_SHADOWS", renderer.children[1].key)
    assert.equals("GFX_VSYNC", gfx.children[1].key)
  end)
end)

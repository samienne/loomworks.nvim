local io_mod = require("loomworks.io")
local uv = vim.uv or vim.loop

--- Create a temp directory for test use.
--- @return string path
local function make_tmpdir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

--- Write raw content to a file (bypassing io_mod).
--- @param path string
--- @param content string
local function write_raw(path, content)
  local fd = uv.fs_open(path, "w", 438)
  uv.fs_write(fd, content, 0)
  uv.fs_close(fd)
end

--- Read raw content from a file (bypassing io_mod).
--- @param path string
--- @return string|nil
local function read_raw(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then return nil end
  local stat = uv.fs_fstat(fd)
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data
end

describe("io", function()
  -- Track temp dirs for cleanup
  local tmpdirs = {}

  --- Create and register a temp dir for automatic cleanup.
  local function tmpdir()
    local d = make_tmpdir()
    tmpdirs[#tmpdirs + 1] = d
    return d
  end

  after_each(function()
    for _, d in ipairs(tmpdirs) do
      io_mod.rm_rf(d)
    end
    tmpdirs = {}
  end)

  describe("_pretty_json", function()
    it("pretty-prints simple object with 2-space indentation", function()
      local result = io_mod._pretty_json('{"a":1,"b":2}')
      assert.equals('{\n  "a": 1,\n  "b": 2\n}\n', result)
    end)

    it("handles nested objects", function()
      local result = io_mod._pretty_json('{"a":{"b":1}}')
      assert.equals('{\n  "a": {\n    "b": 1\n  }\n}\n', result)
    end)

  end)

  describe("read_json", function()
    it("reads valid JSON from main file", function()
      local dir = tmpdir()
      local path = dir .. "/test.json"
      write_raw(path, '{"hello":"world"}')

      local data, err = io_mod.read_json(path)
      assert.is_nil(err)
      assert.is_not_nil(data)
      assert.equals("world", data.hello)
    end)

    it("falls back to .bak when main file is corrupted", function()
      local dir = tmpdir()
      local path = dir .. "/test.json"
      write_raw(path, "not valid json {{{")
      write_raw(path .. ".bak", '{"from":"backup"}')

      local data, err = io_mod.read_json(path)
      assert.is_nil(err)
      assert.is_not_nil(data)
      assert.equals("backup", data.from)
    end)

    it("returns nil when both main and .bak are missing", function()
      local dir = tmpdir()
      local path = dir .. "/nonexistent.json"

      local data, err = io_mod.read_json(path)
      assert.is_nil(data)
      assert.is_not_nil(err)
    end)

    it("returns nil when both main and .bak are corrupted", function()
      local dir = tmpdir()
      local path = dir .. "/test.json"
      write_raw(path, "garbage")
      write_raw(path .. ".bak", "also garbage")

      local data, err = io_mod.read_json(path)
      assert.is_nil(data)
      assert.is_not_nil(err)
    end)
  end)

  describe("write_file_atomic", function()
    it("creates a new file with correct content", function()
      local dir = tmpdir()
      local path = dir .. "/newfile.txt"

      local ok, err = io_mod.write_file_atomic(path, "hello")
      assert.is_true(ok)
      assert.is_nil(err)

      local content = read_raw(path)
      assert.equals("hello", content)
    end)

    it("creates .bak of existing file", function()
      local dir = tmpdir()
      local path = dir .. "/existing.txt"
      write_raw(path, "original")

      local ok = io_mod.write_file_atomic(path, "updated")
      assert.is_true(ok)

      local bak_content = read_raw(path .. ".bak")
      assert.equals("original", bak_content)
    end)

    it("verifies content survives write via read-back", function()
      local dir = tmpdir()
      local path = dir .. "/readback.txt"
      local content = "line1\nline2\nline3\n"

      io_mod.write_file_atomic(path, content)

      local result = io_mod.read_file(path)
      assert.equals(content, result)
    end)
  end)

  describe("write_json", function()
    it("round-trips a table through write_json and read_json", function()
      local dir = tmpdir()
      local path = dir .. "/round.json"
      local tbl = { name = "test", count = 42, nested = { a = true } }

      local ok, err = io_mod.write_json(path, tbl)
      assert.is_true(ok)
      assert.is_nil(err)

      local result = io_mod.read_json(path)
      assert.is_not_nil(result)
      assert.equals("test", result.name)
      assert.equals(42, result.count)
      assert.is_true(result.nested.a)
    end)
  end)

  describe("rm_rf", function()
    it("removes a directory tree", function()
      local dir = tmpdir()
      local sub = dir .. "/sub"
      vim.fn.mkdir(sub, "p")
      write_raw(sub .. "/file.txt", "data")
      write_raw(dir .. "/root.txt", "data")

      local ok, err = io_mod.rm_rf(dir)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_nil(uv.fs_stat(dir))

      -- Already cleaned up; remove from tracking so after_each doesn't error
      for i, d in ipairs(tmpdirs) do
        if d == dir then
          table.remove(tmpdirs, i)
          break
        end
      end
    end)

    it("returns true for non-existent path", function()
      local ok, err = io_mod.rm_rf("/tmp/loomworks_test_nonexistent_" .. tostring(os.clock()))
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("removes a single file", function()
      local dir = tmpdir()
      local path = dir .. "/single.txt"
      write_raw(path, "data")

      local ok, err = io_mod.rm_rf(path)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_nil(uv.fs_stat(path))
    end)
  end)

  describe("ensure_dir", function()
    it("creates nested directories", function()
      local dir = tmpdir()
      local nested = dir .. "/a/b/c"

      local ok, err = io_mod.ensure_dir(nested)
      assert.is_true(ok)
      assert.is_nil(err)

      local stat = uv.fs_stat(nested)
      assert.is_not_nil(stat)
      assert.equals("directory", stat.type)
    end)

    it("is no-op when directory already exists", function()
      local dir = tmpdir()

      local ok, err = io_mod.ensure_dir(dir)
      assert.is_true(ok)
      assert.is_nil(err)
    end)
  end)
end)

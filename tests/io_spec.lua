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

        -- user.json / loomworks.json / the cache are rewritten on every
        -- mutation; a hash-order key sequence made every rewrite a noisy diff.
        it("writes object keys in sorted order at every depth (stable diffs)", function()
            local dir = tmpdir()
            local path = dir .. "/sorted.json"
            local inner, outer = {}, {}
            local names = {}
            for i = 1, 40 do names[#names + 1] = string.format("k%02d_%s", i, string.char(122 - (i % 26))) end
            -- insert in reverse order so insertion order != sorted order
            for i = #names, 1, -1 do inner[names[i]] = i; outer[names[i]] = { v = i, [names[i]] = true } end
            outer.nested = inner
            assert.is_true(io_mod.write_json(path, outer))
            local text = io_mod.read_file(path)
            local function assert_sorted(block)
                local keys = {}
                for k in block:gmatch('\n%s*"([^"]+)":') do keys[#keys + 1] = k end
                local sorted = vim.deepcopy(keys)
                table.sort(sorted)
                assert.same(sorted, keys)
            end
            -- top-level keys only: lines indented by exactly two spaces
            local top = {}
            for k in text:gmatch('\n  "([^"]+)":') do top[#top + 1] = k end
            local sorted_top = vim.deepcopy(top); table.sort(sorted_top)
            assert.same(sorted_top, top)
            assert.equals(41, #top)
            assert_sorted(text:match('"nested": (%b{})'))
            -- identical content → byte-identical output
            local path2 = dir .. "/sorted2.json"
            assert.is_true(io_mod.write_json(path2, vim.deepcopy(outer)))
            assert.equals(text, io_mod.read_file(path2))
        end)

        it("keeps arrays in order and the empty object/array distinction", function()
            local dir = tmpdir()
            local path = dir .. "/shapes.json"
            local tbl = { list = { "b", "a", "c" }, empty_obj = vim.empty_dict(), empty_arr = {},
                s = "q\"uote\n", n = 1.5, b = false }
            assert.is_true(io_mod.write_json(path, tbl))
            local text = io_mod.read_file(path)
            assert.is_truthy(text:find('"empty_obj": {', 1, true), text)
            assert.is_truthy(text:find('"empty_arr": [', 1, true), text)
            local back = vim.json.decode(text)
            assert.same({ "b", "a", "c" }, back.list)
            assert.equals("q\"uote\n", back.s)
            assert.equals(1.5, back.n)
            assert.is_false(back.b)
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

describe("exclusive create retry (a leftover held delete-pending, Windows)", function()
    local real_open, real_ms
    before_each(function()
        real_open, real_ms = io_mod._open_exclusive, io_mod.CREATE_RETRY_MS
        io_mod.CREATE_RETRY_MS = 1
    end)
    after_each(function()
        io_mod._open_exclusive, io_mod.CREATE_RETRY_MS = real_open, real_ms
    end)

    --- Fail the first `n` creates with `code`, then create for real.
    local function failing(n, code)
        local calls = 0
        io_mod._open_exclusive = function(path, mode)
            calls = calls + 1
            if calls <= n then return nil, code .. ": operation not permitted: " .. path, code end
            return real_open(path, mode)
        end
        return function() return calls end
    end

    it("write_fresh retries a create that fails while the old file lingers, then succeeds", function()
        for _, code in ipairs({ "EPERM", "EEXIST", "EACCES" }) do
            local dir = make_tmpdir()
            local tmp = dir .. "/f.json.tmp"
            write_raw(tmp, "stale")
            local calls = failing(2, code)
            local ok, err = io_mod.write_fresh(tmp, "new", 438)
            assert.is_true(ok, err)
            assert.equals(3, calls())
            assert.equals("new", io_mod.read_file(tmp))
        end
    end)

    it("write_fresh gives up after the bounded retries and returns the error", function()
        local dir = make_tmpdir()
        local calls = failing(1000, "EPERM")
        local ok, err = io_mod.write_fresh(dir .. "/g.tmp", "x", 438)
        assert.is_false(ok)
        assert.truthy(tostring(err):find("EPERM", 1, true), err)
        assert.equals(io_mod.CREATE_RETRIES, calls())
        local okw, werr = io_mod.write_file_atomic(dir .. "/h.json", "{}")
        assert.is_false(okw)
        assert.truthy(tostring(werr):find("write tmp", 1, true), werr)
    end)

    it("write_exclusive retries EPERM but never EEXIST (callers pick another name)", function()
        local dir = make_tmpdir()
        local calls = failing(2, "EPERM")
        assert.is_true(io_mod.write_exclusive(dir .. "/a", "1"))
        assert.equals(3, calls())
        calls = failing(1000, "EPERM")
        local ok, _, code = io_mod.write_exclusive(dir .. "/b", "1")
        assert.is_false(ok)
        assert.equals("EPERM", code)
        assert.equals(io_mod.CREATE_RETRIES, calls())
        io_mod._open_exclusive = real_open
        write_raw(dir .. "/c", "old")
        calls = failing(0, "EPERM")
        local ok2, _, code2 = io_mod.write_exclusive(dir .. "/c", "1")
        assert.is_false(ok2)
        assert.equals("EEXIST", code2)
        assert.equals(1, calls())
        assert.equals("old", io_mod.read_file(dir .. "/c"))
    end)

    it("write_fresh never retries through a directory at the name", function()
        local dir = make_tmpdir()
        vim.fn.mkdir(dir .. "/d.tmp", "p")
        local calls = failing(0, "EPERM")
        local ok = io_mod.write_fresh(dir .. "/d.tmp", "x", 438)
        assert.is_false(ok)
        assert.equals(1, calls())
        assert.equals("directory", uv.fs_lstat(dir .. "/d.tmp").type)
    end)
end)

--- Tests for loomworks.msvc — VS install discovery (vswhere) and clang-cl
--- lookup. The vcvars env snapshot spawns a real cmd/batch, so it's covered by
--- the end-to-end meson MSVC build rather than here.

package.loaded["loomworks.msvc"] = nil
local msvc = require("loomworks.msvc")

--- Save/restore globals around a function.
local function with(overrides, fn)
    local saved = {}
    for path, value in pairs(overrides) do
        local parts = {}
        for p in path:gmatch("[^%.]+") do parts[#parts + 1] = p end
        local tbl = _G
        for i = 1, #parts - 1 do tbl = tbl[parts[i]] end
        saved[path] = { tbl = tbl, key = parts[#parts], prev = tbl[parts[#parts]] }
        tbl[parts[#parts]] = value
    end
    local ok, err = pcall(fn)
    for _, s in pairs(saved) do s.tbl[s.key] = s.prev end
    if not ok then error(err) end
end

local function system_returning(stdout)
    return function()
        return { wait = function() return { code = 0, stdout = stdout } end }
    end
end

describe("msvc.detect", function()
    it("parses VS installs from vswhere and locates vcvarsall", function()
        msvc.clear_cache()
        local json = vim.json.encode({
            {
                installationPath = "C:\\Program Files\\Microsoft Visual Studio\\2022\\Enterprise",
                catalog = { productLineVersion = "2022" },
                productId = "Microsoft.VisualStudio.Product.Enterprise",
            },
            {
                installationPath = "C:\\BuildTools",
                catalog = { productLineVersion = "2022" },
                productId = "Microsoft.VisualStudio.Product.BuildTools",
            },
        })
        with({
            ["vim.uv.fs_stat"] = function() return { type = "file" } end,
            ["vim.system"] = system_returning(json),
        }, function()
            local installs = msvc.detect()
            assert.equals(2, #installs)
            local by_id = {}
            for _, i in ipairs(installs) do by_id[i.id] = i end
            assert.is_not_nil(by_id["msvc-17-2022-enterprise"])
            assert.is_not_nil(by_id["msvc-17-2022-buildtools"])
            assert.matches("vcvarsall%.bat$", by_id["msvc-17-2022-enterprise"].vcvarsall)
            assert.equals("x64", by_id["msvc-17-2022-enterprise"].arch)
        end)
        msvc.clear_cache()
    end)

    it("returns empty when vswhere is absent", function()
        msvc.clear_cache()
        with({ ["vim.uv.fs_stat"] = function() return nil end }, function()
            assert.equals(0, #msvc.detect())
        end)
        msvc.clear_cache()
    end)

    it("skips installs without a discoverable vcvarsall", function()
        msvc.clear_cache()
        local json = vim.json.encode({
            {
                installationPath = "C:\\VS",
                catalog = { productLineVersion = "2022" },
                productId = "Microsoft.VisualStudio.Product.Community",
            },
        })
        with({
            -- vswhere exists; no vcvarsall does (fs_stat nil for the .bat).
            ["vim.uv.fs_stat"] = function(p)
                return p:find("vswhere") and { type = "file" } or nil
            end,
            ["vim.system"] = system_returning(json),
        }, function()
            assert.equals(0, #msvc.detect())
        end)
        msvc.clear_cache()
    end)
end)

describe("msvc.clang_cl", function()
    it("returns nil when clang-cl is not on PATH", function()
        msvc.clear_cache()
        with({ ["vim.fn.exepath"] = function() return "" end }, function()
            assert.is_nil(msvc.clang_cl())
        end)
        msvc.clear_cache()
    end)

    it("returns path + version when present", function()
        msvc.clear_cache()
        with({
            ["vim.fn.exepath"] = function() return "C:/LLVM/bin/clang-cl.exe" end,
            ["vim.system"] = system_returning("clang version 18.1.7\n"),
        }, function()
            local cc = msvc.clang_cl()
            assert.is_not_nil(cc)
            assert.equals("C:/LLVM/bin/clang-cl.exe", cc.path)
            assert.equals("18.1.7", cc.version)
        end)
        msvc.clear_cache()
    end)
end)

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

    -- Regression: `vim.fn.exepath` returns the extension in the casing
    -- PATHEXT carries, i.e. `clang-cl.EXE`. meson matches the compiler
    -- basename against `clang-cl.exe` case-sensitively; given the uppercase
    -- spelling it does not recognise the MSVC driver, falls back to probing a
    -- GNU-style linker, and configure dies with
    --   "Unable to detect linker for compiler `...clang-cl.EXE -Wl,--version`".
    it("lowercases the executable extension exepath reports", function()
        msvc.clear_cache()
        with({
            ["vim.fn.exepath"] = function()
                return "C:\\Program Files\\LLVM\\bin\\clang-cl.EXE"
            end,
            ["vim.system"] = system_returning("clang version 18.1.7\n"),
        }, function()
            local cc = msvc.clang_cl()
            assert.is_not_nil(cc)
            assert.equals("C:/Program Files/LLVM/bin/clang-cl.exe", cc.path,
                "an uppercase .EXE breaks meson's clang-cl detection")
        end)
        msvc.clear_cache()
    end)
end)

describe("msvc.clang_cl_for", function()
    local INSTALL = {
        id = "msvc-17-2022-community",
        display = "MSVC 17 2022 (Community)",
        vs_major = "17",
        version_line = "2022",
        product = "Community",
        vcvarsall = "C:/VS/Community/VC/Auxiliary/Build/vcvarsall.bat",
        arch = "x64",
        install_path = "C:/VS/Community",
    }
    local BUNDLED = "C:/VS/Community/VC/Tools/Llvm/x64/bin/clang-cl.exe"
    local BUNDLED_CLANGD = "C:/VS/Community/VC/Tools/Llvm/x64/bin/clangd.exe"

    it("prefers the VS-bundled clang-cl + sibling clangd", function()
        msvc.clear_cache()
        with({
            ["vim.uv.fs_stat"] = function(p)
                return (p == BUNDLED or p == BUNDLED_CLANGD) and { type = "file" } or nil
            end,
            ["vim.system"] = system_returning("clang version 18.1.7\n"),
        }, function()
            local cc = msvc.clang_cl_for(INSTALL)
            assert.is_not_nil(cc)
            assert.equals(BUNDLED, cc.path)
            assert.equals("18.1.7", cc.version)
            assert.equals(BUNDLED_CLANGD, cc.clangd_path)
        end)
        msvc.clear_cache()
    end)

    it("falls back to standalone/PATH clang-cl when no bundled one exists", function()
        msvc.clear_cache()
        with({
            -- Bundled clang-cl absent; standalone's sibling clangd present.
            ["vim.uv.fs_stat"] = function(p)
                return p == "C:/LLVM/bin/clangd.exe" and { type = "file" } or nil
            end,
            ["vim.fn.exepath"] = function() return "C:/LLVM/bin/clang-cl.exe" end,
            ["vim.system"] = system_returning("clang version 17.0.6\n"),
        }, function()
            local cc = msvc.clang_cl_for(INSTALL)
            assert.is_not_nil(cc)
            assert.equals("C:/LLVM/bin/clang-cl.exe", cc.path)
            assert.equals("17.0.6", cc.version)
            assert.equals("C:/LLVM/bin/clangd.exe", cc.clangd_path)
        end)
        msvc.clear_cache()
    end)

    it("leaves clangd_path nil when no sibling clangd is found", function()
        msvc.clear_cache()
        with({
            ["vim.uv.fs_stat"] = function() return nil end, -- nothing on disk
            ["vim.fn.exepath"] = function() return "C:/LLVM/bin/clang-cl.exe" end,
            ["vim.system"] = system_returning("clang version 17.0.6\n"),
        }, function()
            local cc = msvc.clang_cl_for(INSTALL)
            assert.is_not_nil(cc)
            assert.equals("C:/LLVM/bin/clang-cl.exe", cc.path)
            assert.is_nil(cc.clangd_path)
        end)
        msvc.clear_cache()
    end)

    it("returns nil when neither bundled nor standalone clang-cl exists", function()
        msvc.clear_cache()
        with({
            ["vim.uv.fs_stat"] = function() return nil end,
            ["vim.fn.exepath"] = function() return "" end,
        }, function()
            assert.is_nil(msvc.clang_cl_for(INSTALL))
        end)
        msvc.clear_cache()
    end)
end)

describe("msvc.detect_async", function()
    it("returns the same install shape as detect (stubbed vswhere)", function()
        msvc.clear_cache()
        local json = vim.json.encode({
            {
                installationPath = "C:\\Program Files\\Microsoft Visual Studio\\2022\\Community",
                catalog = { productLineVersion = "2022" },
                productId = "Microsoft.VisualStudio.Product.Community",
            },
        })
        local got
        with({
            ["vim.uv.fs_stat"] = function() return { type = "file" } end,
            ["vim.schedule"] = function(fn) fn() end,
            ["vim.system"] = function(_cmd, _opts, cb)
                cb({ code = 0, stdout = json })
                return { wait = function() return { code = 0, stdout = json } end }
            end,
        }, function()
            msvc.detect_async(function(installs) got = installs end)
        end)
        assert.is_not_nil(got)
        assert.equals(1, #got)
        assert.equals("msvc-17-2022-community", got[1].id)
        assert.equals("MSVC 17 2022 (Community)", got[1].display)
        assert.equals("17", got[1].vs_major)
        assert.equals("x64", got[1].arch)
        assert.matches("vcvarsall%.bat$", got[1].vcvarsall)
        assert.equals("C:/Program Files/Microsoft Visual Studio/2022/Community",
            got[1].install_path)
        msvc.clear_cache()
    end)
end)

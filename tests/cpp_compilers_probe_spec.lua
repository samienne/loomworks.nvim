--- Tests for cpp_compilers.probe_path — identification of an
--- arbitrary user-provided compiler executable. The family /
--- version / sibling-clangd logic that's shared with the PATH-scan
--- path lives here, and these tests pin its contract.
---
--- Real compilers aren't available in CI, so the tests stub
--- `vim.fn.system` to return canned `--version` output, and stub
--- `vim.uv.fs_stat` / `vim.fn.executable` so sibling-lookup
--- decisions are independent of the host filesystem.

-- We poke private state so reload the module fresh per spec to
-- avoid cross-test cache pollution.
package.loaded["loomworks.cpp_compilers"] = nil
local cpp = require("loomworks.cpp_compilers")

local function with_stubs(stubs, fn)
    local saved = {}
    for path, value in pairs(stubs) do
        local parts, key = {}, nil
        for p in string.gmatch(path, "[^%.]+") do parts[#parts + 1] = p end
        local tbl = _G
        for i = 1, #parts - 1 do tbl = tbl[parts[i]] end
        key = parts[#parts]
        saved[path] = { tbl = tbl, key = key, prev = tbl[key] }
        tbl[key] = value
    end
    local ok, err = pcall(fn)
    for path, s in pairs(saved) do
        s.tbl[s.key] = s.prev
    end
    if not ok then error(err) end
end

describe("cpp_compilers.probe_path", function()
    it("returns nil for empty path", function()
        assert.is_nil(cpp.probe_path(nil))
        assert.is_nil(cpp.probe_path(""))
    end)

    it("returns nil when path doesn't exist", function()
        with_stubs({
            ["vim.uv.fs_stat"] = function() return nil end,
        }, function()
            assert.is_nil(cpp.probe_path("/nonexistent/clang++"))
        end)
    end)

    it("identifies Clang from --version output", function()
        with_stubs({
            ["vim.uv.fs_stat"] = function(path)
                return path == "/opt/myclang/bin/clang++" and { type = "file" } or nil
            end,
            ["vim.fn.system"] = function() return "clang version 19.0.0 (...)\n" end,
            ["vim.v"] = { shell_error = 0 },
            ["vim.fn.executable"] = function() return 0 end,
        }, function()
            local info = cpp.probe_path("/opt/myclang/bin/clang++")
            assert.is_not_nil(info)
            assert.equals("clang", info.family)
            assert.equals("19.0.0", info.version)
            assert.equals("/opt/myclang/bin/clang++", info.path)
        end)
    end)

    it("identifies GCC from --version output", function()
        with_stubs({
            ["vim.uv.fs_stat"] = function(path)
                return path == "/usr/bin/g++" and { type = "file" } or nil
            end,
            ["vim.fn.system"] = function()
                return "g++ (Ubuntu 13.2.0-23ubuntu4) 13.2.0\nCopyright (C) 2023 Free Software Foundation, Inc.\n"
            end,
            ["vim.v"] = { shell_error = 0 },
            ["vim.fn.executable"] = function() return 0 end,
        }, function()
            local info = cpp.probe_path("/usr/bin/g++")
            assert.is_not_nil(info)
            assert.equals("gcc", info.family)
            assert.equals("13.2.0", info.version)
        end)
    end)

    it("falls back to basename when --version is uninformative", function()
        -- An exotic compiler that prints something we don't recognize.
        -- Family detection should still fall back to the binary name.
        with_stubs({
            ["vim.uv.fs_stat"] = function() return { type = "file" } end,
            ["vim.fn.system"] = function() return "Some Vendor C++ 7.1.2\n" end,
            ["vim.v"] = { shell_error = 0 },
            ["vim.fn.executable"] = function() return 0 end,
        }, function()
            local info = cpp.probe_path("/opt/vendor/bin/cxx")
            -- Family is nil — we don't recognize "vendor" — but the
            -- result is still returned with the version filled in,
            -- so the kit works as a CC/CXX passthrough.
            assert.is_not_nil(info)
            assert.is_nil(info.family)
            assert.equals("7.1.2", info.version)
        end)
    end)

    it("only sets clangd_path for Clang family", function()
        -- Stub sibling clangd as existing for both inputs; the probe
        -- should only return it for Clang.
        local seen_paths = {}
        with_stubs({
            ["vim.uv.fs_stat"] = function(path)
                seen_paths[path] = true
                return { type = "file" }
            end,
            ["vim.fn.executable"] = function() return 1 end,
            ["vim.fn.system"] = function(cmd)
                if cmd[1]:match("clang") then return "clang version 19.0.0\n" end
                return "g++ (...) 13.2.0\nFree Software Foundation\n"
            end,
            ["vim.v"] = { shell_error = 0 },
        }, function()
            local clang = cpp.probe_path("/opt/c/bin/clang++")
            local gcc = cpp.probe_path("/usr/bin/g++")
            assert.is_not_nil(clang.clangd_path,
                "clang family should expose sibling clangd")
            assert.is_nil(gcc.clangd_path,
                "gcc family must not claim a clangd sibling")
        end)
    end)

    it("derives c_path sibling for a clang++ input", function()
        with_stubs({
            ["vim.uv.fs_stat"] = function(path)
                -- clang++ exists, sibling clang also exists.
                return (path:match("clang%+%+$") or path:match("/clang$"))
                    and { type = "file" } or nil
            end,
            ["vim.fn.executable"] = function() return 0 end,
            ["vim.fn.system"] = function() return "clang version 19.0.0\n" end,
            ["vim.v"] = { shell_error = 0 },
        }, function()
            local info = cpp.probe_path("/opt/c/bin/clang++")
            assert.equals("/opt/c/bin/clang", info.c_path)
        end)
    end)

    it("falls back to cxx path when c sibling missing", function()
        with_stubs({
            ["vim.uv.fs_stat"] = function(path)
                return path:match("g%+%+$") and { type = "file" } or nil
            end,
            ["vim.fn.executable"] = function() return 0 end,
            ["vim.fn.system"] = function()
                return "g++ 13.2.0\nFree Software Foundation\n"
            end,
            ["vim.v"] = { shell_error = 0 },
        }, function()
            local info = cpp.probe_path("/some/dir/g++")
            assert.equals(info.path, info.c_path,
                "no `gcc` sibling → c_path falls back to cxx path")
        end)
    end)

    it("returns nil when --version exits non-zero", function()
        with_stubs({
            ["vim.uv.fs_stat"] = function() return { type = "file" } end,
            ["vim.fn.system"] = function() return "" end,
            ["vim.v"] = { shell_error = 127 },
            ["vim.fn.executable"] = function() return 0 end,
        }, function()
            assert.is_nil(cpp.probe_path("/opt/not-a-compiler"))
        end)
    end)
end)

describe("cpp_compilers.detect PATH scan", function()
    -- Regression: the C-driver counterpart of a C++ driver was derived with the
    -- gsub passes in the wrong order — `g%+%+` ran before `clang%+%+`, so
    -- "clang++" (which contains the substring "g++") became "clangcc", the
    -- probe failed, and c_path fell back to the C++ driver. Result: CC=clang++,
    -- and meson compiled C sources as C++ ("cannot compile programs").
    it("derives the clang C driver as clang, not clang++", function()
        cpp.clear_cache()
        with_stubs({
            -- Only LLVM clang++/clang exist (no gcc/g++, no versioned names).
            ["vim.fn.executable"] = function(name)
                return (name == "clang++" or name == "clang") and 1 or 0
            end,
            ["vim.fn.exepath"] = function(name)
                if name == "clang++" then return "C:/LLVM/bin/clang++.exe" end
                if name == "clang" then return "C:/LLVM/bin/clang.exe" end
                return ""
            end,
            ["vim.fn.system"] = function() return "clang version 18.1.7\n" end,
            ["vim.v"] = { shell_error = 0 },
            ["vim.uv.fs_stat"] = function() return nil end,
        }, function()
            local clang
            for _, c in ipairs(cpp.detect()) do
                if c.family == "clang" then clang = c end
            end
            assert.is_not_nil(clang)
            assert.equals("C:/LLVM/bin/clang++.exe", clang.path)
            assert.equals("C:/LLVM/bin/clang.exe", clang.c_path)
        end)
        cpp.clear_cache()
    end)

    -- Regression: on macOS /usr/bin/gcc and /usr/bin/g++ are shims for Apple
    -- clang. detect() derived the family from the BINARY NAME, so the same
    -- compiler was reported twice — once honestly as clang-17.0.0 and once as
    -- "gcc-17.0.0 / GCC 17.0.0". A CI matrix pinning gcc-17 expecting GCC
    -- silently got clang. Family must come from `--version`, as probe_path
    -- already does.
    local function macos_stubs(system)
        return {
            ["vim.fn.executable"] = function(name)
                return (name == "gcc" or name == "g++"
                    or name == "clang" or name == "clang++") and 1 or 0
            end,
            ["vim.fn.exepath"] = function(name) return "/usr/bin/" .. name end,
            ["vim.fn.system"] = system,
            ["vim.v"] = { shell_error = 0 },
            ["vim.uv.fs_stat"] = function() return nil end,
        }
    end

    -- Apple's shims announce themselves honestly when asked.
    local function apple_version(cmd)
        local path = type(cmd) == "table" and cmd[1] or tostring(cmd)
        if path:match("gcc$") or path:match("g%+%+$") or path:match("clang") then
            return "Apple clang version 17.0.0 (clang-1700.0.13.3)\n"
                .. "Target: arm64-apple-darwin24.0.0\n"
        end
        return ""
    end

    it("does not report Apple's gcc shim as GCC", function()
        cpp.clear_cache()
        with_stubs(macos_stubs(apple_version), function()
            for _, c in ipairs(cpp.detect()) do
                assert.not_equals("gcc", c.family,
                    "Apple clang shim must not be reported as the gcc family "
                    .. "(id " .. tostring(c.id) .. ")")
            end
        end)
        cpp.clear_cache()
    end)

    it("collapses the gcc/clang shims into a single compiler entry", function()
        cpp.clear_cache()
        with_stubs(macos_stubs(apple_version), function()
            local found = cpp.detect()
            assert.equals(1, #found,
                "same compiler behind two names must be deduplicated")
            assert.equals("clang-17.0.0", found[1].id)
            -- The surviving entry keeps the honest path, not the shim's.
            assert.equals("/usr/bin/clang++", found[1].path)
            assert.equals("/usr/bin/clang", found[1].c_path)
        end)
        cpp.clear_cache()
    end)

    -- The guard must not overcorrect: a real GCC still has to be found by name
    -- on a system where gcc is genuinely GCC.
    it("still detects a real GCC alongside clang", function()
        cpp.clear_cache()
        with_stubs(macos_stubs(function(cmd)
            local path = type(cmd) == "table" and cmd[1] or tostring(cmd)
            if path:match("clang") then
                return "clang version 18.1.7\n"
            end
            return "g++ (Homebrew GCC 14.4.0) 14.4.0\n"
                .. "Copyright (C) 2024 Free Software Foundation, Inc.\n"
        end), function()
            local by_family = {}
            for _, c in ipairs(cpp.detect()) do by_family[c.family] = c end
            assert.is_not_nil(by_family.gcc, "real GCC must still be detected")
            assert.equals("14.4.0", by_family.gcc.version)
            assert.is_not_nil(by_family.clang)
            assert.equals("18.1.7", by_family.clang.version)
        end)
        cpp.clear_cache()
    end)
end)

--- Tests for the cpp_compiler SDK provider — the user-declared
--- C/C++ compiler installation, surfaced through the existing SDK
--- machinery. Covers validate, derive_key, query_capabilities, and
--- the display_name override.

package.loaded["loomworks.cpp_compilers"] = nil
package.loaded["loomworks.sdks.cpp_compiler"] = nil
local cpp_compiler = require("loomworks.sdks.cpp_compiler")
local cpp_compilers = require("loomworks.cpp_compilers")

--- Helper: stub `cpp_compilers.probe_path` to return canned info.
local function with_probe(info, fn)
    local prev = cpp_compilers.probe_path
    cpp_compilers.probe_path = function(_path) return info end
    local ok, err = pcall(fn)
    cpp_compilers.probe_path = prev
    if not ok then error(err) end
end

describe("sdks/cpp_compiler", function()
    describe("provider identity", function()
        it("declares id and display_name", function()
            assert.equals("cpp_compiler", cpp_compiler.id)
            assert.is_string(cpp_compiler.display_name)
        end)

        it("declares a path_prompt the UI can show", function()
            -- The default "<display_name> SDK path" prompt is misleading
            -- for a compiler binary; the provider provides its own.
            assert.is_string(cpp_compiler.path_prompt)
            assert.is_truthy(cpp_compiler.path_prompt:lower():find("compiler"))
        end)

        it("detect_all returns empty — user-declared only", function()
            assert.same({}, cpp_compiler.detect_all())
        end)
    end)

    describe("validate", function()
        it("returns nil for empty path", function()
            assert.is_nil(cpp_compiler.validate(nil))
            assert.is_nil(cpp_compiler.validate(""))
        end)

        it("returns nil when probe fails", function()
            with_probe(nil, function()
                assert.is_nil(cpp_compiler.validate("/opt/whatever"))
            end)
        end)

        it("returns version, family, and a path-derived token", function()
            with_probe({
                family = "clang", version = "19.0.0",
                path = "/opt/harmony-clang/bin/clang++",
            }, function()
                local info = cpp_compiler.validate("/opt/harmony-clang/bin/clang++")
                assert.is_not_nil(info)
                assert.equals("19.0.0", info.version)
                assert.equals("clang", info.family)
                -- Token derived from the parent directory of the bin
                -- dir, sanitized (lowercase, non-alnum to dashes).
                assert.equals("harmony-clang", info.basename_token)
            end)
        end)

        it("falls back to the binary basename when no parent dir", function()
            with_probe({
                family = "gcc", version = "13.2.0",
                path = "g++",
            }, function()
                local info = cpp_compiler.validate("g++")
                assert.is_not_nil(info)
                assert.is_truthy(info.basename_token)
            end)
        end)
    end)

    describe("derive_key", function()
        it("includes family, version, and path token", function()
            local key = cpp_compiler.derive_key({
                family = "clang", version = "19.0.0",
                basename_token = "harmony-clang",
            })
            assert.equals("cpp_compiler-clang-19.0.0-harmony-clang", key)
        end)

        it("distinguishes two builds at the same version", function()
            local k1 = cpp_compiler.derive_key({
                family = "clang", version = "19.0.0",
                basename_token = "harmony-clang",
            })
            local k2 = cpp_compiler.derive_key({
                family = "clang", version = "19.0.0",
                basename_token = "system-clang",
            })
            assert.is_false(k1 == k2,
                "two distinct custom builds must yield distinct keys")
        end)

        it("uses 'cpp' as family placeholder when unknown", function()
            local key = cpp_compiler.derive_key({
                version = "7.0.0", basename_token = "vendor-cxx",
            })
            assert.is_truthy(key:find("cpp"), "got: " .. key)
        end)
    end)

    describe("query_capabilities", function()
        local function fake_sdk(path)
            return { sdk_path = function() return path end }
        end

        it("returns the cmake module in list query", function()
            assert.same({ "cmake" }, cpp_compiler.query_capabilities(fake_sdk("/x"), nil))
        end)

        it("returns nil for unsupported modules", function()
            assert.is_nil(cpp_compiler.query_capabilities(fake_sdk("/x"), "harmony"))
        end)

        it("returns cmake caps with single-compiler shape", function()
            with_probe({
                family = "clang", version = "19.0.0",
                path = "/opt/c/bin/clang++",
                c_path = "/opt/c/bin/clang",
                clangd_path = "/opt/c/bin/clangd",
                bin_dir = "/opt/c/bin",
            }, function()
                local caps = cpp_compiler.query_capabilities(
                    fake_sdk("/opt/c/bin/clang++"), "cmake")
                assert.is_not_nil(caps)
                -- No platforms[] — that's what tells cmake.kits_from_sdk
                -- to take the single-compiler branch instead of the
                -- platform × arch cross product.
                assert.is_nil(caps.platforms)
                assert.equals("/opt/c/bin/clang++", caps.compiler_path)
                assert.equals("/opt/c/bin/clang", caps.cc_path)
                assert.equals("/opt/c/bin/clangd", caps.clangd_path)
                assert.equals("clang", caps.compiler_id)
                assert.equals("19.0.0", caps.compiler_version)
                assert.equals("Ninja", caps.generator)
            end)
        end)

        it("returns nil for cmake when path probes to nothing", function()
            with_probe(nil, function()
                assert.is_nil(cpp_compiler.query_capabilities(
                    fake_sdk("/opt/missing/clang++"), "cmake"))
            end)
        end)
    end)

    describe("display_name_for", function()
        local function fake_sdk(path) return { sdk_path = function() return path end } end

        it("renders Clang family with version and (custom) suffix", function()
            with_probe({
                family = "clang", version = "19.0.0",
                path = "/opt/c/bin/clang++",
            }, function()
                local name = cpp_compiler.display_name_for(fake_sdk("/opt/c/bin/clang++"))
                assert.is_truthy(name:find("Clang"))
                assert.is_truthy(name:find("19.0.0"))
                assert.is_truthy(name:find("custom"))
            end)
        end)

        it("renders GCC family", function()
            with_probe({ family = "gcc", version = "13.2.0", path = "/usr/bin/g++" },
                function()
                    local name = cpp_compiler.display_name_for(fake_sdk("/usr/bin/g++"))
                    assert.is_truthy(name:find("GCC"))
                end)
        end)

        it("falls back to generic label when probe yields nothing", function()
            with_probe(nil, function()
                local name = cpp_compiler.display_name_for(fake_sdk("/x"))
                assert.is_string(name)
                assert.is_truthy(name:lower():find("c"))
            end)
        end)
    end)
end)

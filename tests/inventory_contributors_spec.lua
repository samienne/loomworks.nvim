--- Tests for the environment inventory's required derivation (active profile /
--- union / SDK pin / missing module plugin / classification) and its
--- contributors — cmake, meson, typescript, shell, the shared compiler scans,
--- the LSP / DAP inventory companions (PATH + Mason) and SDK providers — each
--- with injected probes, never the host's tools (headless §16.33).

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local inv = require("loomworks.inventory")
local h = require("tests.helpers")

--- A probe context with everything injected: nothing on PATH unless listed,
--- `run` answers from `outputs[argv[1]]`, files from `files`.
local function fake_ctx(opts)
    opts = opts or {}
    local on_path = opts.path or {}
    local outputs = opts.outputs or {}
    local files = opts.files or {}
    local ran = {}
    local ctx = inv.context(opts.workspace, {
        platform = opts.platform or "linux",
        lookup = function(name) return on_path[name] end,
        run = function(argv, cb)
            ran[#ran + 1] = argv
            cb({ code = 0, stdout = outputs[argv[1]] or "", stderr = "" })
        end,
        read_file = function(p) return files[p] end,
        exists = function(p) return files[p] ~= nil end,
        getenv = function(k) return (opts.env or {})[k] end,
        stdpath_data = opts.stdpath_data or false,
        timeout_ms = opts.timeout_ms or 2000,
    })
    ctx._ran = ran
    return ctx
end

--- Probe a declaration list and return results keyed by id.
local function probe(decls, ctx)
    local results = inv.probe_all(decls, ctx)
    local by = {}
    for _, r in ipairs(results) do by[r.id] = r end
    return by, results
end

-- ---------------------------------------------------------------------------
-- Required derivation + classification
-- ---------------------------------------------------------------------------
describe("inventory requirements", function()
    local Core = require("loomworks.core")
    local real_modules = require("loomworks.modules")
    local function modules_get(id) return id and real_modules.get(id) or nil end

    local GCC = { compiler_id = "gcc-12", generator = "Ninja", compiler_path = "/usr/bin/g++", display = "GCC 12" }
    local CLANG = { compiler_id = "clang-18", generator = "Ninja", compiler_path = "/usr/bin/clang++", display = "Clang 18" }

    local function make_ws(opts)
        opts = opts or {}
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = opts.projects or { App = { cmake = {} } },
                configuration_sets = opts.sets or { debug = { App = "Debug" } },
            }),
            ["loomworks.user.json"] = h.make_user_json({ profiles = opts.profiles or {} }),
        }
        local deps = h.make_test_deps(files, {
            modules = { get = modules_get },
            cache = { save = function() return true end },
        })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core._workspace._tools_by_type = {
            cmake = {
                { tool_key = "ninja-gcc-12", tool_data = GCC, tool_label = "GCC 12" },
                { tool_key = "ninja-clang-18", tool_data = CLANG, tool_label = "Clang 18" },
            },
        }
        core:remerge()
        return core:get_workspace()
    end

    local function by_id(reqs)
        local t = {}
        for _, r in ipairs(reqs) do t[r.id] = r end
        return t
    end

    local TWO_PROFILES = {
        gcc = { configuration_set = "debug", tools = { cmake = { key = "ninja-gcc-12", data = GCC } } },
        clang = { configuration_set = "debug", tools = { cmake = { key = "ninja-clang-18", data = CLANG } } },
    }

    it("no active profile → the union over every profile, naming each", function()
        local ws = make_ws({ profiles = TWO_PROFILES })
        ws._active_profile = nil
        local r = by_id(inv.requirements(ws))
        assert.is_not_nil(r["exe:cmake"])
        assert.is_not_nil(r["exe:ninja"])
        assert.is_not_nil(r[inv.path_id("cxx", "/usr/bin/g++")])
        assert.is_not_nil(r[inv.path_id("cxx", "/usr/bin/clang++")])
        assert.equals(2, #r["exe:cmake"].required_by)
        assert.equals("compilers:path", r[inv.path_id("cxx", "/usr/bin/g++")].via)
    end)

    it("an active profile scopes to its own projects and tools", function()
        local ws = make_ws({ profiles = TWO_PROFILES })
        for _, p in ipairs(ws._profiles) do
            if p.key:find("gcc") then ws._active_profile = p end
        end
        assert.is_not_nil(ws._active_profile)
        local r = by_id(inv.requirements(ws))
        assert.is_not_nil(r[inv.path_id("cxx", "/usr/bin/g++")])
        assert.is_nil(r[inv.path_id("cxx", "/usr/bin/clang++")])
        assert.equals(1, #r["exe:cmake"].required_by)
        assert.is_truthy(r["exe:cmake"].required_by[1]:find("/App$"))
    end)

    it("a pinned SDK installation is required by the profile that pins it", function()
        local ws = make_ws({ profiles = TWO_PROFILES })
        local p = ws._profiles[1]
        p._sdk = { key = "cpp_compiler-gcc-13-x", _type = "cpp_compiler", _path = "/opt/x/g++",
            display_name = function() return "GCC 13 (x)" end }
        ws._active_profile = p
        local r = by_id(inv.requirements(ws))
        local sdk = r["sdk:cpp_compiler-gcc-13-x"]
        assert.is_not_nil(sdk)
        assert.equals("sdks:cpp_compiler", sdk.via)
        assert.equals(p.key, sdk.required_by[1])
    end)

    it("a project whose module is not loaded requires that module plugin", function()
        local ws = make_ws({ projects = { App = { cmake = {} }, Lib = { nosuchmod = {} } }, sets = {} })
        local r = by_id(inv.requirements(ws)) -- no profiles → every project
        assert.is_not_nil(r["module:nosuchmod"])
        assert.equals("plugins", r["module:nosuchmod"].via)
        assert.is_truthy(r["module:nosuchmod"].hint:find("lw module install nosuchmod", 1, true))
        assert.is_not_nil(r["exe:cmake"]) -- a module's own executable is still required
    end)

    it("classify: a missing required result is the only actionable item", function()
        local tier = {
            results = {
                { id = "exe:cmake", label = "cmake", status = "missing", category = "build tools", hint = "get cmake" },
                { id = "exe:make", label = "make", status = "missing", category = "build tools" },
                { id = "exe:ninja", label = "ninja", status = "unknown", category = "build tools" },
            },
            declared = { { id = "exe:cmake", category = "build tools" }, { id = "compilers:path", category = "compilers" } },
        }
        local reqs = {
            { id = "exe:cmake", label = "cmake", required_by = { "p/App" } },
            { id = "exe:ninja", label = "ninja", required_by = { "p/App" } },
            { id = "cxx:/usr/bin/g++", label = "GCC 12", via = "compilers:path", required_by = { "p/App" } },
            { id = "sdk:gone", label = "gone", via = "sdks:vendor", required_by = { "p" } },
        }
        local entries = inv.classify(tier, reqs)
        local e = {}
        for _, x in ipairs(entries) do e[x.id] = x end
        assert.is_true(e["exe:cmake"].required)
        assert.is_false(e["exe:make"].required)
        assert.equals("missing", e["cxx:/usr/bin/g++"].status) -- via declared, no result → missing
        assert.equals("compilers", e["cxx:/usr/bin/g++"].category)
        assert.equals("unknown", e["sdk:gone"].status)       -- via never probed → unknown
        local sug = inv.suggestions_for(entries)
        assert.equals(2, #sug)
        assert.equals("cmake not found — needed by p/App", sug[1].title)
        assert.equals("get cmake", sug[1].remedy)
    end)

    it("a requirement whose enumeration was inconclusive reads unknown, not missing", function()
        local tier = {
            results = { { id = "compilers:path", label = "gcc / clang", status = "unknown", category = "compilers" } },
            declared = { { id = "compilers:path", category = "compilers" } },
        }
        local entries = inv.classify(tier, { { id = "cxx:/x", label = "X", via = "compilers:path", required_by = { "a" } } })
        for _, x in ipairs(entries) do
            if x.id == "cxx:/x" then assert.equals("unknown", x.status) end
        end
        assert.equals(0, #inv.suggestions_for(entries))
    end)

    it("a requirement satisfied by a found alternative binds to it, not to the missing primary", function()
        -- An MSVC-style Ninja build runs cmake/ninja inside vcvarsall, whose PATH
        -- carries Visual Studio's bundled copies (cmake §13): those satisfy it.
        local VSC, VSN = "vs-cmake:c:/vs/v.bat", "vs-ninja:c:/vs/v.bat"
        local tier = {
            results = {
                { id = "exe:cmake", label = "cmake", status = "missing", category = "build tools", hint = "get cmake" },
                { id = "exe:ninja", label = "ninja", status = "missing", category = "build tools", hint = "get ninja" },
                { id = VSC, label = "cmake (VS 2022 Community)", status = "found", category = "build tools", detail = "VS-bundled" },
                { id = VSN, label = "ninja (VS 2022 Community)", status = "found", category = "build tools", detail = "VS-bundled" },
            },
            declared = { { id = "exe:cmake", category = "build tools" }, { id = "exe:ninja", category = "build tools" } },
        }
        local reqs = {
            { id = "exe:cmake", label = "cmake", alternatives = { VSC }, required_by = { "msvc/App" } },
            { id = "exe:ninja", label = "ninja", alternatives = { VSN }, required_by = { "msvc/App" } },
            { id = "exe:cmake", label = "cmake", required_by = { "gcc/App" } }, -- no vcvars: PATH only
        }
        local e = {}
        local entries = inv.classify(tier, reqs)
        for _, x in ipairs(entries) do e[x.id] = x end
        assert.is_true(e[VSC].required)
        assert.same({ "msvc/App" }, e[VSC].required_by)
        assert.is_true(e[VSN].required)
        assert.is_false(e["exe:ninja"].required)            -- satisfied by the bundled copy
        assert.is_true(e["exe:cmake"].required)
        assert.same({ "gcc/App" }, e["exe:cmake"].required_by) -- only the profile that cannot use it
        local sug = inv.suggestions_for(entries)
        assert.equals(1, #sug)
        assert.equals("cmake not found — needed by gcc/App", sug[1].title)

        -- The primary wins when found (vcvars APPENDS its directories to PATH).
        tier.results[1].status = "found"
        local e2 = {}
        for _, x in ipairs(inv.classify(tier, reqs)) do e2[x.id] = x end
        assert.same({ "msvc/App", "gcc/App" }, e2["exe:cmake"].required_by)
        assert.is_false(e2[VSC].required)
    end)

    it("names_phrase compacts who needs an item; full = the whole list", function()
        assert.equals("App", inv.names_phrase({ "App" }))
        assert.equals("dev/App", inv.names_phrase({ "dev/App" }))
        assert.equals("dev (2 projects)", inv.names_phrase({ "dev/App", "dev/Lib" }))
        assert.equals("2 profiles (dev, asan)", inv.names_phrase({ "dev/App", "asan/App", "asan/Lib" }))
        assert.equals("3 projects (App, Lib, Core)", inv.names_phrase({ "App", "Lib", "Core" }))
        -- Long names: as many as fit, then a count — never a wrapping list.
        local long = {}
        for i = 1, 5 do long[i] = "Debug:ninja-msvc-17-2022-enterprise-" .. i .. "/App" end
        local p = inv.names_phrase(long)
        assert.equals("5 profiles (Debug:ninja-msvc-17-2022-enterprise-1 +4)", p)
        assert.equals(table.concat(long, ", "), inv.names_phrase(long, { full = true }))
    end)
end)

-- ---------------------------------------------------------------------------
-- Contributors (injected probes — never the host's tools)
-- ---------------------------------------------------------------------------
describe("inventory contributors", function()
    local cpp = require("loomworks.cpp_compilers")
    local msvc = require("loomworks.msvc")
    local cmake = require("loomworks.modules.cmake")
    local meson = require("loomworks.modules.meson")
    local ts = require("loomworks.modules.typescript")
    local shell = require("loomworks.modules.shell")

    local function ids(decls)
        local t = {}
        for _, d in ipairs(decls) do t[d.id] = d end
        return t
    end

    it("exe_declaration: found with a parsed version, missing with the hint", function()
        local d = inv.exe_declaration({ id = "exe:cmake", label = "cmake", names = { "cmake" }, hint = "get it" })
        local by = probe({ d }, fake_ctx({ path = { cmake = "/usr/bin/cmake" },
            outputs = { ["/usr/bin/cmake"] = "cmake version 3.30.2\n" } }))
        assert.equals("found", by["exe:cmake"].status)
        assert.equals("3.30.2", by["exe:cmake"].version)
        assert.equals("/usr/bin/cmake", by["exe:cmake"].path)
        by = probe({ d }, fake_ctx())
        assert.equals("missing", by["exe:cmake"].status)
        assert.equals("get it", by["exe:cmake"].hint)
    end)

    it("cmake declares cmake, ninja, make and the shared compiler scan", function()
        local d = ids(cmake.health_inventory(fake_ctx()))
        assert.is_not_nil(d["exe:cmake"])
        assert.is_not_nil(d["exe:ninja"])
        assert.is_not_nil(d["exe:make"])
        assert.is_not_nil(d["compilers:path"])
        assert.equals(vim.fn.has("win32") == 1, d["compilers:msvc"] ~= nil)
    end)

    it("the compiler scan reports each compiler the kit detection finds", function()
        local orig = cpp.detect_async
        cpp.detect_async = function(cb)
            cb({ { id = "gcc-13.2.0", display = "GCC 13.2.0", version = "13.2.0", path = "/usr/bin/g++" } })
        end
        local by = probe({ cpp.health_declaration() }, fake_ctx())
        cpp.detect_async = function(cb) cb({}) end
        local none = probe({ cpp.health_declaration() }, fake_ctx())
        cpp.detect_async = orig
        local r = by[inv.path_id("cxx", "/usr/bin/g++")]
        assert.equals("found", r.status)
        assert.equals("13.2.0", r.version)
        assert.equals("missing", none["compilers:path"].status)
    end)

    it("the MSVC scan lists installs and clang-cl (Windows), nothing elsewhere", function()
        local orig = { has = vim.fn.has, detect = msvc.detect_async, for_ = msvc.clang_cl_for_async, cl = msvc.clang_cl_async }
        vim.fn.has = function(f) if f == "win32" then return 0 end return orig.has(f) end
        assert.is_nil(msvc.health_declaration())
        vim.fn.has = function(f) if f == "win32" then return 1 end return orig.has(f) end
        msvc.detect_async = function(cb)
            cb({ { display = "MSVC 17 2022 (Community)", vcvarsall = "C:/VS/VC/Auxiliary/Build/vcvarsall.bat",
                install_path = "C:/VS", product_version = "17.11.2" } })
        end
        msvc.clang_cl_for_async = function(_, cb) cb({ path = "C:/VS/VC/Tools/Llvm/x64/bin/clang-cl.exe", version = "18.1.8" }) end
        msvc.clang_cl_async = function(cb) cb(nil) end
        local ok, by = pcall(probe, { msvc.health_declaration() }, fake_ctx({ platform = "windows", files = {
            ["C:/VS/VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt"] = "14.44.35207\r\n",
        } }))
        vim.fn.has, msvc.detect_async, msvc.clang_cl_for_async, msvc.clang_cl_async = orig.has, orig.detect, orig.for_, orig.cl
        assert.is_true(ok, tostring(by))
        local vs = by["msvc:c:/vs/vc/auxiliary/build/vcvarsall.bat"]
        assert.equals("found", vs.status)
        -- The toolset builds use (vcvarsall's default), not the VS product version.
        assert.equals("14.44.35207", vs.version)
        assert.equals("VS 17.11.2", vs.detail)
        assert.equals("found", by["clang-cl:c:/vs/vc/tools/llvm/x64/bin/clang-cl.exe"].status)
    end)

    it("the MSVC scan lists Visual Studio's bundled cmake + ninja when vcvarsall would add them", function()
        local orig = { has = vim.fn.has, detect = msvc.detect_async, for_ = msvc.clang_cl_for_async, cl = msvc.clang_cl_async }
        vim.fn.has = function(f) if f == "win32" then return 1 end return orig.has(f) end
        local function inst(p, line, product)
            return { display = "MSVC 17 " .. line .. " (" .. product .. ")", vcvarsall = p .. "/VC/Auxiliary/Build/vcvarsall.bat",
                install_path = p, version_line = line, product = product, product_version = "17.14.37 (July 2026)" }
        end
        msvc.detect_async = function(cb) cb({ inst("C:/VS/Ent", "2022", "Enterprise"), inst("C:/VS/Old", "2022", "BuildTools") }) end
        msvc.clang_cl_for_async = function(_, cb) cb(nil) end
        msvc.clang_cl_async = function(cb) cb(nil) end
        local ext = "/Common7/IDE/CommonExtensions/Microsoft/CMake"
        local files = {
            ["C:/VS/Ent" .. ext .. "/CMake/bin/cmake.exe"] = "", ["C:/VS/Ent" .. ext .. "/Ninja/ninja.exe"] = "",
            -- Old: cmake only — vcvarsall adds neither directory then.
            ["C:/VS/Old" .. ext .. "/CMake/bin/cmake.exe"] = "",
        }
        local ctx = fake_ctx({ platform = "windows", files = files, outputs = {
            ["C:/VS/Ent" .. ext .. "/CMake/bin/cmake.exe"] = "cmake version 3.31.6-msvc6\n",
            ["C:/VS/Ent" .. ext .. "/Ninja/ninja.exe"] = "1.12.1\n",
        } })
        local ok, by = pcall(probe, { msvc.health_declaration() }, ctx)
        vim.fn.has, msvc.detect_async, msvc.clang_cl_for_async, msvc.clang_cl_async = orig.has, orig.detect, orig.for_, orig.cl
        assert.is_true(ok, tostring(by))
        local c = by[msvc.bundled_id("cmake", "C:/VS/Ent/VC/Auxiliary/Build/vcvarsall.bat")]
        local n = by[msvc.bundled_id("ninja", "C:/VS/Ent/VC/Auxiliary/Build/vcvarsall.bat")]
        assert.equals("found", c.status)
        assert.equals("3.31.6", c.version)
        assert.equals("build tools", c.category)
        assert.equals("VS-bundled", c.detail)
        assert.equals("cmake (VS 2022 Enterprise)", c.label)
        assert.equals("1.12.1", n.version)
        assert.is_nil(by[msvc.bundled_id("cmake", "C:/VS/Old/VC/Auxiliary/Build/vcvarsall.bat")])
    end)

    describe("cmake requirements", function()
        local function reqs(tool_data, cfg, label)
            local tool = tool_data and { data = tool_data, label = label or "T" } or nil
            local t = {}
            for _, r in ipairs(cmake.health_requirements({ project = {}, tool = tool, configuration = cfg })) do
                t[r.id] = r
            end
            return t
        end

        it("GNU kit: cmake, ninja and the compiler (via the PATH scan)", function()
            local r = reqs({ generator = "Ninja", compiler_path = "/usr/bin/g++" })
            assert.is_not_nil(r["exe:cmake"])
            assert.is_not_nil(r["exe:ninja"])
            assert.equals("compilers:path", r[inv.path_id("cxx", "/usr/bin/g++")].via)
        end)

        it("Makefiles generator requires make", function()
            local r = reqs({ generator = "Unix Makefiles", compiler_path = "/usr/bin/g++" })
            assert.is_not_nil(r["exe:make"])
            assert.is_nil(r["exe:ninja"])
        end)

        it("VS generator / Ninja-MSVC kit require the MSVC install", function()
            local r = reqs({ generator = "Visual Studio 17 2022", vcvarsall = "C:/VS/vcvarsall.bat" })
            assert.is_not_nil(r[inv.path_id("msvc", "C:/VS/vcvarsall.bat")])
            assert.is_nil(r["exe:ninja"])
        end)

        it("an MSVC-style Ninja kit accepts Visual Studio's bundled cmake/ninja (run inside vcvarsall)", function()
            local vc = "C:/VS/VC/Auxiliary/Build/vcvarsall.bat"
            for _, td in ipairs({
                { generator = "Ninja", vcvarsall = vc },
                { generator = "Ninja", vcvarsall = vc, compiler_path = "C:/VS/VC/Tools/Llvm/x64/bin/clang-cl.exe" },
            }) do
                local r = reqs(td)
                assert.same({ msvc.bundled_id("cmake", vc) }, r["exe:cmake"].alternatives)
                assert.same({ msvc.bundled_id("ninja", vc) }, r["exe:ninja"].alternatives)
            end
            -- A preset on an MSVC kit that names Ninja is wrapped the same way.
            local p = reqs({ generator = "Ninja", vcvarsall = vc },
                { from_preset = true, module_config = { generator = "Ninja" } })
            assert.same({ msvc.bundled_id("ninja", vc) }, p["exe:ninja"].alternatives)
            -- The Visual Studio generator runs cmake from PATH (no vcvarsall
            -- wrapper): the bundled copy does not count.
            local vsgen = reqs({ generator = "Visual Studio 17 2022", vcvarsall = vc })
            assert.is_nil(vsgen["exe:cmake"].alternatives)
            -- A GNU kit has no vcvarsall either.
            assert.is_nil(reqs({ generator = "Ninja", compiler_path = "/usr/bin/g++" })["exe:cmake"].alternatives)
        end)

        it("clang-cl kit requires the driver and its MSVC install", function()
            local r = reqs({ generator = "Ninja", compiler_path = "C:/LLVM/clang-cl.exe", vcvarsall = "C:/VS/vcvarsall.bat" })
            assert.is_not_nil(r[inv.path_id("clang-cl", "C:/LLVM/clang-cl.exe")])
            assert.is_not_nil(r[inv.path_id("msvc", "C:/VS/vcvarsall.bat")])
        end)

        it("an SDK kit with its own cmake requires neither cmake nor a compiler", function()
            local r = reqs({ generator = "Ninja", cmake_path = "/sdk/cmake", sdk_key = "vendor-1", compiler_path = "/sdk/cc" })
            assert.is_nil(r["exe:cmake"])
            assert.is_not_nil(r["exe:ninja"])
            assert.is_nil(r[inv.path_id("cxx", "/sdk/cc")])
        end)

        it("a preset requires cmake and the generator it names — nothing else", function()
            local r = reqs({ generator = "Ninja", compiler_path = "/usr/bin/g++" },
                { from_preset = true, module_config = { generator = "Unix Makefiles" } })
            assert.is_not_nil(r["exe:cmake"])
            assert.is_not_nil(r["exe:make"])
            assert.is_nil(r["exe:ninja"])
            assert.is_nil(r[inv.path_id("cxx", "/usr/bin/g++")])
            local bare = reqs(nil, { from_preset = true, module_config = {} })
            assert.is_not_nil(bare["exe:cmake"])
            assert.equals(1, vim.tbl_count(bare))
        end)

        it("no tool (no profile) → cmake only", function()
            local r = reqs(nil, nil)
            assert.same({ "exe:cmake" }, vim.tbl_keys(r))
        end)
    end)

    it("meson declares meson (its own lookup) + the shared ids; requirements follow the tool", function()
        local d = ids(meson.health_inventory(fake_ctx()))
        assert.is_not_nil(d["exe:meson"])
        assert.is_not_nil(d["exe:ninja"])
        assert.is_not_nil(d["compilers:path"])

        local orig = vim.fn.exepath
        vim.fn.exepath = function(n) return n == "meson" and "/usr/bin/meson" or "" end
        local by = probe({ d["exe:meson"] }, fake_ctx({ outputs = { ["/usr/bin/meson"] = "1.4.0\n" } }))
        vim.fn.exepath = function() return "" end
        local none = probe({ d["exe:meson"] }, fake_ctx())
        vim.fn.exepath = orig
        assert.equals("1.4.0", by["exe:meson"].version)
        assert.equals("missing", none["exe:meson"].status)
        assert.equals("pip install meson", none["exe:meson"].hint)

        local function r(td)
            local t = {}
            for _, x in ipairs(meson.health_requirements({ project = {}, tool = td and { data = td } or nil })) do t[x.id] = x end
            return t
        end
        local gnu = r({ compiler_family = "gcc", compiler_path = "/usr/bin/g++" })
        assert.is_not_nil(gnu["exe:meson"]); assert.is_not_nil(gnu["exe:ninja"])
        assert.is_not_nil(gnu[inv.path_id("cxx", "/usr/bin/g++")])
        local cl = r({ compiler_family = "msvc", vcvarsall = "C:/VS/v.bat", compiler_path = "C:/VS/v.bat" })
        assert.is_not_nil(cl[inv.path_id("msvc", "C:/VS/v.bat")])
        assert.is_nil(cl[inv.path_id("cxx", "C:/VS/v.bat")])
        -- meson's MSVC-style tasks run in the vcvars environment (its PATH carries
        -- VS's bundled ninja); a GNU tool's do not.
        assert.same({ msvc.bundled_id("ninja", "C:/VS/v.bat") }, cl["exe:ninja"].alternatives)
        assert.is_nil(cl["exe:meson"].alternatives)
        assert.is_nil(gnu["exe:ninja"].alternatives)
        local ccl = r({ compiler_family = "clang-cl", compiler_path = "C:/L/clang-cl.exe", vcvarsall = "C:/VS/v.bat" })
        assert.is_not_nil(ccl[inv.path_id("clang-cl", "C:/L/clang-cl.exe")])
        assert.is_not_nil(ccl[inv.path_id("msvc", "C:/VS/v.bat")])
    end)

    it("typescript declares and requires node + npm; shell declares nothing", function()
        local d = ids(ts.health_inventory(fake_ctx()))
        assert.is_not_nil(d["exe:node"]); assert.is_not_nil(d["exe:npm"])
        local r = ts.health_requirements({})
        assert.equals("exe:node", r[1].id); assert.equals("exe:npm", r[2].id)
        assert.is_nil(shell.health_inventory)
        assert.is_nil(shell.health_requirements)
    end)

    describe("language servers / debug adapters (PATH + Mason)", function()
        local DATA = "/home/u/.local/share/nvim"
        local function mason_files(pkg, receipt, extra)
            local f = { [DATA .. "/mason/packages/" .. pkg .. "/mason-receipt.json"] = receipt }
            for k, v in pairs(extra or {}) do f[k] = v end
            return f
        end

        it("editor_data_dir follows the headless platform rules", function()
            assert.equals("C:/Users/u/AppData/Local/nvim-data", inv.editor_data_dir(fake_ctx({
                platform = "windows", env = { LOCALAPPDATA = "C:\\Users\\u\\AppData\\Local" } })))
            assert.equals("C:/L/work-data", inv.editor_data_dir(fake_ctx({
                platform = "windows", env = { LOCALAPPDATA = "C:/L", NVIM_APPNAME = "work" } })))
            assert.equals("/x/nvim", inv.editor_data_dir(fake_ctx({ env = { XDG_DATA_HOME = "/x" } })))
            assert.equals(DATA, inv.editor_data_dir(fake_ctx({ env = { HOME = "/home/u" } })))
        end)

        it("clangd: one result per location, Mason version + JSON-escaped bin link from the receipt", function()
            local companion = require("loomworks.integrations.inventory.clangd")
            local bin = DATA .. "/mason/packages/clangd/clangd_18.1.3/bin/clangd"
            local files = mason_files("clangd",
                '{"source":{"id":"pkg:github\\/clangd\\/clangd@18.1.3"},"links":{"bin":{"clangd":"clangd_18.1.3\\/bin\\/clangd"}}}',
                { [bin] = "x" })
            local ctx = fake_ctx({ env = { HOME = "/home/u" }, files = files,
                path = { clangd = "/usr/bin/clangd" },
                outputs = { ["/usr/bin/clangd"] = "Ubuntu clangd version 17.0.6\n" } })
            local by = probe(companion.health_inventory(ctx), ctx)
            assert.equals("18.1.3", by["lsp:clangd:mason"].version)
            assert.equals(bin, by["lsp:clangd:mason"].path)
            assert.equals("17.0.6", by["lsp:clangd:path"].version)
            assert.equals("language servers", by["lsp:clangd:path"].category)
            -- Mason's version came from the receipt: only the PATH clangd ran.
            assert.equals(1, #ctx._ran)
        end)

        it("a PATH hit inside Mason is the Mason install (listed once)", function()
            local companion = require("loomworks.integrations.inventory.clangd")
            local bin = DATA .. "/mason/packages/clangd/c/bin/clangd"
            local ctx = fake_ctx({ env = { HOME = "/home/u" },
                files = mason_files("clangd", '{"source":{"id":"pkg:x@1.0.0"},"links":{"bin":{"clangd":"c/bin/clangd"}}}', { [bin] = "x" }),
                path = { clangd = DATA .. "/mason/bin/clangd" } })
            local by, list = probe(companion.health_inventory(ctx), ctx)
            assert.equals(1, #list)
            assert.is_not_nil(by["lsp:clangd:mason"])
        end)

        it("nothing found → one missing result with the hint", function()
            local companion = require("loomworks.integrations.inventory.qmlls")
            local by = probe(companion.health_inventory(fake_ctx({ env = { HOME = "/home/u" } })),
                fake_ctx({ env = { HOME = "/home/u" } }))
            assert.equals("missing", by["lsp:qmlls"].status)
            assert.is_string(by["lsp:qmlls"].hint)
        end)

        it("codelldb: Mason package file + receipt version (v-prefix stripped), no spawn", function()
            local companion = require("loomworks.integrations.inventory.codelldb")
            local adapter = DATA .. "/mason/packages/codelldb/extension/adapter/codelldb"
            local ctx = fake_ctx({ env = { HOME = "/home/u" },
                files = mason_files("codelldb", '{"source":{"id":"pkg:github/vadimcn/vscode-lldb@v1.12.1"}}', { [adapter] = "x" }) })
            local by = probe(companion.health_inventory(ctx), ctx)
            assert.equals("1.12.1", by["dap:codelldb:mason"].version)
            assert.equals("debug adapters", by["dap:codelldb:mason"].category)
            assert.equals(0, #ctx._ran)
        end)

        it("pwa-node also declares the shared exe:node", function()
            local d = ids(require("loomworks.integrations.inventory.pwa_node").health_inventory(fake_ctx()))
            assert.is_not_nil(d["dap:pwa-node"])
            assert.is_not_nil(d["exe:node"])
        end)

        it("the LSP integrations re-export their companion's hook", function()
            -- The integration files need the editor at load; the LSP registry
            -- discovers (requires) them.
            local lsp = require("loomworks.lsp")
            for _, name in ipairs({ "clangd", "qmlls" }) do
                local integration = lsp.integration(name)
                assert.is_not_nil(integration)
                assert.equals(require("loomworks.integrations.inventory." .. name).health_inventory,
                    integration.health_inventory)
            end
        end)
    end)

    it("SDK providers: pinned installations probed once each via validate", function()
        local calls = 0
        local provider = { id = "vendor", api_version = 1, display_name = "Vendor SDK",
            detect_all = function() return {} end,
            validate = function(path) calls = calls + 1; return path == "/ok" and { version = "2.0" } or nil end }
        local sdk_ok = { key = "vendor-2", _type = "vendor", _path = "/ok", display_name = function() return "Vendor 2" end }
        local sdk_bad = { key = "vendor-3", _type = "vendor", _path = "/gone", display_name = function() return "Vendor 3" end }
        local ws = { _profiles = {
            { sdk = function() return sdk_ok end }, { sdk = function() return sdk_ok end },
            { sdk = function() return sdk_bad end },
        } }
        local saved = inv._contributors
        inv._contributors = { { kind = "sdk", id = "vendor", api = 1, impl = provider } }
        local ctx = fake_ctx({ workspace = ws })
        local by = probe(inv.declarations(ctx), ctx)
        inv._contributors = saved
        assert.equals(2, calls) -- once per distinct pinned installation
        assert.equals("found", by["sdk:vendor-2"].status)
        assert.equals("2.0", by["sdk:vendor-2"].version)
        assert.equals("missing", by["sdk:vendor-3"].status)
        assert.equals("SDKs", by["sdk:vendor-3"].category)
    end)

    it("compiler caches are declared by core (informational)", function()
        local saved = inv._contributors
        inv._contributors = {}
        local ctx = fake_ctx({ path = { ccache = "/usr/bin/ccache" }, outputs = { ["/usr/bin/ccache"] = "ccache version 4.9.1" } })
        local by = probe(inv.declarations(ctx), ctx)
        inv._contributors = saved
        assert.equals("found", by["exe:ccache"].status)
        assert.equals("4.9.1", by["exe:ccache"].version)
        assert.equals("compiler caches", by["exe:ccache"].category)
        assert.equals("missing", by["exe:sccache"].status)
        assert.equals("found", by["lw"].status)
    end)
end)


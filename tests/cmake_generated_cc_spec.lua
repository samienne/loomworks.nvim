--- Tests for the cmake module's generated compile_commands.json (§12):
--- reconstructing a compilation database from the file-api codemodel +
--- toolchains replies for non-emitting generators (Visual Studio / Xcode),
--- and the lsp_configs wiring that points clangd at the generated dir.

local cmake = require("loomworks.modules.cmake")
local uv = vim.uv or vim.loop

--- Directory holding the hand-crafted file-api reply fixtures.
local FIXTURES = debug.getinfo(1, "S").source:sub(2)
    :gsub("\\", "/")
    :gsub("/[^/]*$", "") .. "/fixtures/cmake_file_api"

--- Read + decode a fixture JSON file.
--- @param name string basename under the fixtures dir
--- @return table
local function load_fixture(name)
    local f = assert(io.open(FIXTURES .. "/" .. name, "r"))
    local content = f:read("*a")
    f:close()
    return vim.json.decode(content)
end

--- Index a list of compile_commands entries by (basename of) file.
--- @param entries table[]
--- @return table<string, table>
local function by_basename(entries)
    local out = {}
    for _, e in ipairs(entries) do
        out[e.file:match("[^/]+$")] = e
    end
    return out
end

--- True if `needle` appears as a contiguous subsequence of argv `hay`.
local function contains_seq(hay, needle)
    for i = 0, #hay - #needle do
        local ok = true
        for j = 1, #needle do
            if hay[i + j] ~= needle[j] then ok = false break end
        end
        if ok then return true end
    end
    return false
end

--- True if `tok` is present anywhere in argv `hay`.
local function has_tok(hay, tok)
    for _, v in ipairs(hay) do
        if v == tok then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- generator_emits_compile_commands / compile_commands_generated default
-- ---------------------------------------------------------------------------

describe("cmake generator_emits_compile_commands", function()
    it("is true for Ninja and Makefile generators", function()
        assert.is_true(cmake.generator_emits_compile_commands("Ninja"))
        assert.is_true(cmake.generator_emits_compile_commands("Ninja Multi-Config"))
        assert.is_true(cmake.generator_emits_compile_commands("Unix Makefiles"))
        assert.is_true(cmake.generator_emits_compile_commands("MinGW Makefiles"))
    end)

    it("is false for Visual Studio and Xcode generators", function()
        assert.is_false(cmake.generator_emits_compile_commands("Visual Studio 17 2022"))
        assert.is_false(cmake.generator_emits_compile_commands("Xcode"))
    end)

    it("is false for nil / unknown generators", function()
        assert.is_false(cmake.generator_emits_compile_commands(nil))
        assert.is_false(cmake.generator_emits_compile_commands("Some Future Generator"))
    end)
end)

describe("cmake compile_commands_generated field (from M.info)", function()
    --- Grab the module_config of a named configuration from M.info output.
    local function config_mc(info, name)
        local cfg = info.configurations[name] or info.preset_configurations[name]
        return cfg
    end

    it("defaults false for plain variant configs (generator unknown at info time)", function()
        local info = cmake.info("/nonexistent/proj", {})
        local dbg = config_mc(info, "variant:Debug")
        assert.is_not_nil(dbg)
        assert.is_false(dbg.compile_commands_generated)
    end)

    it("is true for a user config pinning a Visual Studio generator", function()
        local info = cmake.info("/nonexistent/proj", {
            configurations = {
                msvc = { inherits = "variant:Debug", generator = "Visual Studio 17 2022" },
            },
        })
        local msvc = config_mc(info, "msvc")
        assert.is_not_nil(msvc)
        assert.is_true(msvc.compile_commands_generated)
    end)

    it("is false for a user config pinning a Ninja generator", function()
        local info = cmake.info("/nonexistent/proj", {
            configurations = {
                nj = { inherits = "variant:Debug", generator = "Ninja" },
            },
        })
        local nj = config_mc(info, "nj")
        assert.is_not_nil(nj)
        assert.is_false(nj.compile_commands_generated)
    end)
end)

-- ---------------------------------------------------------------------------
-- _build_cc_entries — pure reconstruction
-- ---------------------------------------------------------------------------

describe("cmake _build_cc_entries", function()
    local codemodel, detail, toolchains
    before_each(function()
        codemodel = load_fixture("codemodel-v2.json")
        detail = load_fixture("target-app-Debug.json")
        toolchains = load_fixture("toolchains-v1.json")
    end)

    local function build(tc, opts)
        return cmake._build_cc_entries(
            codemodel,
            { ["target-app-Debug.json"] = detail },
            tc,
            codemodel.paths.source,
            "Debug",
            "C:/proj/build",
            opts)
    end

    it("produces one entry per source", function()
        local entries = build(toolchains)
        assert.equals(2, #entries)
        local idx = by_basename(entries)
        assert.is_not_nil(idx["main.cpp"])
        assert.is_not_nil(idx["helper.cpp"])
    end)

    it("resolves source paths to absolute against the codemodel source root", function()
        local idx = by_basename(build(toolchains))
        assert.equals("C:/proj/src/main.cpp", idx["main.cpp"].file)
        assert.equals("C:/proj/src/util/helper.cpp", idx["helper.cpp"].file)
        assert.equals("C:/proj/build", idx["main.cpp"].directory)
    end)

    describe("MSVC compiler (cl.exe from toolchains)", function()
        it("uses cl.exe as argv[0] and the source as the last arg", function()
            local e = by_basename(build(toolchains))["main.cpp"]
            assert.equals("cl.exe", e.arguments[1]:match("[^/]+$"))
            assert.equals(e.file, e.arguments[#e.arguments])
        end)

        it("renders includes as /I and system includes as /external:I", function()
            local a = by_basename(build(toolchains))["main.cpp"].arguments
            assert.is_true(contains_seq(a, { "/I", "C:/proj/src/include" }))
            assert.is_true(contains_seq(a, { "/external:I", "C:/vendor/boost" }))
        end)

        it("renders defines as /D<define>", function()
            local a = by_basename(build(toolchains))["main.cpp"].arguments
            assert.is_true(has_tok(a, "/DFOO=1"))
            assert.is_true(has_tok(a, "/DBAR"))
        end)

        it("splits a multi-flag fragment into separate argv tokens", function()
            local a = by_basename(build(toolchains))["main.cpp"].arguments
            assert.is_true(has_tok(a, "/std:c++17"))
            assert.is_true(has_tok(a, "/EHsc"))
        end)
    end)

    describe("GNU compiler (g++)", function()
        local gnu_tc = {
            toolchains = {
                { language = "CXX", compiler = { path = "/usr/bin/g++" } },
            },
        }

        it("uses the GNU driver and -I / -isystem / -D syntax", function()
            local a = by_basename(build(gnu_tc))["main.cpp"].arguments
            assert.equals("/usr/bin/g++", a[1])
            assert.is_true(has_tok(a, "-IC:/proj/src/include"))
            assert.is_true(contains_seq(a, { "-isystem", "C:/vendor/boost" }))
            assert.is_true(has_tok(a, "-DFOO=1"))
            assert.is_true(has_tok(a, "-DBAR"))
        end)
    end)

    it("falls back to opts.compiler when a language has no toolchain entry", function()
        local a = by_basename(build(nil, { compiler = "/usr/bin/clang++" }))["main.cpp"].arguments
        assert.equals("/usr/bin/clang++", a[1])
        -- clang++ is a GNU-style driver → -I syntax.
        assert.is_true(has_tok(a, "-IC:/proj/src/include"))
    end)
end)

-- ---------------------------------------------------------------------------
-- generate_compile_commands — end-to-end with fixtures on disk
-- ---------------------------------------------------------------------------

describe("cmake generate_compile_commands", function()
    local tmp
    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp .. "/build/.cmake/api/v1/reply", "p")
        local reply = tmp .. "/build/.cmake/api/v1/reply"
        local function cp(src, dst)
            local f = assert(io.open(FIXTURES .. "/" .. src, "r"))
            local body = f:read("*a"); f:close()
            local o = assert(io.open(reply .. "/" .. dst, "w"))
            o:write(body); o:close()
        end
        cp("codemodel-v2.json", "codemodel-v2-x.json")
        cp("target-app-Debug.json", "target-app-Debug.json")
        cp("toolchains-v1.json", "toolchains-v1-x.json")
        -- Index referencing the codemodel + toolchains objects.
        local index = {
            objects = {
                { kind = "codemodel", version = { major = 2, minor = 0 }, jsonFile = "codemodel-v2-x.json" },
                { kind = "toolchains", version = { major = 1, minor = 0 }, jsonFile = "toolchains-v1-x.json" },
            },
        }
        local i = assert(io.open(reply .. "/index-2025.json", "w"))
        i:write(vim.json.encode(index)); i:close()
    end)
    after_each(function()
        if tmp then vim.fn.delete(tmp, "rf") end
    end)

    it("writes a compile_commands.json with one entry per source", function()
        local out_dir = tmp .. "/cache/cc"
        local n = cmake.generate_compile_commands(tmp .. "/build", out_dir, { variant = "Debug" })
        assert.equals(2, n)
        local f = assert(io.open(out_dir .. "/compile_commands.json", "r"))
        local decoded = vim.json.decode(f:read("*a")); f:close()
        assert.equals(2, #decoded)
        assert.equals("cl.exe", decoded[1].arguments[1]:match("[^/]+$"))
    end)

    it("returns nil when no codemodel reply exists", function()
        assert.is_nil(cmake.generate_compile_commands(tmp .. "/no-build", tmp .. "/out"))
    end)
end)

-- ---------------------------------------------------------------------------
-- lsp_configs — clangd compile_commands_dir routing (§12)
-- ---------------------------------------------------------------------------

describe("cmake lsp_configs compile_commands_dir (generated vs build dir)", function()
    --- Build a fake Project + Workspace whose active profile carries a
    --- ProfileProject with the given build_dir, active configuration, and
    --- tool (kit) generator. Mirrors qmlls_spec's fake_project.
    local function fake_project(opts)
        local build_dir = opts.build_dir
        local cfg = opts.config -- Configuration-like: { module_config = {...}, base_name = ... }
        local tool_data = opts.tool_data
        local ws = {
            root = opts.ws_root or "/work",
            get_active_profile = function()
                if not build_dir then return nil end
                return {
                    project = function()
                        return {
                            build_dir = function() return build_dir end,
                            configuration = function() return cfg end,
                        }
                    end,
                    tool_for = function()
                        return tool_data and { data = tool_data } or nil
                    end,
                }
            end,
        }
        return {
            key = "myapp",
            path = "myapp",
            type = "cmake",
            type_config = {},
            tool_data = tool_data,
            _workspace = ws,
        }
    end

    it("points clangd at the build dir for a Ninja config", function()
        local cfgs = cmake.lsp_configs(fake_project({
            ws_root = "/work",
            build_dir = "/work/.nvim/build/myapp/ninja/Debug",
            config = { base_name = "Debug", module_config = { variant = "Debug" } },
            tool_data = { generator = "Ninja" },
        }))
        assert.equals("clangd", cfgs[1].server)
        assert.equals("/work/.nvim/build/myapp/ninja/Debug", cfgs[1].compile_commands_dir)
    end)

    it("points clangd at a loomworks-owned dir for a Visual Studio config", function()
        local build_dir = "/work/.nvim/build/myapp/msvc"
        local cfgs = cmake.lsp_configs(fake_project({
            ws_root = "/work",
            build_dir = build_dir,
            config = { base_name = "Debug", module_config = { variant = "Debug" } },
            tool_data = { generator = "Visual Studio 17 2022" },
        }))
        local dir = cfgs[1].compile_commands_dir
        assert.are_not.equal(build_dir, dir)
        -- Under the loomworks-owned cache, mirroring the build-dir subpath.
        assert.is_truthy(dir:find("/.nvim/cache/cc/", 1, true),
            "expected generated dir under .nvim/cache/cc, got: " .. tostring(dir))
        assert.is_truthy(dir:find("myapp/msvc", 1, true))
        -- qmlls entry keeps the real build dir.
        assert.equals(build_dir, cfgs[2].build_dir)
    end)

    it("honors an explicit config-level compile_commands_generated = true", function()
        local build_dir = "/work/.nvim/build/myapp/x"
        local cfgs = cmake.lsp_configs(fake_project({
            ws_root = "/work",
            build_dir = build_dir,
            config = { base_name = "Debug", module_config = {
                variant = "Debug", compile_commands_generated = true } },
            tool_data = { generator = "Ninja" }, -- would otherwise be build_dir
        }))
        assert.is_truthy(cfgs[1].compile_commands_dir:find("/.nvim/cache/cc/", 1, true))
    end)
end)

-- ---------------------------------------------------------------------------
-- Optional real Visual Studio configure + reconstruction (Windows only).
-- Mirrors cmake_clang_cl_e2e_spec's guard: skip (never fail) without a real
-- VS-generator toolchain. This is the true validation that we can rebuild a
-- database CMake never emitted.
-- ---------------------------------------------------------------------------

--- Recursively remove a directory tree (best effort).
local function rm_rf(path)
    local handle = uv.fs_scandir(path)
    if not handle then pcall(uv.fs_unlink, path); return end
    while true do
        local entry, etype = uv.fs_scandir_next(handle)
        if not entry then break end
        local full = path .. "/" .. entry
        if etype == "directory" then rm_rf(full) else pcall(uv.fs_unlink, full) end
    end
    pcall(uv.fs_rmdir, path)
end

--- First detected kit whose generator is a Visual Studio generator, or nil.
local function first_vs_kit()
    local ok, kits = pcall(function() return require("loomworks.cmake_kits").detect() end)
    if not ok or type(kits) ~= "table" then return nil end
    for _, kit in ipairs(kits) do
        if type(kit.generator) == "string" and kit.generator:match("^Visual Studio") then
            return kit
        end
    end
    return nil
end

describe("cmake generate_compile_commands end-to-end (real VS configure)", function()
    it("reconstructs a database from a real Visual Studio configure", function()
        if vim.fn.has("win32") ~= 1 then
            pending("VS generated-cc e2e requires Windows")
            return
        end
        local installs = require("loomworks.msvc").detect()
        if not installs or #installs == 0 then
            pending("VS generated-cc e2e requires a detected MSVC install (vswhere)")
            return
        end
        local kit = first_vs_kit()
        if not kit then
            pending("VS generated-cc e2e requires a detected Visual Studio generator kit")
            return
        end

        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        local build_dir = root .. "/build"
        vim.fn.mkdir(build_dir, "p")
        vim.fn.mkdir(root .. "/inc", "p")

        local function write(rel, body)
            local f = assert(io.open(root .. "/" .. rel, "w"))
            f:write(body); f:close()
        end
        write("CMakeLists.txt", table.concat({
            "cmake_minimum_required(VERSION 3.15)",
            "project(lw_vs_gencc CXX)",
            "add_executable(app main.cpp)",
            "target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/inc)",
            "target_compile_definitions(app PRIVATE LW_DEFINED=1)",
            "",
        }, "\n"))
        write("main.cpp", "#include <widget.h>\nint main(){ return 0; }\n")
        write("inc/widget.h", "// header\n")

        local ok, err = pcall(function()
            local ctx = {
                name = "App",
                path = ".",
                workspace_root = root,
                configurations = {
                    ["variant:Debug"] = { variant = "Debug", generator = kit.generator },
                },
                tool_data = {
                    id = kit.id,
                    generator = kit.generator,
                    compiler_path = kit.compiler_path,
                },
                cached_build_dir = build_dir,
            }
            local tasks = cmake.tasks(ctx, "variant:Debug")
            local configure
            for _, t in ipairs(tasks) do
                if t.loomworks and t.loomworks.action == "configure" then configure = t end
            end
            assert.is_not_nil(configure)
            local cfg_cmd = configure.builder().cmd
            local res = vim.system(cfg_cmd, { text = true }):wait()
            assert.equals(0, res.code,
                "VS configure failed (exit " .. tostring(res.code) .. ")\n"
                .. "cmd: " .. vim.inspect(cfg_cmd) .. "\n"
                .. "stderr:\n" .. tostring(res.stderr))

            -- VS generators never emit compile_commands.json.
            assert.is_nil(uv.fs_stat(build_dir .. "/compile_commands.json"))

            local out_dir = root .. "/.nvim/cache/cc/app"
            local n = cmake.generate_compile_commands(build_dir, out_dir, {
                variant = "Debug",
                compiler = kit.compiler_path,
            })
            assert.is_truthy(n and n >= 1, "no entries generated")

            local f = assert(io.open(out_dir .. "/compile_commands.json", "r"))
            local entries = vim.json.decode(f:read("*a")); f:close()

            local main_entry
            for _, e in ipairs(entries) do
                if e.file:match("main%.cpp$") then main_entry = e end
            end
            assert.is_not_nil(main_entry, "no entry for main.cpp")
            -- cl.exe as the driver so clangd's cl-compatible mode applies.
            assert.equals("cl.exe", main_entry.arguments[1]:match("[^/]+$"))
            -- Our include dir rendered in MSVC syntax.
            local joined = table.concat(main_entry.arguments, " ")
            assert.is_truthy(joined:find("/I", 1, true), "no /I include flag: " .. joined)
            assert.is_truthy(joined:lower():find("/inc", 1, true),
                "include dir not present: " .. joined)
        end)

        rm_rf(root)
        if not ok then error(err) end
    end)
end)

local M = {}

--- @class loomworks.CmakeKit
--- @field id string unique identifier (e.g. "msvc-17-2022-enterprise", "ninja-gcc-14.2.0", "ninja-clang-cl-17-community")
--- @field display string human-readable name (e.g. "MSVC 17 2022 (Enterprise)", "Ninja - clang-cl (MSVC 17 2022 (Community))")
--- @field generator string cmake -G value
--- @field compiler_id string|nil compiler identifier
--- @field compiler_path string|nil path to compiler binary (clang-cl kits: the clang-cl driver, used for both C and C++)
--- @field env table<string, string> environment variables needed
--- @field vcvarsall string|nil path to vcvarsall.bat (MSVC / clang-cl kits)
--- @field arch string|nil target architecture for vcvarsall
--- @field clangd_path string|nil path to clangd binary bundled with this toolchain

--- @type loomworks.CmakeKit[]|nil
M._cached = nil

local uv = vim.uv or vim.loop

--- Build the MSVC "Visual Studio <NN> <YYYY>" generator kit for one install.
--- MSVC + clang-cl discovery is owned by the shared `loomworks.msvc` module;
--- this only shapes an install descriptor into cmake's kit table.
--- @param inst table one entry from `loomworks.msvc` detect()/detect_async()
--- @return loomworks.CmakeKit
local function vs_generator_kit(inst)
    return {
        id = inst.id,
        display = inst.display,
        generator = "Visual Studio " .. inst.vs_major .. " " .. inst.version_line,
        compiler_id = "msvc-" .. inst.vs_major,
        env = {},
        vcvarsall = inst.vcvarsall,
        arch = inst.arch,
    }
end

--- Build the Ninja + MSVC (cl.exe) kit for one install. Needs the vcvarsall
--- environment at build time.
--- @param inst table
--- @return loomworks.CmakeKit
local function ninja_msvc_kit(inst)
    local compiler_id = "msvc-" .. inst.vs_major
    return {
        id = "ninja-" .. compiler_id .. "-" .. inst.product:lower(),
        display = "Ninja - " .. inst.display,
        generator = "Ninja",
        compiler_id = compiler_id,
        env = {},
        vcvarsall = inst.vcvarsall,
        arch = inst.arch,
    }
end

--- Build the Ninja + clang-cl kit for one install. clang-cl is both the C and
--- C++ driver and reuses the paired install's STL / Windows SDK / linker via
--- vcvarsall, so there is exactly one clang-cl kit per install.
--- @param inst table
--- @param cc { path: string, version: string, clangd_path: string|nil }
--- @return loomworks.CmakeKit
local function clang_cl_kit(inst, cc)
    return {
        id = "ninja-clang-cl-" .. inst.vs_major .. "-" .. inst.product:lower(),
        display = "Ninja - clang-cl (" .. inst.display .. ")",
        generator = "Ninja",
        compiler_id = "clang-cl-" .. cc.version,
        compiler_path = cc.path,
        clangd_path = cc.clangd_path,
        vcvarsall = inst.vcvarsall,
        arch = inst.arch,
        env = {},
    }
end

--- Try to find a clangd binary alongside a compiler path.
--- Looks for clangd in the same directory as the compiler.
--- @param compiler_path string
--- @return string|nil clangd_path
local function find_sibling_clangd(compiler_path)
    local dir = compiler_path:match("^(.+)/[^/]+$")
    if not dir then return nil end
    local candidate = dir .. "/clangd"
    if vim.fn.executable(candidate) == 1 then return candidate end
    candidate = dir .. "/clangd.exe"
    if uv.fs_stat(candidate) then return candidate end
    return nil
end

--- Detect C/C++ compilers in PATH. Delegates to the shared
--- `loomworks.cpp_compilers` module, shaping the result into the
--- `{path=...}` fields this adapter uses.
--- @return { id: string, display: string, path: string, version: string, family: string, clangd_path: string|nil }[]
local function detect_compilers()
    local shared = require("loomworks.cpp_compilers").detect()
    local out = {}
    for _, c in ipairs(shared) do
        out[#out + 1] = {
            id = c.id,
            display = c.display,
            path = c.path,
            version = c.version,
            family = c.family,
            clangd_path = c.clangd_path,
        }
    end
    return out
end

--- Detect all available cmake build kits.
--- @return loomworks.CmakeKit[]
function M.detect()
    if M._cached then return M._cached end

    local msvc = require("loomworks.msvc")
    local installs = msvc.detect()
    local kits = {}

    -- VS-generator MSVC kits (one per install).
    for _, inst in ipairs(installs) do
        kits[#kits + 1] = vs_generator_kit(inst)
    end

    local ninja_available = vim.fn.executable("ninja") == 1
    if ninja_available then
        for _, comp in ipairs(detect_compilers()) do
            kits[#kits + 1] = {
                id = "ninja-" .. comp.id,
                display = "Ninja - " .. comp.display,
                generator = "Ninja",
                compiler_id = comp.id,
                compiler_path = comp.path,
                clangd_path = comp.clangd_path,
                env = {},
            }
        end

        -- Ninja + MSVC (cl.exe) kits need the vcvarsall environment.
        for _, inst in ipairs(installs) do
            kits[#kits + 1] = ninja_msvc_kit(inst)
        end

        -- Ninja + clang-cl kits — one per install (VS-bundled clang-cl
        -- preferred, standalone/PATH as fallback).
        for _, inst in ipairs(installs) do
            local cc = msvc.clang_cl_for(inst)
            if cc then kits[#kits + 1] = clang_cl_kit(inst, cc) end
        end
    end

    M._cached = kits
    return kits
end

--- Clear the detection cache (also clears the shared compiler + MSVC caches
--- this module sources its kits from).
function M.clear_cache()
    M._cached = nil
    require("loomworks.cpp_compilers").clear_cache()
    require("loomworks.msvc").clear_cache()
end

--- Detect compilers asynchronously.
--- Uses sync vim.fn.executable() for fast PATH lookups, then chains
--- async vim.system() calls for --version probes sequentially.
--- @param callback fun(compilers: table[])
local function detect_compilers_async(callback)
    local candidates = {}
    for _, base in ipairs({ "gcc", "g++", "clang", "clang++" }) do
        candidates[#candidates + 1] = base
        for v = 8, 25 do
            candidates[#candidates + 1] = base .. "-" .. v
        end
    end

    local executable_names = {}
    for _, name in ipairs(candidates) do
        if vim.fn.executable(name) == 1 then
            local path = vim.fn.exepath(name)
            if path ~= "" then
                executable_names[#executable_names + 1] = { name = name, path = path }
            end
        end
    end

    if #executable_names == 0 then
        callback({})
        return
    end

    -- Chain async --version probes
    local compilers = {}
    local seen = {}
    local idx = 0

    local function next_probe()
        idx = idx + 1
        if idx > #executable_names then
            table.sort(compilers, function(a, b)
                if a.family ~= b.family then return a.family < b.family end
                return a.version > b.version
            end)
            callback(compilers)
            return
        end

        local entry = executable_names[idx]
        if seen[entry.path] then
            next_probe()
            return
        end

        vim.system({ entry.path, "--version" }, { text = true }, function(result)
            vim.schedule(function()
                local version
                if result.code == 0 and result.stdout then
                    version = result.stdout:match("(%d+%.%d+%.%d+)") or result.stdout:match("(%d+%.%d+)")
                end
                if not version then
                    next_probe()
                    return
                end

                local name = entry.name
                local path = entry.path
                local family
                if name:match("^clang") then
                    family = "clang"
                elseif name:match("^g[c%+]") then
                    family = "gcc"
                end
                if not family then
                    next_probe()
                    return
                end

                local compound_id = family .. "-" .. version
                if seen[compound_id] then
                    next_probe()
                    return
                end
                seen[compound_id] = true
                seen[path] = true

                local is_cpp = name:match("%+%+")
                local cpp_path = path
                if not is_cpp then
                    local cpp_name = name:gsub("^gcc", "g++"):gsub("^clang$", "clang++"):gsub("^clang%-(%d)", "clang++-%1")
                    if vim.fn.executable(cpp_name) == 1 then
                        local p = vim.fn.exepath(cpp_name)
                        if p ~= "" then cpp_path = p end
                    end
                end

                compilers[#compilers + 1] = {
                    id = compound_id,
                    display = family == "gcc" and ("GCC " .. version) or ("Clang " .. version),
                    path = cpp_path,
                    version = version,
                    family = family,
                    clangd_path = find_sibling_clangd(cpp_path),
                }

                next_probe()
            end)
        end)
    end

    next_probe()
end

--- Detect all available cmake build kits asynchronously.
--- Calls callback(kits) when detection is complete.
--- If results are cached, calls callback immediately.
--- @param callback fun(kits: loomworks.CmakeKit[])
function M.detect_async(callback)
    if M._cached then
        callback(M._cached)
        return
    end

    local msvc = require("loomworks.msvc")
    msvc.detect_async(function(installs)
        detect_compilers_async(function(compilers)
            local kits = {}

            for _, inst in ipairs(installs) do
                kits[#kits + 1] = vs_generator_kit(inst)
            end

            local ninja_available = vim.fn.executable("ninja") == 1
            if ninja_available then
                for _, comp in ipairs(compilers) do
                    kits[#kits + 1] = {
                        id = "ninja-" .. comp.id,
                        display = "Ninja - " .. comp.display,
                        generator = "Ninja",
                        compiler_id = comp.id,
                        compiler_path = comp.path,
                        clangd_path = comp.clangd_path,
                        env = {},
                    }
                end

                for _, inst in ipairs(installs) do
                    kits[#kits + 1] = ninja_msvc_kit(inst)
                end

                for _, inst in ipairs(installs) do
                    local cc = msvc.clang_cl_for(inst)
                    if cc then kits[#kits + 1] = clang_cl_kit(inst, cc) end
                end
            end

            M._cached = kits
            callback(kits)
        end)
    end)
end

--- Find a kit by its id.
--- @param id string
--- @return loomworks.CmakeKit|nil
function M.get_by_id(id)
    for _, kit in ipairs(M.detect()) do
        if kit.id == id then return kit end
    end
    return nil
end

--- Find a kit by its display name.
--- @param display string
--- @return loomworks.CmakeKit|nil
function M.get_by_display(display)
    for _, kit in ipairs(M.detect()) do
        if kit.display == display then return kit end
    end
    return nil
end

--- Get the default kit (first MSVC if available, else first Ninja).
--- @return loomworks.CmakeKit|nil
function M.default_kit()
    local kits = M.detect()
    return kits[1]
end

return M

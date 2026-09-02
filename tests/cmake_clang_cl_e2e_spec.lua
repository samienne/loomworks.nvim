--- End-to-end clang-cl build test: runs a REAL `cmake` configure + build with
--- a detected Ninja + clang-cl kit against a tiny fixture project and asserts a
--- binary is produced.
---
--- Complements `cmake_clang_cl_spec.lua` (which only asserts command
--- CONSTRUCTION with stubbed detection). This one executes the actual pipeline,
--- so it only runs when a genuine toolchain is present:
---   * Windows host,
---   * at least one MSVC install (vswhere), and
---   * a real Ninja + clang-cl kit (kits are ninja-gated, so its presence also
---     implies ninja is available; cmake/ninja resolve inside the vcvars env the
---     configure command is wrapped in).
--- Anywhere else (Linux CI, no MSVC, no clang-cl) it is a `pending(...)` skip,
--- never a failure — `make test` stays green everywhere.

local cmake = require("loomworks.modules.cmake")
local uv = vim.uv or vim.loop

--- Recursively search a directory tree for a file with the given basename.
--- @param dir string
--- @param name string basename to find (e.g. "app.exe")
--- @return string|nil absolute path
local function find_file(dir, name)
    local handle = uv.fs_scandir(dir)
    if not handle then return nil end
    while true do
        local entry, etype = uv.fs_scandir_next(handle)
        if not entry then break end
        local full = dir .. "/" .. entry
        if etype == "directory" then
            local found = find_file(full, name)
            if found then return found end
        elseif entry == name then
            return full
        end
    end
    return nil
end

--- Remove a directory tree (best-effort).
--- @param path string
local function rm_rf(path)
    local handle = uv.fs_scandir(path)
    if not handle then
        pcall(uv.fs_unlink, path)
        return
    end
    while true do
        local entry, etype = uv.fs_scandir_next(handle)
        if not entry then break end
        local full = path .. "/" .. entry
        if etype == "directory" then
            rm_rf(full)
        else
            pcall(uv.fs_unlink, full)
        end
    end
    pcall(uv.fs_rmdir, path)
end

--- First detected Ninja + clang-cl kit, or nil.
--- @return loomworks.CmakeKit|nil
local function first_clang_cl_kit()
    local ok, kits = pcall(function() return require("loomworks.cmake_kits").detect() end)
    if not ok or type(kits) ~= "table" then return nil end
    for _, kit in ipairs(kits) do
        if kit.id and kit.id:match("^ninja%-clang%-cl%-") then return kit end
    end
    return nil
end

--- Find the task with the given loomworks action.
--- @param tasks table[]
--- @param action string
--- @return table|nil
local function find_task(tasks, action)
    for _, t in ipairs(tasks) do
        if t.loomworks and t.loomworks.action == action then return t end
    end
    return nil
end

describe("cmake clang-cl end-to-end (real configure + build)", function()
    it("configures and builds a fixture project with a detected clang-cl kit", function()
        -- ---- Guard: skip (not fail) when no real toolchain is present ----
        if vim.fn.has("win32") ~= 1 then
            pending("clang-cl e2e requires Windows")
            return
        end
        local installs = require("loomworks.msvc").detect()
        if not installs or #installs == 0 then
            pending("clang-cl e2e requires a detected MSVC install (vswhere)")
            return
        end
        local kit = first_clang_cl_kit()
        if not kit then
            pending("clang-cl e2e requires a detected Ninja + clang-cl kit")
            return
        end

        -- ---- Fixture project ----
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        local build_dir = root .. "/build"
        vim.fn.mkdir(build_dir, "p")

        local function write(rel, body)
            local f = assert(io.open(root .. "/" .. rel, "w"))
            f:write(body)
            f:close()
        end
        write("CMakeLists.txt", table.concat({
            "cmake_minimum_required(VERSION 3.15)",
            "project(lw_clangcl_e2e CXX)",
            "add_executable(app main.cpp)",
            "",
        }, "\n"))
        write("main.cpp", "int main() { return 0; }\n")

        local ok, err = pcall(function()
            -- ctx mirrors cmake_clang_cl_spec's ctx(), but with the REAL kit.
            local ctx = {
                name = "App",
                path = ".", -- CMakeLists.txt lives at the fixture root
                workspace_root = root,
                configurations = {
                    ["variant:Debug"] = { variant = "Debug", generator = "Ninja" },
                },
                tool_data = {
                    generator = "Ninja",
                    compiler_path = kit.compiler_path,
                    vcvarsall = kit.vcvarsall,
                    arch = kit.arch,
                    clangd_path = kit.clangd_path,
                },
                cached_build_dir = build_dir,
            }

            local tasks = cmake.tasks(ctx, "variant:Debug")

            -- ---- Configure for real ----
            local configure = find_task(tasks, "configure")
            assert.is_not_nil(configure)
            local cfg_cmd = configure.builder().cmd
            local cfg = vim.system(cfg_cmd, { text = true }):wait()
            assert.equals(0, cfg.code,
                "clang-cl configure failed (exit " .. tostring(cfg.code) .. ")\n"
                .. "cmd: " .. vim.inspect(cfg_cmd) .. "\n"
                .. "stdout:\n" .. tostring(cfg.stdout) .. "\n"
                .. "stderr:\n" .. tostring(cfg.stderr))
            assert.is_truthy(uv.fs_stat(build_dir .. "/compile_commands.json"),
                "configure did not produce compile_commands.json")

            -- ---- Build for real ----
            local build = find_task(tasks, "build")
            assert.is_not_nil(build)
            local build_cmd = build.builder().cmd
            local b = vim.system(build_cmd, { text = true }):wait()
            assert.equals(0, b.code,
                "clang-cl build failed (exit " .. tostring(b.code) .. ")\n"
                .. "cmd: " .. vim.inspect(build_cmd) .. "\n"
                .. "stdout:\n" .. tostring(b.stdout) .. "\n"
                .. "stderr:\n" .. tostring(b.stderr))

            -- ---- Artifact: Ninja places single-config output at the build
            -- root, but search the tree to be robust. ----
            local exe = uv.fs_stat(build_dir .. "/app.exe") and (build_dir .. "/app.exe")
                or find_file(build_dir, "app.exe")
            assert.is_truthy(exe, "no app.exe produced under " .. build_dir)
        end)

        rm_rf(root)
        if not ok then error(err) end
    end)
end)

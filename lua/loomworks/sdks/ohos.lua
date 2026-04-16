--- loomworks/sdks/ohos.lua — OpenHarmony/HarmonyOS SDK provider.
---
--- Detects DevEco Studio installations, validates paths, creates SDK
--- objects with module-specific capabilities.

local SDK = require("loomworks.sdk")

local P = {}
P.id = "ohos"
P.display_name = "OpenHarmony"

local uv = vim.uv or vim.loop
local io_mod = require("loomworks.io")
local is_win = vim.fn.has("win32") == 1

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Resolve a tool path, checking platform-specific extensions.
--- @param base string base path without extension
--- @param exts string[] extensions to try
--- @return string|nil
local function resolve_tool(base, exts)
    for _, ext in ipairs(exts) do
        local p = base .. ext
        if uv.fs_stat(p) then return p end
    end
    return nil
end

local exe_exts = is_win and { ".exe", "" } or { "", ".exe" }
local script_exts = is_win and { ".bat", ".cmd", "" } or { "", ".sh" }

--- Read version from DevEco's product-info.json.
--- @param deveco_home string
--- @return string|nil
local function read_version(deveco_home)
    local content = io_mod.read_file(deveco_home .. "/product-info.json")
    if not content then return nil end
    local ok, data = pcall(vim.json.decode, content)
    if ok and data and data.version then
        return data.version
    end
    -- Fallback: check SDK version
    content = io_mod.read_file(deveco_home .. "/sdk/default/openharmony/oh-uni-package.json")
    if not content then return nil end
    ok, data = pcall(vim.json.decode, content)
    if ok and data and data.version then
        return data.version
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Provider interface
-- ---------------------------------------------------------------------------

--- Detect all DevEco Studio installations.
--- @return { path: string, version: string|nil }[]
function P.detect_all()
    local results = {}
    local seen = {}

    local function try_add(path)
        if not path or seen[path:lower()] then return end
        -- Resolve to actual on-disk case
        local real = uv.fs_realpath(path)
        if real then path = vim.fs.normalize(real) end
        local key = path:lower()
        if seen[key] then return end
        seen[key] = true

        if P.validate(path) then
            results[#results + 1] = {
                path = path,
                version = read_version(path),
            }
        end
    end

    -- 1. Environment variable
    local env = os.getenv("DEVECO_HOME")
    if env and env ~= "" then try_add(env:gsub("[/\\]+$", "")) end

    -- 2. DevEco .home marker files in %LOCALAPPDATA%/Huawei/DevEcoStudio*/
    local local_app_data = os.getenv("LOCALAPPDATA")
    if local_app_data then
        local huawei_dir = local_app_data .. "/Huawei"
        local handle = uv.fs_scandir(huawei_dir)
        if handle then
            while true do
                local name, ftype = uv.fs_scandir_next(handle)
                if not name then break end
                if (ftype == "directory" or ftype == nil)
                    and name:match("^DevEcoStudio") then
                    local home_file = huawei_dir .. "/" .. name .. "/.home"
                    local content = io_mod.read_file(home_file)
                    if content then
                        local home = content:match("^%s*(.-)%s*$"):gsub("\\", "/")
                        if home ~= "" then try_add(home) end
                    end
                end
            end
        end
    end

    -- 3. Default path
    try_add("C:/Program Files/Huawei/DevEco Studio")

    return results
end

--- Validate a path as a DevEco Studio installation.
--- @param path string
--- @return table|nil { version: string|nil } if valid
function P.validate(path)
    if not path or not uv.fs_stat(path) then return nil end
    -- Must have hvigor tools and node
    local hvigorw = path .. "/tools/hvigor/bin/hvigorw.js"
    local node = resolve_tool(path .. "/tools/node/node", exe_exts)
    if not uv.fs_stat(hvigorw) or not node then return nil end
    return { version = read_version(path) }
end

--- Check if a detected version satisfies a version constraint.
--- @param constraint { version?: string, min_version?: string }
--- @param detected_version string
--- @return boolean
function P.match_version(constraint, detected_version)
    if not constraint then return true end
    if not detected_version then return true end

    if constraint.version then
        -- Exact match
        return detected_version == constraint.version
    end

    if constraint.min_version then
        -- Simple string comparison works for semver-like versions
        return detected_version >= constraint.min_version
    end

    return true
end

--- Create an SDK domain object from a validated installation.
--- @param key string SDK identity key
--- @param path string installation path
--- @param version string|nil
--- @return loomworks.SDK
function P.create_sdk(key, path, version)
    return SDK.new({
        key = key,
        type = P.id,
        version = version,
        path = path,
        resolved = true,
        provider = P,
    })
end

--- Query capabilities for a specific module.
--- Returns opaque data that only the module interprets.
--- @param sdk loomworks.SDK
--- @param module_id string|nil nil returns all capability keys
--- @return table|nil
function P.query_capabilities(sdk, module_id)
    local path = sdk:sdk_path()
    if not path then return nil end

    if module_id == nil then
        -- Return list of supported module IDs
        return { "cmake", "harmony" }
    end

    if module_id == "harmony" then
        return {
            deveco_home = path,
            node = resolve_tool(path .. "/tools/node/node", exe_exts),
            hvigorw_js = path .. "/tools/hvigor/bin/hvigorw.js",
            ohpm = resolve_tool(path .. "/tools/ohpm/bin/ohpm", script_exts),
            hdc = resolve_tool(path .. "/sdk/default/openharmony/toolchains/hdc", exe_exts),
            java = resolve_tool(path .. "/jbr/bin/java", exe_exts),
        }
    end

    if module_id == "cmake" then
        local native = path .. "/sdk/default/openharmony/native"
        local toolchain = native .. "/build/cmake/ohos.toolchain.cmake"
        if not uv.fs_stat(toolchain) then return nil end
        return {
            toolchain_file = toolchain,
            cmake_path = resolve_tool(native .. "/build-tools/cmake/bin/cmake", exe_exts),
            archs = { "arm64-v8a", "armeabi-v7a" },
            arch_args = {
                ["arm64-v8a"] = { "-DOHOS_ARCH=arm64-v8a" },
                ["armeabi-v7a"] = { "-DOHOS_ARCH=armeabi-v7a" },
            },
            sdk_display = P.display_name .. " " .. (sdk:sdk_version() or ""),
        }
    end

    return nil
end

return P

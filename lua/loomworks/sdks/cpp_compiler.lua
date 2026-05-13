--- loomworks/sdks/cpp_compiler.lua — User-declared C/C++ compiler
--- SDK provider.
---
--- Lets the user pin a specific compiler installation (typically a
--- cross-compiler or a custom build) to a profile. Unlike the ohos
--- provider, there is no auto-detection — the user must explicitly
--- declare the path. We treat the compiler binary as the SDK's
--- "installation path"; everything else (family, version, sibling
--- clangd, C-driver counterpart) is derived by
--- `loomworks.cpp_compilers.probe_path`.
---
--- The SDK key includes the compiler family, version, and a
--- path-derived token so multiple custom builds at different
--- paths but the same version don't collide.
---
--- Capabilities for the cmake module produce a single kit (no
--- platforms × archs cross product). See `cmake.kits_from_sdk` for
--- the consumer side.

local SDK = require("loomworks.sdk")
local cpp_compilers = require("loomworks.cpp_compilers")

local P = {}
P.id = "cpp_compiler"
P.display_name = "C/C++ Compiler"
P.path_prompt = "Path to C/C++ compiler executable"

local uv = vim.uv or vim.loop

--- No auto-detection — user-declared compilers are always added
--- manually via the SDK section's "browse for path" entry. Returning
--- an empty list keeps the UI clean (no detected installations
--- block, just the browse row).
--- @return { path: string, version: string|nil }[]
function P.detect_all()
    return {}
end

--- Validate that the given path is a working C/C++ compiler. Delegates
--- to `cpp_compilers.probe_path` for the actual identification; we
--- just shape the result into the validate contract (a table with
--- `version` plus any extra fields the workspace key derivation
--- might use).
--- @param path string
--- @return table|nil { version, family, basename_token } when valid
function P.validate(path)
    if not path or path == "" then return nil end
    local info = cpp_compilers.probe_path(path)
    if not info then return nil end
    -- A short path-derived token lets `derive_key` produce stable
    -- distinct ids for two custom clang builds of the same version
    -- living in different directories. Uses the parent-directory
    -- basename when meaningful (e.g. "/opt/harmony-clang/bin/clang++"
    -- → "harmony-clang"), otherwise the compiler basename.
    local parent = path:match("^(.+)[/\\][^/\\]+[/\\][^/\\]+$")
    local token = parent and parent:match("[^/\\]+$") or nil
    if not token or token == "" then
        token = path:match("[^/\\]+$") or "compiler"
    end
    -- Sanitize: lowercase, replace non-alphanum with `-`.
    token = token:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if token == "" then token = "compiler" end
    return {
        version = info.version,
        family = info.family,
        basename_token = token,
    }
end

--- Version-constraint matching. Compiler SDKs don't currently
--- participate in version constraints from loomworks.json (the SDK
--- key already pins exactly), so we accept anything that has the
--- right type — matches the ohos provider's behaviour for
--- unconstrained queries.
--- @return boolean
function P.match_version()
    return true
end

--- Derive the SDK key. Overrides the workspace's default
--- `<type>-<version>` shape because two custom compilers of the same
--- family and version at different paths must produce distinct keys
--- (the profile pins by key, so collisions would conflate them).
---
--- Result: `cpp_compiler-<family>-<version>-<path_token>`
---   e.g. `cpp_compiler-clang-19.0.0-harmony-clang`
---
--- When validate didn't yield a family (unknown compiler), uses
--- `cpp` in its place so the shape stays parseable.
--- @param info table the table validate returned
--- @return string
function P.derive_key(info)
    local family = info.family or "cpp"
    local version = info.version or "unknown"
    local token = info.basename_token or "custom"
    return P.id .. "-" .. family .. "-" .. version .. "-" .. token
end

--- Create the SDK domain object.
--- @param key string
--- @param path string compiler executable path
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

--- Query capabilities for a specific module. cmake is the only
--- consumer right now (it knows how to take a single compiler and
--- generate a Ninja kit).
---
--- We re-probe at query time rather than caching on the SDK so a
--- compiler upgrade in-place (same path, new version) doesn't keep
--- the stale version. `probe_path` is fast (one `--version` exec).
--- @param sdk loomworks.SDK
--- @param module_id string|nil nil returns the list of supported modules
--- @return table|nil
function P.query_capabilities(sdk, module_id)
    if module_id == nil then return { "cmake" } end
    if module_id ~= "cmake" then return nil end

    local path = sdk:sdk_path()
    if not path then return nil end

    local info = cpp_compilers.probe_path(path)
    if not info then return nil end

    return {
        -- Single-kit shape (no platforms[] / archs[]): cmake's
        -- kits_from_sdk has a dedicated branch for this caps shape.
        compiler_path = info.path,
        cc_path = info.c_path,
        clangd_path = info.clangd_path,
        compiler_id = info.family,
        compiler_version = info.version,
        bin_dir = info.bin_dir,
        generator = "Ninja",
    }
end

--- Display name for the SDK row. Includes the family and version
--- when known so the user can tell two custom compilers apart at a
--- glance. The path also appears separately in the SDK section.
--- @param sdk loomworks.SDK
--- @return string
function P.display_name_for(sdk)
    local info = cpp_compilers.probe_path(sdk:sdk_path() or "")
    if info then
        local family = info.family == "gcc" and "GCC"
            or info.family == "clang" and "Clang"
            or "C++"
        return family .. " " .. info.version .. " (custom)"
    end
    return "C/C++ Compiler (custom)"
end

return P

--- loomworks/reserved_compiler.lua — Reserved compiler-selection keys.
---
--- The profile's TOOL (kit) is the single source of truth for the C/C++
--- compiler: its identity keys build directories and selects the clangd
--- binary. A project configuration therefore may not select a compiler
--- through its own `options` (CMake cache vars) or `env` (driver vars).
--- These keys are rejected at config-edit time and defensively stripped at
--- task-build time. Defined once here and shared by the cmake/meson modules
--- and the configuration mutation path. Mirrors the reserved-name pattern in
--- `variables.lua`. See specification.md §15 (invariant "The tool owns the
--- compiler") and spec/modules/cmake.md §5b.

local M = {}

--- CMake cache option keys reserved as compiler selectors: any
--- `CMAKE_<LANG>_COMPILER` (C, CXX, Fortran, CUDA, …). The trailing
--- `_COMPILER$` anchor deliberately EXCLUDES neighbours that merely start
--- the same way — `CMAKE_<LANG>_COMPILER_LAUNCHER`, `..._COMPILER_ID`,
--- `..._COMPILER_TARGET`, `..._COMPILER_WORKS` — none of which end in
--- `_COMPILER`. Compiler flags (`CFLAGS`/`CXXFLAGS`/…) never match.
M.OPTION_PATTERN = "^CMAKE_.+_COMPILER$"

--- Compiler-driver environment variables reserved for the tool. Exactly the
--- driver vars — NOT the `*FLAGS` (CFLAGS/CXXFLAGS/LDFLAGS stay allowed) and
--- NOT compiler launchers. Keys are upper-case; `is_reserved_env` matches a
--- name case-insensitively.
M.ENV_NAMES = {
    CC = true,
    CXX = true,
    FC = true,
    CUDACXX = true,
    CUDAHOSTCXX = true,
    OBJC = true,
    OBJCXX = true,
    ISPC = true,
}

--- @param key any CMake cache option key
--- @return boolean
function M.is_reserved_option(key)
    return type(key) == "string" and key:match(M.OPTION_PATTERN) ~= nil
end

--- Whether `name` is a reserved compiler-driver variable. Matched
--- CASE-INSENSITIVELY on every host: Windows environment names are
--- case-insensitive (`cc` IS `CC` there), and a configuration file is shared
--- across hosts, so a name that selects the compiler on one host is refused
--- everywhere rather than silently overriding the tool's compiler on Windows
--- only. (A lower-case `cc` has no legitimate distinct meaning on POSIX
--- build tools either.)
--- @param name any environment variable name
--- @return boolean
function M.is_reserved_env(name)
    return type(name) == "string" and M.ENV_NAMES[name:upper()] == true
end

--- Whether `name` is the executable search path variable (`PATH`, any case).
--- Not reserved — a configuration may set it — but setting it REPLACES the
--- PATH the tool establishes (e.g. the MSVC developer environment), so the
--- CLI warns at set time and `config_env.resolve` warns once at runtime.
--- @param name any environment variable name
--- @return boolean
function M.is_path_env(name)
    return type(name) == "string" and name:upper() == "PATH"
end

return M

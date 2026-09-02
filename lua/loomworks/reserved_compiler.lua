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
--- NOT compiler launchers.
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

--- @param name any environment variable name
--- @return boolean
function M.is_reserved_env(name)
    return type(name) == "string" and M.ENV_NAMES[name] == true
end

return M

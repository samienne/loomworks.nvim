--- loomworks/paths.lua — small path helpers shared across launch, debug, and
--- deploy resolution.

local M = {}

--- Is `p` an absolute path? Recognizes POSIX roots (`/…`) and Windows drive
--- roots (`C:\…` / `C:/…`).
--- @param p string
--- @return boolean
function M.is_absolute(p)
    return p:match("^%a:[/\\]") ~= nil or p:sub(1, 1) == "/"
end

--- Join a build directory with a target artifact path.
---
--- The module file-API contract is that `artifact` is RELATIVE to the build
--- dir (see loomworks.Target.artifact) — the normal case, and what cmake's
--- parse_targets normalizes to. This join guard is a safety net for the
--- documented exception: cmake's file-API legitimately emits an ABSOLUTE
--- artifact path when the output lives outside the top-level build directory
--- (e.g. a target with RUNTIME_OUTPUT_DIRECTORY pointing elsewhere). Prepending
--- build_dir to such a path would double it (`C:/b/C:/out/app.exe`), so an
--- already-absolute artifact is returned unchanged.
--- @param build_dir string
--- @param artifact string relative-to-build-dir (normal) or absolute (guarded)
--- @return string
function M.artifact_path(build_dir, artifact)
    if M.is_absolute(artifact) then
        return artifact
    end
    return build_dir .. "/" .. artifact
end

return M

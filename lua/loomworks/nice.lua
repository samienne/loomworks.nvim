--- loomworks/nice.lua — Linux nice/ionice wrapper for build commands.
---
--- Keeps the editor and OS responsive when long-running builds and
--- tests hog the box. Wraps a cmd array so the child runs at a lower
--- OS scheduler priority (CPU and I/O) without us having to touch the
--- syscall layer.
---
--- Only applies on Linux. Windows lacks a clean CLI-level equivalent
--- (`start /belownormal` detaches; `wmic ... setpriority` races) and
--- macOS lacks `ionice`, so we no-op there. The wrap is a strict
--- prefix — original cmd args appear unchanged after the prefix.

local M = {}

--- Cached result of `nice` + `ionice` discovery, so we don't probe
--- `vim.fn.executable` on every task launch. `nil` until first call,
--- then `true`/`false` for the rest of the session.
--- @type boolean|nil
local _supported

--- Are both `nice` and `ionice` available on this system?
--- Linux-only; false on Windows/macOS even if `nice` happens to exist
--- (ionice is the Linux-specific half).
--- @return boolean
local function supported()
    if _supported ~= nil then return _supported end
    if vim.fn.has("linux") ~= 1 then
        _supported = false
        return false
    end
    _supported = vim.fn.executable("nice") == 1
        and vim.fn.executable("ionice") == 1
    return _supported
end

--- Wrap a cmd array with `ionice -c 3 nice -n 10` so the spawned
--- process runs under idle I/O and reduced CPU priority. Returns the
--- cmd unchanged on unsupported platforms or when the wrapper binaries
--- are missing — callers don't need to branch.
---
--- Levels are hardcoded for now:
---   - `nice -n 10`: mild CPU step-down. Not idle (-n 19) because
---     idle-class nice can stall single-job builds noticeably; 10 keeps
---     builds making steady progress while clearly yielding to the
---     editor and clangd.
---   - `ionice -c 3`: idle I/O class. Strongest editor responsiveness
---     win; the small build slowdown on contested disks is the trade
---     we explicitly chose.
---
--- @param cmd string[]
--- @return string[]
function M.wrap_cmd(cmd)
    if not supported() then return cmd end
    return vim.list_extend(
        { "ionice", "-c", "3", "nice", "-n", "10" },
        cmd
    )
end

--- Whether the wrapper is active on this system. Exposed for status /
--- debug output and tests.
--- @return boolean
function M.is_active()
    return supported()
end

--- Test hook: reset the cached discovery result so tests can flip the
--- platform/executable state and re-probe. Not part of the public API.
function M._reset_cache()
    _supported = nil
end

return M

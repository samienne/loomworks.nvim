--- loomworks/provision/sha256.lua — SHA-256 of binary data, for the host
--- binaries the plugin downloads (spec §19.16 "Host binary", step 5h.3).
---
--- `vim.fn.sha256` hashes a Lua string holding NUL and high bytes correctly
--- on the Neovim versions tested (0.12: such a string reaches Vimscript as a
--- Blob, which `sha256()` accepts). That conversion is not a documented
--- guarantee on every supported version (>= 0.9), so it is used only after a
--- known-answer check passes in this process; otherwise a pure-Lua
--- implementation (loomworks.sha256, vendored from loomworks) is used.
--- Both run on the main loop only (`vim.fn` is not callable in a fast event).

local char = string.char

local M = {}

--- The pure-Lua SHA-256 of `s`, lowercase hex.
M.lua = require("loomworks.sha256").lua

--- A string with NUL and high bytes, and its SHA-256 (the known answer the
--- native check compares against).
M.PROBE = "a\0b\0\0c" .. char(255, 0, 10, 13)
M.PROBE_SHA256 = "d113d7d8ccf053e2cc4e48dcbb08ecb67cc0f1b46071cfd728b3b79a3f4268a9"

local native_ok

--- Whether `vim.fn.sha256` hashes binary strings faithfully here (checked
--- once per process against `PROBE`).
--- @return boolean
function M.native_ok()
    if native_ok == nil then
        local ok, r = pcall(function() return vim.fn.sha256(M.PROBE) end)
        native_ok = ok and r == M.PROBE_SHA256
    end
    return native_ok
end

--- The SHA-256 of `s`, lowercase hex: `vim.fn.sha256` when it passed the
--- check, else the pure-Lua one.
--- @param s string
--- @return string
function M.hex(s)
    if M.native_ok() then return vim.fn.sha256(s) end
    return M.lua(s)
end

--- The SHA-256 of the file at `path`, or nil + why.
--- @param path string
--- @return string|nil sha256, string|nil err
function M.file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, "cannot read " .. path .. ": " .. tostring(err) end
    local data = f:read("*a")
    f:close()
    if not data then return nil, "cannot read " .. path end
    return M.hex(data)
end

return M

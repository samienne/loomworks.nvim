--- loomworks/lsp_server_cmd.lua — resolve a language server's program before
--- the editor spawns it (the LSP integrations, integrations/lsp/*).
---
--- `vim.lsp.rpc.start` spawns through libuv, which on Windows tries the
--- current directory (the workspace, maybe a cloned repository) before PATH
--- for a BARE program name; anywhere, a relative or empty PATH entry means
--- "the current directory". So a bare name (the default `clangd`, `qmlls`) is
--- looked up in the ABSOLUTE PATH entries only (the server's env first, else
--- the editor's), with PATHEXT on Windows. A configured value with a path
--- separator is the user's explicit choice and is left as is.

local M = {}

M.is_windows = package.config:sub(1, 1) == "\\"

local uv = vim.uv or vim.loop

--- @param p any
--- @return boolean
local function is_absolute(p)
    if type(p) ~= "string" or p == "" then return false end
    if M.is_windows then
        return p:match("^%a:[/\\]") ~= nil or p:match("^[/\\][/\\][^/\\]") ~= nil
    end
    return p:sub(1, 1) == "/"
end

--- `name` from the server's env (case-insensitively on Windows), else the
--- editor's environment.
--- @param name string
--- @param env? table<string,string>
--- @return string|nil
local function getenv(name, env)
    if type(env) == "table" then
        if env[name] ~= nil then return tostring(env[name]) end
        if M.is_windows then
            local lname = name:lower()
            for k, v in pairs(env) do
                if type(k) == "string" and k:lower() == lname then return tostring(v) end
            end
        end
    end
    local v = uv.os_getenv(name)
    if v ~= nil and v ~= "" then return v end
    return nil
end

--- @param p string
--- @return boolean
local function is_executable(p)
    local st = uv.fs_stat(p)
    if not st or st.type ~= "file" then return false end
    if M.is_windows then return true end
    local ok, res = pcall(uv.fs_access, p, "X")
    return not ok or res == true
end

--- The absolute path of a bare program name, or nil + err.
--- @param name string
--- @param env? table<string,string>
--- @return string|nil path, string|nil err
function M.resolve(name, env)
    local exts = { "" }
    if M.is_windows then
        exts = {}
        if name:match("%.[^./\\]+$") then exts[1] = "" end
        for e in (getenv("PATHEXT", env) or ".COM;.EXE;.BAT;.CMD"):gmatch("[^;]+") do
            if e:sub(1, 1) == "." then exts[#exts + 1] = e:lower() end
        end
    end
    local sep = M.is_windows and ";" or ":"
    for entry in ((getenv("PATH", env) or "") .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do
        entry = entry:gsub('^"(.*)"$', "%1")
        if is_absolute(entry) then
            local base = entry:gsub("[/\\]+$", "")
            for _, ext in ipairs(exts) do
                local p = base .. "/" .. name .. ext
                if is_executable(p) then return M.is_windows and (p:gsub("/", "\\")) or p end
            end
        end
    end
    return nil, name .. " not found on PATH"
end

--- Resolve argv[1] of a language-server command in place when it is a bare
--- name. Raises a clear error when it is not on PATH (`vim.lsp.rpc.start`
--- would fail on it anyway).
--- @param args string[]
--- @param env? table<string,string>
--- @param who string label for the error ("loomworks.clangd")
--- @return string[] args
function M.resolve_cmd(args, env, who)
    local name = args[1]
    if type(name) == "string" and name ~= "" and not name:find("[/\\]") then
        local p, err = M.resolve(name, env)
        if not p then error(who .. ": " .. tostring(err), 0) end
        args[1] = p
    end
    return args
end

return M

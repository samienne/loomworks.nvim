--- loomworks/exe.lua — resolve a program name to an absolute path before
--- spawning it (editor and standalone host alike).
---
--- Spawning a BARE program name lets the OS / libuv pick the file. On Windows
--- libuv's search (behind `vim.system` / `uv.spawn`) tries the current
--- directory before PATH unless `NoDefaultCurrentDirectoryInExePath` is set in
--- the spawning process, and cmd.exe does the same for commands it runs;
--- anywhere, a relative or empty PATH entry means "the current directory". With
--- the working directory inside a cloned repository, a bare `cmake` / `git` /
--- `npm` could run a file the repository ships. So every spawn of a bare name
--- goes through `M.resolve`, which returns an ABSOLUTE path found in an
--- absolute PATH entry only (never the cwd, never an empty/relative entry),
--- honoring PATHEXT on Windows — or fails with "<name> not found on PATH".
---
--- `cmd` / `cmd.exe` always resolves to `%SystemRoot%\System32\cmd.exe`.
---
--- The host bootstrap has its own copy of the resolution rule
--- (`lua/boot/exe.lua`): boot modules cannot depend on the bundle.

local M = {}

M.is_windows = package.config:sub(1, 1) == "\\"

--- Environment variable forcing Windows (libuv's search, cmd.exe) to skip the
--- current directory when resolving a bare program name.
M.NO_CWD_ENV = "NoDefaultCurrentDirectoryInExePath"

local function uv()
    local v = rawget(_G, "vim")
    return (v and (v.uv or v.loop)) or require("uv")
end

--- Is `p` an absolute path? Windows: drive-rooted (`C:\`, `C:/`) or UNC
--- (`\\server\share`); a bare `\foo` is relative to the current drive.
--- @param p any
--- @return boolean
function M.is_absolute(p)
    if type(p) ~= "string" or p == "" then return false end
    if M.is_windows then
        return p:match("^%a:[/\\]") ~= nil or p:match("^[/\\][/\\][^/\\]") ~= nil
    end
    return p:sub(1, 1) == "/"
end

--- Read `name` from the (optional) task env dict first — case-insensitively on
--- Windows — then from the process environment.
--- @param name string
--- @param env? table<string,string>
--- @return string|nil
function M.getenv(name, env)
    if type(env) == "table" then
        if env[name] ~= nil then return tostring(env[name]) end
        if M.is_windows then
            local lname = name:lower()
            for k, v in pairs(env) do
                if type(k) == "string" and k:lower() == lname then return tostring(v) end
            end
        end
    end
    local u = uv()
    if u.os_getenv then
        local ok, v = pcall(u.os_getenv, name)
        if ok and v ~= nil and v ~= "" then return v end
    end
    local v = os.getenv(name)
    if v ~= nil and v ~= "" then return v end
    return nil
end

--- The absolute directories of PATH (task env first, else the process env), in
--- order. Empty, relative (`.`, `bin`) and — on Windows — drive-relative
--- entries are dropped: each would mean "relative to the current directory".
--- Surrounding double quotes (legal in a Windows PATH entry) are removed.
--- @param env? table<string,string>
--- @return string[]
function M.path_entries(env)
    local sep = M.is_windows and ";" or ":"
    local out = {}
    for entry in ((M.getenv("PATH", env) or "") .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do
        entry = entry:gsub('^"(.*)"$', "%1")
        if M.is_absolute(entry) then out[#out + 1] = entry end
    end
    return out
end

--- PATHEXT extensions (lower-case, with the dot). Windows only.
--- @param env? table<string,string>
--- @return string[]
function M.pathext(env)
    local exts = {}
    for e in (M.getenv("PATHEXT", env) or ".COM;.EXE;.BAT;.CMD"):gmatch("[^;]+") do
        if e:sub(1, 1) == "." then exts[#exts + 1] = e:lower() end
    end
    return exts
end

local function is_file(p)
    local st = uv().fs_stat(p)
    return st ~= nil and st.type == "file"
end

local function is_executable(p)
    if not is_file(p) then return false end
    if M.is_windows then return true end
    local u = uv()
    if u.fs_access then
        local ok, res = pcall(u.fs_access, p, "X")
        if ok then return res == true end
    end
    return true
end

local function native(p)
    if M.is_windows then return (p:gsub("/", "\\")) end
    return p
end

--- `%SystemRoot%\System32\cmd.exe` (an absolute `ComSpec` under SystemRoot is
--- accepted as a fallback), or nil + err. Never a bare `cmd`.
--- @param env? table<string,string>
--- @return string|nil path, string|nil err
function M.cmd_exe(env)
    local sr = M.getenv("SystemRoot", env) or M.getenv("windir", env)
    if sr and M.is_absolute(sr) then
        local cand = native(sr:gsub("[/\\]+$", "") .. "\\System32\\cmd.exe")
        if is_file(cand) then return cand end
        local cs = M.getenv("ComSpec", env)
        if cs and M.is_absolute(cs) then
            local lsr = native(sr:gsub("[/\\]+$", "")):lower() .. "\\"
            local ncs = native(cs)
            if ncs:lower():sub(1, #lsr) == lsr and is_file(ncs) then return ncs end
        end
    end
    return nil, "cmd.exe not found under %SystemRoot%"
end

--- Resolve a program name to an absolute path.
---
--- * `name` containing a path separator is an explicit path: absolute as is,
---   or — only when the caller names the child's working directory `cwd`
---   (absolute) — relative to that directory, exactly as the spawn would
---   interpret it (e.g. a shell-module step `./build.sh` run in its project
---   dir). Without such a `cwd` a relative path is refused. It is returned when
---   the file exists (on Windows also trying PATHEXT extensions when it has
---   none).
--- * A bare name is looked up in the absolute PATH entries only (`env.PATH`
---   when given, else the process PATH), with PATHEXT on Windows — never in
---   the current directory or `cwd`.
--- @param name string
--- @param env? table<string,string> task environment (its PATH/PATHEXT win)
--- @param cwd? string the child's working directory (for an explicit relative path)
--- @return string|nil path, string|nil err
function M.resolve(name, env, cwd)
    if type(name) ~= "string" or name == "" then
        return nil, "empty command"
    end
    local has_ext = name:match("%.[^./\\]+$") ~= nil
    local exts = { "" }
    if M.is_windows then
        exts = {}
        if has_ext then exts[1] = "" end
        for _, e in ipairs(M.pathext(env)) do exts[#exts + 1] = e end
    end
    if name:find("[/\\]") then
        if not M.is_absolute(name) then
            if not M.is_absolute(cwd) then
                return nil, "relative program path '" .. name ..
                    "' is not allowed here (use an absolute path)"
            end
            name = cwd:gsub("[/\\]+$", "") .. "/" .. name:gsub("^%.[/\\]", "")
        end
        for _, ext in ipairs(exts) do
            if is_executable(name .. ext) then return native(name .. ext) end
        end
        return nil, name .. " does not exist"
    end
    if M.is_windows then
        local l = name:lower()
        if l == "cmd" or l == "cmd.exe" then return M.cmd_exe(env) end
    end
    for _, dir in ipairs(M.path_entries(env)) do
        local base = dir:gsub("[/\\]+$", "")
        for _, ext in ipairs(exts) do
            local p = base .. "/" .. name .. ext
            if is_executable(p) then return native(p) end
        end
    end
    return nil, name .. " not found on PATH"
end

--- `vim.fn.exepath` equivalent built on `M.resolve`: the absolute path, or "".
--- @param name string
--- @param env? table<string,string>
--- @return string
function M.exepath(name, env)
    return M.resolve(name, env) or ""
end

--- `vim.fn.exepath(name)`, minus current-directory hits. Neovim before 0.12
--- searches the current directory first on Windows (and any Neovim follows a
--- relative PATH entry); a result that is not absolute, or that lies directly
--- in the current directory when that directory is not itself an absolute PATH
--- entry, is replaced by `M.exepath(name)` (absolute PATH entries only). An
--- empty result stays empty. Keeps `vim.fn.exepath` as the primary source so
--- existing callers (and their tests) see the same answers otherwise.
--- @param name string
--- @return string
function M.editor_exepath(name)
    local p = vim.fn.exepath(name)
    if p == nil or p == "" then return "" end
    local function norm(x)
        x = tostring(x):gsub("\\", "/"):gsub("/+$", "")
        return M.is_windows and x:lower() or x
    end
    -- Rooted (drive, UNC or leading slash): Neovim itself only reports rooted
    -- paths, so only a genuinely relative answer is suspect here.
    if M.is_absolute(p) or p:match("^[/\\]") then
        local dir = norm(p:match("^(.*)[/\\][^/\\]*$") or "")
        if dir ~= norm(uv().cwd() or "") then return p end
        for _, e in ipairs(M.path_entries()) do
            if norm(e) == dir then return p end
        end
    end
    return M.exepath(name)
end

--- Resolve argv[1] of a language-server command in place when it is a BARE
--- name (e.g. the default `clangd`), so `vim.lsp.rpc.start` never lets libuv
--- search the current directory for it. A value with a path separator (a
--- configured binary) is left as is. Raises a clear error when a bare name is
--- not on PATH — `vim.lsp.rpc.start` would fail on it anyway.
--- @param args string[]
--- @param env? table<string,string>
--- @param who string label for the error ("loomworks.clangd")
--- @return string[] args
function M.resolve_server_cmd(args, env, who)
    local name = args[1]
    if type(name) == "string" and name ~= "" and not name:find("[/\\]") then
        local p, err = M.resolve(name, env)
        if not p then error(who .. ": " .. tostring(err), 0) end
        args[1] = p
    end
    return args
end

--- A copy of argv with argv[1] resolved (see `M.resolve`; `cwd` = the child's
--- working directory, for an explicit relative path), or nil + err.
--- @param cmd string[]
--- @param env? table<string,string>
--- @return string[]|nil argv, string|nil err
function M.argv(cmd, env, cwd)
    if type(cmd) ~= "table" or type(cmd[1]) ~= "string" then
        return nil, "no command"
    end
    local exe, err = M.resolve(cmd[1], env, cwd)
    if not exe then return nil, err end
    local out = { exe }
    for i = 2, #cmd do out[i] = cmd[i] end
    return out
end

--- Add `NoDefaultCurrentDirectoryInExePath=1` to a task env on Windows (so a
--- cmd.exe / .bat the task runs never searches its cwd for a bare command).
--- Returns the (possibly new) env table; unchanged elsewhere.
--- @param env? table<string,string>
--- @return table<string,string>|nil
function M.with_no_cwd_env(env)
    if not M.is_windows then return env end
    local out = {}
    for k, v in pairs(env or {}) do out[k] = v end
    out[M.NO_CWD_ENV] = "1"
    return out
end

--- Harden a task spec `{ cmd, cwd?, env? }` in place before it is spawned:
--- resolve `cmd[1]` against the task's own PATH (falling back to the process
--- PATH) and, on Windows, add `NoDefaultCurrentDirectoryInExePath=1` to its
--- env. Returns the spec, or nil + err when the program cannot be resolved —
--- the caller must then NOT spawn it.
--- @param spec table
--- @return table|nil spec, string|nil err
function M.harden_spec(spec)
    if type(spec) ~= "table" or type(spec.cmd) ~= "table" then
        return nil, "no command"
    end
    local env = type(spec.env) == "table" and spec.env or nil
    local argv, err = M.argv(spec.cmd, env, type(spec.cwd) == "string" and spec.cwd or nil)
    if not argv then return nil, err end
    spec.cmd = argv
    if M.is_windows then spec.env = M.with_no_cwd_env(env) end
    return spec
end

--- `vim.system` over a resolved argv. When argv[1] cannot be resolved nothing
--- is spawned: the result is `{ code = 127, stdout = "", stderr = err }`,
--- delivered to `on_exit` (scheduled) and returned by `:wait()` — the same
--- shape the standalone shim reports for a failed spawn.
--- @param cmd string[]
--- @param opts? table vim.system options (its `env.PATH` is used to resolve)
--- @param on_exit? fun(res: table)
--- @return table handle with `wait()` (and `pid`/`kill` when spawned)
function M.system(cmd, opts, on_exit)
    local env = opts and type(opts.env) == "table" and opts.env or nil
    local argv, err = M.argv(cmd, env, opts and opts.cwd or nil)
    if argv then return vim.system(argv, opts, on_exit) end
    local res = { code = 127, signal = 0, stdout = "", stderr = tostring(err) }
    if on_exit then vim.schedule(function() on_exit(res) end) end
    return {
        wait = function() return res end,
        kill = function() end,
        is_closing = function() return true end,
    }
end

return M

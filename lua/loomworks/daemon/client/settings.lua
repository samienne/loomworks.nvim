--- loomworks/daemon/client/settings.lua — the editor's settings for the
--- `--stdio` relay it spawns (spec §19.16 "The relay process"): its
--- timings, the directory it runs in and its environment.

local uv = vim.uv or vim.loop

local M = {}

local function env_ms(name)
    local v = tonumber(os.getenv(name) or "")
    return (v and v > 0) and v or nil
end

local function is_win() return package.config:sub(1, 1) == "\\" end

--- How long after closing a relay's standard input the editor waits before
--- it kills the relay's own process (spec §19.16: about 5 s).
M.KILL_MS = env_ms("LW_TEST_RELAY_KILL_MS") or 5000
--- How long, once the relay exited, its remaining pipe EOFs are waited for
--- before the outcome is reported anyway (the daemon never holds them).
M.EOF_GRACE_MS = 1000
--- How long, once a relay's standard output reached EOF before `welcome`,
--- its exit is waited for (spec §19.16: about 5 s).
M.EXIT_WAIT_MS = env_ms("LW_TEST_RELAY_EXIT_WAIT_MS") or 5000
--- How many standard-error lines are kept.
M.STDERR_LINES = 50

--- The per-user data directory `lw` shares (spec §17.2): LOOMWORKS_DATA_DIR,
--- else the platform's per-user data location.
--- @return string
function M.data_dir()
    local env = function(n) local v = os.getenv(n); return (v and v ~= "") and v or nil end
    local o = env("LOOMWORKS_DATA_DIR")
    if o then return (o:gsub("\\", "/"):gsub("/+$", "")) end
    if is_win() and env("LOCALAPPDATA") then
        return (env("LOCALAPPDATA"):gsub("\\", "/")) .. "/loomworks"
    end
    if env("XDG_DATA_HOME") then return (env("XDG_DATA_HOME"):gsub("\\", "/")) .. "/loomworks" end
    return ((env("HOME") or env("USERPROFILE") or "."):gsub("\\", "/")) .. "/.local/share/loomworks"
end

--- The directory a relay runs in: the runtime's per-user state directory,
--- so no relay holds the workspace (or the editor's cwd) open.
--- @return string
function M.state_dir()
    return M.data_dir() .. "/daemon"
end

--- A relay's environment as a "K=V" list: this process's without the names
--- in `unset` (the managed lw's: loomworks.provision.select.child_unset), with
--- `LW_ROOT` and then `extra` set last.
--- @param root string
--- @param extra? table<string, string>
--- @param unset? string[]
--- @return string[]
function M.env(root, extra, unset)
    local out, by_key = {}, {}
    for k, v in pairs(uv.os_environ()) do
        local key = is_win() and k:upper() or k
        local cur = by_key[key]
        if not cur then
            by_key[key] = { k, v }
        elseif is_win() and uv.os_getenv(k) == v and uv.os_getenv(cur[1]) ~= cur[2] then
            -- Two spellings of one variable (Path / PATH): keep the one this
            -- process resolves.
            by_key[key] = { k, v }
        end
    end
    local function set(k, v) by_key[is_win() and k:upper() or k] = { k, v } end
    for _, k in ipairs(unset or {}) do by_key[is_win() and k:upper() or k] = nil end
    set("LW_ROOT", root)
    for k, v in pairs(extra or {}) do set(k, v) end
    for _, kv in pairs(by_key) do out[#out + 1] = kv[1] .. "=" .. kv[2] end
    table.sort(out)
    return out
end

return M

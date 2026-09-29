--- Health provider #4 — repo launcher and pin (headless §16.31).
---
--- When a version pin (lw.pin) is found — the same upward pin-root discovery
--- the redirect uses, from the workspace root or, outside a workspace, the
--- current directory — checks that lw.sh / lw.cmd / lw.pin will work for every
--- contributor and CI runner. Reports, never fixes: every remedy is a command
--- (usually the repair, `lw bootstrap install`, which keeps the pin).
---
--- The checks themselves live in boot.launcher_check, shared with the
--- `lw bootstrap` status page (spec §16.24); this module supplies the git
--- runner (loomworks.exe, both hosts, each query under a timeout without
--- optional locks) and the hash, and adds the `launcher:` prefix. On-demand and
--- report-only: never on the passive `N suggestions` path, nothing cached.

local uv = vim.uv or vim.loop

local M = {}

--- Per-query timeout (ms).
M.GIT_TIMEOUT_MS = 10000

local GIT_ENV = {
    GIT_OPTIONAL_LOCKS = "0",
    GIT_TERMINAL_PROMPT = "0",
    GCM_INTERACTIVE = "never",
    LC_ALL = "C",
}

--- Run `git -C <cwd> <args...>`; returns code, stdout. Test seam.
--- Repository-local configuration must not run commands on lw's behalf
--- (spec §17.8): no fsmonitor hook, no hooks path.
--- @return integer code, string stdout
function M._git(cwd, args)
    local exe = require("loomworks.exe")
    local git = exe.resolve("git")
    if not git then return 127, "" end
    local cmd = { git, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=", "-C", cwd }
    for _, a in ipairs(args) do cmd[#cmd + 1] = a end
    local res
    local ok = pcall(exe.system, cmd, { text = true, timeout = M.GIT_TIMEOUT_MS, env = GIT_ENV },
        function(r) res = r end)
    if not ok then return 127, "" end
    vim.wait(M.GIT_TIMEOUT_MS + 2000, function() return res ~= nil end, 10)
    if not res then return 124, "" end
    return res.code or -1, res.stdout or ""
end

--- Inspect the pin root; returns the report or nil when there is no pin. The
--- checks, wording and remedies are boot.launcher_check's — the one
--- implementation shared with the `lw bootstrap` status page (spec §16.24);
--- this adapter supplies the host's git runner + hash and adds the
--- `launcher:` prefix.
--- @param start string directory to search upward from
--- @return { root: string, version: string|nil, mode: string, items: loomworks.Suggestion[] }|nil
function M.report(start)
    local pin = require("boot.pin")
    local check = require("boot.launcher_check")
    local root = start and pin.find_pin_root(start)
    if not root then return nil end
    local assets = {}
    for _, a in pairs(pin.HOST_ASSETS) do assets[#assets + 1] = a end
    local r = check.run_checks(root, {
        git = function(cwd, args) return M._git(cwd, args) end,
        sha256 = function(s) return vim.fn.sha256(s) end,
        exists = function(path) return uv.fs_stat(path) ~= nil end,
        stale = function(rt, version)
            return require("boot.repo_meta").stale_cache(rt, version, assets, pin.valid_version)
        end,
        invoked = check.invoked(),
    })
    local items = {}
    for _, f in ipairs(r.findings) do
        items[#items + 1] = {
            kind = f.kind, title = "launcher: " .. f.title, remedy = f.remedy, detail = f.detail,
            detail_verbose = (f.kind == "info" and f.detail ~= nil) or nil,
        }
    end
    return { root = root, version = r.version, mode = r.mode, items = items }
end

--- Health provider (on-demand, report-only, pin-scoped).
--- @param workspace loomworks.Workspace|nil
--- @return loomworks.Suggestion[]
function M.provider(workspace)
    local start = (type(workspace) == "table" and type(workspace.root) == "string" and workspace.root)
        or os.getenv("LW_ROOT") or uv.cwd()
    local r = M.report(start)
    return r and r.items or {}
end

return M

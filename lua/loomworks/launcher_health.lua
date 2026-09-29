--- Health provider #4 — repo launcher and pin (headless §16.31).
---
--- When a version pin (lw.pin) is found — the same upward pin-root discovery
--- the redirect uses, from the workspace root or, outside a workspace, the
--- current directory — checks that lw.sh / lw.cmd / lw.pin will work for every
--- contributor and CI runner. Reports, never fixes: every remedy is a command
--- (usually the repair form of the pin update, `./lw.sh update --version
--- <pinned>`, which keeps the pin).
---
--- File checks are local reads; the git checks (only inside a git work tree,
--- with git available) are four local queries, each under a timeout, run
--- without optional locks. On-demand and report-only: never on the passive
--- `N suggestions` path, nothing cached.

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

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

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

local function mb(bytes) return string.format("%.1f MB", bytes / 1048576) end

local function join(list) return table.concat(list, ", ") end

--- Inspect the pin root; returns the report or nil when there is no pin.
--- @param start string directory to search upward from
--- @return { root: string, version: string|nil, items: loomworks.Suggestion[] }|nil
function M.report(start)
    local pin = require("boot.pin")
    local launcher = require("boot.launcher")
    local root = start and pin.find_pin_root(start)
    if not root then return nil end
    local items = {}
    local function nag(title, remedy, detail)
        items[#items + 1] = { kind = "suggestion", title = "launcher: " .. title, remedy = remedy,
            detail = detail }
    end
    local function info(title, detail)
        items[#items + 1] = { kind = "info", title = "launcher: " .. title, detail = detail,
            detail_verbose = detail ~= nil or nil }
    end

    -- ---- the pin --------------------------------------------------------
    local text = read(root .. "/lw.pin") or ""
    local p, perr = pin.parse(text)
    local version = p and p.version or nil
    local has_sh = uv.fs_stat(root .. "/lw.sh") ~= nil
    local function repair()
        local v = version or "<x.y.z>"
        if has_sh then
            return "run `./lw.sh update --version " .. v .. "`, which keeps the pin"
                .. " - `.\\lw.cmd update ...` from cmd/PowerShell"
        end
        return "run `lw update --version " .. v .. "`, which keeps the pin"
    end
    if not p then
        nag("lw.pin cannot be read (" .. tostring(perr) .. ")",
            "rewrite it with `lw update --version <x.y.z>` (or `lw bootstrap`) - lw help launcher")
    else
        local missing = {}
        local want = {}
        for _, a in pairs(pin.HOST_ASSETS) do want[#want + 1] = a end
        table.sort(want)
        want[#want + 1] = pin.bundle_asset(version)
        for _, a in ipairs(want) do
            if not p.hashes[a] then missing[#missing + 1] = a end
        end
        if #missing > 0 then
            nag("lw.pin has no hash for " .. join(missing) .. " - those platforms cannot run the launcher",
                repair())
        end
    end

    -- ---- the launchers ----------------------------------------------------
    local sha = function(s) return vim.fn.sha256(s) end
    for _, kind in ipairs({ "sh", "cmd" }) do
        local name = launcher.KINDS[kind]
        local bytes = read(root .. "/" .. name)
        if not bytes then
            nag(name .. " is missing", repair())
        else
            local c = launcher.classify(kind, bytes, sha)
            if c.status == "known" then
                local texts = {}
                for _, d in ipairs(c.defects) do texts[#texts + 1] = d.text end
                if c.breaks then
                    local broken = {}
                    for _, d in ipairs(c.defects) do
                        if d.severity == "breaks" then broken[#broken + 1] = d.text end
                    end
                    nag(name .. " is the launcher written by lw " .. c.releases .. ": " .. join(broken),
                        repair(), table.concat(texts, "; "))
                else
                    info(name .. " is the launcher written by lw " .. c.releases .. ", older than this lw's: "
                        .. join(texts) .. "; refresh it with " .. (repair():gsub("^run ", "")))
                end
            elseif c.status == "unknown" then
                info(name .. " differs from every launcher lw wrote (local edits?)")
            end
        end
    end

    -- ---- git ---------------------------------------------------------------
    local code, top = M._git(root, { "rev-parse", "--show-toplevel" })
    if code == 0 and top:match("%S") then
        local files = launcher.FILES
        local function args(pre)
            local a = {}
            for _, x in ipairs(pre) do a[#a + 1] = x end
            a[#a + 1] = "--"
            for _, f in ipairs(files) do a[#a + 1] = f end
            return a
        end
        -- tracked + modes
        local c1, stage = M._git(root, args({ "ls-files", "--stage" }))
        local modes = c1 == 0 and launcher.parse_ls_stage(stage) or nil
        if modes then
            local untracked = {}
            for _, f in ipairs(files) do
                if not modes[f] and uv.fs_stat(root .. "/" .. f) then untracked[#untracked + 1] = f end
            end
            if #untracked > 0 then info(join(untracked) .. " not committed yet") end
            if modes["lw.sh"] and modes["lw.sh"] ~= "100755" then
                nag("lw.sh is not executable in git (mode " .. modes["lw.sh"] ..
                    ") - CI on Linux/macOS cannot run it",
                    repair() .. ", or `git update-index --chmod=+x lw.sh`; then commit")
            end
        end
        -- attributes (the user's global attributes file does not count)
        local c2, attr = M._git(root, args({ "-c", "core.attributesFile=", "check-attr", "text", "eol" }))
        if c2 == 0 then
            local a = launcher.parse_check_attr(attr)
            local bad = {}
            for _, f in ipairs(files) do
                if not launcher.attrs_ok(f, a[f]) then bad[#bad + 1] = f end
            end
            if #bad > 0 then
                nag("no line-ending rule for " .. join(bad) .. " in .gitattributes", repair(),
                    "lw.sh and lw.pin need `text eol=lf`, lw.cmd `text eol=crlf`")
            end
        end
        -- committed + checked-out line endings
        local c3, eol = M._git(root, args({ "ls-files", "--eol" }))
        if c3 == 0 then
            local e = launcher.parse_ls_eol(eol)
            local committed, checkout = {}, {}
            for _, f in ipairs(files) do
                local r = e[f]
                if r then
                    if r.index ~= "lf" and r.index ~= "" and r.index ~= "none" then
                        committed[#committed + 1] = f .. " (" .. r.index .. ")"
                    end
                    local want = launcher.EOL[f]
                    if r.worktree ~= "" and r.worktree ~= "none" and r.worktree ~= want then
                        checkout[#checkout + 1] = f .. " (" .. r.worktree .. ", needs " .. want .. ")"
                    end
                end
            end
            if #committed > 0 then
                nag("committed with CR LF line endings: " .. join(committed),
                    "once the attributes are in place: `git add --renormalize lw.sh lw.cmd lw.pin`, then commit")
            end
            if #checkout > 0 then
                nag("wrong line endings in this checkout: " .. join(checkout) ..
                    " - the launcher will fail", repair())
            end
        end
        -- ignore rule: a committed .gitignore of the repo, not a personal one
        local probe = launcher.CACHE_DIR .. "/lw.marker"
        local c4, ign = M._git(root, { "-c", "core.excludesFile=", "check-ignore", "-v", "--no-index", "--", probe })
        local by_repo = false
        if c4 == 0 then
            local m = launcher.parse_check_ignore(ign)
            if m and m.pattern:sub(1, 1) ~= "!" then
                local src = m.source:gsub("\\", "/")
                by_repo = src:match("[^/]+$") == ".gitignore" and not src:match("^%a:/")
                    and src:sub(1, 1) ~= "/" and not src:match("^%.git/")
            end
        end
        if c4 == 0 or c4 == 1 then
            if not by_repo then
                local c5 = M._git(root, { "check-ignore", "-q", "--no-index", "--", probe })
                nag(c5 == 0
                    and ".nvim/cache/ is ignored only by your personal gitignore - others will see downloaded binaries as untracked"
                    or ".nvim/cache/ is not ignored - downloaded binaries show as untracked",
                    repair())
            end
        end
    end

    -- ---- stale cached binaries -------------------------------------------------
    if version then
        local assets = {}
        for _, a in pairs(pin.HOST_ASSETS) do assets[#assets + 1] = a end
        local n, bytes = require("boot.repo_meta").stale_cache(root, version, assets, pin.valid_version)
        if n > 0 then
            info(string.format("%d old pinned binar%s in .nvim/cache (%s) - removed by the next lw update",
                n, n == 1 and "y" or "ies", mb(bytes)))
        end
    end

    if #items == 0 then
        info("lw " .. tostring(version) .. " pinned; lw.sh / lw.cmd current, modes and line endings ok")
    end
    return { root = root, version = version, items = items }
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

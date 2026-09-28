--- loomworks/submodules.lua — git submodule drift report (headless §16.31,
--- provider #3).
---
--- Reports how the workspace repository's submodules (recursively) stand
--- against what the repository records:
---   * checkout vs recorded commit (the parent's index, as `git submodule
---     status` compares): match / ahead / behind / diverged / unrelated /
---     recorded commit not fetched / not initialized / conflicted;
---   * recorded commit vs the tracked branch's LAST-FETCHED remote-tracking ref
---     (`.gitmodules` `branch`, `.` = the parent's current branch, else the
---     submodule's `origin/HEAD`) — local refs only, never a fetch;
---   * uninitialized submodules, with a bounded reachability probe of the URL
---     an initialization would clone (relative URLs resolved against the
---     parent's `origin`, git's rules) — the one network operation.
---
--- An ON-DEMAND, REPORT-ONLY health provider: it spawns git, so it never runs
--- on the passive `N suggestions` path, and its items are informational and
--- never stored in the health cache. Core-generic: git is a property of the
--- workspace root, not of any module.

local M = {}

local uv = vim.uv or vim.loop

--- Spawn timeouts (ms). A timed-out query reads as unknown, never a failure.
M.STATUS_TIMEOUT_MS = 30000
M.QUERY_TIMEOUT_MS = 10000
--- Remote HEAD query budget. A real ssh round trip to a distant forge was
--- measured at ~4.6 s, so 5 s misreported answering remotes; all probes run
--- concurrently, so the budget is paid once, not per URL.
M.REACH_TIMEOUT_MS = 10000
--- At most this many distinct network URLs are probed for reachability (and
--- at most `MAX_LOCAL_URLS` local-path ones, which are cheap local queries).
M.MAX_REACH_URLS = 16
M.MAX_LOCAL_URLS = 64
--- Concurrent local git processes (network probes all run at once).
M.MAX_PARALLEL = 8
--- Submodules named in a grouped item's title before "+N".
M.TITLE_NAMES = 3

--- Environment for every git spawn: read-only (no opportunistic index
--- refresh writes), never prompt (terminal or credential-manager GUI), stable
--- messages.
local GIT_ENV = {
    GIT_OPTIONAL_LOCKS = "0",
    GIT_TERMINAL_PROMPT = "0",
    GCM_INTERACTIVE = "never",
    LC_ALL = "C",
}

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------

--- Forward slashes, no trailing separator (a drive / filesystem root keeps it).
--- @param p string
--- @return string
local function norm(p)
    p = p:gsub("\\", "/")
    if #p > 1 and not p:match("^%a:/$") then p = p:gsub("/+$", "") end
    return p
end

--- The nearest directory at or above `dir` holding a `.git` marker (directory
--- or file) — plain stats, no spawn — or nil.
--- @param dir string
--- @return string|nil
function M.find_repo(dir)
    if type(dir) ~= "string" or dir == "" then return nil end
    local d = norm(dir)
    while true do
        local marker = (d:sub(-1) == "/") and (d .. ".git") or (d .. "/.git")
        if uv.fs_stat(marker) then return d end
        if d == "/" or d:match("^%a:/$") then return nil end
        local parent = d:match("^(.*)/[^/]+$")
        if parent == nil then return nil end
        if parent == "" then
            parent = "/"
        elseif parent:match("^%a:$") then
            parent = parent .. "/"
        end
        d = parent
    end
end

--- Parse `git submodule status [--cached] [--recursive]` output into
--- `{ prefix, sha, path }` entries (the trailing `(describe)` is dropped).
--- @param text string
--- @return { prefix: string, sha: string, path: string }[]
function M.parse_status(text)
    local out = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local prefix, sha, rest = line:match("^([ %+%-U])(%x+) (.+)$")
        if prefix then
            local path = rest:gsub(" %([^()]*%)$", "")
            out[#out + 1] = { prefix = prefix, sha = sha, path = path }
        end
    end
    return out
end

--- Unquote a git-config value (surrounding quotes, `\"`, `\\`) and drop an
--- unquoted trailing `;`/`#` comment.
--- @param v string
--- @return string
local function config_value(v)
    v = vim.trim(v)
    if v:sub(1, 1) == '"' then
        local inner = v:match('^"(.*)"') or v:sub(2)
        return (inner:gsub('\\(["\\])', "%1"))
    end
    v = v:gsub("%s+[;#].*$", "")
    return vim.trim(v)
end

--- Parse a `.gitmodules` file into `{ [path] = { name, path, url?, branch? } }`.
--- @param text string
--- @return table<string, { name: string, path: string, url?: string, branch?: string }>
function M.parse_gitmodules(text)
    local by_name, order = {}, {}
    local cur
    for line in (text or ""):gmatch("[^\r\n]+") do
        local l = vim.trim(line)
        if l ~= "" and not l:match("^[;#]") then
            local name = l:match('^%[%s*[sS][uU][bB][mM][oO][dD][uU][lL][eE]%s+"(.-)"%s*%]$')
            if name then
                cur = by_name[name]
                if not cur then
                    cur = { name = name }
                    by_name[name] = cur
                    order[#order + 1] = name
                end
            elseif l:match("^%[") then
                cur = nil
            elseif cur then
                local k, v = l:match("^([%w%.%-]+)%s*=%s*(.*)$")
                if k then
                    k = k:lower()
                    if k == "path" or k == "url" or k == "branch" then cur[k] = config_value(v) end
                end
            end
        end
    end
    local by_path = {}
    for _, name in ipairs(order) do
        local e = by_name[name]
        if e.path then by_path[norm(e.path)] = e end
    end
    return by_path
end

--- Resolve a submodule URL the way git does: an absolute URL passes through; a
--- relative one (`./x`, `../x`) is taken relative to `base` — the parent's
--- `origin` URL, or its working directory when it has none. Each `../` drops
--- one path component of the base (a trailing `/` is ignored); scp-like
--- `host:path` bases keep their `host:`. nil when there is nothing to resolve
--- against, or the `../` run past the base.
--- @param url string
--- @param base string|nil
--- @return string|nil
function M.resolve_url(url, base)
    if type(url) ~= "string" then return nil end
    if not (url:match("^%./") or url:match("^%.%./")) then return url end
    if type(base) ~= "string" or base == "" then return nil end
    base = base:gsub("\\", "/"):gsub("/+$", "")

    -- Split off the part `../` never climbs above: `scheme://host`, a Windows
    -- drive, a leading `/`, or an scp-like `user@host:`.
    local prefix, path
    local scheme = base:match("^(%a[%w+.-]*://[^/]*)")
    if scheme then
        prefix, path = scheme, base:sub(#scheme + 1)
    elseif base:match("^%a:/") then
        prefix, path = base:sub(1, 2), base:sub(3)
    elseif base:match("^/") then
        prefix, path = "", base
    else
        local host = base:match("^([^/:]+:)")
        if host then
            prefix, path = host, base:sub(#host + 1)
        else
            prefix, path = "", base
        end
    end
    -- An scp-like `host:` joins without a slash; everything else with one.
    local sep = (prefix ~= "" and prefix:sub(-1) == ":" and not prefix:match("^%a:$")) and "" or "/"

    local parts = {}
    for seg in path:gmatch("[^/]+") do parts[#parts + 1] = seg end
    local rest = url
    while true do
        if rest:match("^%./") then
            rest = rest:sub(3)
        elseif rest:match("^%.%./") then
            if #parts == 0 then return nil end
            parts[#parts] = nil
            rest = rest:sub(4)
        else
            break
        end
    end
    local joined = table.concat(parts, "/")
    if joined ~= "" then joined = joined .. "/" end
    if sep == "" then return prefix .. joined .. rest end
    return prefix .. "/" .. joined .. rest
end

--- Whether a (resolved) submodule URL names a local path — probing it is a
--- local git query, not a network round trip.
--- @param url string
--- @return boolean
function M.is_local_url(url)
    return url:match("^/") ~= nil or url:match("^%a:[/\\]") ~= nil or url:match("^file://") ~= nil
end

--- Classify `rev-list --left-right --count recorded...checked_out` counts.
--- @param behind integer commits the recorded commit has that HEAD lacks
--- @param ahead integer commits HEAD has that the recorded commit lacks
--- @return "match"|"ahead"|"behind"|"diverged"
function M.classify(behind, ahead)
    if behind == 0 and ahead == 0 then return "match" end
    if behind == 0 then return "ahead" end
    if ahead == 0 then return "behind" end
    return "diverged"
end

-- ---------------------------------------------------------------------------
-- git runner
-- ---------------------------------------------------------------------------

--- Run `jobs` (`{ cwd, args, timeout, env?, net? }`): local ones with at most
--- `MAX_PARALLEL` concurrent git processes, network ones (`net`) all at once
--- beside them; each job gets `.res = { code, stdout, stderr }` (code 124 on
--- timeout, 127 when the spawn failed). Blocks, pumping the event loop; the
--- on-exit callbacks only record.
--- @param git string resolved git executable
--- @param jobs table[]
local function run_jobs(git, jobs)
    if #jobs == 0 then return end
    local exe = require("loomworks.exe")
    local running = 0
    local pending_local = {}
    for _, j in ipairs(jobs) do if not j.net then pending_local[#pending_local + 1] = j end end
    local local_running = 0
    local next_i = 1
    local function start(job)
        local cmd = { git, "-C", job.cwd }
        for _, a in ipairs(job.args) do cmd[#cmd + 1] = a end
        local env = {}
        for k, v in pairs(GIT_ENV) do env[k] = v end
        for k, v in pairs(job.env or {}) do env[k] = v end
        running = running + 1
        if not job.net then local_running = local_running + 1 end
        local function done()
            running = running - 1
            if not job.net then local_running = local_running - 1 end
        end
        local ok, err = pcall(exe.system, cmd, { text = true, timeout = job.timeout, env = env }, function(r)
            job.res = { code = r.code or -1, stdout = r.stdout or "", stderr = r.stderr or "" }
            done()
        end)
        if not ok then
            job.res = { code = 127, stdout = "", stderr = tostring(err) }
            done()
        end
    end
    pcall(uv.update_time)
    for _, j in ipairs(jobs) do if j.net then start(j) end end
    local deadline_slack = 2000
    while true do
        while local_running < M.MAX_PARALLEL and next_i <= #pending_local do
            start(pending_local[next_i])
            next_i = next_i + 1
        end
        if running <= 0 and next_i > #pending_local then break end
        local before = running
        local max_t = 0
        for _, j in ipairs(jobs) do if not j.res then max_t = math.max(max_t, j.timeout or 0) end end
        local ok_w = vim.wait(max_t + deadline_slack, function()
            return running < before or (running <= 0)
        end, 10)
        if not ok_w then
            -- A job never reported back (a lost callback): give up on the rest.
            for _, j in ipairs(jobs) do
                if not j.res then j.res = { code = 124, stdout = "", stderr = "no result" } end
            end
            break
        end
    end
end

--- First line of a string, trimmed and capped.
local function first_line(s)
    local l = vim.trim(((s or ""):match("^%s*([^\r\n]*)")) or "")
    if #l > 160 then l = l:sub(1, 157) .. "..." end
    return l
end

--- Read a whole file, or nil.
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- The git directory of a working tree: `<dir>/.git`, or where its `.git`
--- file (`gitdir: …`) points.
--- @param dir string
--- @return string|nil
local function git_dir(dir)
    local marker = dir .. "/.git"
    local st = uv.fs_stat(marker)
    if not st then return nil end
    if st.type == "directory" then return marker end
    local txt = read_file(marker)
    local gd = txt and txt:match("^gitdir:%s*([^\r\n]+)")
    if not gd then return nil end
    gd = gd:gsub("\\", "/")
    if not (gd:match("^/") or gd:match("^%a:/")) then gd = dir .. "/" .. gd end
    return gd
end

--- The label of `refs/remotes/origin/HEAD`'s target ("origin/main"), read from
--- the loose symref file; nil when absent (packed / reftable / never set).
--- @param dir string submodule working tree
--- @return string|nil
local function origin_head_label(dir)
    local gd = git_dir(dir)
    if not gd then return nil end
    local txt = read_file(gd .. "/refs/remotes/origin/HEAD")
    local ref = txt and txt:match("^ref:%s*refs/remotes/([^\r\n]+)")
    return ref and vim.trim(ref) or nil
end

--- Parse "L\tR" from `rev-list --left-right --count`.
local function parse_counts(out)
    local l, r = (out or ""):match("^%s*(%d+)%s+(%d+)")
    if not l then return nil end
    return tonumber(l), tonumber(r)
end

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------

--- @class loomworks.SubmoduleEntry
--- @field path string relative to the report root
--- @field name? string `.gitmodules` name
--- @field nested boolean inside another submodule
--- @field state string match|ahead|behind|diverged|unrelated|missing-commit|uninitialized|conflict|unknown
--- @field recorded? string commit the parent records
--- @field checked_out? string commit checked out in the submodule
--- @field ahead? integer checkout commits the recorded commit lacks
--- @field behind? integer recorded commits the checkout lacks
--- @field tracking? { ref: string, ahead: integer, behind: integer }
--- @field url? string resolved URL (uninitialized, probed)
--- @field reachable? boolean a definitive probe answer (absent: not probed / no answer)
--- @field reach? "reachable"|"unreachable"|"no-answer"|"not-checked" probe outcome
--- @field reach_detail? string why a probe failed (text report only)

--- @class loomworks.SubmoduleReport
--- @field root string repository top level
--- @field entries loomworks.SubmoduleEntry[]
--- @field error? string the status query failed

--- Build the submodule report for the repository enclosing `dir`, or nil when
--- there is none, it has no `.gitmodules`, or git is not available.
--- `opts.reachability = false` skips the network probe; `opts.git` names the
--- git executable (tests).
--- @param dir string
--- @param opts? { reachability?: boolean, git?: string }
--- @return loomworks.SubmoduleReport|nil
function M.report(dir, opts)
    opts = opts or {}
    local top = M.find_repo(dir)
    if not top then return nil end
    if not uv.fs_stat(top .. "/.gitmodules") then return nil end
    local git = require("loomworks.exe").resolve(opts.git or "git")
    if not git then return nil end

    local report = { root = top, entries = {} }

    local st = { cwd = top, args = { "-c", "core.quotePath=false", "submodule", "status", "--recursive" },
        timeout = M.STATUS_TIMEOUT_MS }
    run_jobs(git, { st })
    if st.res.code ~= 0 then
        report.error = st.res.code == 124 and "git submodule status timed out"
            or first_line(st.res.stderr ~= "" and st.res.stderr or ("git exited " .. st.res.code))
        return report
    end
    local raw = M.parse_status(st.res.stdout)

    -- Parents: the superproject ("") and every initialized submodule.
    local initialized = {}
    for _, r in ipairs(raw) do
        if r.prefix == " " or r.prefix == "+" then initialized[#initialized + 1] = r.path end
    end
    local function parent_of(path)
        local best = ""
        for _, p in ipairs(initialized) do
            if #p > #best and path:sub(1, #p + 1) == p .. "/" then best = p end
        end
        return best
    end
    local function abs(rel) return rel == "" and top or (top .. "/" .. rel) end

    -- Recorded commits of drifted checkouts (a `+` line shows the checkout):
    -- the parent's index gitlink, one literal-pathspec `ls-files` per parent.
    local recorded_of = {}
    local plus_by_parent, ls_jobs = {}, {}
    for _, r in ipairs(raw) do
        if r.prefix == "+" then
            local parent = parent_of(r.path)
            if not plus_by_parent[parent] then
                plus_by_parent[parent] = { cwd = abs(parent), parent = parent, timeout = M.QUERY_TIMEOUT_MS,
                    env = { GIT_LITERAL_PATHSPECS = "1" },
                    args = { "-c", "core.quotePath=false", "ls-files", "--stage", "--" } }
                ls_jobs[#ls_jobs + 1] = plus_by_parent[parent]
            end
            local j = plus_by_parent[parent]
            j.args[#j.args + 1] = parent == "" and r.path or r.path:sub(#parent + 2)
        end
    end
    run_jobs(git, ls_jobs)
    for _, j in ipairs(ls_jobs) do
        if j.res.code == 0 then
            for line in j.res.stdout:gmatch("[^\r\n]+") do
                local sha, stage, rel = line:match("^160000 (%x+) (%d)\t(.+)$")
                if sha and stage == "0" then
                    recorded_of[j.parent == "" and rel or (j.parent .. "/" .. rel)] = sha
                end
            end
        end
    end
    local modules_of = {}
    local function gitmodules(parent)
        if modules_of[parent] == nil then
            modules_of[parent] = M.parse_gitmodules(read_file(abs(parent) .. "/.gitmodules") or "")
        end
        return modules_of[parent]
    end

    local entries, meta = {}, {}
    for _, r in ipairs(raw) do
        local parent = parent_of(r.path)
        local rel = parent == "" and r.path or r.path:sub(#parent + 2)
        local decl = gitmodules(parent)[rel] or {}
        local e = { path = r.path, name = decl.name, nested = parent ~= "" }
        local m = { parent = parent, rel = rel, decl = decl }
        if r.prefix == "-" then
            e.state, e.recorded = "uninitialized", r.sha
        elseif r.prefix == "U" then
            e.state = "conflict"
        elseif r.prefix == " " then
            e.state, e.recorded, e.checked_out = "match", r.sha, r.sha
        else
            e.checked_out = r.sha
            e.recorded = recorded_of[r.path]
            e.state = "unknown"
        end
        entries[#entries + 1] = e
        meta[e] = m
    end
    report.entries = entries

    -- Per-parent config for uninitialized entries' URLs (one spawn per parent).
    local cfg_jobs, cfg_of = {}, {}
    for _, e in ipairs(entries) do
        local p = meta[e].parent
        if e.state == "uninitialized" and not cfg_of[p] then
            local j = { cwd = abs(p), timeout = M.QUERY_TIMEOUT_MS,
                args = { "config", "--get-regexp", "^(remote\\.origin\\.url|submodule\\..*\\.url)$" } }
            cfg_of[p] = j
            cfg_jobs[#cfg_jobs + 1] = j
        end
    end
    -- `branch = .` → the parent's current branch.
    local branch_jobs = {}
    for _, e in ipairs(entries) do
        local p = meta[e].parent
        if (e.state == "match" or e.state == "unknown") and meta[e].decl.branch == "." and not branch_jobs[p] then
            branch_jobs[p] = { cwd = abs(p), timeout = M.QUERY_TIMEOUT_MS,
                args = { "symbolic-ref", "--short", "-q", "HEAD" } }
            cfg_jobs[#cfg_jobs + 1] = branch_jobs[p]
        end
    end
    run_jobs(git, cfg_jobs)

    local jobs = {}
    -- Checkout vs recorded (drifted checkouts only).
    for _, e in ipairs(entries) do
        if e.state == "unknown" and e.recorded and e.checked_out then
            local j = { cwd = abs(e.path), timeout = M.QUERY_TIMEOUT_MS, kind = "drift", entry = e,
                args = { "rev-list", "--left-right", "--count", e.recorded .. "..." .. e.checked_out } }
            jobs[#jobs + 1] = j
        end
    end
    -- Recorded vs the tracked branch's remote-tracking ref.
    for _, e in ipairs(entries) do
        if (e.state == "match" or e.state == "unknown") and e.recorded then
            local branch = meta[e].decl.branch
            local label
            if branch == "." then
                local bj = branch_jobs[meta[e].parent]
                local b = bj and bj.res and bj.res.code == 0 and vim.trim(bj.res.stdout) or ""
                label = b ~= "" and ("origin/" .. b) or nil
            elseif branch and branch ~= "" then
                label = "origin/" .. branch
            else
                label = origin_head_label(abs(e.path)) or "origin/HEAD"
            end
            if label and not label:match("^%-") then
                jobs[#jobs + 1] = { cwd = abs(e.path), timeout = M.QUERY_TIMEOUT_MS, kind = "track", entry = e,
                    label = label,
                    args = { "rev-list", "--left-right", "--count", e.recorded .. "...refs/remotes/" .. label } }
            end
        end
    end
    -- Reachability of uninitialized entries' URLs.
    if opts.reachability ~= false then
        local by_url, n_net, n_local = {}, 0, 0
        for _, e in ipairs(entries) do
            if e.state == "uninitialized" then
                local m = meta[e]
                local cj = cfg_of[m.parent]
                local origin, configured
                if cj and cj.res and cj.res.code == 0 then
                    for line in cj.res.stdout:gmatch("[^\r\n]+") do
                        local k, v = line:match("^(%S+)%s+(.+)$")
                        if k == "remote.origin.url" then origin = v end
                        if m.decl.name and k == "submodule." .. m.decl.name .. ".url" then configured = v end
                    end
                end
                local url = configured or M.resolve_url(m.decl.url, origin or abs(m.parent))
                if url then
                    e.url = url
                    if url:match("^%-") then
                        e.reach = "not-checked"
                        e.reach_detail = "not checked (URL begins with '-')"
                    elseif by_url[url] then
                        table.insert(by_url[url].entries, e)
                    else
                        local is_local = M.is_local_url(url)
                        local room = is_local and n_local < M.MAX_LOCAL_URLS or (not is_local and n_net < M.MAX_REACH_URLS)
                        if room then
                            if is_local then n_local = n_local + 1 else n_net = n_net + 1 end
                            local j = { cwd = top, timeout = M.REACH_TIMEOUT_MS, kind = "reach", entries = { e },
                                net = not is_local,
                                args = { "-c", "protocol.ext.allow=never", "-c", "credential.interactive=never",
                                    "ls-remote", "-q", url, "HEAD" } }
                            by_url[url] = j
                            jobs[#jobs + 1] = j
                        else
                            e.reach = "not-checked"
                            e.reach_detail = "not checked (more than "
                                .. (is_local and M.MAX_LOCAL_URLS or M.MAX_REACH_URLS) .. " URLs)"
                        end
                    end
                end
            end
        end
    end
    run_jobs(git, jobs)

    local follow = {}
    for _, j in ipairs(jobs) do
        local res = j.res
        if j.kind == "drift" then
            local e = j.entry
            local behind, ahead = parse_counts(res.code == 0 and res.stdout)
            if behind then
                e.behind, e.ahead = behind, ahead
                e.state = M.classify(behind, ahead)
                if e.state == "diverged" then
                    local fj = { cwd = abs(e.path), timeout = M.QUERY_TIMEOUT_MS, kind = "base", entry = e,
                        args = { "merge-base", e.recorded, e.checked_out } }
                    follow[#follow + 1] = fj
                end
            elseif res.code ~= 124 then
                local fj = { cwd = abs(e.path), timeout = M.QUERY_TIMEOUT_MS, kind = "exists", entry = e,
                    args = { "cat-file", "-e", e.recorded .. "^{commit}" } }
                follow[#follow + 1] = fj
            end
        elseif j.kind == "track" then
            local pin_ahead, pin_behind = parse_counts(res.code == 0 and res.stdout)
            if pin_ahead then
                j.entry.tracking = { ref = j.label, ahead = pin_ahead, behind = pin_behind }
            end
        elseif j.kind == "reach" then
            -- Only a definitive answer decides: a probe that timed out (or
            -- never spawned) leaves the remote unverified, not unreachable.
            for _, e in ipairs(j.entries) do
                if res.code == 0 then
                    e.reachable, e.reach = true, "reachable"
                elseif res.code == 124 or res.code == 127 then
                    e.reach = "no-answer"
                    e.reach_detail = res.code == 124
                        and ("no answer within " .. math.floor(M.REACH_TIMEOUT_MS / 1000) .. " s")
                        or first_line(res.stderr)
                else
                    e.reachable, e.reach = false, "unreachable"
                    e.reach_detail = first_line(res.stderr ~= "" and res.stderr or ("git exited " .. res.code))
                end
            end
        end
    end
    run_jobs(git, follow)
    for _, j in ipairs(follow) do
        if j.kind == "base" and j.res.code == 1 then
            j.entry.state = "unrelated"
        elseif j.kind == "exists" and j.res.code ~= 0 and j.res.code ~= 124 then
            j.entry.state = "missing-commit"
        end
    end
    return report
end

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------

local function short(sha) return sha and sha:sub(1, 10) or "?" end

--- "a, b, c, +2" — the first `TITLE_NAMES` names then a count of the rest.
local function names_phrase(names)
    local shown = {}
    for i = 1, math.min(#names, M.TITLE_NAMES) do shown[i] = names[i] end
    if #names > M.TITLE_NAMES then shown[#shown + 1] = "+" .. (#names - M.TITLE_NAMES) end
    return table.concat(shown, ", ")
end

--- Terse phrase for a drifted checkout ("A 1 ahead").
local function drift_phrase(e)
    if e.state == "ahead" then return e.path .. " " .. e.ahead .. " ahead" end
    if e.state == "behind" then return e.path .. " " .. e.behind .. " behind" end
    if e.state == "diverged" then return e.path .. " diverged" end
    if e.state == "unrelated" then return e.path .. " unrelated" end
    if e.state == "missing-commit" then return e.path .. " pin not fetched" end
    if e.state == "conflict" then return e.path .. " conflicted" end
    return e.path .. " differs"
end

--- One verbose line for a drifted checkout.
local function drift_line(e)
    local co, rec = short(e.checked_out), short(e.recorded)
    if e.state == "ahead" then return e.path .. ": checked out " .. co .. " is " .. e.ahead .. " ahead of recorded " .. rec end
    if e.state == "behind" then return e.path .. ": checked out " .. co .. " is " .. e.behind .. " behind recorded " .. rec end
    if e.state == "diverged" then
        return string.format("%s: checked out %s and recorded %s diverged (%d ahead, %d behind)",
            e.path, co, rec, e.ahead or 0, e.behind or 0)
    end
    if e.state == "unrelated" then return e.path .. ": checked out " .. co .. " shares no history with recorded " .. rec end
    if e.state == "missing-commit" then
        return e.path .. ": recorded " .. rec .. " is not present locally (fetch the submodule)"
    end
    if e.state == "conflict" then return e.path .. ": the gitlink has merge conflicts" end
    return e.path .. ": checked out " .. co .. " differs from recorded " .. rec .. " (comparison unavailable)"
end

--- Phrase + verbose line for a pin against its tracked branch.
local function track_phrase(e)
    local t = e.tracking
    if t.ahead == 0 then return e.path .. " " .. t.behind .. " behind " .. t.ref end
    if t.behind == 0 then return e.path .. " " .. t.ahead .. " ahead of " .. t.ref end
    return e.path .. " diverged from " .. t.ref
end
local function track_line(e)
    local t = e.tracking
    return string.format("%s: recorded %s is %d behind, %d ahead of %s", e.path, short(e.recorded),
        t.behind, t.ahead, t.ref)
end

--- Group a report into terse informational items (§16.31 provider #3). Each
--- carries its per-submodule lines as a `detail` shown only by the verbose
--- report (`detail_verbose`).
--- @param report loomworks.SubmoduleReport|nil
--- @return loomworks.Suggestion[]
function M.items(report)
    if not report then return {} end
    local items = {}
    local function item(title, lines)
        items[#items + 1] = { kind = "info", title = title, detail = table.concat(lines, "\n  "), detail_verbose = true }
    end
    if report.error then
        items[#items + 1] = { kind = "info", title = "submodules: could not be checked — " .. report.error }
        return items
    end

    local drift, pins, uninit, unreach, silent = {}, {}, {}, {}, {}
    local nested_uninit = 0
    for _, e in ipairs(report.entries) do
        if e.state == "uninitialized" then
            uninit[#uninit + 1] = e
            if e.nested then nested_uninit = nested_uninit + 1 end
            if e.reachable == false then unreach[#unreach + 1] = e end
            if e.reach == "no-answer" then silent[#silent + 1] = e end
        elseif e.state ~= "match" then
            drift[#drift + 1] = e
        end
        if e.tracking and (e.tracking.ahead > 0 or e.tracking.behind > 0) then pins[#pins + 1] = e end
    end
    local more = " — lw health --verbose"

    if #drift > 0 then
        local names, lines = {}, {}
        for _, e in ipairs(drift) do
            names[#names + 1] = drift_phrase(e)
            lines[#lines + 1] = drift_line(e)
        end
        lines[#lines + 1] = "restore the recorded commits: git submodule update --init --recursive;"
            .. " or record the checked-out one: git add <path> in its parent — lw help submodules"
        item(string.format("submodules: %d checked out off %s recorded commit (%s)%s", #drift,
            #drift == 1 and "its" or "their", names_phrase(names), more), lines)
    end
    if #pins > 0 then
        local names, lines = {}, {}
        for _, e in ipairs(pins) do
            names[#names + 1] = track_phrase(e)
            lines[#lines + 1] = track_line(e)
        end
        lines[#lines + 1] = "as of the last fetch (no network used) — git -C <path> fetch to refresh; lw help submodules"
        item(string.format("submodules: %d pin%s behind %s tracked branch (%s)%s", #pins,
            #pins == 1 and "" or "s", #pins == 1 and "its" or "their", names_phrase(names), more), lines)
    end
    if #uninit > 0 then
        local names, lines = {}, {}
        for _, e in ipairs(uninit) do
            names[#names + 1] = e.path
            lines[#lines + 1] = e.path .. ": not initialized" .. (e.nested and " (nested)" or "")
                .. (e.url and (" — " .. e.url) or "")
                .. (e.reach == "not-checked" and e.reach_detail and (" (" .. e.reach_detail .. ")") or "")
        end
        lines[#lines + 1] = "initialize: git submodule update --init --recursive — lw help submodules"
        item(string.format("submodules: %d not initialized%s (%s)%s", #uninit,
            nested_uninit > 0 and (", " .. nested_uninit .. " nested") or "", names_phrase(names), more), lines)
    end
    if #unreach > 0 then
        local names, lines = {}, {}
        for _, e in ipairs(unreach) do
            names[#names + 1] = e.path
            lines[#lines + 1] = e.path .. ": " .. tostring(e.url) .. " — " .. tostring(e.reach_detail or "unreachable")
        end
        lines[#lines + 1] = "a relative URL resolves against the parent's origin — check that remote hosts it;"
            .. " lw help submodules"
        item(string.format("submodules: %d remote%s unreachable (%s)%s", #unreach,
            #unreach == 1 and "" or "s", names_phrase(names), more), lines)
    end
    if #silent > 0 then
        local names, lines = {}, {}
        for _, e in ipairs(silent) do
            names[#names + 1] = e.path
            lines[#lines + 1] = e.path .. ": " .. tostring(e.url) .. " — " .. tostring(e.reach_detail or "no answer")
        end
        lines[#lines + 1] = "not verified (slow or offline network, or a prompt was needed) — lw help submodules"
        item(string.format("submodules: %d remote%s did not answer within %d s — not verified (%s)%s", #silent,
            #silent == 1 and "" or "s", math.floor(M.REACH_TIMEOUT_MS / 1000), names_phrase(names), more), lines)
    end
    if #drift == 0 and #uninit == 0 and #report.entries > 0 then
        items[#items + 1] = { kind = "info", title = string.format("submodules: %d in sync with %s recorded commit%s",
            #report.entries, #report.entries == 1 and "its" or "their", #report.entries == 1 and "" or "s") }
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Provider
-- ---------------------------------------------------------------------------

--- The last health run's report, for `lw health --json` (`submodules`).
--- @type loomworks.SubmoduleReport|nil
M._last = nil

--- @return loomworks.SubmoduleReport|nil
function M.last_report() return M._last end

--- The JSON form of a report (§16.33 `submodules`), or nil.
--- @param report loomworks.SubmoduleReport|nil
--- @return table|nil
function M.json(report)
    if not report then return nil end
    local entries = {}
    for _, e in ipairs(report.entries) do
        entries[#entries + 1] = {
            path = e.path, name = e.name, nested = e.nested, state = e.state,
            recorded = e.recorded, checked_out = e.checked_out, ahead = e.ahead, behind = e.behind,
            tracking = e.tracking, url = e.url, reachable = e.reachable, reach = e.reach,
        }
    end
    return { root = report.root, entries = entries, error = report.error }
end

--- Health provider (on-demand, report-only, workspace-scoped): the submodule
--- report of the repository enclosing the workspace root, as informational
--- items. Records the report for `--json`.
--- @param workspace loomworks.Workspace|nil
--- @return loomworks.Suggestion[]
function M.provider(workspace)
    M._last = nil
    if type(workspace) ~= "table" or type(workspace.root) ~= "string" then return {} end
    local report = M.report(workspace.root)
    M._last = report
    return M.items(report)
end

return M

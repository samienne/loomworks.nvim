--- loomworks/provision/select.lua — which `lw` host binary the editor
--- launches the workspace daemon from (spec §19.16 "Host binary").
---
--- First match wins:
---   1. explicit: `LOOMWORKS_LW`, then the setup option `binary.path`, a
---      relative value taken against the editor's current directory. A value
---      naming no file (or, on Windows, no `.exe`) is a note and stops the
---      search (explicit means explicit: the editor never runs another lw
---      instead);
---   2. `lw` on the search path: absolute PATH entries only, never the
---      current directory (a repository the editor opened); on Windows
---      `lw.exe` (a `.cmd` shim cannot be started detached without a
---      console);
---   3. the plugin-managed lw under the editor's data directory
---      (loomworks.provision.managed). A wanted one that is not installed yet
---      decides the search too: the selection carries it as `download`, and
---      the observer downloads it (loomworks.provision.fetch) unless
---      `binary.download = false`.
--- `binary.prefer = "managed"` puts 3 before 2. The editor reads no `lw.pin`:
--- a global or managed lw follows the repository's pin itself (§16.23).
--- `binary.source` (development only, never automatic) runs the selected
--- binary with a Lua source tree (`LOOMWORKS_LUA`, §16.11).
---
--- A search-path or explicit lw is weighed by its cached pre-launch probe
--- verdict (loomworks.provision.probe, §19.16 "Pre-launch probe", step 5h.5):
--- an `incompatible` lw on PATH is refused and the search goes on (to the
--- managed lw); an explicit one is never replaced, its verdict only noted
--- (`probe_note`); `unknown` is used. A binary with no verdict yet is chosen
--- and named in `probe`: the observer probes it (async) and resolves again.
--- The selection itself never runs a process. After connecting, the daemon's
--- handshake and `Root.describe` decide (§19.9, §19.20).

local uv = vim.uv or vim.loop

local M = {}

--- @alias loomworks.provision.Source "LOOMWORKS_LW"|"setting"|"PATH"|"managed"

--- @class loomworks.provision.BinarySetting  the setup option `binary`
--- @field path? string an lw host binary to use as is
--- @field prefer? "system"|"managed" which of `lw` on PATH and the plugin-managed lw comes first (default "system")
--- @field source? string|boolean development only: run the binary with this Lua tree (`true`: this plugin's)
--- @field download? boolean false: never download the plugin-managed lw (default true; daemon mode only)
--- @field release_url? string release-source override for that download (else LOOMWORKS_RELEASE_URL, else lw's origin)
--- @field channel? "stable"|"unstable" let the managed lw move ahead of the pin to this channel's newest compatible release (default unset: the pin only; step 5h.5)

--- @class loomworks.provision.Candidate  one step of the search
--- @field source loomworks.provision.Source
--- @field label string how the status page and checkhealth name it
--- @field path? string the binary it found
--- @field verdict "chosen"|"download"|"absent"|"refused"|"not tried"
--- @field reason? string why it was not chosen
--- @field probe? loomworks.provision.Probe the cached pre-launch probe verdict of a PATH or explicit binary (step 5h.5)

--- @class loomworks.provision.Selection  the result of `resolve`
--- @field path? string the chosen host binary
--- @field source? loomworks.provision.Source
--- @field label? string
--- @field candidates loomworks.provision.Candidate[] every step, in search order
--- @field env? table<string, string> extra environment for the daemon (`binary.source`)
--- @field download? loomworks.provision.Wanted the plugin-managed lw to download first (it decided the search)
--- @field note? string why there is none (the Runtime line)
--- @field warning? string an ignored setup value
--- @field probe? string the chosen binary still to be probed (no cached verdict yet, step 5h.5)
--- @field probe_note? string the pre-launch probe's lasting note: an incompatible lw on PATH that was skipped, or an incompatible explicit one used as named
--- @field channel_note? string `binary.channel` is set but has no effect: an lw on PATH or an explicit one was selected (step 5h.5)

M.LABELS = {
    LOOMWORKS_LW = "LOOMWORKS_LW",
    setting = "binary.path setting",
    PATH = "lw on PATH",
    managed = "plugin-managed lw",
}

--- The note when nothing resolved and no details are known (an injected
--- resolver returned nil).
M.NONE_NOTE = "no lw host binary found (LOOMWORKS_LW, binary.path, PATH, plugin-managed lw) — running in-process"

local function is_win() return package.config:sub(1, 1) == "\\" end

local function is_file(p)
    local st = p and uv.fs_stat(p)
    return st ~= nil and st.type == "file"
end

local function is_dir(p)
    local st = p and uv.fs_stat(p)
    return st ~= nil and st.type == "directory"
end

local function slash(p) return (p:gsub("\\", "/")) end

--- Whether `p` is absolute on its own, independent of the current directory
--- (Windows: a drive path or UNC; a bare `\x` is relative to the current
--- drive and does not count).
--- @param p string
--- @param win boolean
--- @return boolean
function M.is_absolute(p, win)
    if type(p) ~= "string" or p == "" then return false end
    if win then return p:match("^%a:[/\\]") ~= nil or p:match("^[/\\][/\\][^/\\]") ~= nil end
    return p:sub(1, 1) == "/"
end

--- The absolute entries of a PATH value, in order. Relative and empty
--- entries are dropped: they name the current directory, which for the editor
--- is a repository it opened, possibly untrusted (spec §19.16).
--- @param path string|nil
--- @param win boolean
--- @return string[]
function M.path_dirs(path, win)
    local sep = win and ";" or ":"
    local out = {}
    for entry in ((path or "") .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do
        if win then entry = entry:gsub('^"(.*)"$', "%1") end
        if M.is_absolute(entry, win) then out[#out + 1] = (slash(entry):gsub("/+$", "")) end
    end
    return out
end

local function is_exec_file(p)
    local st = p and uv.fs_stat(p)
    if not st or st.type ~= "file" then return false end
    if is_win() then return true end
    return uv.fs_access(p, "X") == true
end

--- `lw` on the search path, or nil + why. Only absolute PATH entries are
--- searched, in order, never the current directory (unlike `vim.fn.exepath`,
--- which before Neovim 0.12 looks there first on Windows and on any version
--- follows relative entries). On Windows it is `lw.exe` in each entry (a
--- `.cmd` shim or an extensionless file cannot start the daemon detached, and
--- does not hide a later `lw.exe`); elsewhere an executable regular file `lw`.
--- @param opts? { path?: string, win?: boolean, is_exec?: fun(p: string): boolean, realpath?: fun(p: string): string|nil }
--- @return string|nil path, string|nil why
function M.on_path(opts)
    opts = opts or {}
    local win = opts.win
    if win == nil then win = is_win() end
    local path = opts.path
    if path == nil then path = os.getenv("PATH") end
    local is_exec = opts.is_exec or is_exec_file
    local name = win and "lw.exe" or "lw"
    for _, dir in ipairs(M.path_dirs(path, win)) do
        local p = dir .. "/" .. name
        if is_exec(p) then
            -- The binary itself, not PATH's spelling of it (a link): the
            -- daemon it starts then reports the executable the CLI does.
            local real = (opts.realpath or uv.fs_realpath)(p)
            if type(real) == "string" and real ~= "" then p = real end
            return slash(p)
        end
    end
    return nil, "no lw on the search path"
end

--- An explicit value made absolute against the editor's current directory,
--- forward slashes, `.`/`..` resolved. Done once, at resolution time: the
--- daemon is spawned from lw's state directory, so the path checked must be
--- the path run.
--- @param v string
--- @param cwd string
--- @param win boolean
--- @return string
function M.absolute(v, cwd, win)
    local p = slash(v)
    if not M.is_absolute(p, win) then p = slash(cwd):gsub("/+$", "") .. "/" .. p end
    return slash(vim.fs.normalize(p))
end

--- Check the setup option `binary`. Returns the cleaned setting and a
--- warning for each ignored value (shown once, at setup).
--- @param v any
--- @return loomworks.provision.BinarySetting setting, string|nil warning
function M.check_setting(v)
    if v == nil then return {}, nil end
    if type(v) ~= "table" then return {}, "binary: expected a table, ignored" end
    local out, warns = {}, {}
    if v.path ~= nil then
        if type(v.path) == "string" and v.path ~= "" then out.path = v.path
        else warns[#warns + 1] = "binary.path: expected a file path, ignored" end
    end
    if v.prefer ~= nil then
        if v.prefer == "system" or v.prefer == "managed" then out.prefer = v.prefer
        else warns[#warns + 1] = "binary.prefer: expected \"system\" or \"managed\", ignored" end
    end
    if v.source ~= nil and v.source ~= false then
        if v.source == true or (type(v.source) == "string" and v.source ~= "") then out.source = v.source
        else warns[#warns + 1] = "binary.source: expected a directory or true, ignored" end
    end
    if v.download ~= nil then
        if type(v.download) == "boolean" then out.download = v.download
        else warns[#warns + 1] = "binary.download: expected true or false, ignored" end
    end
    if v.release_url ~= nil then
        if type(v.release_url) == "string" and v.release_url ~= "" then out.release_url = v.release_url
        else warns[#warns + 1] = "binary.release_url: expected a URL or directory, ignored" end
    end
    if v.channel ~= nil then
        if v.channel == "stable" or v.channel == "unstable" then out.channel = v.channel
        else warns[#warns + 1] = "binary.channel: expected \"stable\" or \"unstable\", ignored" end
    end
    return out, (#warns > 0 and table.concat(warns, "; ") or nil)
end

--- The development source tree of `binary.source`, or nil + why.
--- @param src string|boolean
--- @param opts table
--- @return string|nil dir, string|nil why
local function source_dir(src, opts)
    local dir
    if src == true then
        dir = (opts.plugin_lua or require("loomworks.daemon.version").lua_root)()
        if not dir then return nil, "binary.source: this plugin's Lua tree is unknown" end
    else
        dir = (slash(vim.fs.normalize(src)):gsub("/+$", ""))
    end
    if not (opts.is_dir or is_dir)(dir) then return nil, "binary.source: " .. dir .. " is not a directory" end
    return dir
end

--- Select the host binary for the workspace at `root`.
--- opts (tests inject):
---   setting   loomworks.provision.BinarySetting (the setup option `binary`)
---   getenv    replaces os.getenv
---   exists    fun(path) → boolean (a regular file)
---   win       boolean: Windows rules (default: the host's)
---   cwd       the directory a relative explicit value is taken against (default: the editor's)
---   on_path   fun() → path|nil, why
---   managed   fun(opts) → path|nil, why, missing (loomworks.provision.managed.find;
---             opts.setting carries `binary.channel`)
---   data      the editor's data directory (the managed lw; default stdpath)
---   is_dir, plugin_lua  for `binary.source`
---   probe     fun(path) → loomworks.provision.Probe|nil, the cached pre-launch
---             verdict (loomworks.provision.probe.cached); false: no probe
--- @param root string
--- @param opts? table
--- @return string|nil path, loomworks.provision.Source|nil source, loomworks.provision.Selection sel
function M.resolve(root, opts)
    local _ = root -- the workspace: no per-workspace source today (the editor reads no lw.pin)
    opts = opts or {}
    local setting, warning = M.check_setting(opts.setting)
    local getenv = opts.getenv or os.getenv
    local exists = opts.exists or is_file
    local win = opts.win
    if win == nil then win = is_win() end
    local cwd = opts.cwd or uv.cwd()
    local sel ={ candidates = {}, warning = warning }
    local function add(source, verdict, path, reason)
        sel.candidates[#sel.candidates + 1] = { source = source, label = M.LABELS[source],
            verdict = verdict, path = path, reason = reason }
    end
    local function choose(source, path)
        add(source, "chosen", path)
        sel.path, sel.source, sel.label = path, source, M.LABELS[source]
    end
    -- The cached pre-launch verdict of a PATH or explicit binary (step 5h.5);
    -- the managed lw is never probed.
    local probe = opts.probe
    if probe == nil then probe = require("loomworks.provision.probe").cached end
    local function verdict(path)
        if not probe then return nil, false end
        local v = probe(path)
        return v, v == nil
    end
    local function problems(v) return table.concat(v.problems, "; ") end

    local order = { "PATH", "managed" }
    if setting.prefer == "managed" then order = { "managed", "PATH" } end

    -- 1. Explicit: the environment, then the setup option.
    local explicit = {
        { "LOOMWORKS_LW", getenv("LOOMWORKS_LW") },
        { "setting", setting.path },
    }
    for _, e in ipairs(explicit) do
        local source, v = e[1], e[2]
        if sel.path or sel.note then
            add(source, "not tried", (v and v ~= "") and slash(v) or nil, "a source above decided")
        elseif v and v ~= "" then
            local p = M.absolute(v, cwd, win)
            local bad = (win and not p:lower():match("%.exe$")) and "not an .exe"
                or (not exists(p) and "not a file") or nil
            if not bad then
                choose(source, p)
                -- Explicit means explicit: an incompatible verdict is only
                -- noted, never a reason to run another lw (rule 1).
                local v, pending = verdict(p)
                sel.candidates[#sel.candidates].probe = v
                if pending then sel.probe = p end
                if v and v.verdict == "incompatible" then
                    sel.probe_note = string.format("%s %s is incompatible (%s) — used as named; the handshake decides",
                        M.LABELS[source], p, problems(v))
                end
            else
                add(source, "refused", p, bad)
                sel.note = string.format("%s names %s, which is %s — no lw host binary "
                    .. "(an explicit lw is never replaced by another); running in-process", M.LABELS[source], p, bad)
            end
        else
            add(source, "absent", nil, "not set")
        end
    end

    -- 2-3. The search path and the plugin-managed lw.
    for _, source in ipairs(order) do
        if sel.path or sel.note or sel.download then
            add(source, "not tried", nil, "a source above decided")
        else
            local p, why, missing
            if source == "PATH" then p, why = (opts.on_path or M.on_path)()
            else
                p, why, missing = (opts.managed or require("loomworks.provision.managed").find)({ setting = setting,
                    data = opts.data, win = opts.win })
            end
            local v, pending
            if p and source == "PATH" then v, pending = verdict(p) end
            if p and v and v.verdict == "incompatible" then
                -- A definite failure: skipped, the search goes on (spec
                -- §19.16 rule 3, "too old").
                add(source, "refused", p, "too old/incompatible: " .. problems(v))
                sel.candidates[#sel.candidates].probe = v
                sel.probe_note = "lw on PATH (" .. p .. ") is too old/incompatible: " .. problems(v)
            elseif p then
                choose(source, p)
                sel.candidates[#sel.candidates].probe = v
                if pending then sel.probe = p end
            elseif missing and setting.download == false then
                add(source, "absent", nil, tostring(why) .. "; downloads are off (binary.download = false)")
            elseif missing then
                local mp = require("loomworks.provision.managed").path(missing.sha256, { data = opts.data, win = win })
                add(source, "download", mp, "lw v" .. tostring(missing.version) .. " (" .. tostring(missing.asset)
                    .. (missing.unreadable and ") could not be read (" .. tostring(why) .. "): downloaded again in daemon mode"
                        or missing.corrupt and ") is corrupt (" .. tostring(why) .. "): downloaded again in daemon mode"
                        or ") is not installed yet: downloaded in daemon mode"))
                sel.download = missing
                sel.source, sel.label = source, M.LABELS[source]
            else
                add(source, "absent", nil, why)
            end
        end
    end

    if sel.path and setting.source then
        local dir, why = source_dir(setting.source, opts)
        if dir then
            sel.env = { LOOMWORKS_LUA = dir }
        else
            sel.warning = sel.warning and (sel.warning .. "; " .. why) or why
        end
    end
    if not sel.path and not sel.note and not sel.download then sel.note = M.none_note(sel) end
    -- Only the plugin's managed lw resolves a channel (spec §19.16 "Channel
    -- upgrades"): an lw the user installed or named is theirs to update.
    if setting.channel and sel.path and sel.source ~= "managed" then
        sel.channel_note = "binary.channel = " .. setting.channel .. " has no effect: " .. tostring(sel.label)
            .. " is selected" .. (sel.source == "PATH" and " (binary.prefer = \"managed\" changes that)" or "")
    end
    return sel.path, sel.source, sel
end

--- The Runtime-line note for a selection that chose nothing: each source and
--- why it gave nothing.
--- @param sel? loomworks.provision.Selection
--- @return string
function M.none_note(sel)
    if not sel then return M.NONE_NOTE end
    if sel.note then return sel.note end
    if sel.download then
        local d = sel.download
        return "the plugin-managed lw v" .. tostring(d.version) .. " (" .. tostring(d.asset)
            .. (d.unreadable and ") could not be read — running in-process"
                or d.corrupt and ") is corrupt — running in-process" or ") is not installed yet — running in-process")
    end
    local parts = {}
    for _, c in ipairs(sel.candidates or {}) do
        parts[#parts + 1] = c.label .. ": " .. tostring(c.reason or c.verdict)
    end
    if #parts == 0 then return M.NONE_NOTE end
    return "no lw host binary (" .. table.concat(parts, "; ") .. ") — running in-process"
end

--- One line naming the chosen binary and why (the Runtime line while it
--- launches, `:LoomworksDaemon status`, checkhealth).
--- @param sel loomworks.provision.Selection
--- @return string
function M.describe(sel)
    if not sel.path then
        if sel.download then
            local d = sel.download
            return "lw v" .. tostring(d.version) .. " (" .. tostring(d.asset) .. "), downloaded first ("
                .. tostring(sel.label) .. ")"
        end
        return M.none_note(sel)
    end
    local s = sel.path .. " (" .. sel.label .. ")"
    if sel.env and sel.env.LOOMWORKS_LUA then s = s .. " with the Lua source " .. sel.env.LOOMWORKS_LUA end
    -- The pre-launch probe (step 5h.5): a verdict worth saying. (A skipped
    -- lw on PATH is the candidate's reason and the observer's `probe_note`.)
    local chosen
    for _, c in ipairs(sel.candidates or {}) do
        if c.verdict == "chosen" then chosen = c end
    end
    if sel.probe then
        s = s .. "; not probed yet"
    elseif chosen and chosen.probe and (chosen.probe.verdict ~= "compatible" or #chosen.probe.degraded > 0) then
        s = s .. "; probe: " .. require("loomworks.provision.probe").describe(chosen.probe)
    end
    return s
end

return M

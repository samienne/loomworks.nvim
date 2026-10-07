--- loomworks/provision/select.lua — which `lw` host binary the editor
--- launches the workspace daemon from (spec §19.16 "Host binary").
---
--- First match wins:
---   1. explicit: `LOOMWORKS_LW`, then the setup option `binary.path`. A value
---      naming no file is a note and stops the search (explicit means
---      explicit: the editor never runs another lw instead);
---   2. `lw` on the search path (on Windows only an `.exe`: a `.cmd` shim
---      cannot be started detached without a console);
---   3. the plugin-managed lw under the editor's data directory
---      (loomworks.provision.managed).
--- `binary.prefer = "managed"` puts 3 before 2. The editor reads no `lw.pin`:
--- a global or managed lw follows the repository's pin itself (§16.23).
--- `binary.source` (development only, never automatic) runs the selected
--- binary with a Lua source tree (`LOOMWORKS_LUA`, §16.11).
---
--- Compatibility is not probed here (step 5h.5); after connecting, the
--- daemon's handshake and `Root.describe` decide (§19.9, §19.20).

local uv = vim.uv or vim.loop

local M = {}

--- @alias loomworks.provision.Source "LOOMWORKS_LW"|"setting"|"PATH"|"managed"

--- @class loomworks.provision.BinarySetting  the setup option `binary`
--- @field path? string an lw host binary to use as is
--- @field prefer? "system"|"managed" which of `lw` on PATH and the plugin-managed lw comes first (default "system")
--- @field source? string|boolean development only: run the binary with this Lua tree (`true`: this plugin's)

--- @class loomworks.provision.Candidate  one step of the search
--- @field source loomworks.provision.Source
--- @field label string how the status page and checkhealth name it
--- @field path? string the binary it found
--- @field verdict "chosen"|"absent"|"refused"|"not tried"
--- @field reason? string why it was not chosen

--- @class loomworks.provision.Selection  the result of `resolve`
--- @field path? string the chosen host binary
--- @field source? loomworks.provision.Source
--- @field label? string
--- @field candidates loomworks.provision.Candidate[] every step, in search order
--- @field env? table<string, string> extra environment for the daemon (`binary.source`)
--- @field note? string why there is none (the Runtime line)
--- @field warning? string an ignored setup value

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

--- `lw` on the search path, or nil + why.
--- @param opts? { exepath?: fun(name: string): string, realpath?: fun(p: string): string|nil, win?: boolean }
--- @return string|nil path, string|nil why
function M.on_path(opts)
    opts = opts or {}
    local ok, exe = pcall(opts.exepath or vim.fn.exepath, "lw")
    if not ok or type(exe) ~= "string" or exe == "" then return nil, "no lw on the search path" end
    -- The binary itself, not PATH's spelling of it (`lw.EXE` via PATHEXT, a
    -- link): the daemon it starts then reports the executable the CLI does.
    local real = (opts.realpath or uv.fs_realpath)(exe)
    if type(real) == "string" and real ~= "" then exe = real end
    exe = slash(exe)
    local win = opts.win
    if win == nil then win = is_win() end
    if win and not exe:lower():match("%.exe$") then
        return nil, exe .. " is not an .exe (a script cannot start the daemon detached)"
    end
    return exe
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
---   on_path   fun() → path|nil, why
---   managed   fun() → path|nil, why (loomworks.provision.managed.find)
---   is_dir, plugin_lua  for `binary.source`
--- @param root string
--- @param opts? table
--- @return string|nil path, loomworks.provision.Source|nil source, loomworks.provision.Selection sel
function M.resolve(root, opts)
    local _ = root -- the workspace: no per-workspace source today (the editor reads no lw.pin)
    opts = opts or {}
    local setting, warning = M.check_setting(opts.setting)
    local getenv = opts.getenv or os.getenv
    local exists = opts.exists or is_file
    local sel = { candidates = {}, warning = warning }
    local function add(source, verdict, path, reason)
        sel.candidates[#sel.candidates + 1] = { source = source, label = M.LABELS[source],
            verdict = verdict, path = path, reason = reason }
    end
    local function choose(source, path)
        add(source, "chosen", path)
        sel.path, sel.source, sel.label = path, source, M.LABELS[source]
    end

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
            local p = slash(vim.fs.normalize(v))
            if exists(p) then
                choose(source, p)
            else
                add(source, "refused", p, "not a file")
                sel.note = string.format("%s names %s, which is not a file — no lw host binary "
                    .. "(an explicit lw is never replaced by another); running in-process", M.LABELS[source], p)
            end
        else
            add(source, "absent", nil, "not set")
        end
    end

    -- 2-3. The search path and the plugin-managed lw.
    for _, source in ipairs(order) do
        if sel.path or sel.note then
            add(source, "not tried", nil, "a source above decided")
        else
            local p, why
            if source == "PATH" then p, why = (opts.on_path or M.on_path)()
            else p, why = (opts.managed or require("loomworks.provision.managed").find)() end
            if p then choose(source, p) else add(source, "absent", nil, why) end
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
    if not sel.path and not sel.note then sel.note = M.none_note(sel) end
    return sel.path, sel.source, sel
end

--- The Runtime-line note for a selection that chose nothing: each source and
--- why it gave nothing.
--- @param sel? loomworks.provision.Selection
--- @return string
function M.none_note(sel)
    if not sel then return M.NONE_NOTE end
    if sel.note then return sel.note end
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
    if not sel.path then return M.none_note(sel) end
    local s = sel.path .. " (" .. sel.label .. ")"
    if sel.env and sel.env.LOOMWORKS_LUA then s = s .. " with the Lua source " .. sel.env.LOOMWORKS_LUA end
    return s
end

return M

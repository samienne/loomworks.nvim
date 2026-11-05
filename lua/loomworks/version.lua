--- loomworks/version.lua — the plugin's own version (spec §19.16): the
--- newest release heading of the plugin's `CHANGELOG.md`, with `+dev` when
--- an `## Unreleased` entry precedes it (a development checkout). It is what
--- the editor announces as its `lw_version` in `hello`, what the unloaded
--- status header shows, and what a version-mismatch note names as "this
--- plugin". The binary's own identity (its release or source fingerprint)
--- is the binary's business; the editor never compares it with this.

local M = {}

--- The directory holding this file (`<plugin>/lua/loomworks`), or nil.
--- @return string|nil
local function here()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) ~= "@" then return nil end
    return (src:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$"))
end

--- The plugin's Lua root (the directory holding `loomworks/`), or nil.
--- @return string|nil
function M.lua_root()
    local dir = here()
    return dir and dir:match("^(.*)/loomworks$") or nil
end

local function read_file(path)
    local fd = io.open(path, "rb")
    if not fd then return nil end
    local s = fd:read("*a")
    fd:close()
    return s
end

--- The version a CHANGELOG text names: its first release heading, `+dev`
--- when an `## Unreleased` heading comes first. nil when it names none.
--- @param text string|nil
--- @return string|nil
function M.parse(text)
    if type(text) ~= "string" then return nil end
    local unreleased = false
    for line in text:gmatch("[^\r\n]+") do
        local head = line:match("^##%s+(.-)%s*$")
        if head then
            if head:lower():match("^unreleased") then
                unreleased = true
            else
                local rel = head:match("^[vV]?(%d+%.%d+%.%d+[%w%.%-]*)")
                if rel then return unreleased and (rel .. "+dev") or rel end
            end
        end
    end
    return nil
end

local _version
--- The plugin's version (memoized), or nil when its CHANGELOG names none.
--- @return string|nil
function M.get()
    if _version == nil then
        local root = M.lua_root()
        local text = root and read_file(root .. "/../CHANGELOG.md") or nil
        _version = M.parse(text) or false
    end
    return _version or nil
end

--- Test seam: forget (or set) the memoized version.
--- @param v string|nil
function M._set(v) _version = v end

return M

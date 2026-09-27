--- loomworks/plugin_loader.lua — load a plugin file named by configuration.
---
--- Module / SDK provider / progress-parser ids come from workspace files
--- (`loomworks.json`, `.nvim/loomworks.user.json`, cache) — i.e. from a clone
--- that may be untrusted. A bare `require("loomworks.modules." .. id)` would
--- resolve the name through `package.path`, whose default (LuaJIT and Neovim)
--- begins with `./?.lua`: an id that no installed plugin ships then falls
--- through to a Lua file relative to the current directory. So configuration-
--- derived ids never go through `require`:
---
---   1. the id must be a plain identifier (`^[%w_]+$` — no dots, slashes, or
---      path syntax), else it is refused with a diagnostic;
---   2. the file is located on the runtime path only
---      (`nvim_get_runtime_file("lua/loomworks/<kind>/<id>.lua")` — in the
---      standalone host that is the system-Lua root, the fused bundle, and the
---      acquired-module roots; see shim `runtime_files`);
---   3. that exact file is loaded (`loadfile`, or the luvi bundle reader for a
---      bundle-relative entry) and cached in `package.loaded` under the same
---      module name, so a later static `require` of it yields the same table.
---
--- A module already in `package.loaded` (loaded by a static `require` from our
--- own code, or seeded by a test) is returned as is.

local M = {}

--- The id grammar for configuration-named plugin files.
M.ID_PATTERN = "^[%w_]+$"

--- Is `id` a syntactically valid plugin id?
--- @param id any
--- @return boolean
function M.valid_id(id)
    return type(id) == "string" and id:match(M.ID_PATTERN) ~= nil
end

--- Render a (possibly hostile) id for a diagnostic: quoted, with anything
--- outside printable ASCII escaped so it can never carry terminal control
--- sequences into a message.
--- @param id any
--- @return string
function M.display_id(id)
    local s = tostring(id)
    if #s > 64 then s = s:sub(1, 64) .. "..." end
    s = s:gsub("[%c\128-\255\"\\]", function(c) return ("\\x%02x"):format(c:byte()) end)
    return '"' .. s .. '"'
end

local function is_absolute(p)
    return p:match("^%a:[/\\]") ~= nil or p:match("^[/\\]") ~= nil
end

--- Load a chunk from a runtime-file path. In the standalone host a relative
--- entry is a luvi-bundle path (the shim lists bundle entries relative to the
--- bundle root); in the editor every runtime-path entry is a file on disk.
--- @param path string
--- @return function|nil chunk, string|nil err
local function load_chunk(path)
    if vim._loomworks_shim and not is_absolute(path) then
        -- `luvi` is a preloaded builtin in the standalone host; never resolve
        -- it through package.path.
        local luvi = package.loaded["luvi"]
            or (package.preload["luvi"] and package.preload["luvi"]("luvi"))
        local bundle = type(luvi) == "table" and luvi.bundle or nil
        local src = bundle and bundle.readfile and bundle.readfile(path)
        if not src then return nil, "cannot read bundle file '" .. path .. "'" end
        return loadstring(src, "bundle:" .. path)
    end
    return loadfile(path)
end

--- Load `loomworks.<kind>.<id>` from the runtime path.
---
--- Returns the module value, or nil plus a reason and a status:
---   * "invalid" — the id is not a plain identifier (never looked up);
---   * "missing" — no such file on the runtime path;
---   * "error"   — the file exists but failed to compile or run.
--- @param kind string "modules" | "sdks" | "progress"
--- @param id any
--- @return any|nil mod, string|nil err, "invalid"|"missing"|"error"|nil status
function M.load(kind, id)
    if not M.valid_id(id) then
        return nil, "invalid id " .. M.display_id(id)
            .. " (plugin ids are letters, digits and underscores only)", "invalid"
    end
    local modname = "loomworks." .. kind .. "." .. id
    local loaded = package.loaded[modname]
    if loaded ~= nil then return loaded end

    local files = vim.api.nvim_get_runtime_file("lua/loomworks/" .. kind .. "/" .. id .. ".lua", false)
    local path = files and files[1]
    if not path then
        return nil, "no lua/loomworks/" .. kind .. "/" .. id .. ".lua on the runtime path", "missing"
    end
    local chunk, cerr = load_chunk(path)
    if not chunk then return nil, tostring(cerr), "error" end
    local ok, mod = pcall(chunk, modname)
    if not ok then return nil, tostring(mod), "error" end
    if mod == nil then mod = true end
    package.loaded[modname] = mod
    return mod
end

return M

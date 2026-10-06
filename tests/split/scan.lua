--- Static scanner behind tests/split_boundary_spec.lua (ARCHITECTURE.md
--- "Plugin/binary boundary").
---
--- Run `nvim -l tests/split/scan.lua` from the repo root to print today's
--- edges, dynamic-require sites and reach-in counts in allowlist.lua format.
---
--- What is scanned, per plugin-side and shared file (whole-line `--` comments
--- are skipped):
---   * static requires: `require("x")`, `require('x')`, `require "x"`,
---     `require 'x'`, `pcall(require, "x")` (also with single quotes);
---   * dynamic requires: `require(<expr>)`, `pcall(require, <expr>)`, and a
---     string literal naming one of our module trees followed by `..`
---     (`"loomworks." .. name`, `"boot." .. x`). These are counted per file, since
---     the target cannot be known statically;
---   * reach-ins (plugin-side only): `core:`, `get_workspace(` and `._workspace`,
---     the ways the editor gets at binary-side domain objects without a require;
---   * interface references (plugin-side only, the interface ratchet of step
---     5g.3): `iface = "<name>", v = <n>` names an interface version; any other
---     quoted interface name (`"loomworks.<Upper>..."`, `"lw.<...>"`) is
---     unversioned. The guard checks each version has a schema and
---     transcripts under spec/protocol/.
---
--- Not caught: an aliased require (`local r = require; r("x")`),
--- `package.loaded[...]` / `package.preload[...]` lookups, `loadfile`/`dofile`,
--- requires inside `--[[ ]]` block comments or after code on the same line as a
--- trailing comment, and a binary-side module reached through a value another
--- module returns (e.g. a domain object passed in as an argument, other than
--- through the reach-in spellings above).

local M = {}

local function script_root()
    local src = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
    local dir = src:match("^(.*)/tests/split/[^/]*$")
    if dir and dir ~= "" then return dir end
    return (vim.fn.getcwd():gsub("\\", "/"))
end

M.root = script_root()
M.boundary = dofile(M.root .. "/tests/split/boundary.lua")

--- Repo-relative paths of every Lua file the guard covers.
function M.files()
    local out = {}
    for _, sub in ipairs({ "lua", "plugin" }) do
        local found = vim.fn.globpath(M.root .. "/" .. sub, "**/*.lua", false, true)
        for _, p in ipairs(found) do
            p = p:gsub("\\", "/")
            out[#out + 1] = p:sub(#M.root + 2)
        end
    end
    table.sort(out)
    return out
end

--- Module name of a `lua/` file, nil for other files.
function M.module_name(rel)
    local inner = rel:match("^lua/(.+)%.lua$")
    if not inner then return nil end
    inner = inner:gsub("/", ".")
    inner = inner:gsub("%.init$", "")
    return inner
end

--- Sides whose patterns match a module name (normally exactly one).
function M.sides_of(mod)
    local hits = {}
    for _, side in ipairs({ "plugin", "shared", "binary" }) do
        for _, pat in ipairs(M.boundary[side]) do
            if mod:match(pat) then
                hits[#hits + 1] = side
                break
            end
        end
    end
    return hits
end

--- Side of a repo-relative file: "plugin" for plugin/*.lua, else its module's.
function M.side_of_file(rel)
    if rel:match("^plugin/") then return "plugin" end
    local hits = M.sides_of(M.module_name(rel))
    return #hits == 1 and hits[1] or nil
end

local function code_lines(rel)
    local fh = assert(io.open(M.root .. "/" .. rel, "rb"))
    local text = fh:read("*a")
    fh:close()
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if not line:match("^%s*%-%-") then lines[#lines + 1] = line end
    end
    return lines
end

local STATIC = {
    'require%s*%(%s*"([^"]+)"%s*%)',
    "require%s*%(%s*'([^']+)'%s*%)",
    'require%s*"([^"]+)"',
    "require%s*'([^']+)'",
    'pcall%s*%(%s*require%s*,%s*"([^"]+)"%s*%)',
    "pcall%s*%(%s*require%s*,%s*'([^']+)'%s*%)",
}

local DYNAMIC = {
    "require%s*%(%s*[%a_]",
    "pcall%s*%(%s*require%s*,%s*[%a_]",
    "[\"'](loomworks%.[%w_.]*)[\"']%s*%.%.",
    "[\"'](boot%.[%w_.]*)[\"']%s*%.%.",
    "[\"'](loomtest%.[%w_.]*)[\"']%s*%.%.",
}

local REACH = {
    "%f[%w_]core:",
    "get_workspace%s*%(",
    "%._workspace%f[^%w_]",
}

local function count(line, pat)
    local n = 0
    for _ in line:gmatch(pat) do n = n + 1 end
    return n
end

--- Scan one file: sorted unique static targets, dynamic-site count, reach-ins.
function M.scan_file(rel)
    local targets, seen, dynamic, reach = {}, {}, 0, 0
    for _, line in ipairs(code_lines(rel)) do
        for _, pat in ipairs(STATIC) do
            for target in line:gmatch(pat) do
                if not seen[target] then
                    seen[target] = true
                    targets[#targets + 1] = target
                end
            end
        end
        for _, pat in ipairs(DYNAMIC) do dynamic = dynamic + count(line, pat) end
        for _, pat in ipairs(REACH) do reach = reach + count(line, pat) end
    end
    table.sort(targets)
    return targets, dynamic, reach
end

-- Interface references (the interface ratchet, step 5g.3): a versioned one
-- is `iface = "<name>", v = <n>` (the observer's interface tables); any other
-- quoted interface name (`"loomworks.Tasks"`, `"lw.internal.Snapshot"`) in
-- plugin-side code names no version and fails the guard.
local IFACE_VERSIONED = {
    'iface%s*=%s*"([%w_.]+)"%s*,%s*v%s*=%s*(%d+)',
    "iface%s*=%s*'([%w_.]+)'%s*,%s*v%s*=%s*(%d+)",
}
local IFACE_NAME = {
    '"(loomworks%.%u[%w_]*)"', "'(loomworks%.%u[%w_]*)'",
    '"(lw%.[%w_.]*%u[%w_]*)"', "'(lw%.[%w_.]*%u[%w_]*)'",
}

--- The interface versions a file names (`refs`, `{ iface, v, line }`) and
--- the interface names it quotes without a version (`unversioned`).
--- @param rel string
--- @return table[] refs, string[] unversioned
function M.interface_refs(rel)
    local refs, unversioned = {}, {}
    for n, line in ipairs(code_lines(rel)) do
        local rest = line
        for _, pat in ipairs(IFACE_VERSIONED) do
            for name, v in line:gmatch(pat) do refs[#refs + 1] = { iface = name, v = tonumber(v), line = n } end
            rest = rest:gsub(pat, "")
        end
        for _, pat in ipairs(IFACE_NAME) do
            for name in rest:gmatch(pat) do unversioned[#unversioned + 1] = name end
        end
    end
    return refs, unversioned
end

--- Current state of the tree.
--- @return table { unclassified, ambiguous, edges, dynamic, reach_ins, counts, interfaces }
---   `interfaces[rel]` = { refs, unversioned } of each plugin-side file naming one
function M.current()
    local res = {
        unclassified = {}, ambiguous = {}, edges = {}, dynamic = {}, reach_ins = {},
        counts = { plugin = 0, shared = 0, binary = 0 }, interfaces = {},
    }
    local files = M.files()
    local side_by_mod = {}
    for _, rel in ipairs(files) do
        local mod = M.module_name(rel)
        if mod then
            local hits = M.sides_of(mod)
            if #hits == 0 then
                res.unclassified[#res.unclassified + 1] = rel
            elseif #hits > 1 then
                res.ambiguous[#res.ambiguous + 1] = rel .. " (" .. table.concat(hits, ", ") .. ")"
            else
                side_by_mod[mod] = hits[1]
                res.counts[hits[1]] = res.counts[hits[1]] + 1
            end
        end
    end
    for _, rel in ipairs(files) do
        local side = M.side_of_file(rel)
        if side == "plugin" or side == "shared" then
            local targets, dynamic, reach = M.scan_file(rel)
            local bad = {}
            for _, t in ipairs(targets) do
                if side_by_mod[t] == "binary" then bad[#bad + 1] = t end
            end
            if #bad > 0 then res.edges[rel] = bad end
            if dynamic > 0 then res.dynamic[rel] = dynamic end
            if side == "plugin" and reach > 0 then res.reach_ins[rel] = reach end
            if side == "plugin" then
                local refs, unversioned = M.interface_refs(rel)
                if #refs > 0 or #unversioned > 0 then res.interfaces[rel] = { refs = refs, unversioned = unversioned } end
            end
        end
    end
    return res
end

local function sorted_keys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end
M.sorted_keys = sorted_keys

--- Today's state rendered in tests/split/allowlist.lua format.
function M.render(res)
    local out = { "return {", "    edges = {" }
    for _, rel in ipairs(sorted_keys(res.edges)) do
        out[#out + 1] = ('        ["%s"] = {'):format(rel)
        for _, t in ipairs(res.edges[rel]) do
            out[#out + 1] = ('            "%s",'):format(t)
        end
        out[#out + 1] = "        },"
    end
    out[#out + 1] = "    },"
    for _, key in ipairs({ "dynamic", "reach_ins" }) do
        out[#out + 1] = ("    %s = {"):format(key)
        for _, rel in ipairs(sorted_keys(res[key])) do
            out[#out + 1] = ('        ["%s"] = %d,'):format(rel, res[key][rel])
        end
        out[#out + 1] = "    },"
    end
    out[#out + 1] = "}"
    return table.concat(out, "\n")
end

if arg and arg[0] and arg[0]:gsub("\\", "/"):match("tests/split/scan%.lua$") then
    io.write(M.render(M.current()), "\n")
end

return M

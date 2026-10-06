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
-- is a table constructor holding both `iface = "<name>"` and `v = <n>`, in
-- either order and across lines (the observer's interface tables); any other
-- quoted interface name (`"loomworks.Tasks"`, `"lw.internal.Snapshot"`) in
-- plugin-side code names no version and fails the guard. An interface named
-- at run time — `iface = <expression>`, or an interface call (`:call(`)
-- whose interface argument is not a string literal — cannot be checked
-- statically: such sites are counted per file (`dynamic`) and must match the
-- `interfaces_dynamic` allowlist exactly, like dynamic requires.
-- (Blind spot, deferred to step 5j: the methods and signals called on a
-- versioned interface are not checked against its schema.)
local IFACE_FIELD = { '()iface%s*=%s*"([%w_.]+)"()', "()iface%s*=%s*'([%w_.]+)'()" }
local IFACE_NAME = {
    '"(loomworks%.%u[%w_]*)"', "'(loomworks%.%u[%w_]*)'",
    '"(lw%.[%w_.]*%u[%w_]*)"', "'(lw%.[%w_.]*%u[%w_]*)'",
}
local IFACE_DYNAMIC = {
    "%f[%w_]iface%s*=%s*[%a_]",                     -- iface = <expression>
    ":call%s*%(%s*[^,%)]+,%s*[^%s\"']",           -- conn:call(object, <expression>, ...)
}

--- The code of `rel` as one string, comment lines blanked (line numbers kept).
local function code_text(rel)
    local fh = assert(io.open(M.root .. "/" .. rel, "rb"))
    local text = fh:read("*a")
    fh:close()
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line:match("^%s*%-%-") and "" or line
    end
    return table.concat(lines, "\n")
end

--- The span `[open, close]` of the innermost `{ ... }` enclosing `pos`
--- (quoted strings skipped), or nil.
local function enclosing_table(text, pos)
    local stack, i, n = {}, 1, #text
    local open_at
    while i <= n do
        local c = text:sub(i, i)
        if c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = text:sub(j, j)
                if d == "\\" then j = j + 1 elseif d == c or d == "\n" then break end
                j = j + 1
            end
            i = j
        elseif c == "{" then
            stack[#stack + 1] = i
        elseif c == "}" then
            local o = table.remove(stack)
            if o and o < pos and i > pos and (not open_at or o > open_at[1]) then open_at = { o, i } end
        end
        i = i + 1
    end
    return open_at and open_at[1], open_at and open_at[2]
end

--- `v = <n>` at the top level of the table body text[open+1 .. close-1].
local function table_version(text, open, close)
    local depth, i = 0, open + 1
    while i < close do
        local c = text:sub(i, i)
        if c == "{" then depth = depth + 1
        elseif c == "}" then depth = depth - 1
        elseif depth == 0 and c == "v" and not text:sub(i - 1, i - 1):match("[%w_.]") then
            local v = text:sub(i, close):match("^v%s*=%s*(%d+)")
            if v then return tonumber(v) end
        end
        i = i + 1
    end
end

local function line_of(text, pos)
    local _, nl = text:sub(1, pos):gsub("\n", "")
    return nl + 1
end

--- The interface versions a file names (`refs`, `{ iface, v, line }`), the
--- interface names it quotes without a version (`unversioned`), and the
--- number of sites naming an interface at run time (`dynamic`).
--- @param rel string
--- @return table[] refs, string[] unversioned, integer dynamic
function M.interface_refs(rel)
    return M.interface_refs_text(code_text(rel))
end

--- `interface_refs` of a code text (comment lines already blanked).
--- @param text string
--- @return table[] refs, string[] unversioned, integer dynamic
function M.interface_refs_text(text)
    local refs, unversioned, dynamic = {}, {}, 0
    local covered = {}
    for _, pat in ipairs(IFACE_FIELD) do
        for pos, name, stop in text:gmatch(pat) do
            local open, close = enclosing_table(text, pos)
            local v = open and table_version(text, open, close)
            if v then
                refs[#refs + 1] = { iface = name, v = v, line = line_of(text, pos) }
                covered[#covered + 1] = { pos, stop }
            end
        end
    end
    local function is_covered(at)
        for _, c in ipairs(covered) do if at >= c[1] and at < c[2] then return true end end
        return false
    end
    for _, pat in ipairs(IFACE_NAME) do
        for at, name in text:gmatch("()" .. pat) do
            if not is_covered(at) then unversioned[#unversioned + 1] = name end
        end
    end
    for _, pat in ipairs(IFACE_DYNAMIC) do
        for _ in text:gmatch(pat) do dynamic = dynamic + 1 end
    end
    return refs, unversioned, dynamic
end

--- Current state of the tree.
--- @return table { unclassified, ambiguous, edges, dynamic, reach_ins, counts, interfaces }
---   `interfaces[rel]` = { refs, unversioned } of each plugin-side file naming one
function M.current()
    local res = {
        unclassified = {}, ambiguous = {}, edges = {}, dynamic = {}, reach_ins = {},
        counts = { plugin = 0, shared = 0, binary = 0 }, interfaces = {}, interfaces_dynamic = {},
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
                local refs, unversioned, idyn = M.interface_refs(rel)
                if #refs > 0 or #unversioned > 0 then res.interfaces[rel] = { refs = refs, unversioned = unversioned } end
                if idyn > 0 then res.interfaces_dynamic[rel] = idyn end
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
    for _, key in ipairs({ "dynamic", "reach_ins", "interfaces_dynamic" }) do
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

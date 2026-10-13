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
---     transcripts under spec/protocol/;
---   * editor operation call sites (step 5k), also in binary-side files: see
---     count_ops below.
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

-- Editor operation call sites (step 5k): the places the editor starts a
-- build / configure / clean / launch / debug in-process. Step 5k routes them
-- through the daemon (Build/1, Launch/1.prepare_run / prepare_debug), so
-- their count per file may only fall. Counted:
--   * in plugin-side and shared files: calls of the overseer entry points
--     (`run_profile_action`, `run_configuration_action`, `run_*_clean`,
--     `launch_single_task`, `launch_run_task`) and of the session start
--     (`<…>tracker.start(`), the nvim-dap session start (`debug_mod.run(`),
--     and the operation methods `:build(` / `:configure(` / `:clean(` /
--     `:launch(`, plus `:debug(` on a receiver named `*target` (the
--     LaunchTarget method; any other `:debug(` is a logger);
--   * in binary-side files: only the calls into those plugin-side starters
--     (the overseer entry points, `debug_mod.run(`, `tracker.start(`). A
--     binary-side module can only reach them from inside the editor, so each
--     is an in-process editor start living on the wrong side (e.g.
--     `LaunchTarget:launch` / `:debug` -> `overseer.launch_run_task` /
--     `debug_mod.run`), which 5k moves behind Launch/1. Binary-side
--     operation methods (`profile:build()`) are the domain's own, not counted.
-- A function's calls of its own module's helpers are not routing: an entry
-- point only counts through a receiver other than `M` (bare `launch_tasks(`,
-- overseer's internal helper, and `M.run_profile_action(` are skipped).
-- `require("loomworks.overseer")` / `"loomworks.debug"` /
-- `"loomworks.session_tracker"` read as `overseer` / `debug_mod` /
-- `session_tracker`. String contents and trailing `--` comments are blanked
-- before matching; a definition head (`function M.run_profile_action(`) is
-- not a site, but calls later on the same line are.
-- Not counted, on purpose: the device steps (`:device_install(`,
-- `:device_launch(`, `overseer.run_cmd_task(`). Device targets stay
-- in-process (decision D1 of step 5k), so they would put a floor under the
-- ceilings that 5k never lowers and hide whether the moved sites went.
-- Blind spots: a call through an alias (`local f = overseer.launch_run_task`),
-- the dap module or session tracker bound under another name (`local d =
-- require("loomworks.debug")`; overseer entry points count on any receiver
-- but `M`), a LaunchTarget held in a variable not named `*target`, a call
-- result as receiver for `:debug(`, and a string or comment spanning lines.
local REQ_ALIAS = {
    ["loomworks.overseer"] = "overseer",
    ["loomworks.debug"] = "debug_mod",
    ["loomworks.session_tracker"] = "session_tracker",
}
local ENTRY = {
    run_profile_action = true, run_configuration_action = true,
    run_profile_clean = true, run_configuration_clean = true,
    launch_single_task = true, launch_run_task = true,
}
local OP_METHODS = {
    "[%w_%]%)]%s*:build%s*%(",
    "[%w_%]%)]%s*:configure%s*%(",
    "[%w_%]%)]%s*:clean%s*%(",
    "[%w_%]%)]%s*:launch%s*%(",
}

--- `line` with known requires aliased, string contents blanked, a trailing
--- `--` comment and a leading definition head removed.
local function op_code(line)
    line = line:gsub("require%s*%(?%s*([\"'])([%w_.]+)%1%s*%)?", function(_, name)
        return REQ_ALIAS[name]
    end)
    local out, i, n = {}, 1, #line
    while i <= n do
        local c = line:sub(i, i)
        if c == "-" and line:sub(i + 1, i + 1) == "-" then break end
        if c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = line:sub(j, j)
                if d == "\\" then j = j + 2
                elseif d == c then break
                else j = j + 1 end
            end
            out[#out + 1] = c .. c
            i = j + 1
        elseif c == "[" and line:match("^%[=*%[", i) then
            local eq = line:match("^%[(=*)%[", i)
            local _, e = line:find("]" .. eq .. "]", i + #eq + 2, true)
            out[#out + 1] = '""'
            if not e then break end
            i = e + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    line = table.concat(out)
    line = line:gsub("^%s*local%s+function%s+[%w_]+%s*%(", "")
    line = line:gsub("^%s*function%s+[%w_.:]+%s*%(", "")
    return line
end
M.op_code = op_code

--- Editor operation call sites on one code line of a file on `side`
--- ("plugin" when nil; "binary" counts only calls into plugin-side starters).
local function count_ops(line, side)
    line = op_code(line)
    local n = 0
    for recv, name in line:gmatch("([%w_]+)%s*%.%s*([%w_]+)%s*%(") do
        if recv ~= "M" and ENTRY[name] then n = n + 1
        elseif recv == "debug_mod" and name == "run" then n = n + 1
        elseif recv:match("tracker$") and name == "start" then n = n + 1 end
    end
    if side == "binary" then return n end
    for _, pat in ipairs(OP_METHODS) do n = n + count(line, pat) end
    for recv in line:gmatch("([%w_]+)%s*:%s*debug%s*%(") do
        if recv:lower():match("target$") then n = n + 1 end
    end
    return n
end
M.count_ops = count_ops

--- Scan one file: sorted unique static targets, dynamic-site count, reach-ins,
--- editor operation call sites (counted by the rules of `side`, see count_ops).
function M.scan_file(rel, side)
    local targets, seen, dynamic, reach, ops = {}, {}, 0, 0, 0
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
        ops = ops + count_ops(line, side)
    end
    table.sort(targets)
    return targets, dynamic, reach, ops
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
-- Methods and signals (step 5j): a versioned table declares the `methods` the
-- file calls on it and the `signals` it handles (`methods = { "describe" }`,
-- string literals only); the guard checks each against the version's
-- transcripts (`uncovered`), and every interface call's method (the fourth
-- argument of `:call(`, a string literal) against the file's declarations.
-- (Blind spot: a signal handler is not matched to a declaration, since signal
-- dispatch has no scannable form, so `signals` is trusted as declared.)
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

--- The string literals of the list field `name = { "a", "b" }` at the top
--- level of the table body text[open+1 .. close-1]; nil without the field,
--- false when the list holds anything but string literals.
local function table_list(text, open, close, name)
    local depth, i = 0, open + 1
    while i < close do
        local c = text:sub(i, i)
        if c == "{" then depth = depth + 1
        elseif c == "}" then depth = depth - 1
        elseif depth == 0 and c == name:sub(1, 1) and not text:sub(i - 1, i - 1):match("[%w_.]") then
            local body = text:sub(i, close):match("^" .. name .. "%s*=%s*(%b{})")
            if body then
                local out, rest = {}, body:sub(2, -2)
                for _, s in rest:gmatch("([\"'])([%w_]*)%1") do out[#out + 1] = s end
                local left = rest:gsub("([\"'])[%w_]*%1", ""):gsub("[%s,;]", "")
                if left ~= "" then return false end
                return out
            end
        end
        i = i + 1
    end
end

-- An interface call (`:call(`) and its method, the fourth argument.
local CALL_SITE = ":call%s*%("
local CALL_METHOD = ":call%s*%(%s*[^,()]+,%s*[^,()]+,%s*[^,()]+,%s*([\"'])([%w_]+)%1"

--- The interface versions a file names (`refs`, `{ iface, v, line, object,
--- methods, signals }`, the last three as the table declares them), the
--- interface names it quotes without a version (`unversioned`), the number
--- of sites naming an interface at run time (`dynamic`) and its interface
--- calls (`calls`, `{ method, line }`, `method` nil when not a literal).
--- @param rel string
--- @return table[] refs, string[] unversioned, integer dynamic, table[] calls
function M.interface_refs(rel)
    return M.interface_refs_text(code_text(rel))
end

--- `interface_refs` of a code text (comment lines already blanked).
--- @param text string
--- @return table[] refs, string[] unversioned, integer dynamic, table[] calls
function M.interface_refs_text(text)
    local refs, unversioned, dynamic, calls = {}, {}, 0, {}
    local covered = {}
    for _, pat in ipairs(IFACE_FIELD) do
        for pos, name, stop in text:gmatch(pat) do
            local open, close = enclosing_table(text, pos)
            local v = open and table_version(text, open, close)
            if v then
                refs[#refs + 1] = {
                    iface = name, v = v, line = line_of(text, pos),
                    object = text:sub(open, close):match("[{,%s]object%s*=%s*[\"']([^\"']*)[\"']"),
                    methods = table_list(text, open, close, "methods"),
                    signals = table_list(text, open, close, "signals"),
                }
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
    for at in text:gmatch("()" .. CALL_SITE) do
        local _, method = text:match("^" .. CALL_METHOD, at)
        calls[#calls + 1] = { method = method, line = line_of(text, at) }
    end
    return refs, unversioned, dynamic, calls
end

--- What a decoded transcript file covers of interface `iface`/`v` on
--- `object`: the methods its cases `send` as calls and the signals they
--- `expect` (a signal frame naming the interface, or naming none but the
--- object). Sets keyed by name.
--- @param doc table
--- @param iface string
--- @param v integer
--- @param object string|nil
--- @return table<string, true> methods, table<string, true> signals
function M.transcript_coverage(doc, iface, v, object)
    local methods, signals = {}, {}
    for _, case in ipairs(type(doc) == "table" and type(doc.cases) == "table" and doc.cases or {}) do
        for _, step in ipairs(type(case) == "table" and type(case.steps) == "table" and case.steps or {}) do
            local s, e = step.send, step.expect
            if type(s) == "table" and s.kind == "call" and s.iface == iface and s.v == v
                and type(s.method) == "string" then
                methods[s.method] = true
            end
            if type(e) == "table" and e.kind == "signal" and type(e.name) == "string"
                and (e.iface == iface or (e.iface == nil and object ~= nil and e.object == object)) then
                signals[e.name] = true
            end
        end
    end
    return methods, signals
end

--- The declared uses of `ref` (an `interface_refs` entry) that its
--- transcripts do not cover, as `"<iface>/<v> method <name>"` and
--- `"<iface>/<v> signal <name>"`.
--- @param ref table
--- @param doc table the decoded transcripts of ref.iface / ref.v
--- @return string[]
function M.uncovered(ref, doc)
    local methods, signals = M.transcript_coverage(doc, ref.iface, ref.v, ref.object)
    local out = {}
    for _, m in ipairs(type(ref.methods) == "table" and ref.methods or {}) do
        if not methods[m] then out[#out + 1] = ("%s/%d method %s"):format(ref.iface, ref.v, m) end
    end
    for _, s in ipairs(type(ref.signals) == "table" and ref.signals or {}) do
        if not signals[s] then out[#out + 1] = ("%s/%d signal %s"):format(ref.iface, ref.v, s) end
    end
    return out
end

--- Current state of the tree.
--- @return table { unclassified, ambiguous, edges, dynamic, reach_ins, operation_sites, counts, interfaces }
---   `interfaces[rel]` = { refs, unversioned, calls } of each plugin-side file naming one
function M.current()
    local res = {
        unclassified = {}, ambiguous = {}, edges = {}, dynamic = {}, reach_ins = {}, operation_sites = {},
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
            local targets, dynamic, reach, ops = M.scan_file(rel, side)
            local bad = {}
            for _, t in ipairs(targets) do
                if side_by_mod[t] == "binary" then bad[#bad + 1] = t end
            end
            if #bad > 0 then res.edges[rel] = bad end
            if dynamic > 0 then res.dynamic[rel] = dynamic end
            if side == "plugin" and reach > 0 then res.reach_ins[rel] = reach end
            if ops > 0 then res.operation_sites[rel] = ops end
            if side == "plugin" then
                local refs, unversioned, idyn, calls = M.interface_refs(rel)
                if #refs > 0 or #unversioned > 0 or #calls > 0 then
                    res.interfaces[rel] = { refs = refs, unversioned = unversioned, calls = calls }
                end
                if idyn > 0 then res.interfaces_dynamic[rel] = idyn end
            end
        elseif side == "binary" then
            local _, _, _, ops = M.scan_file(rel, side)
            if ops > 0 then res.operation_sites[rel] = ops end
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
    for _, key in ipairs({ "dynamic", "reach_ins", "operation_sites", "interfaces_dynamic" }) do
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

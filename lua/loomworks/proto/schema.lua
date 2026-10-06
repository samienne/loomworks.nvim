--- loomworks/proto/schema.lua — the protocol's JSON Schema validator (spec
--- §19.20 "Schemas and conformance").
---
--- Implements exactly the restricted keyword set every interface document may
--- use — `type`, `properties`, `required`, `additionalProperties`, `items`,
--- `enum`, `const`, `oneOf`, `$ref`, `$defs`, `minimum`, `maximum`, `pattern`,
--- `description` — with JSON Schema 2020-12 semantics for those keywords. Pure
--- Lua (shared by the daemon and the plugin, runs under `nvim -l` and the luvi
--- host); the only `vim.*` it touches is the JSON null sentinel.
---
--- `pattern` takes the portable regular-expression subset `M.translate_pattern`
--- understands (anchors, literals, `.`, classes `[...]`, the escapes `\d \w \s`
--- and `\` + punctuation, and the quantifiers `* + ?` on a single atom — no
--- groups, alternation or counted repetition); the lint refuses any other
--- pattern, so every validator in every language reads it identically.
---
--- Values are decoded JSON: objects and arrays are Lua tables (an empty table
--- is both, unless it carries the empty-dict marker), JSON null is `vim.NIL`
--- (or nil inside a table).

local M = {}

--- The keywords a schema node may use.
M.KEYWORDS = {
    type = true, properties = true, required = true, additionalProperties = true,
    items = true, enum = true, const = true, oneOf = true, ["$ref"] = true,
    ["$defs"] = true, minimum = true, maximum = true, pattern = true, description = true,
}

local NIL = rawget(_G, "vim") and vim.NIL or nil
local EMPTY_DICT_MT = rawget(_G, "vim") and vim._empty_dict_mt or nil

local function is_null(v) return v == nil or (NIL ~= nil and v == NIL) end

--- Is the table a JSON array (a sequence 1..n, or empty without the dict marker)?
--- @param t table
--- @return boolean
function M.is_array(t)
    if type(t) ~= "table" or (NIL ~= nil and t == NIL) then return false end
    if next(t) == nil then return EMPTY_DICT_MT == nil or getmetatable(t) ~= EMPTY_DICT_MT end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
        n = n + 1
    end
    return n == #t
end

--- Is the table a JSON object (string keys only; an empty table is one)?
--- @param t table
--- @return boolean
function M.is_object(t)
    if type(t) ~= "table" or (NIL ~= nil and t == NIL) then return false end
    for k in pairs(t) do
        if type(k) ~= "string" then return false end
    end
    return true
end

--- The JSON type names a value has (an empty table is "object" and "array";
--- an integral number is "integer" and "number").
local function has_type(v, name)
    if name == "null" then return is_null(v) end
    if is_null(v) then return false end
    local lt = type(v)
    if name == "boolean" then return lt == "boolean" end
    if name == "string" then return lt == "string" end
    if name == "number" then return lt == "number" and v == v and v ~= math.huge and v ~= -math.huge end
    if name == "integer" then
        return lt == "number" and v == v and v ~= math.huge and v ~= -math.huge and v % 1 == 0
    end
    if name == "object" then return M.is_object(v) end
    if name == "array" then return M.is_array(v) end
    return false
end

local function type_text(v)
    if is_null(v) then return "null" end
    local lt = type(v)
    if lt == "table" then return M.is_array(v) and "array" or "object" end
    if lt == "number" then return v % 1 == 0 and "integer" or "number" end
    return lt
end

--- Deep equality of decoded JSON values.
--- @return boolean
function M.equal(a, b)
    if is_null(a) and is_null(b) then return true end
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not M.equal(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

local LUA_MAGIC = "^$()%.[]*+-?"

local function esc_lua(c)
    if LUA_MAGIC:find(c, 1, true) then return "%" .. c end
    return c
end

local ESCAPE_CLASS = { d = "%d", w = "[%w_]", s = "%s", D = "%D", W = "[^%w_]", S = "%S" }
local ESCAPE_IN_CLASS = { d = "%d", w = "%w_", s = "%s" }

--- Translate a portable regular expression (the subset described above) to
--- a Lua pattern. Returns nil + why for anything outside the subset.
--- @param re string
--- @return string|nil lua_pattern, string|nil err
function M.translate_pattern(re)
    if type(re) ~= "string" then return nil, "pattern is not a string" end
    local out, i, n = {}, 1, #re
    local atom_open = false -- the previous token is an atom a quantifier may follow
    while i <= n do
        local c = re:sub(i, i)
        if c == "^" and i == 1 then
            out[#out + 1] = "^"; atom_open = false
        elseif c == "$" and i == n then
            out[#out + 1] = "$"; atom_open = false
        elseif c == "\\" then
            local e = re:sub(i + 1, i + 1)
            if e == "" then return nil, "trailing backslash" end
            if ESCAPE_CLASS[e] then
                out[#out + 1] = ESCAPE_CLASS[e]
            elseif e:match("%p") then
                out[#out + 1] = esc_lua(e)
            else
                return nil, "unsupported escape \\" .. e
            end
            i = i + 1; atom_open = true
        elseif c == "[" then
            local j, cls = i + 1, { "[" }
            if re:sub(j, j) == "^" then cls[#cls + 1] = "^"; j = j + 1 end
            local closed = false
            while j <= n do
                local d = re:sub(j, j)
                if d == "]" and #cls > 1 and not (#cls == 2 and cls[2] == "^") then closed = true; break end
                if d == "\\" then
                    local e = re:sub(j + 1, j + 1)
                    if ESCAPE_IN_CLASS[e] then cls[#cls + 1] = ESCAPE_IN_CLASS[e]
                    elseif e ~= "" and e:match("%p") then cls[#cls + 1] = "%" .. e
                    else return nil, "unsupported escape in class \\" .. e end
                    j = j + 2
                elseif d == "-" and #cls > 1 and re:sub(j + 1, j + 1) ~= "]" then
                    cls[#cls + 1] = "-"; j = j + 1
                elseif d == "[" then
                    return nil, "nested class"
                else
                    cls[#cls + 1] = d:match("%w") and d or ("%" .. d)
                    j = j + 1
                end
            end
            if not closed then return nil, "unterminated class" end
            cls[#cls + 1] = "]"
            out[#out + 1] = table.concat(cls)
            i = j; atom_open = true
        elseif c == "*" or c == "+" or c == "?" then
            if not atom_open then return nil, "quantifier without an atom" end
            out[#out + 1] = (c == "*") and "*" or c == "+" and "+" or "?"
            atom_open = false
        elseif c == "(" or c == ")" or c == "|" or c == "{" or c == "}" then
            return nil, "unsupported construct '" .. c .. "'"
        elseif c == "." then
            out[#out + 1] = "."; atom_open = true
        elseif c == "^" or c == "$" then
            return nil, "anchor '" .. c .. "' in the middle"
        else
            out[#out + 1] = esc_lua(c); atom_open = true
        end
        i = i + 1
    end
    return table.concat(out)
end

local pattern_cache = {}
local function match_pattern(re, s)
    local p = pattern_cache[re]
    if p == nil then
        p = M.translate_pattern(re) or false
        pattern_cache[re] = p
    end
    if not p then return false end
    return s:find(p) ~= nil
end

-- ---------------------------------------------------------------------------
-- References
-- ---------------------------------------------------------------------------

local function unescape_pointer(s)
    return (s:gsub("~1", "/"):gsub("~0", "~"))
end

--- Walk a JSON pointer (`/a/b`) into a document.
--- @param doc table
--- @param pointer string
--- @return any|nil
function M.pointer(doc, pointer)
    if pointer == "" or pointer == "/" then return doc end
    local node = doc
    for part in pointer:gmatch("[^/]+") do
        if type(node) ~= "table" then return nil end
        part = unescape_pointer(part)
        local nk = tonumber(part)
        local nxt = node[part]
        if nxt == nil and nk and M.is_array(node) then nxt = node[nk + 1] end
        node = nxt
        if node == nil then return nil end
    end
    return node
end

--- Resolve a `$ref` relative to the document holding it: `#/...` is local;
--- `<doc>#/...` names another document through `resolve_doc(name, base)`,
--- which returns that document (and its own base, for its local refs).
--- @param ref string
--- @param ctx { doc: table, base: any, resolve_doc?: fun(name: string, base: any): table|nil, any }
--- @return table|nil node, table|nil ctx_of_node, string|nil err
function M.resolve_ref(ref, ctx)
    local docname, pointer = ref:match("^([^#]*)#(.*)$")
    if not docname then docname, pointer = ref, "" end
    local doc, base = ctx.doc, ctx.base
    if docname ~= "" then
        if not ctx.resolve_doc then return nil, nil, "no resolver for " .. ref end
        doc, base = ctx.resolve_doc(docname, ctx.base)
        if not doc then return nil, nil, "unresolved document " .. docname end
    end
    local node = M.pointer(doc, pointer)
    if type(node) ~= "table" then return nil, nil, "unresolved reference " .. ref end
    if doc == ctx.doc then return node, ctx end
    return node, { doc = doc, base = base, resolve_doc = ctx.resolve_doc }
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

local function at(path) return path == "" and "/" or path end



local function check(node, v, path, ctx, depth)
    if depth > 64 then return false, at(path) .. ": schema nesting too deep" end
    if type(node) == "boolean" then
        if node then return true end
        return false, at(path) .. ": not allowed"
    end
    if type(node) ~= "table" then return true end
    if node["$ref"] ~= nil then
        local target, tctx, err = M.resolve_ref(node["$ref"], ctx)
        if not target then return false, at(path) .. ": " .. err end
        local ok, verr = check(target, v, path, tctx, depth + 1)
        if not ok then return false, verr end
    end
    local t = node.type
    if t ~= nil then
        local names = type(t) == "table" and t or { t }
        local okt = false
        for _, name in ipairs(names) do
            if has_type(v, name) then okt = true; break end
        end
        if not okt then
            return false, string.format("%s: expected %s, got %s", at(path), table.concat(names, " or "), type_text(v))
        end
    end
    if node.const ~= nil and not M.equal(node.const, v) then
        return false, at(path) .. ": does not equal the constant " .. tostring(type(node.const) == "table" and "value" or node.const)
    end
    if node.enum ~= nil then
        local found = false
        for _, e in ipairs(node.enum) do
            if M.equal(e, v) then found = true; break end
        end
        if not found then return false, at(path) .. ": " .. tostring(type(v) == "table" and type_text(v) or v) .. " is not one of the allowed values" end
    end
    if type(v) == "number" then
        if node.minimum ~= nil and v < node.minimum then return false, at(path) .. ": below the minimum " .. node.minimum end
        if node.maximum ~= nil and v > node.maximum then return false, at(path) .. ": above the maximum " .. node.maximum end
    end
    if type(v) == "string" and node.pattern ~= nil and not match_pattern(node.pattern, v) then
        return false, at(path) .. ": does not match the pattern " .. node.pattern
    end
    if type(v) == "table" and not is_null(v) then
        if M.is_object(v) then
            if node.required ~= nil then
                for _, name in ipairs(node.required) do
                    if v[name] == nil then
                        return false, at(path) .. ": missing required property '" .. name .. "'"
                    end
                end
            end
            local props = node.properties
            local addl = node.additionalProperties
            local names = {}
            for k in pairs(v) do names[#names + 1] = k end
            table.sort(names)
            for _, k in ipairs(names) do
                local sub = props and props[k]
                local p = path .. "/" .. k
                if sub ~= nil then
                    local ok, err = check(sub, v[k], p, ctx, depth + 1)
                    if not ok then return false, err end
                elseif addl == false then
                    return false, at(path) .. ": unknown property '" .. k .. "'"
                elseif type(addl) == "table" then
                    local ok, err = check(addl, v[k], p, ctx, depth + 1)
                    if not ok then return false, err end
                end
            end
        end
        if M.is_array(v) and node.items ~= nil then
            for i = 1, #v do
                local ok, err = check(node.items, v[i], path .. "/" .. (i - 1), ctx, depth + 1)
                if not ok then return false, err end
            end
        end
    end
    if node.oneOf ~= nil then
        local matched, first_err = 0, nil
        for _, branch in ipairs(node.oneOf) do
            local ok, err = check(branch, v, path, ctx, depth + 1)
            if ok then matched = matched + 1 elseif not first_err then first_err = err end
        end
        if matched ~= 1 then
            if matched == 0 then
                return false, at(path) .. ": matches none of the alternatives (first: " .. tostring(first_err) .. ")"
            end
            return false, at(path) .. ": matches " .. matched .. " alternatives, expected exactly one"
        end
    end
    return true
end


--- Validate `value` against `schema`. `opts.doc` is the document the schema
--- belongs to (for `#/...` references; default the schema itself),
--- `opts.base` that document's identity and `opts.resolve_doc(name, base)` a
--- resolver of cross-document references.
--- @param schema table|boolean
--- @param value any
--- @param opts? { doc?: table, base?: any, resolve_doc?: fun(name: string, base: any): table|nil, any }
--- @return boolean ok, string|nil err the first violation: "<json pointer>: <what>"
function M.validate(schema, value, opts)
    opts = opts or {}
    local ctx = { doc = opts.doc or schema, base = opts.base, resolve_doc = opts.resolve_doc }
    return check(schema, value, "", ctx, 0)
end

return M

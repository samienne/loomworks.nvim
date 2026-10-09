--- Guard test for the plugin/binary split (ARCHITECTURE.md "Plugin/binary
--- boundary"). Static scan only: no workspace, no build.
---
---   tests/split/boundary.lua   which side every lua/ module is on
---   tests/split/allowlist.lua  today's coupling, which may only shrink
---   tests/split/scan.lua       the scanner (and its documented blind spots)

local scan = dofile((debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
    :gsub("split_boundary_spec%.lua$", "split/scan.lua")))
local allow = dofile(scan.root .. "/tests/split/allowlist.lua")

local SEE = "See ARCHITECTURE.md \"Plugin/binary boundary\"."
local RULE = "The Neovim plugin may reach the `lw` binary's code only through the "
    .. "daemon protocol; it must not gain new requires of binary-side modules or new "
    .. "reach-ins to domain objects. " .. SEE

local function fail(title, lines, hint)
    error(("%s\n  %s\n%s"):format(title, table.concat(lines, "\n  "), hint), 0)
end

local current = scan.current()

describe("plugin/binary boundary", function()
    it("classifies every module under lua/ exactly once", function()
        if #current.unclassified > 0 then
            fail("Modules on no side of the plugin/binary split:", current.unclassified,
                "Add a pattern for each to tests/split/boundary.lua (plugin, shared or "
                .. "binary). " .. SEE)
        end
        if #current.ambiguous > 0 then
            fail("Modules matched by more than one side:", current.ambiguous,
                "Make the patterns in tests/split/boundary.lua disjoint. " .. SEE)
        end
        assert.is_true(current.counts.plugin > 0 and current.counts.binary > 0)
    end)

    it("adds no plugin->binary or shared->binary require edges (ratchet 1)", function()
        local new, stale = {}, {}
        local allowed = allow.edges or {}
        for _, rel in ipairs(scan.sorted_keys(current.edges)) do
            local ok = {}
            for _, t in ipairs(allowed[rel] or {}) do ok[t] = true end
            for _, t in ipairs(current.edges[rel]) do
                if not ok[t] then new[#new + 1] = rel .. " -> " .. t end
            end
        end
        for _, rel in ipairs(scan.sorted_keys(allowed)) do
            local now = {}
            for _, t in ipairs(current.edges[rel] or {}) do now[t] = true end
            for _, t in ipairs(allowed[rel]) do
                if not now[t] then stale[#stale + 1] = rel .. " -> " .. t end
            end
        end
        if #new > 0 then
            fail("New require of a binary-side module from plugin/shared code:", new, RULE)
        end
        if #stale > 0 then
            fail("Allow-listed edges that no longer exist:", stale,
                "Good: delete them from `edges` in tests/split/allowlist.lua so the "
                .. "list keeps shrinking. " .. SEE)
        end
    end)

    it("adds no dynamic requires in plugin/shared code", function()
        local diff = {}
        local keys, seen = {}, {}
        for _, t in ipairs({ current.dynamic, allow.dynamic or {} }) do
            for rel in pairs(t) do
                if not seen[rel] then seen[rel] = true; keys[#keys + 1] = rel end
            end
        end
        table.sort(keys)
        for _, rel in ipairs(keys) do
            local now, rec = current.dynamic[rel] or 0, (allow.dynamic or {})[rel] or 0
            if now ~= rec then
                diff[#diff + 1] = ("%s: %d now, %d recorded"):format(rel, now, rec)
            end
        end
        if #diff > 0 then
            fail("Dynamic require sites changed (target not statically checkable):", diff,
                "A new one must be shown not to load binary-side code, then recorded; a "
                .. "removed one is deleted from `dynamic` in tests/split/allowlist.lua. "
                .. SEE)
        end
    end)

    -- The interface ratchet (spec §19.19 step 5g.3, §19.20): every interface
    -- the plugin calls or subscribes to is named with its version, and that
    -- version has a schema and conformance transcripts under spec/protocol/.
    it("names only interface versions with a schema and transcripts (interface ratchet)", function()
        local bad = {}
        local function exists(rel)
            local fh = io.open(scan.root .. "/spec/protocol/" .. rel, "rb")
            if fh then fh:close() end
            return fh ~= nil
        end
        local n = 0
        for _, rel in ipairs(scan.sorted_keys(current.interfaces)) do
            local e = current.interfaces[rel]
            for _, name in ipairs(e.unversioned) do
                bad[#bad + 1] = ("%s: %q names no interface version (write `iface = %q, v = <n>`)")
                    :format(rel, name, name)
            end
            for _, r in ipairs(e.refs) do
                n = n + 1
                local ns, rest = r.iface:match("^([%w_]+)%.(.+)$")
                local schema = ns and ("interfaces/%s/%s.%d.json"):format(ns, rest, r.v)
                local transcripts = ns and ("transcripts/%s/%s.%d.json"):format(ns, rest, r.v)
                if not (schema and exists(schema)) then
                    bad[#bad + 1] = ("%s:%d: %s/%d has no schema (spec/protocol/%s)"):format(rel, r.line, r.iface,
                        r.v, tostring(schema))
                end
                if not (transcripts and exists(transcripts)) then
                    bad[#bad + 1] = ("%s:%d: %s/%d has no transcripts (spec/protocol/%s)"):format(rel, r.line,
                        r.iface, r.v, tostring(transcripts))
                end
            end
        end
        if #bad > 0 then
            fail("Plugin-side interface references without a schema'd, transcribed version:", bad,
                "The plugin may call an interface only at a version the protocol defines (spec/protocol/). " .. SEE)
        end
        -- The observer's subscriptions are the first such references.
        assert.is_true(n >= 3)
    end)

    it("names interfaces at run time only at the allow-listed sites (interface ratchet)", function()
        local diff, keys, seen = {}, {}, {}
        local rec_all = allow.interfaces_dynamic or {}
        for _, t in ipairs({ current.interfaces_dynamic, rec_all }) do
            for rel in pairs(t) do
                if not seen[rel] then seen[rel] = true; keys[#keys + 1] = rel end
            end
        end
        table.sort(keys)
        for _, rel in ipairs(keys) do
            local now, rec = current.interfaces_dynamic[rel] or 0, rec_all[rel] or 0
            if now ~= rec then diff[#diff + 1] = ("%s: %d now, %d recorded"):format(rel, now, rec) end
        end
        if #diff > 0 then
            fail("Sites naming a daemon interface at run time changed (not statically checkable):", diff,
                "A new one must be shown to resolve to a versioned `{ iface = ..., v = <n> }` table, then "
                .. "recorded in `interfaces_dynamic` in tests/split/allowlist.lua; a removed one is deleted. " .. SEE)
        end
    end)

    -- Step 5j: each versioned table declares the methods the file calls on it
    -- and the signals it handles; every interface call's method is a declared
    -- literal, and every declared one is exercised by the version's transcripts.
    it("calls only methods its interface tables declare (interface ratchet, 5j)", function()
        local bad = {}
        for _, rel in ipairs(scan.sorted_keys(current.interfaces)) do
            local e = current.interfaces[rel]
            local declared = {}
            for _, r in ipairs(e.refs) do
                for _, field in ipairs({ "methods", "signals" }) do
                    local list = r[field]
                    if list == nil then
                        bad[#bad + 1] = ("%s:%d: %s/%d declares no `%s` (write `%s = { ... }`, empty if none)")
                            :format(rel, r.line, r.iface, r.v, field, field)
                    elseif list == false then
                        bad[#bad + 1] = ("%s:%d: %s/%d `%s` is not a list of string literals")
                            :format(rel, r.line, r.iface, r.v, field)
                    end
                end
                for _, m in ipairs(r.methods or {}) do declared[m] = true end
            end
            for _, c in ipairs(e.calls or {}) do
                if not c.method then
                    bad[#bad + 1] = ("%s:%d: an interface call whose method is not a string literal"):format(rel, c.line)
                elseif not declared[c.method] then
                    bad[#bad + 1] = ("%s:%d: calls method %q, which no interface table in the file declares in `methods`")
                        :format(rel, c.line, c.method)
                end
            end
        end
        if #bad > 0 then
            fail("Plugin-side interface uses not declared on a versioned interface table:", bad,
                "Declare on the `{ iface = ..., v = <n> }` table the `methods` the file calls and the `signals` "
                .. "it handles, so the guard can check them against the transcripts. " .. SEE)
        end
    end)

    it("uses only methods and signals its versions' transcripts cover (interface ratchet, 5j)", function()
        local found, seen, checked = {}, {}, 0
        for _, rel in ipairs(scan.sorted_keys(current.interfaces)) do
            for _, r in ipairs(current.interfaces[rel].refs) do
                local ns, rest = r.iface:match("^([%w_]+)%.(.+)$")
                local fh = ns and io.open(("%s/spec/protocol/transcripts/%s/%s.%d.json")
                    :format(scan.root, ns, rest, r.v), "rb")
                if fh then -- (a missing file fails the ratchet above)
                    local doc = vim.json.decode(fh:read("*a"))
                    fh:close()
                    checked = checked + #(r.methods or {}) + #(r.signals or {})
                    for _, u in ipairs(scan.uncovered(r, doc)) do
                        if not seen[u] then seen[u] = rel .. ":" .. r.line; found[#found + 1] = u end
                    end
                end
            end
        end
        table.sort(found)
        local rec, recset = allow.transcripts_uncovered or {}, {}
        local new, stale = {}, {}
        for _, u in ipairs(rec) do recset[u] = true end
        for _, u in ipairs(found) do
            if not recset[u] then new[#new + 1] = ("%s (declared at %s)"):format(u, seen[u]) end
        end
        for _, u in ipairs(rec) do
            if not seen[u] then stale[#stale + 1] = u end
        end
        if #new > 0 then
            fail("Plugin-side interface uses no transcript of that version exercises:", new,
                "Add a case to spec/protocol/transcripts/<namespace>/<Rest>.<v>.json that sends the method "
                .. "(a `call`) or expects the signal, so client and server conformance cover it. " .. SEE)
        end
        if #stale > 0 then
            fail("Recorded uncovered uses that are now covered or no longer used:", stale,
                "Good: delete them from `transcripts_uncovered` in tests/split/allowlist.lua. " .. SEE)
        end
        -- Root's describe and subscribe and Workspace's changed, at least.
        assert.is_true(checked >= 3)
    end)

    it("the coverage check names the interface, version and missing method or signal", function()
        local ref = { iface = "loomworks.Foo", v = 2, object = "/foo",
            methods = { "get", "set" }, signals = { "changed", "gone" } }
        local doc = { cases = {
            { steps = {
                { send = { kind = "call", object = "/foo", iface = "loomworks.Foo", v = 2, method = "get" } },
                -- Another version's or interface's call covers nothing here.
                { send = { kind = "call", object = "/foo", iface = "loomworks.Foo", v = 1, method = "set" } },
                { send = { kind = "call", object = "/", iface = "loomworks.Root", v = 2, method = "set" } },
                -- A signal frame naming no interface counts on the interface's object.
                { expect = { kind = "signal", object = "/foo", name = "changed" } },
                { expect_none = { kind = "signal", object = "/foo", name = "gone" } },
            } },
        } }
        assert.same({ "loomworks.Foo/2 method set", "loomworks.Foo/2 signal gone" }, scan.uncovered(ref, doc))
        ref.methods, ref.signals = { "get" }, { "changed" }
        assert.same({}, scan.uncovered(ref, doc))
        assert.same({ "loomworks.Foo/2 method get" }, scan.uncovered({ iface = "loomworks.Foo", v = 2,
            methods = { "get" } }, { cases = {} }))
    end)

    it("the interface scanner reads declared methods and signals and interface calls' methods", function()
        local r, _, _, calls = scan.interface_refs_text(table.concat({
            "M.A = {",
            '    object = "/a", iface = "loomworks.A", v = 1,',
            '    methods = { "describe", "subscribe" }, signals = {},',
            "}",
            'M.B = { iface = "loomworks.B", v = 1, methods = { name } }',
            'conn:call(M.A.object, M.A.iface, M.A.v, "describe", {}, cb)',
            "conn:call(M.A.object, M.A.iface, M.A.v, method, {}, cb)",
        }, "\n"))
        assert.equals(2, #r)
        assert.equals("/a", r[1].object)
        assert.same({ "describe", "subscribe" }, r[1].methods)
        assert.same({}, r[1].signals)
        assert.is_false(r[2].methods)
        assert.is_nil(r[2].signals)
        assert.same({ { method = "describe", line = 6 }, { line = 7 } }, calls)
    end)

    it("the interface scanner: either field order, tables across lines, runtime names counted", function()
        local function refs(text)
            local r, u, d = scan.interface_refs_text(text)
            local out = {}
            for _, x in ipairs(r) do out[#out + 1] = x.iface .. "/" .. x.v .. "@" .. x.line end
            return out, u, d
        end
        local r, u, d = refs('local A = { v = 2, object = "/x", iface = "loomworks.Foo" }')
        assert.same({ "loomworks.Foo/2@1" }, r); assert.same({}, u); assert.equals(0, d)
        r, u = refs(table.concat({ "local A = {", '    iface = "loomworks.Foo",', '    object = "/x",',
            "    v = 3,", "}" }, "\n"))
        assert.same({ "loomworks.Foo/3@2" }, r); assert.same({}, u)
        -- A `v` of a nested table or another field (`dev = 1`) is not the version.
        r, u = refs('local A = { iface = "loomworks.Foo", opts = { v = 1 }, dev = 1 }')
        assert.same({}, r); assert.same({ "loomworks.Foo" }, u)
        -- A bare quoted name names no version.
        r, u = refs('conn:call("/x", "loomworks.Foo", 1, "m", {}, cb)')
        assert.same({}, r); assert.same({ "loomworks.Foo" }, u)
        -- Runtime names: `iface = <expression>` and a call through a variable.
        local _, _, n = refs(table.concat({ "local a = { iface = want.iface, v = want.v }",
            'conn:call(o, name, 1, "m", {}, cb)' }, "\n"))
        assert.equals(2, n)
    end)

    it("does not raise domain reach-ins per plugin file (ratchet 2)", function()
        local rose, dropped = {}, {}
        local ceil = allow.reach_ins or {}
        for _, rel in ipairs(scan.sorted_keys(current.reach_ins)) do
            local now, max = current.reach_ins[rel], ceil[rel] or 0
            if now > max then
                rose[#rose + 1] = ("%s: %d sites, ceiling %d"):format(rel, now, max)
            end
        end
        for _, rel in ipairs(scan.sorted_keys(ceil)) do
            local now = current.reach_ins[rel] or 0
            if now < ceil[rel] then
                dropped[#dropped + 1] = ("%s: %d sites, ceiling %d"):format(rel, now, ceil[rel])
            end
        end
        if #rose > 0 then
            fail("More `core:` / `get_workspace(` / `._workspace` reach-ins than recorded:",
                rose, RULE)
        end
        if #dropped > 0 then
            fail("Reach-ins dropped below the recorded ceiling:", dropped,
                "Good: lower (or delete) the number in `reach_ins` in "
                .. "tests/split/allowlist.lua so it cannot creep back. " .. SEE)
        end
    end)
end)

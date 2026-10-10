-- The protocol's schema documents and their tooling (spec §19.20 "Schemas and
-- conformance"; step 5g.1): the validator over the restricted keyword set, the
-- lint of every document under spec/protocol, and the additive ratchet of
-- every frozen interface version against its current document.

local uv = vim.uv or vim.loop
local schema = require("loomworks.proto.schema")
local documents = require("loomworks.proto.documents")
local check = require("loomworks.proto.schema_check")

local DIR = documents.dir()

--- Every *.json under `dir`, as paths relative to it.
local function json_files(dir, rel, out)
    out = out or {}
    local h = uv.fs_scandir(dir .. (rel ~= "" and ("/" .. rel) or ""))
    if not h then return out end
    while true do
        local name, typ = uv.fs_scandir_next(h)
        if not name then break end
        local r = rel ~= "" and (rel .. "/" .. name) or name
        if typ == "directory" then json_files(dir, r, out)
        elseif name:sub(-5) == ".json" then out[#out + 1] = r end
    end
    table.sort(out)
    return out
end

--- A document set over in-memory documents (relative path -> table).
local function mem_set(docs)
    return documents.set(function(rel)
        if docs[rel] then return vim.json.encode(docs[rel]) end
        return nil, "no " .. rel
    end)
end

describe("schema validator (restricted keyword set)", function()
    local function ok(s, v) return (schema.validate(s, v)) end

    it("checks types, integers, null and the empty table", function()
        assert.is_true(ok({ type = "integer" }, 3))
        assert.is_false(ok({ type = "integer" }, 3.5))
        assert.is_true(ok({ type = "number" }, 3.5))
        assert.is_true(ok({ type = { "string", "null" } }, vim.NIL))
        assert.is_false(ok({ type = "string" }, vim.NIL))
        assert.is_true(ok({ type = "object" }, vim.empty_dict()))
        assert.is_true(ok({ type = "array" }, {}))
        assert.is_false(ok({ type = "array" }, vim.empty_dict()))
        -- A decoded [] is an array, never an object; a decoded {} the reverse.
        assert.is_false(ok({ type = "object" }, vim.json.decode("[]")))
        assert.is_true(ok({ type = "object" }, vim.json.decode("{}")))
        local either = { oneOf = { { type = "object" }, { type = "array" } } }
        assert.is_true(ok(either, vim.json.decode("[]")))
        assert.is_true(ok(either, vim.json.decode("{}")))
        assert.is_false(ok({ type = "object" }, { 1, 2 }))
        assert.is_false(ok({ type = "array" }, { a = 1 }))
    end)

    it("checks properties, required and additionalProperties, naming the first violation", function()
        local s = { type = "object", required = { "a" }, additionalProperties = false,
            properties = { a = { type = "string" }, b = { type = "array", items = { type = "integer" } } } }
        assert.is_true(ok(s, { a = "x", b = { 1, 2 } }))
        local _, err = schema.validate(s, { b = {} })
        assert.equals("/: missing required property 'a'", err)
        _, err = schema.validate(s, { a = "x", c = 1 })
        assert.equals("/: unknown property 'c'", err)
        _, err = schema.validate(s, { a = "x", b = { 1, "2" } })
        assert.equals("/b/1: expected integer, got string", err)
        assert.is_true(ok({ type = "object", additionalProperties = { type = "string" } }, { x = "y" }))
        assert.is_false(ok({ type = "object", additionalProperties = { type = "string" } }, { x = 1 }))
    end)

    it("checks enum, const, minimum, maximum and oneOf (exactly one)", function()
        assert.is_true(ok({ enum = { "a", "b" } }, "b"))
        assert.is_false(ok({ enum = { "a", "b" } }, "c"))
        assert.is_true(ok({ const = { x = 1 } }, { x = 1 }))
        assert.is_false(ok({ const = 2 }, 3))
        assert.is_false(ok({ minimum = 1 }, 0))
        assert.is_false(ok({ maximum = 1 }, 2))
        local one = { oneOf = { { type = "string" }, { type = "integer" }, { type = "number" } } }
        assert.is_true(ok(one, "x"))
        assert.is_false(ok(one, 3)) -- integer and number both match
        assert.is_true(ok(one, 3.5))
    end)

    it("translates the portable pattern subset and refuses the rest", function()
        assert.is_true(ok({ pattern = "^[a-z][a-z0-9_]*\\.[A-Z]\\w*$" }, "loomworks.Root"))
        assert.is_false(ok({ pattern = "^[a-z][a-z0-9_]*\\.[A-Z]\\w*$" }, "loomworks_Root"))
        assert.is_true(ok({ pattern = "^/" }, "/x"))
        assert.is_true(ok({ pattern = "^[0-9a-f]+$" }, "00ff"))
        assert.is_false(ok({ pattern = "^[0-9a-f]+$" }, "00fg"))
        assert.is_true(ok({ pattern = "a-b%c" }, "xa-b%cx"))
        -- `.` is any character but a line terminator (ECMA-262).
        assert.is_true(ok({ pattern = "^a.b$" }, "a-b"))
        assert.is_false(ok({ pattern = "^a.b$" }, "a\nb"))
        assert.is_false(ok({ pattern = "^a.b$" }, "a\rb"))
        -- Ranges join two letters or digits; a range with a punctuation end
        -- (which a Lua class would misread) is refused.
        assert.is_true(ok({ pattern = "^[a-cX-Z0-2_-]+$" }, "aZ1_-"))
        assert.is_false(ok({ pattern = "^[a-c]+$" }, "-"))
        for _, bad in ipairs({ "(a|b)", "a{2}", "a|b", "^a^", "\\q", "[abc", "[!-/]", "[a-%]", "[\\.-z]", "[z-a]" }) do
            assert.is_nil((schema.translate_pattern(bad)), bad)
        end
    end)

    it("resolves local and cross-document references", function()
        local set = documents.set()
        assert.is_true((set:validate("interfaces/loomworks/Common.1.json", "/$defs/Ref", { key = "debug" })))
        assert.is_false((set:validate("interfaces/loomworks/Common.1.json", "/$defs/Ref", { id = "a", key = "b" })))
        assert.is_true((set:validate("interfaces/loomworks/Common.1.json", "/$defs/Outcome",
            { outcome = "refused", message = "no", exit_code = 1 })))
        assert.is_false((set:validate("interfaces/loomworks/Common.1.json", "/$defs/Outcome",
            { outcome = "refused", message = "no" })))
        -- transport.json refers into the interface documents by path.
        assert.is_true((set:validate("transport.json", "/frames/call",
            { kind = "call", req_id = 1, object = "/", iface = "loomworks.Root", v = 1, method = "describe",
              args = vim.empty_dict(), env = { PATH = "/bin" } })))
        assert.is_false((set:validate("transport.json", "/frames/call",
            { kind = "call", req_id = 1, object = "/", iface = "loomworks.Root", v = 1, method = "describe",
              env = { PATH = 1 } })))
        -- Tests/1.run's task result: one row per test step run.
        local tr = "/methods/run/task/result"
        assert.is_true((set:validate("interfaces/loomworks/Tests.1.json", tr, { exit_code = 1, junit = {},
            steps = { { name = "unit", exit_code = 0, status = "passed" }, { name = "it", exit_code = 2, status = "failed" } } })))
        assert.is_false((set:validate("interfaces/loomworks/Tests.1.json", tr, { exit_code = 0, steps = 2 })))
        assert.is_false((set:validate("interfaces/loomworks/Tests.1.json", tr, { exit_code = 0,
            steps = { { name = "unit", exit_code = 0 } } })))
        local _, err = set:validate("transport.json", "/frames/nope", {})
        assert.truthy(err:find("no schema", 1, true))
    end)
end)

describe("protocol documents (lint)", function()
    it("finds the protocol directory with the transport, meta, Root/1 and Common/1 documents", function()
        assert.truthy(DIR)
        local files = json_files(DIR, "")
        for _, want in ipairs({ "transport.json", "meta/interface.schema.json", "meta/transport.schema.json",
            "interfaces/loomworks/Root.1.json", "interfaces/loomworks/Common.1.json" }) do
            assert.truthy(vim.tbl_contains(files, want), want)
        end
    end)

    it("every document is well-formed, valid against its meta-schema and uses only the allowed keywords", function()
        local set = documents.set()
        local problems = {}
        for _, rel in ipairs(json_files(DIR, "")) do
            vim.list_extend(problems, check.lint(set, rel))
        end
        assert.same({}, problems)
    end)

    it("the lint reports a foreign keyword, a non-portable pattern, a dangling $ref and a name/path mismatch", function()
        local doc = {
            interface = "lwtest.Lint", version = 1, status = "draft",
            methods = {
                go = {
                    params = { type = "object", properties = { a = { type = "string", format = "uri" } } },
                    result = { type = "string", pattern = "(a|b)" },
                },
                ["BadName"] = { params = {}, result = { ["$ref"] = "#/$defs/Missing" } },
            },
        }
        local set = documents.set(function(rel)
            if rel == "interfaces/lwtest/Lint.1.json" then return vim.json.encode(doc) end
            return documents.read(rel)
        end)
        local text = table.concat(check.lint(set, "interfaces/lwtest/Lint.1.json"), "\n")
        assert.truthy(text:find("keyword 'format' is not allowed", 1, true), text)
        assert.truthy(text:find("outside the portable subset", 1, true), text)
        assert.truthy(text:find("unresolved reference #/$defs/Missing", 1, true), text)
        assert.truthy(text:find("method BadName is not snake_case", 1, true), text)
        assert.truthy(text:find("not valid against meta/interface.schema.json", 1, true), text)
        doc.interface = "lwtest.Other"
        text = table.concat(check.lint(documents.set(function(rel)
            if rel == "interfaces/lwtest/Lint.1.json" then return vim.json.encode(doc) end
            return documents.read(rel)
        end), "interfaces/lwtest/Lint.1.json"), "\n")
        assert.truthy(text:find("lives at interfaces/lwtest/Lint.1.json", 1, true), text)
    end)

    it("the lint refuses a draft under frozen/", function()
        local doc = vim.json.decode(documents.read("interfaces/loomworks/Root.1.json"))
        local function lint(status)
            doc.status = status
            return table.concat(check.lint(documents.set(function(rel)
                if rel == "frozen/interfaces/loomworks/Root.1.json" then return vim.json.encode(doc) end
                return documents.read(rel)
            end), "frozen/interfaces/loomworks/Root.1.json"), "\n")
        end
        local text = lint("draft")
        assert.truthy(text:find("a draft is never frozen", 1, true), text)
        assert.falsy(lint("stable"):find("a draft is never frozen", 1, true))
    end)
end)

describe("additive ratchet", function()
    it("every frozen interface version is additive against its current document", function()
        local frozen = documents.set(function(rel) return documents.read("frozen/" .. rel) end)
        local current = documents.set()
        local problems = {}
        for _, rel in ipairs(json_files(DIR .. "/frozen", "")) do
            vim.list_extend(problems, check.ratchet(frozen, current, rel))
        end
        assert.same({}, problems)
    end)

    local REL = "interfaces/lwtest/R.1.json"
    local function base()
        return {
            interface = "lwtest.R", version = 1, status = "stable",
            methods = {
                get = {
                    params = { type = "object", required = { "id" }, properties = {
                        id = { type = "string" }, mode = { enum = { "a", "b" } } } },
                    result = { type = "object", required = { "state" }, properties = {
                        state = { enum = { "on", "off" } }, out = { ["$ref"] = "lwtest.T/1#/$defs/Out" } } },
                },
            },
            signals = { changed = { args = { type = "object", properties = {
                n = { type = "integer" }, kind = { enum = { "x", "y" } } } } } },
            ["$defs"] = { Unused = { type = "string" } },
        }
    end
    local function types()
        return { interface = "lwtest.T", version = 1, status = "stable", types_only = true, methods = {},
            ["$defs"] = { Out = { oneOf = { { const = "x" }, { const = "y" } } } } }
    end
    local function diff(mutate, mutate_types)
        local old, new, ot, nt = base(), base(), types(), types()
        mutate(new)
        if mutate_types then mutate_types(nt) end
        return check.ratchet(mem_set({ [REL] = old, ["interfaces/lwtest/T.1.json"] = ot }),
            mem_set({ [REL] = new, ["interfaces/lwtest/T.1.json"] = nt }), REL)
    end

    it("accepts the additive changes", function()
        assert.same({}, diff(function(d)
            d.methods.get.params.properties.extra = { type = "boolean" }       -- an optional parameter
            d.methods.get.result.properties.more = { type = "string" }         -- a result field
            table.insert(d.methods.get.result.required, "more")
            table.insert(d.methods.get.params.properties.mode.enum, "c")       -- a parameter value
            table.insert(d.methods.get.result.properties.state.enum, "broken") -- a result state
            table.insert(d.signals.changed.args.properties.kind.enum, "z")     -- a signal value
            d.signals.changed.args.properties.why = { type = "string" }        -- a signal field
            d.methods.put = { params = { type = "object" }, result = { type = "object" } } -- a method
        end, function(t)
            table.insert(t["$defs"].Out.oneOf, { const = "z" })                -- an outcome
        end))
    end)

    it("refuses removal, renaming, retyping and new requirements, asking for a new version", function()
        local function one(mutate, needle, mt)
            local p = diff(mutate, mt)
            local text = table.concat(p, "\n")
            assert.truthy(#p > 0 and text:find(needle, 1, true), needle .. " <- " .. text)
            assert.truthy(text:find("make version 2", 1, true), text)
        end
        one(function(d) d.methods.get = nil end, "method removed")
        one(function(d) d.methods.get.params.properties.mode = nil end, "property 'mode' removed")
        one(function(d) table.insert(d.methods.get.params.required, "mode") end, "parameter 'mode' made required")
        one(function(d) d.methods.get.params.properties.req = { type = "string" }
            table.insert(d.methods.get.params.required, "req") end, "parameter 'req' made required")
        one(function(d) d.methods.get.params.properties.id.type = "integer" end, "retyped from string to integer")
        one(function(d) d.methods.get.params.properties.mode.enum = { "a" } end, "enum value b removed")
        one(function(d) d.methods.get.result.properties.state.enum = { "on" } end, "enum value off removed")
        one(function(d) d.methods.get.result.required = {} end, "'state' no longer required")
        one(function(d) d.signals.changed = nil end, "signal removed")
        one(function(d) d["$defs"].Unused = nil end, "definition removed")
        one(function(d) d.methods.get.mutates = true end, "mutates changed")
        one(function() end, "/oneOf", function(t) t["$defs"].Out.oneOf[2] = { const = "w" } end)
        one(function(d) d.subscribe_args = { type = "object", required = { "x" },
            properties = { x = { type = "string" } } } end, "subscription args made required")
    end)

    it("checks subscription args as parameters", function()
        local function with(sa_old, sa_new)
            local old, new = base(), base()
            old.subscribe_args, new.subscribe_args = sa_old, sa_new
            return check.ratchet(mem_set({ [REL] = old, ["interfaces/lwtest/T.1.json"] = types() }),
                mem_set({ [REL] = new, ["interfaces/lwtest/T.1.json"] = types() }), REL)
        end
        local sa = function() return { type = "object", properties = { only = { type = "integer" } } } end
        assert.same({}, with(nil, sa()))
        local grown = sa()
        grown.properties.more = { type = "string" }
        assert.same({}, with(sa(), grown))
        assert.truthy(table.concat(with(sa(), nil), "\n"):find("subscription args removed", 1, true))
        local req = sa()
        req.required = { "only" }
        assert.truthy(table.concat(with(sa(), req), "\n"):find("parameter 'only' made required", 1, true))
    end)

    it("holds the transport document to the same rules: frames, error codes, definitions", function()
        local TR = "transport.json"
        local cur = vim.json.decode(documents.read(TR))
        local function tdiff(mutate)
            local new = vim.json.decode(documents.read(TR))
            mutate(new)
            local function over(d)
                return documents.set(function(rel)
                    if rel == TR then return vim.json.encode(d) end
                    return documents.read(rel)
                end)
            end
            return table.concat(check.ratchet(over(cur), over(new), TR), "\n")
        end
        assert.equals("", tdiff(function(d)
            d.frames.welcome.properties = d.frames.welcome.properties or {}
            d.frames.welcome.properties.extra = { type = "string" }
            d.error_codes.brand_new = { description = "x" }
        end))
        local text = tdiff(function(d) d.frames.signal = nil end)
        assert.truthy(text:find("/frames/signal: frame removed", 1, true), text)
        assert.truthy(text:find("make transport 12", 1, true), text)
        text = tdiff(function(d) d.error_codes.forbidden = nil end)
        assert.truthy(text:find("/error_codes/forbidden: error code removed", 1, true), text)
        text = tdiff(function(d)
            d.frames.hello.required = d.frames.hello.required or {}
            table.insert(d.frames.hello.required, "brand_new")
            d.frames.hello.properties.brand_new = { type = "string" }
        end)
        assert.truthy(text:find("parameter 'brand_new' made required", 1, true), text)
    end)
end)

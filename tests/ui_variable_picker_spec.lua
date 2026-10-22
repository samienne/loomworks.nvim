-- Segment pickers in the launch/deploy editors offer the built-in path
-- variables; `${target_dir}` only where the edited context resolves a build
-- target (spec §8.7: unavailable for a command-type launch).

local function names(list)
    local out = {}
    for _, v in ipairs(list) do out[#out + 1] = v.var end
    return out
end

local function find(list, var)
    for _, v in ipairs(list) do if v.var == var then return v end end
end

describe("editor segment pickers", function()
    for _, mod in ipairs({ "loomworks.ui.path_editor", "loomworks.ui.deploy_editor" }) do
        it(mod .. " offers ${target_dir} as a root-only path variable in a target context", function()
            local list = require(mod).build_variable_list(nil, { target_context = true })
            local td = find(list, "target_dir")
            assert.is_table(td, table.concat(names(list), ", "))
            assert.is_true(td.root_only)
            assert.equals("Target directory", td.label)
            -- The other built-ins stay, user variables follow them.
            local l2 = require(mod).build_variable_list({ variables = { out = { type = "path" } } },
                { target_context = true })
            assert.same({ "workspace_root", "build_dir", "project_path", "target_dir", "variant", "config_set", "out" },
                names(l2))
        end)

        it(mod .. " does not offer ${target_dir} without a target context (command launch)", function()
            local list = require(mod).build_variable_list({ variables = { out = { type = "path" } } })
            assert.same({ "workspace_root", "build_dir", "project_path", "variant", "config_set", "out" },
                names(list))
        end)
    end
end)

-- The path previews of the launch, deploy and path editors come from the
-- caller (Projects/1.expand_preview, step 5o C2b2-2): asked once per
-- template, shown once the answer arrives.
describe("editor path previews (path_editor.preview_cache)", function()
    local preview_cache = require("loomworks.ui.path_editor").preview_cache

    it("an answer given at once is the preview at once; asked once per template", function()
        local asked, refreshed = {}, 0
        local get = preview_cache(function(t, cb)
            asked[#asked + 1] = t
            cb("/abs/" .. t)
        end, function() refreshed = refreshed + 1 end)
        assert.equals("/abs/a", get("a"))
        assert.equals("/abs/a", get("a"))
        assert.same({ "a" }, asked)
        assert.equals(0, refreshed)
    end)

    it("a later answer refreshes the dialog; before it no preview, never asked twice", function()
        local pending, refreshed = {}, 0
        local get = preview_cache(function(t, cb) pending[#pending + 1] = { t = t, cb = cb } end,
            function() refreshed = refreshed + 1 end)
        assert.is_nil(get("${build_dir}/x"))
        assert.is_nil(get("${build_dir}/x"))
        assert.equals(1, #pending)
        pending[1].cb("/b/x")
        assert.equals(1, refreshed)
        assert.equals("/b/x", get("${build_dir}/x"))
    end)

    it("an unresolved reference, a refusal, an empty template or no source: no preview", function()
        local get = preview_cache(function(t, cb) cb(t == "u" and "${nope}/u" or nil) end, function() end)
        assert.is_nil(get("u"))
        assert.is_nil(get("r"))
        assert.is_nil(get(""))
        assert.is_nil(preview_cache(nil, function() end)("a"))
    end)
end)

-- Segment pickers in the launch/deploy editors offer the built-in path
-- variables, including `${target_dir}` (spec §8.7).

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
        it(mod .. " offers ${target_dir} as a root-only path variable", function()
            local list = require(mod).build_variable_list(nil)
            local td = find(list, "target_dir")
            assert.is_table(td, table.concat(names(list), ", "))
            assert.is_true(td.root_only)
            assert.equals("Target directory", td.label)
            -- The other built-ins stay, user variables follow them.
            local l2 = require(mod).build_variable_list({ variables = { out = { type = "path" } } })
            assert.same({ "workspace_root", "build_dir", "project_path", "target_dir", "variant", "config_set", "out" },
                names(l2))
        end)
    end
end)

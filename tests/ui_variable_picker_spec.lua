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

-- The launch editor's path and deploy editors offer `${target_dir}` exactly
-- when the edited launch is target-backed (spec §8.7: defined for a
-- target-backed launch's args, working_dir and deploy destinations,
-- unavailable for a command-type launch).
describe("launch editor ${target_dir} context", function()
    local View = require("loomworks.ui.view")

    --- Open the launch editor (`target_context` as given) and press <CR> on
    --- each row that opens a path or deploy editor; returns the
    --- `target_context` each one was opened with, by row.
    local function opened_contexts(target_context)
        local tree
        local orig_new = View.new
        View.new = function(vopts)
            tree = vopts.widget
            return { open = function() end, close = function() end, refresh = function() end }
        end
        local ok, err = pcall(require("loomworks.ui.launch_editor").open, {
            title = "Edit", name = "run", command = "", args = { "a", "k=v" }, working_dir = "", env = {},
            deploy = { ["out/"] = { project = "App", path = "f" } },
            projects = {}, profiles = {}, target_context = target_context,
            on_accept = function() end, on_cancel = function() end,
        })
        View.new = orig_new
        assert(ok, err)
        local pe, de = require("loomworks.ui.path_editor"), require("loomworks.ui.deploy_editor")
        local orig_pe, orig_de, orig_select = pe.open, de.open, vim.ui.select
        local seen, current = {}, nil
        pe.open = function(o) seen[current] = { o.target_context } end
        de.open = function(o) seen[current] = { o.target_context } end
        vim.ui.select = function(items, _, cb)
            for _, it in ipairs(items) do
                if it:find("path", 1, true) or it:find("Path", 1, true) then return cb(it) end
            end
        end
        local orig_input = vim.ui.input
        vim.ui.input = function(_, cb) cb("--opt") end
        local rows = { "^%s*Work dir", "Add path argument", "Add key=value argument", "Add deploy step",
            "<%- ", "^%s*a ?", "k=v" }
        local lines = tree:render()
        local ok2, err2 = pcall(function()
            for _, pat in ipairs(rows) do
                local row
                for i, l in ipairs(lines) do
                    if l:find(pat) and tree.line_meta[i] and tree.line_meta[i].on_enter then row = i; break end
                end
                assert(row, "no row matching " .. pat .. " in:\n" .. table.concat(lines, "\n"))
                current = pat
                tree.line_meta[row].on_enter()
                assert(seen[pat], pat .. " opened no editor")
            end
        end)
        pe.open, de.open, vim.ui.select, vim.ui.input = orig_pe, orig_de, orig_select, orig_input
        assert(ok2, err2)
        return seen
    end

    it("a target-backed launch's path and deploy editors offer ${target_dir}", function()
        for pat, ctx in pairs(opened_contexts(true)) do
            assert.is_true(ctx[1], pat)
        end
    end)

    it("a command-type launch's do not", function()
        for pat, ctx in pairs(opened_contexts(nil)) do
            assert.is_falsy(ctx[1], pat)
        end
    end)
end)

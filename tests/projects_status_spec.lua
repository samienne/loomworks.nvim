--- Tests for the Projects section's target rendering (loomworks.ui.helpers
--- render_targets) over plain target rows.

-- ---------------------------------------------------------------------------
-- Target rendering tests
-- ---------------------------------------------------------------------------

describe("Target rendering", function()
    local helpers = require("loomworks.ui.helpers")

    --- Minimal tree mock that records all output.
    local function make_mock_tree()
        local lines = {}
        local level = 0
        return {
            _lines = lines,
            leaf = function(_, text, hl)
                lines[#lines + 1] = { text = text, hl = hl, level = level, type = "leaf" }
            end,
            node = function(_, text, opts, children_fn)
                lines[#lines + 1] = { text = text, hl = opts and opts.hl, level = level, type = "node" }
                level = level + 1
                children_fn()
                level = level - 1
            end,
            group = function(_, label, hl, children_fn)
                lines[#lines + 1] = { text = label, hl = hl, level = level, type = "group" }
                level = level + 1
                children_fn()
                level = level - 1
            end,
        }
    end

    it("renders targets grouped by type with counts", function()
        local tree = make_mock_tree()
        helpers.render_targets(tree, {
            app = { type = "executable" },
            cli = { type = "executable" },
            libcore = { type = "static_library" },
            libutil = { type = "shared_library" },
        })

        -- Top-level: foldable Targets header with total count
        assert.equals("Targets (4)", tree._lines[1].text)
        assert.equals("node", tree._lines[1].type)

        -- Type group headers (level 1) with per-group counts
        local group_headers = {}
        for _, line in ipairs(tree._lines) do
            if line.level == 1 and line.type == "node" then
                group_headers[#group_headers + 1] = line.text
            end
        end
        assert.equals(3, #group_headers)
        assert.equals("Executables (2)", group_headers[1])
        assert.equals("Static Libraries (1)", group_headers[2])
        assert.equals("Shared Libraries (1)", group_headers[3])

        -- Target names inside groups (level 2), sorted alphabetically
        local target_names = {}
        for _, line in ipairs(tree._lines) do
            if line.level == 2 then
                target_names[#target_names + 1] = line.text
            end
        end
        assert.equals(4, #target_names)
        assert.equals("app", target_names[1])
        assert.equals("cli", target_names[2])
        assert.equals("libcore", target_names[3])
        assert.equals("libutil", target_names[4])
    end)

    it("renders leaf nodes for targets without dependencies", function()
        local tree = make_mock_tree()
        helpers.render_targets(tree, {
            app = { type = "executable" },
        })

        local target_line
        for _, line in ipairs(tree._lines) do
            if line.text == "app" then
                target_line = line
                break
            end
        end
        assert.is_not_nil(target_line)
        assert.equals("leaf", target_line.type)
    end)

    it("renders foldable nodes for targets with dependencies", function()
        local tree = make_mock_tree()
        helpers.render_targets(tree, {
            app = { type = "executable", dependencies = { "libcore", "libutil" } },
        })

        local target_line, links_line
        for _, line in ipairs(tree._lines) do
            if line.text == "app" then
                target_line = line
            end
            if line.text and line.text:match("^Links:") then
                links_line = line
            end
        end
        assert.is_not_nil(target_line)
        assert.equals("node", target_line.type)
        assert.is_not_nil(links_line)
        assert.equals("Links: libcore, libutil", links_line.text)
    end)

    it("renders foldable nodes for targets with artifact path", function()
        local tree = make_mock_tree()
        helpers.render_targets(tree, {
            libcore = { type = "static_library", artifact = "libs/core/libcore.a" },
        })

        local target_line, path_line
        for _, line in ipairs(tree._lines) do
            if line.text == "libcore" then
                target_line = line
            end
            if line.text and line.text:match("^Path:") then
                path_line = line
            end
        end
        assert.is_not_nil(target_line)
        assert.equals("node", target_line.type)
        assert.is_not_nil(path_line)
        assert.equals("Path: libs/core/libcore.a", path_line.text)
    end)

    it("renders path before links when target has both", function()
        local tree = make_mock_tree()
        helpers.render_targets(tree, {
            app = { type = "executable", artifact = "bin/app.exe", dependencies = { "lib" } },
        })

        local detail_lines = {}
        for _, line in ipairs(tree._lines) do
            if line.text and (line.text:match("^Path:") or line.text:match("^Links:")) then
                detail_lines[#detail_lines + 1] = line.text
            end
        end
        assert.equals(2, #detail_lines)
        assert.equals("Path: bin/app.exe", detail_lines[1])
        assert.equals("Links: lib", detail_lines[2])
    end)

    it("renders type groups in correct order", function()
        local tree = make_mock_tree()
        helpers.render_targets(tree, {
            iface = { type = "interface_library" },
            obj = { type = "object_library" },
            mod = { type = "module_library" },
            app = { type = "executable" },
        })

        local group_headers = {}
        for _, line in ipairs(tree._lines) do
            if line.level == 1 and line.type == "node" then
                group_headers[#group_headers + 1] = line.text
            end
        end
        assert.equals("Executables (1)", group_headers[1])
        assert.equals("Module Libraries (1)", group_headers[2])
        assert.equals("Object Libraries (1)", group_headers[3])
        assert.equals("Interface Libraries (1)", group_headers[4])
    end)

    it("integrates into render_unit_details when the unit has targets", function()
        local tree = make_mock_tree()
        helpers.render_unit_details(tree, "/root/.lw/build/App/Debug", {
            app = { type = "executable", dependencies = { "lib" } },
            lib = { type = "static_library" },
        }, nil)

        -- Should include Targets node with count
        local has_targets = false
        for _, line in ipairs(tree._lines) do
            if line.text and line.text:match("^Targets %(%d+%)$") then
                has_targets = true
                break
            end
        end
        assert.is_true(has_targets, "render_unit_details should include Targets node")
    end)

    it("does not render Targets when the unit has no targets", function()
        local tree = make_mock_tree()
        helpers.render_unit_details(tree, nil, nil, nil)

        for _, line in ipairs(tree._lines) do
            if line.text then
                assert.is_nil(line.text:match("^Targets %(%d+%)$"),
                    "should not render Targets node without target data")
            end
        end
    end)

    -- Regression: the Targets fold_key (and its descendants
    -- `ttype:<type>` / `target:<name>`) used to be a constant string
    -- because the profiles section called render_cached_details with
    -- fold_prefix = nil. Two profiles sharing a project produced
    -- duplicate fold_keys; collapsing the second one's Targets node
    -- moved the cursor to the first one's row.
    it("render_targets emits distinct fold_keys per prefix", function()
        local function fold_keyed_tree()
            local lines = {}
            local level = 0
            return {
                _lines = lines,
                leaf = function(_, text, hl)
                    lines[#lines + 1] = { text = text, hl = hl, level = level, type = "leaf" }
                end,
                node = function(_, text, opts, children_fn)
                    lines[#lines + 1] = {
                        text = text, level = level, type = "node",
                        fold_key = opts and opts.fold_key,
                    }
                    level = level + 1
                    children_fn()
                    level = level - 1
                end,
            }
        end

        local targets = {
            app = { type = "executable" },
            libcore = { type = "static_library" },
        }

        local a = fold_keyed_tree()
        helpers.render_targets(a, targets, "profile_proj:Debug:App")
        local b = fold_keyed_tree()
        helpers.render_targets(b, targets, "profile_proj:Release:App")

        local function find_fold_keys(tree)
            local out = {}
            for _, line in ipairs(tree._lines) do
                if line.fold_key then out[#out + 1] = line.fold_key end
            end
            return out
        end

        local keys_a = find_fold_keys(a)
        local keys_b = find_fold_keys(b)
        assert.is_true(#keys_a > 0)
        assert.equals(#keys_a, #keys_b)
        for i = 1, #keys_a do
            assert.not_equals(keys_a[i], keys_b[i],
                "fold_key collision at index " .. i .. ": " .. keys_a[i])
            assert.is_truthy(keys_a[i]:match("^profile_proj:Debug:App:"),
                "expected prefix in key: " .. keys_a[i])
            assert.is_truthy(keys_b[i]:match("^profile_proj:Release:App:"),
                "expected prefix in key: " .. keys_b[i])
        end
    end)
end)

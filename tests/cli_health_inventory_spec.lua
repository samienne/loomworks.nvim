--- Tests for `lw health`'s environment-inventory rendering (headless §16.33):
--- outside a workspace (no split), inside (suggestion → Required → Other → lw),
--- `--verbose`, `--json`, and the passive `lw status` count reusing the cached
--- tier without probing. The probe is stubbed (`cli._probe_inventory`).

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local inv = require("loomworks.inventory")


-- ---------------------------------------------------------------------------
-- lw health rendering + --json
-- ---------------------------------------------------------------------------
describe("lw health inventory output", function()
    local cli = require("loomworks.cli")

    local function capture(fn)
        local out_buf = {}
        local rw, rs = io.write, io.stderr
        io.write = function(...) for _, s in ipairs({ ... }) do out_buf[#out_buf + 1] = s end end
        io.stderr = { write = function() end }
        local ok, err = pcall(fn)
        io.write, io.stderr = rw, rs
        if not ok then error(err, 0) end
        return table.concat(out_buf)
    end

    local function tier_for(ws)
        return {
            key = inv.environment_key(ws), computed_at = 1,
            declared = { { id = "exe:node", category = "build tools" }, { id = "exe:npm", category = "build tools" },
                { id = "lsp:clangd", category = "language servers" }, { id = "lw", category = "lw" } },
            results = {
                { id = "exe:node", label = "node", status = "found", version = "20.11.0", path = "/usr/bin/node", category = "build tools" },
                { id = "exe:npm", label = "npm", status = "missing", hint = "install Node.js", category = "build tools" },
                { id = "lsp:clangd:path", label = "clangd", status = "found", version = "18.1.8", path = "/usr/bin/clangd", category = "language servers" },
                { id = "lw", label = "lw", status = "found", version = "0.1.30", category = "lw" },
            },
        }
    end

    local orig
    before_each(function()
        orig = cli._probe_inventory
        cli._probe_inventory = function(ws) return tier_for(ws) end
    end)
    after_each(function() cli._probe_inventory = orig end)

    local function make_ws()
        local root = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(root .. "/App", "p")
        local f = assert(io.open(root .. "/loomworks.json", "w"))
        f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } }))
        f:close()
        return root
    end

    it("outside a workspace lists every category, one line per item", function()
        local text = capture(function() assert.equals(0, cli.cmd_health(nil)) end)
        assert.is_truthy(text:find("build tools", 1, true))
        assert.is_truthy(text:find("✓ node 20.11.0", 1, true))
        assert.is_truthy(text:find("– npm", 1, true))
        assert.is_truthy(text:find("not found (install Node.js)", 1, true))
        assert.is_nil(text:find("Required by this workspace", 1, true))
    end)

    it("inside a workspace: the missing required item is a suggestion, then Required / Other / lw", function()
        local root = make_ws()
        local text = capture(function() assert.equals(0, cli.cmd_health(root)) end)
        assert.is_truthy(text:find("• npm not found — needed by App", 1, true))
        assert.is_truthy(text:find("Required by this workspace", 1, true))
        assert.is_truthy(text:find("✗ npm", 1, true))
        assert.is_truthy(text:find("✓ node 20.11.0", 1, true))
        assert.is_truthy(text:find("Other", 1, true))
        assert.is_truthy(text:find("✓ clangd 18.1.8", 1, true))
        assert.is_truthy(text:find("\nlw  0.1.30", 1, true))
        -- Required comes before Other.
        assert.is_true(text:find("Required by this workspace", 1, true) < text:find("\nOther", 1, true))

        -- The passive status count now includes it — without probing.
        cli._probe_inventory = function() error("status must not probe") end
        local status = capture(function() cli.cmd_status(root, {}) end)
        assert.is_truthy(status:find("1 suggestion", 1, true))
        vim.fn.delete(root, "rf")
    end)

    it("--verbose expands Other to one line per item with locations", function()
        local root = make_ws()
        local text = capture(function() cli.cmd_health(root, { verbose = true }) end)
        assert.is_truthy(text:find("/usr/bin/clangd", 1, true))
        vim.fn.delete(root, "rf")
    end)

    it("--json prints {schema, workspace, suggestions, inventory} and exits 0", function()
        local root = make_ws()
        local rc
        local text = capture(function() rc = cli.cmd_health(root, { json = true }) end)
        assert.equals(0, rc)
        local doc = vim.json.decode(text)
        assert.equals(1, doc.schema)
        assert.equals(root, doc.workspace.root)
        local by = {}
        for _, e in ipairs(doc.inventory) do by[e.id] = e end
        assert.is_true(by["exe:npm"].required)
        assert.equals("missing", by["exe:npm"].status)
        assert.same({ "App" }, by["exe:npm"].required_by)
        assert.is_false(by["lsp:clangd:path"].required)
        assert.equals("build tools", by["exe:node"].category)
        local found
        for _, s in ipairs(doc.suggestions) do
            if s.title == "npm not found — needed by App" then found = s end
        end
        assert.is_not_nil(found)
        assert.equals("suggestion", found.kind)
        vim.fn.delete(root, "rf")
    end)

    it("--json outside a workspace has no workspace field", function()
        local doc = vim.json.decode(capture(function() cli.cmd_health(nil, { json = true }) end))
        assert.is_nil(doc.workspace)
        assert.equals(4, #doc.inventory)
    end)
end)

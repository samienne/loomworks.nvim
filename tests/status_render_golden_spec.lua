-- The status page body renders the same lines, highlights and line actions
-- whatever source its state comes from (spec §19.13 "Two sources, one
-- shape"): these fixtures pin the page, every fold open, against recorded
-- output (tests/fixtures/status_golden/<name>.txt). The page reads the
-- fixture's daemon state (tests/fixtures/status_golden/<name>.view.json: its
-- `view.Header/1`, `view.Workspace/1`, `LspConfig/1` options and
-- `DebugConfig/1.adapters` records) through a fake observer. Regenerate a
-- recording only for an intended change of the page:
--   LOOMWORKS_UPDATE_GOLDEN=1 make test-file FILE=tests/status_render_golden_spec.lua

local Tree = require("loomworks.ui.tree")

local GOLDEN_DIR = "tests/fixtures/status_golden/"

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    -- A checkout may have turned the recording's line ends into CRLF.
    return (s:gsub("\r\n", "\n"))
end

--- The page as text: each line, then its highlights and its widget's keys.
local function render_text(tree)
    local lines, hls, meta = tree:render()
    local by_line = {}
    for _, hl in ipairs(hls) do
        by_line[hl.line] = by_line[hl.line] or {}
        table.insert(by_line[hl.line], string.format("%d-%d %s", hl.col_start, hl.col_end, hl.hl_group))
    end
    local out = {}
    for i, l in ipairs(lines) do
        out[#out + 1] = string.format("%3d|%s", i, l)
        if by_line[i] then out[#out + 1] = "   hl " .. table.concat(by_line[i], "; ") end
        local w = meta[i]
        if w then
            local keys = {}
            for k, v in pairs(w) do
                keys[#keys + 1] = type(v) == "function" and (k .. "()") or (k .. "=" .. tostring(v))
            end
            table.sort(keys)
            out[#out + 1] = "   w  " .. table.concat(keys, " ")
        end
        if tree.line_hover[i] then
            local hv = tree.line_hover[i]()
            out[#out + 1] = "   K  " .. (type(hv) == "table" and table.concat(hv, "\\n") or tostring(hv))
        end
    end
    return table.concat(out, "\n") .. "\n"
end

--- Render the status page of fixture `name` with every fold open.
local function render_fixture(name)
    local text = assert(read(GOLDEN_DIR .. name .. ".view.json"), "no fixture " .. name)
    local doc = vim.json.decode(text)
    local lw = require("loomworks")
    local saved_rt = lw.daemon_runtime_line
    lw.daemon_runtime_line = function() return nil end

    -- The fixture's views held as the daemon's, by a fake observer.
    local observer, views = require("loomworks.daemon.observer"), require("loomworks.views")
    local obs = { state = "connected", root = doc.header.root }
    function obs:workspace_view() return doc.workspace end
    function obs:tasks() return {} end
    function obs:_clock() return 0 end
    function obs:lsp_phase()
        return "loaded", { state = "loaded", options = doc.lsp_options }
    end
    -- (The editor is attached to it while the page renders.)
    local saved_obs = { observer._current, observer._attached_root }
    views.set(obs, "header", doc.header)
    local eo = require("loomworks.daemon.editor_ops")
    local orig_adapters = eo.debug_adapters
    eo.debug_adapters = function() return doc.debug_adapters end

    observer._current, observer._attached_root = obs, doc.header.root
    local ok, text = pcall(function()
        local tree = Tree.new(require("loomworks.ui.status")._render_fn)
        tree.width = 100
        setmetatable(tree._folds, { __index = function() return true end })
        return render_text(tree)
    end)
    observer._current, observer._attached_root = saved_obs[1], saved_obs[2]
    views.clear(obs)
    eo.debug_adapters = orig_adapters
    lw.daemon_runtime_line = saved_rt
    assert(ok, text)
    return text
end

describe("status page rendering (golden)", function()
    for _, name in ipairs({ "cmake", "shell", "empty", "tools" }) do
        it("renders the " .. name .. " fixture as recorded", function()
            local text = render_fixture(name)
            local path = GOLDEN_DIR .. name .. ".txt"
            if os.getenv("LOOMWORKS_UPDATE_GOLDEN") == "1" then
                vim.fn.mkdir(GOLDEN_DIR, "p")
                local f = assert(io.open(path, "wb")); f:write(text); f:close()
            end
            local out_dir = os.getenv("LOOMWORKS_GOLDEN_OUT")
            if out_dir then
                local f = assert(io.open(out_dir .. "/" .. name .. ".txt", "wb")); f:write(text); f:close()
            end
            local want = read(path)
            assert.is_not_nil(want, "no recording: " .. path)
            assert.equals(want, text)
        end)
    end
end)

-- The refused-state hint (spec ui.md §1.4): the keys are refused while no
-- workspace is loaded (core §19.16 "Model writes"): the lw commands instead.
describe("status page refused-state hint", function()
    local function render(trust)
        local lw = require("loomworks")
        local saved = { lw.get_workspace, lw.view_header }
        lw.get_workspace = function() return nil end
        lw.view_header = function()
            return { state = "refused", root = "/root", error = "refused", trust = trust, version = "test" }
        end
        local ok, lines = pcall(function()
            local tree = Tree.new(require("loomworks.ui.status")._render_fn)
            tree.width = 100
            return (tree:render())
        end)
        lw.get_workspace, lw.view_header = saved[1], saved[2]
        assert(ok, lines)
        return lines[#lines]
    end

    it("names the lw commands", function()
        assert.equals("lw trust  ·  lw trust --discard", vim.trim(render("user")))
        assert.equals("lw nuke", vim.trim(render("cache")))
    end)
end)

--- CLI output never passes terminal control sequences through from data:
--- names/paths/values read from workspace, cache and health files are rendered
--- with every control character (except TAB/LF) made visible, while the CLI's
--- own coloring still works. Fixture strings carry a benign title-setting OSC
--- sequence and a cursor-movement CSI; the assertions check they are escaped.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local term = require("loomworks.term")
local ESC, BEL = "\27", "\7"
local EVIL = "x" .. ESC .. "]0;title" .. BEL .. ESC .. "[2Ay\r\0z"

describe("loomworks.term", function()
    it("escapes C0 controls except TAB/LF, DEL and UTF-8 C1 controls", function()
        local r = term.render("a\tb\nc" .. EVIL .. "\127" .. "\194\155" .. "d")
        assert.is_nil(r:find(ESC, 1, true))
        assert.is_nil(r:find(BEL, 1, true))
        assert.is_nil(r:find("\r", 1, true))
        assert.is_nil(r:find("\0", 1, true))
        assert.is_nil(r:find("\194\155", 1, true))
        assert.is_truthy(r:find("^[]0;title^G^[[2Ay^M^@z", 1, true))
        assert.is_truthy(r:find("^?", 1, true))
        assert.is_truthy(r:find("\\u009b", 1, true))
        assert.is_truthy(r:find("a\tb\nc", 1, true))
    end)

    it("keeps ordinary UTF-8 text intact", function()
        local s = "café · — ✓ ✗ …"
        assert.equals(s, term.render(s))
    end)

    it("ascii() folds the report glyphs to ASCII and leaves data alone", function()
        assert.equals("* - + x - - -> ... >=", term.ascii("• · ✓ ✗ – — → … ≥"))
        -- other non-ASCII (a user's name in a path) is data, not a glyph
        assert.equals("C:/Users/José/lw", term.ascii("C:/Users/José/lw"))
    end)

    it("turns only its own markers into SGR sequences", function()
        local painted = term.sgr("36") .. "lw pull" .. term.sgr("0")
        assert.equals(ESC .. "[36mlw pull" .. ESC .. "[0m", term.render(painted))
        -- A forged marker (wrong nonce) stays inert.
        local forged = "\0" .. string.rep("0", 16) .. "{31}boom"
        assert.is_nil(term.render(forged):find(ESC, 1, true))
    end)
end)

describe("CLI output of workspace data", function()
    local cli = require("loomworks.cli")

    local function capture(fn)
        local buf = {}
        local rw, rs = io.write, io.stderr
        io.write = function(...) for _, s in ipairs({ ... }) do buf[#buf + 1] = s end end
        io.stderr = { write = function(_, s) buf[#buf + 1] = s end }
        local ok, err = pcall(fn)
        io.write, io.stderr = rw, rs
        if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
        return table.concat(buf)
    end

    local function make_ws(project_key)
        local root = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(root .. "/App", "p")
        root = ((vim.uv or vim.loop).fs_realpath(root) or root):gsub("\\", "/")
        local f = assert(io.open(root .. "/loomworks.json", "w"))
        f:write(vim.json.encode({ projects = { [project_key] = { typescript = { path = "App" } } } }))
        f:close()
        return root
    end

    it("lw status escapes control sequences in a project name", function()
        local root = make_ws("App" .. EVIL)
        local text = capture(function() cli.cmd_status(root, {}) end)
        assert.is_nil(text:find(ESC, 1, true), text)
        assert.is_nil(text:find(BEL, 1, true), text)
        vim.fn.delete(root, "rf")
    end)

    it("lw health escapes control sequences in probe/inventory results", function()
        local orig = cli._probe_inventory
        cli._probe_inventory = function()
            return {
                key = "k", computed_at = 1,
                declared = { { id = "exe:evil", category = "build tools" } },
                results = { {
                    id = "exe:evil", label = "tool" .. EVIL, status = "found",
                    version = "1.0" .. EVIL, path = "/bin/t" .. EVIL, hint = "hint" .. EVIL,
                    category = "build tools",
                } },
            }
        end
        local text = capture(function() cli.cmd_health(nil, { verbose = true }) end)
        cli._probe_inventory = orig
        assert.is_truthy(text:find("tool", 1, true))
        assert.is_nil(text:find(ESC, 1, true), text)
        assert.is_nil(text:find(BEL, 1, true), text)
        assert.is_truthy(text:find("^[", 1, true))
    end)
end)

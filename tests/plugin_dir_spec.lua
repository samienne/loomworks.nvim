--- Neovim's plugin/ directory: the suite runs every spec file with
--- `--noplugin` (scripts/run_specs.lua), so nothing else ever sources
--- plugin/*.lua. This spec parses each of them and sources the main one, so a
--- syntax error there (which would leave the editor with no :Loomworks*
--- commands at all) fails the suite.

local uv = vim.uv or vim.loop

local function plugin_files()
    local out = {}
    for name, kind in vim.fs.dir("plugin") do
        if kind == "file" and name:match("%.lua$") then out[#out + 1] = "plugin/" .. name end
    end
    table.sort(out)
    return out
end

describe("plugin/*.lua", function()
    it("every file parses", function()
        local files = plugin_files()
        assert.is_true(#files > 0, "no plugin/*.lua found (cwd " .. tostring(uv.cwd()) .. ")")
        for _, f in ipairs(files) do
            local chunk, err = loadfile(f)
            assert.is_function(chunk, f .. ": " .. tostring(err))
        end
    end)

    describe("plugin/loomworks.lua sourced", function()
        local saved_cwd, saved_notify, tmp, src

        before_each(function()
            saved_cwd = uv.cwd()
            src = saved_cwd .. "/plugin/loomworks.lua"
            saved_notify = vim.notify
            -- An empty directory: the auto-load check at the end of the file
            -- finds no workspace there.
            tmp = vim.fn.tempname()
            vim.fn.mkdir(tmp, "p")
            -- The suite's runtimepath names this tree as ".": keep it findable
            -- from the empty directory.
            vim.opt.rtp:prepend(saved_cwd)
            uv.chdir(tmp)
            vim.g.loaded_loomworks = nil
        end)

        after_each(function()
            vim.notify = saved_notify
            uv.chdir(saved_cwd)
            vim.opt.rtp:remove(saved_cwd)
            pcall(vim.api.nvim_del_augroup_by_name, "loomworks_auto_load")
            vim.fn.delete(tmp, "rf")
        end)

        it("creates the user commands, and :LoomworksDaemon status reports the host lw", function()
            dofile(src)
            local cmds = vim.api.nvim_get_commands({})
            for _, name in ipairs({ "LoomworksInit", "LoomworksInfo", "LoomworksDaemon", "LoomworksLog" }) do
                assert.is_table(cmds[name], name .. " was not created")
            end
            local seen = {}
            vim.notify = function(msg) seen[#seen + 1] = tostring(msg) end
            vim.cmd("LoomworksDaemon status")
            local text = table.concat(seen, "\n")
            assert.truthy(text:find("loomworks runtime: ", 1, true), text)
            assert.truthy(text:find("\nhost lw: ", 1, true), text)
        end)
    end)
end)

--- loomworks/neotest/init.lua — Neotest adapter for loomworks.
---
--- Not available (daemon.md §19.16 "Tests" Neotest): the editor runs no tests
--- of its own and the workspace daemon's tests are served to the loomtest
--- explorer (loomworks/loomtest_adapter.lua). The adapter finds no root and
--- discovers nothing; the first time neotest asks it for anything while a
--- workspace is loaded, it says so once per session.

local test_source = require("loomworks.test_source")

local adapter = { name = "loomworks" }

local NOTICE = "loomworks: neotest is not available with the workspace daemon — use the loomtest explorer"
local _noticed = false

--- Say once per session (scheduled — neotest calls the adapter from nio
--- coroutines) that neotest is not available, while a workspace is loaded.
local function refuse()
    if _noticed or not test_source.attached() then return end
    _noticed = true
    vim.schedule(function() vim.notify(NOTICE, vim.log.levels.INFO) end)
end

--- Test seam: the notice is shown again on the next ask.
function adapter._reset_daemon_notice() _noticed = false end

function adapter.root(_)
    pcall(refuse)
    return nil
end

function adapter.filter_dir()
    pcall(refuse)
    return false
end

function adapter.is_test_file()
    pcall(refuse)
    return false
end

function adapter.discover_positions()
    pcall(refuse)
    return nil
end

function adapter.build_spec()
    pcall(refuse)
    return nil
end

function adapter.results()
    pcall(refuse)
    return {}
end

return adapter

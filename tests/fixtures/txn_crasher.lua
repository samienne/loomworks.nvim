-- A process that runs a multi-file operation and dies at a chosen commit step
-- (spec §19.4 crash tests):
--
--   nvim --headless --clean -l tests/fixtures/txn_crasher.lua <repo root> <workspace root> <step>
--
-- Renames project App to App2 (working copy + build cache, one commit) with
-- loomworks.txn._crash_at = <step>: the process exits (77) at that point of
-- the commit, without any cleanup — as if killed there. Exits 0 when the
-- operation completes (step "none").

local a = _G.arg
local repo, root, step = a[1], a[2], a[3]
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
require("loomworks.txn")._crash_at = (step ~= "none") and step or nil
local rex = os.exit
os.exit = function(code) rex(code) end
cli.cmd_project_rename(root, "App", "App2")
os.exit(0)

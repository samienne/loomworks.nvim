-- Provision the lw the plugin pins (lua/loomworks/provision/pinned.lua) into a
-- repo-local test directory and print the environment the specs run it with.
-- `make lw` / `make test` run it; tests/daemon_helpers.lua runs that binary
-- (LOOMWORKS_LW), and so does every editor the specs start (an explicit lw).
--
--   nvim -l scripts/test_lw.lua <dir>
--
-- The managed pair comes through the plugin's own provisioning
-- (loomworks.provision.fetch: the version's release origin, the pinned
-- SHA-256s checked): the host binary at <dir>/loomworks/lw/<sha256>/lw[.exe]
-- and the release bundle at <dir>/loomworks/bundle/<sha256>/lua-<version>/
-- (the managed slot layout, <dir> standing for the editor's data directory),
-- that bundle slot being the binary's LOOMWORKS_INSTALL_DIR (spec §19.16 "The
-- managed bundle"). Nothing outside <dir> is written: never a global lw,
-- never the user's settings or data.
--
-- stdout: `export LOOMWORKS_LW='...'` and `export LOOMWORKS_INSTALL_DIR='...'`
-- (for `eval`); progress and errors go to stderr.

local src = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local repo = src:match("^(.*)/scripts/[^/]*$") or "."
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path

local function die(msg)
    io.stderr:write("test_lw: " .. msg .. "\n")
    os.exit(1)
end

local dir = _G.arg[1]
if not dir or dir == "" then
    io.stderr:write("usage: nvim -l scripts/test_lw.lua <dir>\n")
    os.exit(2)
end
dir = vim.fn.fnamemodify(dir, ":p"):gsub("\\", "/"):gsub("/+$", "")
vim.fn.mkdir(dir, "p")

local fetch = require("loomworks.provision.fetch")
local want, why = require("loomworks.provision.managed").pinned_wanted()
if not want then die(tostring(why)) end

local lw, err, done
fetch.ensure(want, { data = dir }, function(p, e) lw, err, done = p, e, true end)
vim.wait(600000, function() return done end, 50)
if not lw then die("lw " .. want.version .. " (" .. want.asset .. "): " .. tostring(err or "timed out")) end

-- The bundle slot is the install folder; the rest of the environment is
-- isolated, so the check touches only <dir>.
local install = require("loomworks.provision.managed").bundle_slot(want.bundle_sha256, { data = dir })
local env = {
    LOOMWORKS_DATA_DIR = dir .. "/data",
    LOOMWORKS_INSTALL_DIR = install,
    APPDATA = dir .. "/config",
    XDG_CONFIG_HOME = dir .. "/config",
    LOCALAPPDATA = dir .. "/cache",
    XDG_CACHE_HOME = dir .. "/cache",
    LOOMWORKS_NO_HOUSEKEEPING = "1",
    LOOMWORKS_RELEASE_NOTES = "off",
}
for _, d in ipairs({ env.LOOMWORKS_DATA_DIR, env.APPDATA, env.LOCALAPPDATA }) do vim.fn.mkdir(d, "p") end
-- `lw version --json` answers only with its bundle in the install folder.
local r = vim.system({ lw, "version", "--json" }, { env = env, text = true }):wait()
if r.code ~= 0 then die("lw " .. want.version .. " does not run with its bundle " .. install .. ": " .. (r.stderr or "")) end

local function q(s) return "'" .. s:gsub("'", "'\''") .. "'" end
io.stdout:write("export LOOMWORKS_LW=" .. q(lw) .. "\n")
io.stdout:write("export LOOMWORKS_INSTALL_DIR=" .. q(install) .. "\n")

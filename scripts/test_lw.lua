-- Provision the lw the plugin pins (lua/loomworks/provision/pinned.lua) into a
-- repo-local test directory and print the environment the specs run it with.
-- `make lw` / `make test` run it; tests/daemon_helpers.lua runs that binary
-- (LOOMWORKS_LW), and so does every editor the specs start (an explicit lw).
--
--   nvim -l scripts/test_lw.lua <dir>
--
-- The host binary comes through the plugin's own download code
-- (loomworks.provision.fetch: the version's release origin, the pinned
-- SHA-256 checked) and lands at <dir>/loomworks/lw/<sha256>/lw[.exe] (the
-- managed slot layout, <dir> standing for the editor's data directory). Its
-- release bundle is then installed by that binary itself (`lw self-update
-- --no-host`: manifest signature checked against the key built into lw) from
-- the same release, into <dir>/install. Nothing outside <dir> is written:
-- never a global lw, never the user's settings or data.
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

-- The bundle: an isolated environment, so the run touches only <dir>.
local install = dir .. "/install"
local env = {
    LOOMWORKS_DATA_DIR = dir .. "/data",
    LOOMWORKS_INSTALL_DIR = install,
    APPDATA = dir .. "/config",
    XDG_CONFIG_HOME = dir .. "/config",
    LOCALAPPDATA = dir .. "/cache",
    XDG_CACHE_HOME = dir .. "/cache",
    LOOMWORKS_NO_HOUSEKEEPING = "1",
    LOOMWORKS_RELEASE_NOTES = "off",
    LOOMWORKS_RELEASE_URL = fetch.url(want, { getenv = function() return nil end }):match("^(.*)/[^/]+$"),
}
for _, d in ipairs({ env.LOOMWORKS_DATA_DIR, env.APPDATA, env.LOCALAPPDATA }) do vim.fn.mkdir(d, "p") end
local function run(args)
    local cmd = { lw }
    vim.list_extend(cmd, args)
    return vim.system(cmd, { env = env, text = true }):wait()
end
-- `lw version --json` answers only with a bundle installed.
if run({ "version", "--json" }).code ~= 0 then
    io.stderr:write("test_lw: installing the lw " .. want.version .. " bundle into " .. install .. "\n")
    local r = run({ "--no-input", "self-update", "--no-host" })
    if r.code ~= 0 then die("lw self-update --no-host: " .. (r.stderr or "") .. (r.stdout or "")) end
    if run({ "version", "--json" }).code ~= 0 then die("no lw " .. want.version .. " bundle in " .. install) end
end

local function q(s) return "'" .. s:gsub("'", "'\''") .. "'" end
io.stdout:write("export LOOMWORKS_LW=" .. q(lw) .. "\n")
io.stdout:write("export LOOMWORKS_INSTALL_DIR=" .. q(install) .. "\n")

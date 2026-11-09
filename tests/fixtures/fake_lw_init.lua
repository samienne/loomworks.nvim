-- A fake `lw` for the editor's `lw init` tests (tests/lw_init_spec.lua), run
-- as `nvim --headless -u NONE -l fake_lw_init.lua <report> <exit> <lw args...>`.
-- Writes to <report>, one `key=value` per line: its working directory (`cwd`),
-- its lw arguments (`args`, space-separated) and its LOOMWORKS_LUA and
-- LOOMWORKS_INSTALL_DIR ("-" when unset). With <exit> 0 it creates
-- `.lw/user.json` in its working directory, as `lw init` does.
-- Exits <exit>.
local uv = vim.uv or vim.loop
local report, code = arg[1], tonumber(arg[2]) or 0
local args = {}
for i = 3, #arg do args[#args + 1] = arg[i] end
local cwd = uv.cwd()
local f = assert(io.open(report, "w"))
f:write("cwd=", cwd, "\n")
f:write("args=", table.concat(args, " "), "\n")
for _, n in ipairs({ "LOOMWORKS_LUA", "LOOMWORKS_INSTALL_DIR" }) do
    f:write(n, "=", os.getenv(n) or "-", "\n")
end
f:close()
if code == 0 then
    vim.fn.mkdir(cwd .. "/.lw", "p")
    local w = assert(io.open(cwd .. "/.lw/user.json", "w"))
    w:write("{}\n")
    w:close()
    print("initialized workspace at " .. cwd)
else
    print("lw: init failed")
end
os.exit(code)

-- Concurrent appends to the shared logs (the runtime log of spec §19.10 and
-- the workspace log): two processes that append a line to a fresh file at
-- the same moment must both find their line in it. The C runtime's append
-- mode does not guarantee that on Windows (it seeks to the end, then
-- writes: two writers that seek together write at the same offset and one
-- line overwrites the other) — seen in CI as a runtime log holding the
-- daemon's "serving" line but not the launching client's "launched" one.

local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

--- Start a writer process: for trial t = 1..n it waits for `<dir>/go<t>`,
--- then appends one line to `<dir>/<t>.log` through `how` ("rlog" | "log").
local function writer(dir, id, n, how)
    local script = dir .. "/writer" .. id .. ".lua"
    local f = assert(io.open(script, "w"))
    f:write(string.format([[
package.path = %q .. "/lua/?.lua;" .. package.path
local dir, id, n, how = %q, %q, %d, %q
local uv = vim.uv
local deadline = uv.hrtime() + 120e9
local log
for t = 1, n do
    while not uv.fs_stat(dir .. "/go" .. t) do
        if uv.hrtime() > deadline then os.exit(2) end
    end
    local p = dir .. "/" .. t .. ".log"
    local line = "writer " .. id .. " trial " .. t .. " " .. string.rep(id, id == "a" and 90 or 20)
    if how == "rlog" then
        require("loomworks.daemon.rlog").write_path(p, line)
    else
        log = require("loomworks.log").new({ path = p })
        log:info(line)
    end
end
]], H.REPO, dir, id, n, how))
    f:close()
    local code
    local h, pid = uv.spawn(vim.v.progpath, { args = { "--headless", "-u", "NONE", "-l", script } },
        function(c) code = c end)
    assert.is_not_nil(h, tostring(pid))
    H.track(pid)
    return function() return code end
end

local function race(how)
    local dir = H.tmp()
    local n = 40
    local a, b = writer(dir, "a", n, how), writer(dir, "b", n, how)
    -- Both writers are up (busy-waiting for the first go file).
    vim.wait(1500)
    for t = 1, n do
        local f = assert(io.open(dir .. "/go" .. t, "w")); f:close()
        -- Both appended (or one gave up) before the next trial starts.
        vim.wait(1000, function()
            local g = io.open(dir .. "/" .. t .. ".log", "rb")
            if not g then return false end
            local s = g:read("*a"); g:close()
            local _, k = s:gsub("writer ", "")
            return k >= 2
        end, 2)
    end
    assert.is_true(vim.wait(60000, function() return a() ~= nil and b() ~= nil end, 20))
    assert.equals(0, a())
    assert.equals(0, b())
    local lost = {}
    for t = 1, n do
        local g = assert(io.open(dir .. "/" .. t .. ".log", "rb"))
        local s = g:read("*a"); g:close()
        for _, id in ipairs({ "a", "b" }) do
            if not s:find("writer " .. id .. " trial " .. t .. " ", 1, true) then lost[#lost + 1] = id .. t end
        end
    end
    assert.same({}, lost)
end

describe("concurrent appends to a fresh log never lose a line", function()
    after_each(function() H.cleanup() end)

    it("the runtime log (a client and the daemon it launched, §19.10)", function()
        race("rlog")
    end)

    it("the workspace log (the editor and lw commands)", function()
        race("log")
    end)

    it("leaves no writer running", function()
        H.cleanup()
        assert.equals(0, H.survivors)
    end)
end)

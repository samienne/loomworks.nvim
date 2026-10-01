-- Crash-consistent multi-file commits (spec §19.4), against a real process
-- killed at each commit step (tests/fixtures/txn_crasher.lua): the next load
-- yields the old or the new state, never a mix; journal validation; refusal
-- of an unrecoverable journal; `lw unlock --journal`; a commit in progress.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local txn = require("loomworks.txn")
local op_lock = require("loomworks.op_lock")
local L = require("tests.lock_helpers")
local uv = vim.uv or vim.loop

local CRASHER = L.REPO .. "/tests/fixtures/txn_crasher.lua"

--- Run the crasher on `root`, dying at `step`; returns its exit code.
local function crash(root, step)
    local code
    local handle = uv.spawn(vim.v.progpath, {
        args = { "--headless", "--clean", "-l", CRASHER, L.REPO, root, step },
        stdio = { nil, nil, nil },
    }, function(c) code = c end)
    assert(handle, "could not spawn the crasher")
    assert(vim.wait(30000, function() return code ~= nil end, 20), "crasher did not finish")
    return code
end

local function snapshot(root)
    return { user = L.read(root .. "/.nvim/loomworks.user.json"),
        cache = L.read(root .. "/.nvim/loomworks.cache.json") }
end

--- Which state the two files are in relative to `before` (the rename rewrites
--- both): "old" (both unchanged), "new" (both rewritten), or "mix".
local function state(root, before)
    local now = snapshot(root)
    local u_new, c_new = now.user ~= before.user, now.cache ~= before.cache
    if u_new and c_new then
        assert(now.user:find('"App2"', 1, true), "the working copy is the renamed one")
        return "new"
    end
    if not u_new and not c_new then return "old" end
    return "mix"
end

--- Recover the way the next operation-lock holder does (no load-time saves
--- in between, so the files show exactly what the recovery left).
local function recover(root)
    local tok, msg = op_lock.acquire(root, "test")
    assert(tok, msg)
    local line = tok.recovered
    op_lock.release(tok)
    return line
end

local function journal(root) return root .. "/.nvim/loomworks.txn.json" end

describe("multi-file commit (§19.4)", function()
    after_each(function() L.cleanup(); op_lock.release_all() end)

    it("a completed commit leaves both files new, no journal and no staged copies", function()
        local root = L.make_ws()
        local before = snapshot(root)
        assert.equals(0, crash(root, "none"))
        assert.equals("new", state(root, before))
        assert.is_nil(uv.fs_stat(journal(root)))
        assert.same({}, txn.strays(root))
    end)

    local cases = {
        { step = "staged", expect = "old" },  -- crash during check/stage
        { step = "journal", expect = "new" }, -- journal written, nothing applied
        { step = "apply1", expect = "new" },  -- after the first rename
        { step = "apply2", expect = "new" },  -- after the second rename
        { step = "finish", expect = "new" },  -- before the journal is removed
    }
    for _, c in ipairs(cases) do
        it("killed after step '" .. c.step .. "': recovery yields the " .. c.expect .. " state", function()
            local root = L.make_ws()
            local before = snapshot(root)
            assert.equals(77, crash(root, c.step))
            local line = recover(root)
            assert.equals(c.expect, state(root, before))
            assert.is_nil(uv.fs_stat(journal(root)), "the journal is gone after recovery")
            assert.same({}, txn.strays(root), "stray staged copies are removed")
            if c.step ~= "staged" then
                assert.is_truthy(line and line:find("completed an interrupted rename", 1, true), tostring(line))
            end
        end)
    end

    it("loading the workspace completes an interrupted commit first, and says so", function()
        local root = L.make_ws()
        assert.equals(77, crash(root, "apply1"))
        local r = L.capture(function() cli._load_workspace(root, false) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.is_truthy(r.stderr:find("completed an interrupted rename (pid ", 1, true), r.stderr)
        assert.is_truthy(r.stderr:find(".nvim/loomworks.user.json, .nvim/loomworks.cache.json", 1, true),
            r.stderr)
        assert.is_nil(uv.fs_stat(journal(root)))
        local ws = cli._load_workspace(root, false)
        local keys = {}
        for _, p in pairs(ws._projects) do keys[#keys + 1] = p.key end
        assert.is_true(vim.tbl_contains(keys, "App2"), table.concat(keys, ","))
    end)

    it("a target changed by a writer that ignores the journal refuses the workspace; unlock --journal clears it", function()
        local root = L.make_ws()
        assert.equals(77, crash(root, "journal"))
        local p = root .. "/.nvim/loomworks.user.json"
        local f = assert(io.open(p, "ab")); f:write("\n"); f:close() -- an older version rewrote it
        local r = L.capture(function() cli._load_workspace(root, false) end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("loomworks.txn.json", 1, true), r.stderr)
        assert.is_truthy(r.stderr:find("lw unlock --journal", 1, true), r.stderr)
        assert.is_not_nil(uv.fs_stat(journal(root)), "nothing is touched on refusal")
        r = L.capture(function() cli.cmd_unlock(nil, { "unlock", "--journal" }, root) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.is_truthy(r.stderr:find("WARNING", 1, true), r.stderr)
        assert.is_nil(uv.fs_stat(journal(root)))
        assert.same({}, txn.strays(root))
    end)

    it("a journal naming anything but a workspace file is refused", function()
        local root = L.make_ws()
        local f = assert(io.open(journal(root), "wb"))
        f:write(vim.json.encode({ id = "abc", operation = "publish", entries = {
            { file = "../../etc/passwd", action = "replace", sha256_new = string.rep("a", 64) } } }))
        f:close()
        local r = L.capture(function() cli._load_workspace(root, false) end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("names a file that is not a workspace file", 1, true), r.stderr)
    end)

    it("stray staged files are only ever exact `<workspace file>.txn-<hex>` names", function()
        local root = L.make_ws()
        local nvim = root .. "/.nvim/"
        for _, n in ipairs({ "loomworks.user.json.txn-1a2b", "loomworks.cache.json.txn-ff",
                "other.json.txn-12", "loomworks.user.json.txn-xyz", "loomworks.user.json.txn-12.keep" }) do
            local f = assert(io.open(nvim .. n, "wb")); f:write("x"); f:close()
        end
        local tok = assert(op_lock.acquire(root, "test"))
        op_lock.release(tok)
        assert.is_nil(uv.fs_stat(nvim .. "loomworks.user.json.txn-1a2b"))
        assert.is_nil(uv.fs_stat(nvim .. "loomworks.cache.json.txn-ff"))
        assert.is_not_nil(uv.fs_stat(nvim .. "other.json.txn-12"))
        assert.is_not_nil(uv.fs_stat(nvim .. "loomworks.user.json.txn-xyz"))
        assert.is_not_nil(uv.fs_stat(nvim .. "loomworks.user.json.txn-12.keep"))
    end)

    it("a journal whose writer still holds the operation lock is a commit in progress: busy", function()
        local root = L.make_ws()
        assert.equals(77, crash(root, "journal"))
        L.hold(op_lock.path(root), "rename") -- the "writer", alive
        local r = L.capture(function() cli._load_workspace(root, false) end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("workspace busy: rename", 1, true), r.stderr)
        assert.is_not_nil(uv.fs_stat(journal(root)), "never completed under a live writer")
    end)

    it("publish writes loomworks.json and the working copy as one commit", function()
        local root = L.make_ws()
        local r = L.capture(function() cli.cmd_publish(root) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.is_nil(uv.fs_stat(journal(root)))
        assert.same({}, txn.strays(root))
        assert.is_truthy((L.read(root .. "/loomworks.json") or ""):find("Dev", 1, true))
    end)
end)

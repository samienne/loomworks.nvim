-- Per-user state outside the workspace (spec §16.40): housekeeping and
-- `lw cleanup`. Every leftover type is planted in a sandboxed data / temp /
-- exe directory, aged with utime, and must be removed; recent items, near-miss
-- names, links (symlinks, junctions, hard links), in-use device locks and
-- protected pinned releases must survive.

local hk = require("loomworks.housekeeping")
local proc = require("loomworks.proc")
local lr = require("loomworks.lock_record")
local uv = vim.uv or vim.loop

local IS_WIN = package.config:sub(1, 1) == "\\"
local SHA = string.rep("a", 64)
local SHA2 = string.rep("b", 64)
local NOW = os.time()
local OLD = NOW - 40 * 86400 -- older than every threshold
local HEX24 = string.rep("c", 24)

local function mkdir(p) vim.fn.mkdir(p, "p"); return p end
local function write(p, body)
    mkdir(p:match("^(.*)/[^/]+$"))
    local f = assert(io.open(p, "wb")); f:write(body or "x"); f:close()
    return p
end
local function age(p, t) assert(uv.fs_utime(p, t or OLD, t or OLD)) end
local function exists(p) return uv.fs_lstat(p) ~= nil end
local function read(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end

--- A directory link (junction on Windows, symlink elsewhere); false when the
--- platform refuses (then the case is skipped).
local function dirlink(target, link)
    local ok = uv.fs_symlink(target, link, IS_WIN and { junction = true } or nil)
    return ok and true or false
end

local function sandbox()
    local base = (vim.fn.tempname():gsub("\\", "/"))
    local real = mkdir(base)
    real = (uv.fs_realpath(real) or real):gsub("\\", "/")
    local sb = {
        base = real,
        data = mkdir(real .. "/data"),
        tmp = mkdir(real .. "/tmp"),
        bin = mkdir(real .. "/bin"),
        root = mkdir(real .. "/ws"),
        outside = mkdir(real .. "/outside"),
        cache = mkdir(real .. "/cache"),
    }
    write(sb.outside .. "/precious.txt", "precious")
    write(sb.data .. "/trust.key") -- lw's data directory (marker, §16.40)
    return sb
end

local function opts(sb, extra)
    local o = {
        data = sb.data, tmp_dirs = { sb.tmp }, run_dirs = {}, sockets = false,
        exe = sb.bin .. "/lw.exe", bundle = false, pin_version = false, now = NOW,
        device_lock_dir_default = true, is_windows = true, force = true,
        cache_dir = sb.cache,
    }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

local function paths_of(items)
    local s = {}
    for _, it in ipairs(items) do s[it.path] = it.kind end
    return s
end

--- Plant one of every default-set leftover (aged), returning their paths.
local function plant_leftovers(sb)
    local d = sb.data
    local list = {
        write(d .. "/.dl-0.1.40.zip"),
        write(d .. "/.stage-0.1.40/loomworks/cli.lua"):match("^(.*)/loomworks/cli%.lua$"),
        write(d .. "/release-notes-seen.tmp"),
        write(d .. "/release-notes-seen.tmp123456"),
        write(d .. "/pinned/.dl-" .. SHA .. "-0.1.30.zip"),
        write(d .. "/pinned/.stage-" .. SHA .. "-0.1.30/x.lua"):match("^(.*)/x%.lua$"),
        write(d .. "/pinned/lw-0.1.30-lw-windows-x86_64.exe.dl"),
        write(d .. "/pinned/.trash-0123abcd/x.lua"):match("^(.*)/x%.lua$"),
        write(d .. "/modules/.dl-ohos.zip"),
        write(d .. "/modules/.stage-ohos/m/lua/x.lua"):match("^(.*)/m/lua/x%.lua$"),
        write(d .. "/device-locks/SER1.leftover.tmp.4242"),
        write(d .. "/device-locks/SER1.lock.reclaim.0abc12"),
        write(d .. "/daemon/logs/0123456789abcdef.log"),
        write(d .. "/daemon/logs/0123456789abcdef.log.1"),
        write(sb.tmp .. "/lw-test-" .. HEX24 .. ".xml"),
        write(sb.tmp .. "/lw-describe-" .. HEX24 .. ".txt"),
        write(sb.bin .. "/lw.exe.new"),
        write(sb.bin .. "/lw.exe.old"),
        write(sb.root .. "/.nvim/tmp/lw-test-" .. HEX24 .. ".xml"),
        write(sb.root .. "/.nvim/tmp/lw-describe-" .. HEX24 .. ".txt"),
        write(sb.cache .. "/tools.json.4242." .. HEX24 .. ".tmp"),
    }
    if IS_WIN then list[#list + 1] = write(sb.tmp .. "/lw_vcvars_x64_0123456789abcdef.bat") end
    for _, p in ipairs(list) do age(p) end
    return list
end

describe("housekeeping (spec §16.40)", function()
    local sb
    before_each(function() sb = sandbox() end)
    after_each(function() require("loomworks.io").rm_rf(sb.base) end)

    it("finds and removes every leftover type, and nothing else", function()
        local planted = plant_leftovers(sb)
        -- Kept items that sit in the same directories.
        local keep = {
            write(sb.data .. "/trust.key"), write(sb.data .. "/release-notes-seen"),
            write(sb.data .. "/lua-0.1.40/loomworks/cli.lua"),
            write(sb.data .. "/modules/ohos/lua/x.lua"),
            write(sb.data .. "/pinned/" .. SHA .. "/lua-0.1.30/loomworks/cli.lua"),
            write(sb.data .. "/pinned/lw-0.1.30-lw-windows-x86_64.exe"),
            write(sb.data .. "/device-locks/SER1.leftover"),
            write(sb.bin .. "/lw.exe"),
        }
        for _, p in ipairs(keep) do age(p) end
        local items = hk.collect(opts(sb, { root = sb.root }))
        local got = paths_of(items)
        for _, p in ipairs(planted) do assert.is_truthy(got[p], "not found: " .. p) end
        assert.equals(#planted, #items)
        for _, it in ipairs(items) do assert.is_true(hk.remove(it, NOW), it.path) end
        for _, p in ipairs(planted) do assert.is_false(exists(p), p) end
        for _, p in ipairs(keep) do assert.is_true(exists(p), p) end
    end)

    it("leaves recent leftovers alone (each pattern's age)", function()
        local recent = NOW - 600 -- 10 minutes: younger than every threshold but the 0-age ones
        for _, p in ipairs(plant_leftovers(sb)) do age(p, recent) end
        local got = paths_of(hk.collect(opts(sb, { root = sb.root })))
        -- Only the any-age ones qualify.
        local expect = {
            [sb.data .. "/pinned/.trash-0123abcd"] = true,
            [sb.bin .. "/lw.exe.old"] = true,
        }
        for p in pairs(got) do assert.is_true(expect[p] == true, "removed while recent: " .. p) end
        -- A vcvars probe is removed after an hour, a legacy log only after 30 days.
        if IS_WIN then
            local bat = sb.tmp .. "/lw_vcvars_x64_0123456789abcdef.bat"
            age(bat, NOW - 2 * 3600)
            assert.is_truthy(paths_of(hk.collect(opts(sb)))[bat])
        end
        local log = sb.data .. "/daemon/logs/0123456789abcdef.log"
        age(log, NOW - 5 * 86400)
        assert.is_nil(paths_of(hk.collect(opts(sb)))[log])
        assert.is_truthy(paths_of(hk.collect(opts(sb, { legacy_logs_any_age = true })))[log])
        -- A modification time in the future counts as recent.
        local dl = sb.data .. "/.dl-0.1.40.zip"
        age(dl, NOW + 86400 * 3)
        assert.is_nil(paths_of(hk.collect(opts(sb)))[dl])
    end)

    it("never touches near-miss names", function()
        local d = sb.data
        local near = {
            write(d .. "/.dl-0.1.40.zip.bak"), write(d .. "/.dl-.zip"), write(d .. "/x.dl-0.1.40.zip"),
            write(d .. "/.stage-0.1.40 copy/x"), write(d .. "/release-notes-seen.tmpx"),
            write(d .. "/.stage-/x"),
            write(d .. "/pinned/.dl-" .. SHA:sub(2) .. "-0.1.30.zip"),
            write(d .. "/pinned/.dl-" .. SHA:upper() .. "-0.1.30.zip"),
            write(d .. "/pinned/.trash-zz/x"), write(d .. "/pinned/lw-0.1.30-lw-plan9.dl"),
            write(d .. "/modules/.dl-.hidden.zip"), write(d .. "/modules/.stage-.x/y"),
            write(d .. "/daemon/logs/0123456789abcde.log"), write(d .. "/daemon/logs/notes.log"),
            write(d .. "/device-locks/SER1.leftover.tmp.12ab"),
            write(sb.tmp .. "/lw-test-xyz.xml"), write(sb.tmp .. "/lw-test-" .. HEX24 .. ".xml.keep"),
            write(sb.tmp .. "/lw-describe-short1.txt"),
            write(sb.tmp .. "/lw_vcvars_bogus_0123456789abcdef.bat"),
            write(sb.tmp .. "/lw_vcvars_x64_0123.bat"),
            write(sb.bin .. "/lw.exe.older"), write(sb.bin .. "/other.exe.old"),
            write(sb.root .. "/.nvim/tmp/notes.txt"),
            write(sb.cache .. "/tools.json.tmp"), write(sb.cache .. "/tools.json.12ab." .. HEX24 .. ".tmp"),
            write(sb.cache .. "/tools.json.4242.abc.tmp"), write(sb.cache .. "/xtools.json.4242." .. HEX24 .. ".tmp"),
            write(sb.cache .. "/tools.json.4242." .. HEX24 .. ".tmp.bak"),
        }
        for _, p in ipairs(near) do
            age((p:gsub("/[^/]+$", "")), OLD)
            age(p)
        end
        local items = hk.collect(opts(sb, { root = sb.root, all = true }))
        assert.same({}, paths_of(items))
    end)

    it("never follows or removes a planted link (symlink / junction / hard link)", function()
        local d = sb.data
        -- A directory link at a leftover's name: skipped, target intact.
        local stage_link = d .. "/.stage-0.1.41"
        local linked = dirlink(sb.outside, stage_link)
        -- A leftover directory that contains a link to the outside.
        local stage = mkdir(d .. "/.stage-0.1.42")
        write(stage .. "/x.lua")
        local inner = dirlink(sb.outside, stage .. "/escape")
        age(stage)
        -- A hard link at a leftover's name: only the name goes.
        local hard = d .. "/.dl-0.1.43.zip"
        local hl = uv.fs_link(sb.outside .. "/precious.txt", hard)
        if hl then age(hard) end
        -- A file symlink at a leftover's name (where the OS allows one).
        local flink = d .. "/.dl-0.1.44.zip"
        local fl = uv.fs_symlink(sb.outside .. "/precious.txt", flink)

        local items = hk.collect(opts(sb))
        local got = paths_of(items)
        if linked then assert.is_nil(got[stage_link]) end
        if fl then assert.is_nil(got[flink]) end
        assert.is_truthy(got[stage])
        for _, it in ipairs(items) do assert.is_true(hk.remove(it, NOW), it.path) end
        assert.equals("precious", read(sb.outside .. "/precious.txt"))
        if linked then assert.is_true(exists(stage_link)) end
        if inner then assert.is_false(exists(stage)) end
        if hl then assert.is_false(exists(hard)) end
        if fl then assert.is_true(exists(flink)) end
    end)

    it("tool cache temp files (§16.43): only regular files directly in <cache>, exact name, older than 24 h", function()
        local name = "tools.json.4242." .. HEX24 .. ".tmp"
        local old = write(sb.cache .. "/" .. name)
        age(old)
        -- Survivors: wrong prefix, young file, a link and a directory at a
        -- matching name, a matching file in a subdirectory, the cache itself.
        local wrong = write(sb.cache .. "/tool.json.4242." .. HEX24 .. ".tmp"); age(wrong)
        local young = write(sb.cache .. "/tools.json.4243." .. HEX24 .. ".tmp")
        age(young, NOW - 23 * 3600)
        local dir = mkdir(sb.cache .. "/tools.json.4244." .. HEX24 .. ".tmp")
        write(dir .. "/inner"); age(dir .. "/inner"); age(dir)
        local sub = write(sb.cache .. "/sub/tools.json.4245." .. HEX24 .. ".tmp")
        age(sub); age(sb.cache .. "/sub")
        local dlink = sb.cache .. "/tools.json.4246." .. HEX24 .. ".tmp"
        local dl = dirlink(sb.outside, dlink)
        local flink = sb.cache .. "/tools.json.4247." .. HEX24 .. ".tmp"
        local fl = uv.fs_symlink(sb.outside .. "/precious.txt", flink)
        local cache_file = write(sb.cache .. "/tools.json", "{}"); age(cache_file)

        local items = hk.collect(opts(sb))
        local got = paths_of(items)
        assert.same({ [old] = "temp file" }, got)
        for _, it in ipairs(items) do assert.is_true(hk.remove(it, NOW), it.path) end
        assert.is_false(exists(old))
        for _, p in ipairs({ wrong, young, dir, dir .. "/inner", sub, cache_file }) do
            assert.is_true(exists(p), p)
        end
        if dl then assert.is_true(exists(dlink)) end
        if fl then assert.is_true(exists(flink)) end
        assert.equals("precious", read(sb.outside .. "/precious.txt"))
        -- A <cache> that is itself a link is not scanned.
        local real_cache = mkdir(sb.base .. "/real-cache")
        local o2 = write(real_cache .. "/" .. name); age(o2)
        local link_cache = sb.base .. "/link-cache"
        if dirlink(real_cache, link_cache) then
            assert.same({}, paths_of(hk.collect(opts(sb, { cache_dir = link_cache }))))
        end
        -- Re-checked before removal: replaced by a directory meanwhile -> kept.
        local again = write(sb.cache .. "/" .. name); age(again)
        local items2 = hk.collect(opts(sb))
        assert.equals(1, #items2)
        assert.is_true(uv.fs_unlink(again)); mkdir(again)
        assert.is_false((hk.remove(items2[1], NOW)))
        assert.is_true(exists(again))
    end)

    it("ignores a fixed directory that is itself a link (realpath check)", function()
        local real_pinned = mkdir(sb.outside .. "/pinned")
        write(real_pinned .. "/.dl-" .. SHA .. "-0.1.30.zip")
        age(real_pinned .. "/.dl-" .. SHA .. "-0.1.30.zip")
        if not dirlink(real_pinned, sb.data .. "/pinned") then return end
        local tmp_link = sb.base .. "/tmplink"
        write(sb.outside .. "/lw-test-" .. HEX24 .. ".xml")
        age(sb.outside .. "/lw-test-" .. HEX24 .. ".xml")
        dirlink(sb.outside, tmp_link)
        local items = hk.collect(opts(sb, { tmp_dirs = { tmp_link }, all = true }))
        assert.same({}, paths_of(items))
        assert.is_true(exists(real_pinned .. "/.dl-" .. SHA .. "-0.1.30.zip"))
    end)

    it("device locks: a dead holder's lock without a program goes; live or program-holding ones stay", function()
        local dir = mkdir(sb.data .. "/device-locks")
        local self_st = proc.self_start_time()
        local dead_st = proc.method_of(self_st) .. ":0"
        local function lock(name, rec)
            rec.host = rec.host or lr.this_host()
            rec.lock_nonce = rec.lock_nonce or name
            rec.kind, rec.operation = "lw", "device run"
            write(dir .. "/" .. name .. ".lock", vim.json.encode(rec))
            age(dir .. "/" .. name .. ".lock")
            return dir .. "/" .. name .. ".lock"
        end
        local pid = uv.os_getpid()
        local dead = lock("DEAD", { pid = pid, start_time = dead_st })
        local live = lock("LIVE", { pid = pid, start_time = self_st })
        local prog = lock("PROG", { pid = pid, start_time = dead_st, device_pid = 77, nonce = "ab",
            program = "/data/x" })
        local foreign = lock("FOREIGN", { pid = pid, start_time = dead_st, host = "some-other-host" })
        local items = hk.collect(opts(sb))
        local got = paths_of(items)
        assert.equals("device lock", got[dead])
        assert.is_nil(got[live]); assert.is_nil(got[prog]); assert.is_nil(got[foreign])
        for _, it in ipairs(items) do assert.is_true(hk.remove(it, NOW), it.path) end
        assert.is_false(exists(dead))
        assert.is_true(exists(live)); assert.is_true(exists(prog)); assert.is_true(exists(foreign))
        -- An overridden lock directory is never cleaned.
        local again = lock("DEAD2", { pid = pid, start_time = dead_st })
        assert.is_nil(paths_of(hk.collect(opts(sb, { device_lock_dir_default = false })))[again])
    end)

    it("pinned releases: only with --all, never the pinned version, the running ones, or recently used", function()
        local p = sb.data .. "/pinned"
        local old_b = write(p .. "/" .. SHA .. "/lua-0.1.30/loomworks/cli.lua"):match("^(.*)/loomworks/cli%.lua$")
        local pinned_b = write(p .. "/" .. SHA2 .. "/lua-0.1.31/loomworks/cli.lua"):match("^(.*)/loomworks/cli%.lua$")
        local running_b = write(p .. "/" .. SHA2 .. "/lua-0.1.32/loomworks/cli.lua"):match("^(.*)/loomworks/cli%.lua$")
        local recent_b = write(p .. "/" .. SHA2 .. "/lua-0.1.33/loomworks/cli.lua"):match("^(.*)/loomworks/cli%.lua$")
        local old_bin = write(p .. "/lw-0.1.30-lw-linux-x86_64")
        local pinned_bin = write(p .. "/lw-0.1.31-lw-linux-x86_64")
        local running_bin = write(p .. "/lw-0.1.34-lw-windows-x86_64.exe")
        for _, x in ipairs({ old_b, pinned_b, running_b, old_bin, pinned_bin, running_bin }) do age(x) end
        age(recent_b, NOW - 3 * 86400)
        local o = opts(sb, { pin_version = "0.1.31", exe = running_bin, bundle = running_b })
        assert.same({}, paths_of(hk.collect(o)))
        o.all = true
        local items, info = hk.collect(o)
        local got = paths_of(items)
        assert.equals("pinned release", got[old_b])
        assert.equals("pinned binary", got[old_bin])
        assert.equals(2, #items)
        assert.equals(5, info.kept_pinned)
        -- A shorter threshold reaches the recently used one.
        o.all, o.pinned_age = false, 86400
        assert.is_truthy(paths_of(hk.collect(o))[recent_b])
        o.pinned_age = nil
        o.all = true
        for _, it in ipairs(items) do assert.is_true(hk.remove(it, NOW), it.path) end
        assert.is_false(exists(old_b)); assert.is_false(exists(p .. "/" .. SHA)) -- emptied sha dir removed
        assert.is_false(exists(old_bin))
        for _, x in ipairs({ pinned_b, running_b, recent_b, pinned_bin, running_bin }) do
            assert.is_true(exists(x), x)
        end
        -- No trash left behind.
        for n in vim.fs.dir(p) do assert.is_nil(n:match("^%.trash"), n) end
    end)

    it("the startup pass runs at most once a day, logs to the workspace, never raises", function()
        plant_leftovers(sb)
        mkdir(sb.root .. "/.nvim")
        local o = opts(sb)
        local removed, failed = hk.startup(sb.root, o)
        assert.is_true(removed > 0)
        assert.equals(0, failed)
        local log = read(sb.root .. "/.nvim/loomworks.daemon.log") or ""
        assert.is_truthy(log:find("housekeeping: removed " .. removed, 1, true), log)
        assert.is_true(exists(sb.data .. "/.housekeeping"))
        -- Within the day: nothing runs, the new leftover stays.
        local again = write(sb.data .. "/.dl-0.1.50.zip"); age(again)
        assert.is_nil((hk.startup(sb.root, o)))
        assert.is_true(exists(again))
        -- A day later it runs again.
        o.now = NOW + 86400 + 5
        assert.is_true((hk.startup(sb.root, o)) >= 1)
        assert.is_false(exists(again))
        -- A stamp in the future (clock moved back) does not hold it off.
        age(sb.data .. "/.housekeeping", NOW + 30 * 86400)
        o.now = NOW
        assert.is_not_nil((hk.startup(nil, o)))
        -- No data directory: nothing, no error.
        assert.is_nil((hk.startup(nil, opts(sb, { data = sb.base .. "/missing" }))))
        -- A stamp that is not a file: the pass never runs.
        local d2 = mkdir(sb.base .. "/data2")
        mkdir(d2 .. "/.housekeeping")
        assert.is_nil((hk.startup(nil, opts(sb, { data = d2 }))))
    end)

    it("concurrent passes: every removal tolerates another remover", function()
        plant_leftovers(sb)
        local a = hk.collect(opts(sb, { root = sb.root }))
        local b = hk.collect(opts(sb, { root = sb.root }))
        for i = 1, #a do
            assert.is_true(hk.remove(a[i], NOW), a[i].path)
            assert.is_true(hk.remove(b[i], NOW), b[i].path) -- already gone: success
        end
    end)

    it("re-checks before removing: a leftover replaced by something else is kept", function()
        local p = write(sb.data .. "/.dl-0.1.40.zip"); age(p)
        local items = hk.collect(opts(sb))
        assert.equals(1, #items)
        os.remove(p)
        mkdir(p) -- now a directory
        local ok = hk.remove(items[1], NOW)
        assert.is_false(ok)
        assert.is_true(exists(p))
        -- Freshly rewritten: younger than its age now.
        local q = write(sb.data .. "/.dl-0.1.41.zip"); age(q)
        local it2 = hk.collect(opts(sb))
        write(q, "fresh")
        for _, it in ipairs(it2) do
            if it.path == q then assert.is_false((hk.remove(it, NOW))) end
        end
        assert.is_true(exists(q))
    end)
end)

describe("lw cleanup (spec §16.40)", function()
    local sb
    before_each(function() sb = sandbox() end)
    after_each(function() require("loomworks.io").rm_rf(sb.base) end)

    local function run(args, o)
        local lines, died = {}, nil
        local host = {
            out = function(s) lines[#lines + 1] = s end,
            die = function(msg, code) died = { msg = msg, code = code }; error("die", 0) end,
        }
        local ok, code = pcall(hk.cmd, sb.root, args, host, o)
        return { code = ok and code or (died and died.code), lines = lines, text = table.concat(lines, "\n"), died = died }
    end

    it("dry run lists kind, path, size, age, and removes nothing; --yes removes", function()
        local planted = plant_leftovers(sb)
        local r = run({ "cleanup" }, opts(sb))
        assert.equals(0, r.code)
        assert.is_truthy(r.text:find("dry run", 1, true), r.text)
        assert.is_truthy(r.text:find(sb.data .. "/.dl-0.1.40.zip", 1, true), r.text)
        assert.is_truthy(r.text:find("Remove them with: lw cleanup --yes", 1, true), r.text)
        assert.is_truthy(r.text:find("40 days old", 1, true), r.text)
        for _, p in ipairs(planted) do assert.is_true(exists(p), p) end
        local r2 = run({ "cleanup", "--dry-run" }, opts(sb))
        assert.equals(r.text, r2.text)
        local y = run({ "cleanup", "--yes" }, opts(sb))
        assert.equals(0, y.code, y.text)
        assert.is_truthy(y.text:find("^removed", 1) or y.text:find("\nremoved", 1, true), y.text)
        for _, p in ipairs(planted) do assert.is_false(exists(p), p) end
        assert.is_true(exists(sb.data .. "/.housekeeping"))
        local n = run({ "cleanup" }, opts(sb))
        assert.is_truthy(n.text:find("nothing to clean up", 1, true), n.text)
    end)

    it("--all lists pinned releases and counts the kept ones", function()
        local old = write(sb.data .. "/pinned/" .. SHA .. "/lua-0.1.30/loomworks/cli.lua")
        local keep = write(sb.data .. "/pinned/" .. SHA2 .. "/lua-0.1.31/loomworks/cli.lua")
        age(old:match("^(.*)/loomworks/cli%.lua$")); age(keep:match("^(.*)/loomworks/cli%.lua$"))
        local r = run({ "cleanup", "--all" }, opts(sb, { pin_version = "0.1.31" }))
        assert.is_truthy(r.text:find("pinned release", 1, true), r.text)
        assert.is_truthy(r.text:find("Kept 1 pinned release file", 1, true), r.text)
        assert.is_truthy(r.text:find("lw cleanup --yes --all", 1, true), r.text)
        local r2 = run({ "cleanup", "--pinned-older-than", "90d" }, opts(sb, { pin_version = "0.1.31" }))
        assert.is_nil(r2.text:find("lua-0.1.30", 1, true), r2.text)
    end)

    it("plain lw cleanup lists legacy runtime logs of any age; the startup pass keeps 30 days", function()
        local log = write(sb.data .. "/daemon/logs/0123456789abcdef.log")
        local log1 = write(sb.data .. "/daemon/logs/0123456789abcdef.log.1")
        age(log, NOW - 86400); age(log1, NOW - 60)
        local r = run({ "cleanup" }, opts(sb))
        assert.equals(0, r.code)
        assert.is_nil(r.text:find("nothing to clean up", 1, true), r.text)
        assert.is_truthy(r.text:find("runtime log  " .. log .. " ", 1, true), r.text)
        assert.is_truthy(r.text:find(log1, 1, true), r.text)
        -- The silent startup pass's set (housekeeping) leaves them until 30 days.
        local got = paths_of(hk.collect(opts(sb)))
        assert.is_nil(got[log]); assert.is_nil(got[log1])
        assert.is_true(hk.startup(nil, opts(sb, { now = NOW })) ~= nil)
        assert.is_true(exists(log)); assert.is_true(exists(log1))
        -- --yes removes them.
        local y = run({ "cleanup", "--yes" }, opts(sb))
        assert.equals(0, y.code, y.text)
        assert.is_false(exists(log)); assert.is_false(exists(log1))
    end)

    it("says exactly what --all adds (pinned releases only), in the hint and the help", function()
        local r = run({ "cleanup" }, opts(sb))
        assert.is_truthy(r.text:find("nothing to clean up", 1, true), r.text)
        assert.is_truthy(r.text:find("`--all` adds the pinned releases unused for 30 days", 1, true), r.text)
        -- `lw help cleanup` (the HELP table's source text).
        local src = read((vim.uv or vim.loop).cwd() .. "/lua/loomworks/cli.lua")
        local help = src:match("\n  cleanup = %[%[(.-)%]%]")
        assert.is_truthy(help, "no cleanup help topic")
        assert.is_nil(help:find("every old runtime log", 1, true), help)
        assert.is_truthy(help:find("days (that is all it adds)", 1, true), help)
    end)

    it("reports a removal that fails and exits 1", function()
        local p = write(sb.data .. "/.dl-0.1.40.zip"); age(p)
        local o = opts(sb)
        local items = hk.collect(o)
        items[1].remove = function() return false, "in use" end
        local orig = hk.collect
        hk.collect = function() return items, { kept_pinned = 0 } end
        local r = run({ "cleanup", "--yes" }, o)
        hk.collect = orig
        assert.equals(1, r.code)
        assert.is_truthy(r.text:find("FAILED", 1, true), r.text)
    end)

    it("usage errors exit 2", function()
        for _, args in ipairs({
            { "cleanup", "--yes", "--dry-run" },
            { "cleanup", "--pinned-older-than", "soon" },
            { "cleanup", "--pinned-older-than" },
            { "cleanup", "extra" },
        }) do
            local r = run(args, opts(sb))
            assert.equals(2, r.code, table.concat(args, " "))
        end
        assert.equals(90 * 86400, hk.parse_duration("90d"))
        assert.equals(12 * 3600, hk.parse_duration("12h"))
        assert.equals(45, hk.parse_duration("45"))
        assert.is_nil(hk.parse_duration("0d"))
        assert.is_nil(hk.parse_duration("1.5d"))
    end)
end)

describe("housekeeping review fixes (spec §16.40)", function()
    local sb
    before_each(function() sb = sandbox() end)
    after_each(function() require("loomworks.io").rm_rf(sb.base) end)

    it("<exe>.old is a self-update leftover only on Windows; <exe>.new on every OS", function()
        local old = write(sb.bin .. "/lw.exe.old"); age(old)
        local new = write(sb.bin .. "/lw.exe.new"); age(new)
        local posix = paths_of(hk.collect(opts(sb, { is_windows = false })))
        assert.is_nil(posix[old], "a user's own lw.old copy on POSIX must stay")
        assert.is_truthy(posix[new])
        local win = paths_of(hk.collect(opts(sb, { is_windows = true })))
        assert.is_truthy(win[old]); assert.is_truthy(win[new])
    end)

    it("only real release versions in <data> and pinned; nothing at all without an lw marker", function()
        local words = {
            mkdir(sb.data .. "/.stage-old"), write(sb.data .. "/.dl-foo.zip"),
            write(sb.data .. "/.dl-1.2.zip"), mkdir(sb.data .. "/.stage-v0.1.40"),
            write(sb.data .. "/pinned/.dl-" .. SHA .. "-latest.zip"),
            mkdir(sb.data .. "/pinned/.stage-" .. SHA .. "-backup"),
            write(sb.data .. "/pinned/lw-next-lw-linux-x86_64.dl"),
        }
        for _, p in ipairs(words) do age(p) end
        local real = write(sb.data .. "/.dl-0.1.40-beta.1.zip"); age(real)
        local got = paths_of(hk.collect(opts(sb)))
        for _, p in ipairs(words) do assert.is_nil(got[p], p) end
        assert.is_truthy(got[real])
        -- A data directory with no sign of lw (e.g. LOOMWORKS_DATA_DIR=$HOME):
        -- nothing in it is scanned, and the startup pass writes no stamp.
        local home = mkdir(sb.base .. "/home")
        local dl = write(home .. "/.dl-0.1.40.zip"); age(dl)
        local mods = write(home .. "/modules/.dl-ohos.zip"); age(mods)
        local o = opts(sb, { data = home, force = true })
        local hgot = paths_of(hk.collect(o))
        assert.is_nil(hgot[dl]); assert.is_nil(hgot[mods])
        hk.startup(nil, o)
        assert.is_true(exists(dl)); assert.is_false(exists(home .. "/.housekeeping"))
        -- Any one marker makes it lw's: the trust key, a release, the stamp, pinned/.
        for _, m in ipairs({ "trust.key", "lua-0.1.40/loomworks/cli.lua", ".housekeeping" }) do
            local h2 = mkdir(sb.base .. "/h-" .. m:gsub("[/.]", "_"))
            write(h2 .. "/" .. m)
            local d2 = write(h2 .. "/.dl-0.1.40.zip"); age(d2)
            assert.is_truthy(paths_of(hk.collect(opts(sb, { data = h2 })))[d2], m)
        end
    end)

    it("the startup pass is off under LOOMWORKS_NO_HOUSEKEEPING (set for the whole suite)", function()
        assert.equals("1", vim.env.LOOMWORKS_NO_HOUSEKEEPING)
        local dl = write(sb.data .. "/.dl-0.1.40.zip"); age(dl)
        assert.is_nil((hk.startup(nil, opts(sb, { force = false }))))
        assert.is_true(exists(dl))
        assert.is_true((hk.startup(nil, opts(sb, { force = true }))) == 1)
    end)

    it("a spawned lw never runs the startup pass in the suite (no real temp / socket dirs touched)", function()
        local H = require("tests.daemon_helpers")
        local env = H.env()
        write(env.data .. "/trust.key")
        local dl = write(env.data .. "/.dl-0.1.40.zip"); age(dl)
        local root = H.workspace()
        local r = H.lw({ "status" }, { env = env, cwd = root })
        assert.equals(0, r.code, r.stderr)
        assert.is_true(exists(dl))
        assert.is_false(exists(env.data .. "/.housekeeping"))
        -- With the switch off and the temp dirs sandboxed, the same run cleans.
        local t = mkdir(sb.base .. "/ttmp")
        local env2 = H.env({ LOOMWORKS_NO_HOUSEKEEPING = false, TMP = t, TEMP = t, TMPDIR = t,
            XDG_RUNTIME_DIR = t })
        write(env2.data .. "/trust.key")
        local dl2 = write(env2.data .. "/.dl-0.1.40.zip"); age(dl2)
        local r2 = H.lw({ "status" }, { env = env2, cwd = root })
        assert.equals(0, r2.code, r2.stderr)
        assert.is_false(exists(dl2))
        H.cleanup()
    end)

    it("temp entries of another user are never candidates (POSIX)", function()
        local x = write(sb.tmp .. "/lw-test-" .. HEX24 .. ".xml"); age(x)
        local mine = paths_of(hk.collect(opts(sb)))
        assert.is_truthy(mine[x])
        if not IS_WIN then
            local other = paths_of(hk.collect(opts(sb, { uid = -12345 })))
            assert.is_nil(other[x])
        end
    end)

    it("a hard-linked read-only leftover is unlinked by name only, never made writable", function()
        local precious = sb.outside .. "/ro.txt"
        write(precious, "ro")
        assert(uv.fs_chmod(precious, tonumber("444", 8)))
        local hard = sb.data .. "/.dl-0.1.45.zip"
        if not uv.fs_link(precious, hard) then return end
        age(hard)
        local stage = mkdir(sb.data .. "/.stage-0.1.45")
        local inner = stage .. "/ro2.txt"
        assert(uv.fs_link(precious, inner))
        age(stage)
        for _, it in ipairs(hk.collect(opts(sb))) do hk.remove(it, NOW) end
        local st = uv.fs_stat(precious)
        assert.equals(0, math.floor((st.mode % 512) / 128) % 2, "the target became writable")
        assert.equals("ro", read(precious))
        if not IS_WIN then
            assert.is_false(exists(hard)); assert.is_false(exists(stage))
        end
        pcall(uv.fs_chmod, precious, tonumber("644", 8))
        pcall(uv.fs_chmod, inner, tonumber("644", 8))
        pcall(uv.fs_chmod, hard, tonumber("644", 8))
    end)

    it("a pinned bundle running from <data>/pinned records its own last use (bundle-side)", function()
        local b = write(sb.data .. "/pinned/" .. SHA .. "/lua-0.1.30/loomworks/cli.lua"):match("^(.*)/loomworks/cli%.lua$")
        local bin = write(sb.data .. "/pinned/lw-0.1.30-lw-linux-x86_64")
        local other = write(sb.base .. "/elsewhere/lua-0.1.30/loomworks/cli.lua"):match("^(.*)/loomworks/cli%.lua$")
        for _, p in ipairs({ b, bin, other }) do age(p) end
        hk.touch_running({ data = sb.data, bundle = b, exe = bin, now = NOW })
        hk.touch_running({ data = sb.data, bundle = other, exe = sb.bin .. "/lw.exe", now = NOW })
        assert.equals(NOW, uv.fs_stat(b).mtime.sec)
        assert.equals(NOW, uv.fs_stat(bin).mtime.sec)
        assert.equals(OLD, uv.fs_stat(other).mtime.sec)
    end)
end)

describe("lw cleanup wiring", function()
    it("is a command with help, completion and known options", function()
        _G.LOOMWORKS_CLI_NO_AUTORUN = true
        local cli = require("loomworks.cli")
        local opts_mod = require("loomworks.cli_options")
        assert.is_true(opts_mod.is_command("cleanup"))
        assert.is_true(cli.has_help_topic("cleanup"))
        assert.is_nil((opts_mod.find_unknown({ "cleanup", "--yes", "--all", "--pinned-older-than", "9d" })))
        assert.is_nil((opts_mod.find_unknown({ "cleanup", "--pinned-older-than=9d", "-y", "--dry-run" })))
        assert.equals("--force", (opts_mod.find_unknown({ "cleanup", "--force" })))
    end)
end)

describe("tool cache temp files (spec §16.40, §16.43)", function()
    it("an error resolving the default <cache> does not abort collect", function()
        local sb = sandbox()
        plant_leftovers(sb)
        local o = opts(sb)
        o.cache_dir = nil -- resolved by tool_cache.default_dir
        local tc = require("loomworks.tool_cache")
        local orig = tc.default_dir
        tc.default_dir = function() error("no cache dir") end
        local ok, items, info = pcall(hk.collect, o)
        tc.default_dir = orig
        assert.is_true(ok, tostring(items))
        local got = paths_of(items)
        -- Everything else is still collected (the temp dir's leftovers, …).
        assert.is_not_nil(got[sb.tmp .. "/lw-test-" .. HEX24 .. ".xml"])
        assert.is_not_nil(got[sb.data .. "/.dl-0.1.40.zip"])
        assert.is_nil(got[sb.cache .. "/tools.json.4242." .. HEX24 .. ".tmp"], "the <cache> was not scanned")
        assert.equals(1, info.errors)
        require("loomworks.io").rm_rf(sb.base)
    end)

    it("unlink_file re-checks the path itself: a directory or a link is never unlinked", function()
        local sb = sandbox()
        local d = mkdir(sb.cache .. "/tools.json.1." .. HEX24 .. ".tmp")
        local ok = hk._unlink_file({ path = d })
        assert.is_false(ok)
        assert.is_true(exists(d))
        local link = sb.cache .. "/tools.json.2." .. HEX24 .. ".tmp"
        if uv.fs_symlink(sb.outside .. "/precious.txt", link) then
            assert.is_false((hk._unlink_file({ path = link })))
            assert.is_true(exists(link), "the link itself is kept")
            assert.equals("precious", read(sb.outside .. "/precious.txt"))
        end
        -- A directory link (a junction on Windows, which an unlink would remove).
        local jl = sb.cache .. "/tools.json.4." .. HEX24 .. ".tmp"
        if dirlink(sb.outside, jl) then
            assert.is_false((hk._unlink_file({ path = jl })))
            assert.is_not_nil(uv.fs_lstat(jl), "the directory link itself is kept")
            assert.equals("precious", read(sb.outside .. "/precious.txt"))
        end
        local f = write(sb.cache .. "/tools.json.3." .. HEX24 .. ".tmp")
        assert.is_true((hk._unlink_file({ path = f })))
        assert.is_false(exists(f))
        require("loomworks.io").rm_rf(sb.base)
    end)
end)

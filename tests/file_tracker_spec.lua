local FileTracker = require("loomworks.file_tracker")

describe("FileTracker", function()
    describe("content", function()
        it("returns nil for unwatched path", function()
            local tracker = FileTracker.new({
                callback = function() end,
                read_file = function() return nil end,
                schedule = function(fn) fn() end,
            })
            assert.is_nil(tracker:content("/not/watched"))
        end)

        it("returns seeded content after watch", function()
            local tracker = FileTracker.new({
                callback = function() end,
                read_file = function(path)
                    if path == "/test/file.json" then return '{"hello": true}' end
                    return nil
                end,
                schedule = function(fn) fn() end,
            })
            tracker:watch("/test/file.json")
            assert.equals('{"hello": true}', tracker:content("/test/file.json"))
        end)

        it("returns nil for file that doesn't exist on disk", function()
            local tracker = FileTracker.new({
                callback = function() end,
                read_file = function() return nil end,
                schedule = function(fn) fn() end,
            })
            tracker:watch("/missing/file.json")
            assert.is_nil(tracker:content("/missing/file.json"))
        end)
    end)

    describe("watch", function()
        it("does not double-watch the same path", function()
            local read_count = 0
            local tracker = FileTracker.new({
                callback = function() end,
                read_file = function()
                    read_count = read_count + 1
                    return "content"
                end,
                schedule = function(fn) fn() end,
            })
            tracker:watch("/test/file.json")
            tracker:watch("/test/file.json")
            -- Should only seed once
            assert.equals(1, read_count)
        end)
    end)

    describe("unwatch", function()
        it("clears content after unwatch", function()
            local tracker = FileTracker.new({
                callback = function() end,
                read_file = function() return "content" end,
                schedule = function(fn) fn() end,
            })
            tracker:watch("/test/file.json")
            assert.equals("content", tracker:content("/test/file.json"))
            tracker:unwatch("/test/file.json")
            assert.is_nil(tracker:content("/test/file.json"))
        end)

        it("is safe to call on unwatched path", function()
            local tracker = FileTracker.new({
                callback = function() end,
                schedule = function(fn) fn() end,
            })
            -- Should not error
            tracker:unwatch("/not/watched")
        end)
    end)

    describe("sync", function()
        it("reads every watched file before delivering, inside one batch (spec §2.7)", function()
            local disk = { ["/a"] = "a1", ["/b"] = "b1", ["/c"] = "c1" }
            local tracker, seen, batches
            tracker = FileTracker.new({
                callback = function(path, content)
                    -- While /a is applied, /b already reads as its new bytes.
                    seen[#seen + 1] = { path, content, tracker:content("/b") }
                end,
                batch = function(deliver) batches = batches + 1; deliver() end,
                read_file = function(path) return disk[path] end,
                manual = true,
            })
            tracker:watch("/a"); tracker:watch("/b"); tracker:watch("/c")
            seen, batches = {}, 0
            tracker:sync()
            assert.equals(0, batches)
            disk["/a"], disk["/b"] = "a2", "b2"
            tracker:sync()
            assert.equals(1, batches)
            assert.same({ { "/a", "a2", "b2" }, { "/b", "b2", "b2" } }, seen)
        end)

        it("skips a change an earlier callback already wrote (mark_written)", function()
            local disk = { ["/a"] = "a1", ["/b"] = "b1" }
            local tracker, seen
            tracker = FileTracker.new({
                callback = function(path, content)
                    seen[#seen + 1] = path
                    if path == "/a" then disk["/b"] = "b3"; tracker:mark_written("/b", "b3") end
                end,
                read_file = function(path) return disk[path] end,
                manual = true,
            })
            tracker:watch("/a"); tracker:watch("/b")
            seen = {}
            disk["/a"], disk["/b"] = "a2", "b2"
            tracker:sync()
            assert.same({ "/a" }, seen)
            assert.equals("b3", tracker:content("/b"))
        end)

        it("a callback that throws leaves the undelivered changes for the next sync", function()
            local disk = { ["/a"] = "a1", ["/b"] = "b1" }
            local seen, fail = {}, true
            local tracker = FileTracker.new({
                callback = function(path, content)
                    if path == "/a" and fail then error("remerge failed") end
                    seen[#seen + 1] = { path, content }
                end,
                batch = function(deliver) deliver() end,
                read_file = function(path) return disk[path] end,
                manual = true,
            })
            tracker:watch("/a"); tracker:watch("/b")
            disk["/a"], disk["/b"] = "a2", "b2"
            local ok, err = pcall(tracker.sync, tracker)
            assert.is_false(ok)
            assert.truthy(tostring(err):find("remerge failed", 1, true))
            assert.same({}, seen)
            -- Neither change was applied: the next sync delivers both.
            fail = false
            tracker:sync()
            assert.same({ { "/a", "a2" }, { "/b", "b2" } }, seen)
        end)

        it("a paused tracker delivers nothing until resumed", function()
            local disk = { ["/a"] = "a1" }
            local seen = {}
            local tracker = FileTracker.new({
                callback = function(path, content) seen[#seen + 1] = { path, content } end,
                read_file = function(path) return disk[path] end,
                manual = true,
            })
            tracker:watch("/a")
            tracker:pause()
            disk["/a"] = "a2"
            tracker:sync()
            assert.same({}, seen)
            assert.equals("a1", tracker:content("/a"))
            tracker:resume()
            tracker:sync()
            assert.same({ { "/a", "a2" } }, seen)
        end)

        it("a change `accept` refuses keeps the whole sync pending for a later one (spec §19.13 Freshness of views)", function()
            local disk = { ["/a"] = "a1", ["/b"] = "b1" }
            local seen = {}
            local tracker = FileTracker.new({
                callback = function(path, content) seen[#seen + 1] = { path, content } end,
                read_file = function(path) return disk[path] end,
                manual = true,
            })
            tracker:watch("/a")
            tracker:watch("/b")
            disk["/a"], disk["/b"] = "a2", "b2"
            tracker:sync({ accept = function(path) return path ~= "/a" end })
            assert.same({}, seen)
            assert.equals("a1", tracker:content("/a"))
            assert.equals("b1", tracker:content("/b"))
            tracker:sync()
            assert.same({ { "/a", "a2" }, { "/b", "b2" } }, seen)
        end)

        it("a change seen while paused is delivered after resume, with no further change", function()
            local disk = { ["/a"] = "a1" }
            local seen, queued = {}, {}
            local tracker = FileTracker.new({
                callback = function(path, content) seen[#seen + 1] = { path, content } end,
                read_file = function(path) return disk[path] end,
                schedule = function(fn) queued[#queued + 1] = fn end,
            })
            tracker:watch("/a")
            tracker:pause()
            disk["/a"] = "a2"
            -- The poll that saw the change fires while paused: nothing delivered.
            tracker:sync()
            assert.same({}, seen)
            tracker:resume()
            -- No further stat change (so no further poll): resume itself
            -- schedules the deferred sync.
            for _, fn in ipairs(queued) do fn() end
            tracker:stop()
            assert.same({ { "/a", "a2" } }, seen)
        end)

        it("a throw after some deliveries re-delivers only the rest", function()
            local disk = { ["/a"] = "a1", ["/b"] = "b1", ["/c"] = "c1" }
            local seen, fail = {}, true
            local tracker = FileTracker.new({
                callback = function(path, content)
                    if path == "/b" and fail then error("boom") end
                    seen[#seen + 1] = { path, content }
                end,
                read_file = function(path) return disk[path] end,
                manual = true,
            })
            tracker:watch("/a"); tracker:watch("/b"); tracker:watch("/c")
            disk["/a"], disk["/b"], disk["/c"] = "a2", "b2", "c2"
            assert.is_false(pcall(tracker.sync, tracker))
            assert.same({ { "/a", "a2" } }, seen)
            fail = false
            tracker:sync()
            assert.same({ { "/a", "a2" }, { "/b", "b2" }, { "/c", "c2" } }, seen)
        end)
    end)

    describe("stop", function()
        it("clears all watches", function()
            local tracker = FileTracker.new({
                callback = function() end,
                read_file = function() return "content" end,
                schedule = function(fn) fn() end,
            })
            tracker:watch("/a")
            tracker:watch("/b")
            tracker:stop()
            assert.is_nil(tracker:content("/a"))
            assert.is_nil(tracker:content("/b"))
        end)
    end)

    -- The workspace daemon's tracker (spec/core/daemon.md §19.13).
    describe("hold and saves (the daemon's watch)", function()
        local recheck_ms = FileTracker.SAVE_RECHECK_MS
        after_each(function() FileTracker.SAVE_RECHECK_MS = recheck_ms end)

        it("a held change holds the whole sync until it passes; then everything is delivered", function()
            local disk = { ["/a"] = "a1", ["/b"] = "b1" }
            local seen, holds = {}, 0
            local tracker = FileTracker.new({
                callback = function(path, content) seen[#seen + 1] = { path, content } end,
                read_file = function(path) return disk[path] end,
                hold = function(_, content) if content == "bad" then holds = holds + 1; return true end end,
                manual = true,
            })
            tracker:watch("/a"); tracker:watch("/b")
            disk["/a"], disk["/b"] = "bad", "b2"
            tracker:sync()
            assert.same({}, seen)
            assert.equals("b1", tracker:content("/b"))
            disk["/a"] = "a2"
            tracker:sync()
            assert.same({ { "/a", "a2" }, { "/b", "b2" } }, seen)
        end)

        it("a held path back to its last known content is screened again (its hold released)", function()
            local disk = { ["/a"] = "a1" }
            local screened = {}
            local tracker = FileTracker.new({
                callback = function() end,
                read_file = function(path) return disk[path] end,
                hold = function(_, content) screened[#screened + 1] = content; return content == "bad" end,
                manual = true,
            })
            tracker:watch("/a")
            disk["/a"] = "bad"; tracker:sync()
            disk["/a"] = "a1"; tracker:sync()
            assert.same({ "bad", "a1" }, screened)
            tracker:sync()
            assert.same({ "bad", "a1" }, screened)
        end)

        --- A manual saves-tracker over the fake `disk`; `staged` answers from it
        --- (a `.tmp` or any `.txn-` name of the exact path).
        local function saves_tracker(disk, seen, signals)
            return FileTracker.new({
                callback = function(path, content) seen[#seen + 1] = { path, content } end,
                read_file = function(path) return disk[path] end,
                staged = function(path)
                    if disk[path .. ".tmp"] then return true end
                    for p in pairs(disk) do
                        if p:sub(1, #path + 5) == path .. ".txn-" and #p > #path + 5 then return true end
                    end
                    return false
                end,
                manual = true, saves = true,
                signal = signals and function() signals.n = signals.n + 1 end or nil,
            })
        end

        it("a file deleted after a save that rewrote identical bytes reads as missing at once (its .bak is no save)", function()
            local disk = { ["/a"] = "a1" }
            local seen = {}
            local tracker = saves_tracker(disk, seen)
            tracker:watch("/a")
            -- The save rewrote the same bytes: the .bak equals the content last applied.
            disk["/a.bak"] = "a1"
            disk["/a"] = nil
            tracker:sync()
            assert.same({ { "/a", nil } }, seen)
            tracker:stop()
        end)

        for _, staged in ipairs({ "/a.tmp", "/a.txn-0123abcd" }) do
            it("a file missing beside its staged copy " .. staged .. " is a save in progress: kept, re-checked, then applied", function()
                FileTracker.SAVE_RECHECK_MS = 20
                local disk = { ["/a"] = "a1" }
                local seen, signals = {}, { n = 0 }
                local tracker = saves_tracker(disk, seen, signals)
                tracker:watch("/a")
                -- Between the save's two renames.
                disk[staged], disk["/a"] = "a2", nil
                tracker:sync()
                assert.same({}, seen)
                assert.equals("a1", tracker:content("/a"))
                -- A re-check is signalled; still staged, still kept (and re-armed).
                assert.is_true(vim.wait(5000, function() return signals.n >= 1 end, 10))
                tracker:sync()
                assert.same({}, seen)
                assert.is_true(vim.wait(5000, function() return signals.n >= 2 end, 10))
                -- The staged copy is renamed into place: applied.
                disk["/a"], disk[staged] = "a2", nil
                tracker:sync()
                assert.same({ { "/a", "a2" } }, seen)
                tracker:stop()
            end)
        end

        it("a save whose last rename lands between the missing read and the staged check reads the saved file", function()
            local disk = { ["/a"] = "a1" }
            local seen = {}
            local tracker = FileTracker.new({
                callback = function(path, content) seen[#seen + 1] = { path, content } end,
                read_file = function(path) return disk[path] end,
                -- The `.tmp -> target` rename completes just before the check:
                -- no staged copy is left, and the target is back.
                staged = function(path)
                    disk[path], disk[path .. ".tmp"] = "a2", nil
                    return false
                end,
                manual = true, saves = true,
            })
            tracker:watch("/a")
            disk["/a"], disk["/a.tmp"] = nil, "a2"
            tracker:sync()
            assert.same({ { "/a", "a2" } }, seen)
            assert.equals("a2", tracker:content("/a"))
            tracker:stop()
        end)

        it("a file deleted with no staged copy reads as missing", function()
            local disk = { ["/a"] = "a1" }
            local seen = {}
            local tracker = saves_tracker(disk, seen)
            tracker:watch("/a")
            disk["/a"] = nil
            tracker:sync()
            assert.same({ { "/a", nil } }, seen)
            tracker:stop()
        end)

        it("staged_copy matches only <file>.tmp and <file>.txn-<hex id> of that exact file", function()
            local dir = vim.fn.tempname():gsub("\\", "/")
            vim.fn.mkdir(dir, "p")
            local function touch(name) local f = assert(io.open(dir .. "/" .. name, "wb")); f:write("x"); f:close() end
            local target = dir .. "/w.json"
            assert.is_false(FileTracker.staged_copy(target))
            for _, name in ipairs({ "w.json.bak", "w.json.txn-", "xw.json.txn-1", "w.jsonx.txn-1", "w.json.tmpx", "w.json.txnx-1", "w.json.txn-foo", "w.json.txn-0a1g" }) do
                touch(name)
            end
            assert.is_false(FileTracker.staged_copy(target))
            touch("w.json.txn-0a1b")
            assert.is_true(FileTracker.staged_copy(target))
            os.remove(dir .. "/w.json.txn-0a1b")
            assert.is_false(FileTracker.staged_copy(target))
            touch("w.json.tmp")
            assert.is_true(FileTracker.staged_copy(target))
            vim.fn.delete(dir, "rf")
        end)

        it("a signal queued before stop_signals never calls the removed signal", function()
            local queued = {}
            local signals = 0
            local tracker = FileTracker.new({
                callback = function() end,
                read_file = function() return "x" end,
                schedule = function(fn) queued[#queued + 1] = fn end,
                signal = function() signals = signals + 1 end,
                manual = true,
            })
            tracker:watch(vim.fn.tempname())
            tracker:pause(); tracker:resume()
            assert.equals(1, #queued)
            tracker:stop_signals()
            assert.has_no.errors(function() for _, fn in ipairs(queued) do fn() end end)
            assert.equals(0, signals)
            tracker:stop()
        end)

        it("a re-check queued before stop_signals never calls the removed signal", function()
            FileTracker.SAVE_RECHECK_MS = 10
            local queued = {}
            local signals = 0
            local disk = { ["/a"] = "a1" }
            local tracker = FileTracker.new({
                callback = function() end,
                read_file = function(path) return disk[path] end,
                staged = function() return true end,
                schedule = function(fn) queued[#queued + 1] = fn end,
                signal = function() signals = signals + 1 end,
                manual = true, saves = true,
            })
            tracker:watch("/a")
            disk["/a"] = nil
            tracker:sync() -- a save in progress: a re-check is armed
            assert.is_true(vim.wait(5000, function() return #queued >= 1 end, 5))
            tracker:stop_signals()
            assert.has_no.errors(function() for _, fn in ipairs(queued) do fn() end end)
            assert.equals(0, signals)
            tracker:stop()
        end)
    end)
end)

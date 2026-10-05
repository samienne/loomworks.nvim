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
end)

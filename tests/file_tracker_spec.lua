local FileTracker = require("loomworks.file_tracker")

describe("FileTracker", function()
  describe("new", function()
    it("creates a tracker with defaults", function()
      local tracker = FileTracker.new({
        callback = function() end,
      })
      assert.is_not_nil(tracker)
    end)
  end)

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

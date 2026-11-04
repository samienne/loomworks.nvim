-- The bytes of a task's `output` frame (PROTOCOL.md §14.2): a chunk that is
-- valid UTF-8 travels as `text`, any other as `data` (base64, RFC 4648 §4),
-- exactly one of the two. The editor writes the bytes as they are. (The
-- codec, the daemon's frames and the conformance engine are loomworks' to
-- test.)

local bytes = require("loomworks.proto.bytes")
local observer = require("loomworks.daemon.observer")

describe("output consumers write the bytes as they are", function()
    it("the editor's remote task keeps a data chunk's bytes", function()
        local o = setmetatable({ root = "/r", state = "connected", _tasks = {}, _order = {}, _owned = {},
            seq = 0, _emit = function() end }, observer.Observer)
        o:_on_task({ kind = "task", task_id = "g.1", phase = "start", meta = { name = "dev", kind = "build" } })
        o:_on_task({ kind = "task", task_id = "g.1", phase = "output", stream = "stdout", text = "a€" })
        o:_on_task({ kind = "task", task_id = "g.1", phase = "output", stream = "stderr",
            data = bytes.b64encode("\255\254") })
        assert.equals("a€\255\254", o._tasks["g.1"]:output())
    end)
end)

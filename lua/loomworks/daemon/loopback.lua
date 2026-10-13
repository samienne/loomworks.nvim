--- loomworks/daemon/loopback.lua — the in-memory transport of an attached run
--- (spec §19.1 "Loopback during the transition", §19.8).
---
--- An attached run executes the daemon's code inside the client process; the
--- two sides talk over a pair of connected in-memory ends carrying the same
--- frames as the pipe, through the same encoder/decoder and handlers. Each end
--- mimics exactly the libuv pipe methods the server, the client and the task
--- streams call: `write(data, cb)`, `read_start(cb)`, `read_stop()`,
--- `close(cb)`, `is_closing()` and `get_write_queue_size()`.
---
--- Delivery is asynchronous (`vim.schedule`): chunks arrive in the order they
--- were written and never re-entrantly inside the writer's call, and never
--- from a libuv fast callback (the editor host forbids most of the API
--- there). Bytes a writer queued count in its `get_write_queue_size()` until
--- the peer's reader received them, so a paused reader holds the writer's
--- queue up exactly as a full socket would (the owner flow control of
--- loomworks.daemon.tasks). `close` delivers EOF to the peer after the bytes
--- already written; the closing end's own undelivered bytes stay deliverable
--- (as the kernel buffer of a pipe would) while bytes written TO it are dropped.

local M = {}

--- @class loomworks.daemon.LoopbackEnd
--- @field peer loomworks.daemon.LoopbackEnd|nil
--- @field _inbox { data: string, cb: function|nil }[] chunks written by the peer, not yet read
--- @field _queued integer bytes this end wrote that the peer has not read yet
--- @field _reader fun(err: string|nil, chunk: string|nil)|nil
--- @field _eof boolean the peer closed: EOF follows the inbox
--- @field _eof_sent boolean
--- @field _closing boolean
--- @field _flush_pending boolean
local End = {}
End.__index = End

local function new_end()
    return setmetatable({ _inbox = {}, _queued = 0, _eof = false, _eof_sent = false, _closing = false,
        _flush_pending = false }, End)
end

--- Deliver what the reader may receive now (on the main loop, never inline).
function End:_schedule_flush()
    if self._flush_pending then return end
    self._flush_pending = true
    vim.schedule(function()
        self._flush_pending = false
        self:_flush()
    end)
end

function End:_flush()
    while self._reader and not self._closing and #self._inbox > 0 do
        local item = table.remove(self._inbox, 1)
        local writer = self.peer
        if writer then writer._queued = writer._queued - #item.data end
        if item.cb then vim.schedule(function() item.cb(nil) end) end
        self._reader(nil, item.data)
    end
    if self._reader and not self._closing and self._eof and not self._eof_sent and #self._inbox == 0 then
        self._eof_sent = true
        self._reader(nil, nil)
    end
end

--- Write `data` to the peer; `cb(err|nil)` once the peer read it (or with
--- "EPIPE" when the peer is gone). Returns 0, or nil + error on a closed end.
--- @param data string
--- @param cb? fun(err: string|nil)
--- @return integer|nil, string|nil
function End:write(data, cb)
    if self._closing then return nil, "EBADF" end
    local peer = self.peer
    if not peer or peer._closing then
        if cb then vim.schedule(function() cb("EPIPE") end) end
        return 0
    end
    data = tostring(data)
    self._queued = self._queued + #data
    peer._inbox[#peer._inbox + 1] = { data = data, cb = cb }
    peer:_schedule_flush()
    return 0
end

--- Start reading: `cb(err, chunk)`; `chunk == nil` is EOF.
--- @param cb fun(err: string|nil, chunk: string|nil)
--- @return integer|nil, string|nil
function End:read_start(cb)
    if self._closing then return nil, "EBADF" end
    self._reader = cb
    self:_schedule_flush()
    return 0
end

--- Stop reading: written bytes wait (and count in the writer's queue).
--- @return integer
function End:read_stop()
    self._reader = nil
    return 0
end

--- @return boolean
function End:is_closing() return self._closing end

--- Bytes written by this end the peer has not read yet.
--- @return integer
function End:get_write_queue_size() return self._queued end

--- Close this end (idempotent): the peer reads EOF after the bytes already
--- written to it; bytes written to this end and not read are dropped, their
--- writers' callbacks told "EPIPE".
--- @param cb? fun()
function End:close(cb)
    if self._closing then return end
    self._closing = true
    self._reader = nil
    local dropped = self._inbox
    self._inbox = {}
    local peer = self.peer
    for _, item in ipairs(dropped) do
        if peer then peer._queued = peer._queued - #item.data end
        if item.cb then vim.schedule(function() item.cb("EPIPE") end) end
    end
    if peer and not peer._closing then
        peer._eof = true
        peer:_schedule_flush()
    end
    if cb then vim.schedule(cb) end
end

--- A connected pair of ends: what one writes, the other reads.
--- @return loomworks.daemon.LoopbackEnd a, loomworks.daemon.LoopbackEnd b
function M.pair()
    local a, b = new_end(), new_end()
    a.peer, b.peer = b, a
    return a, b
end

M.End = End
return M

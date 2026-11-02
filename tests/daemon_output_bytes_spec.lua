-- The bytes of a task's `output` frame (PROTOCOL.md §14.2): a chunk that is
-- valid UTF-8 travels as `text`, any other as `data` (base64, RFC 4648 §4),
-- exactly one of the two; an incomplete trailing UTF-8 sequence is held back
-- to the stream's next chunk (or the step's end); a server's own `line.text`
-- is valid UTF-8 (U+FFFD). The editor and the CLI write the bytes as they are.

local bytes = require("loomworks.proto.bytes")
local tasks_mod = require("loomworks.daemon.tasks")
local observer = require("loomworks.daemon.observer")
local engine = require("loomworks.proto.conformance")

local FFFD = "\239\191\189"

describe("output bytes codec (loomworks.proto.bytes)", function()
    it("base64 round-trips every byte and matches RFC 4648 §4", function()
        assert.equals("", bytes.b64encode(""))
        assert.equals("Zg==", bytes.b64encode("f"))
        assert.equals("Zm8=", bytes.b64encode("fo"))
        assert.equals("Zm9v", bytes.b64encode("foo"))
        assert.equals("Zm9vYmFy", bytes.b64encode("foobar"))
        local all = {}
        for i = 0, 255 do all[#all + 1] = string.char(i) end
        local s = table.concat(all)
        for n = 0, 5 do
            local x = s:sub(1, #s - n)
            assert.equals(x, bytes.b64decode(bytes.b64encode(x)))
            if vim.base64 then assert.equals(vim.base64.encode(x), bytes.b64encode(x)) end
        end
        assert.is_nil(bytes.b64decode("Zm9"))
        assert.is_nil(bytes.b64decode("Zm9v!A=="))
    end)

    it("validates UTF-8 strictly", function()
        assert.is_true(bytes.is_utf8("plain"))
        assert.is_true(bytes.is_utf8("€ ä 𝄞"))
        assert.is_false(bytes.is_utf8("\255"))
        assert.is_false(bytes.is_utf8("\192\175"))        -- overlong
        assert.is_false(bytes.is_utf8("\237\160\128"))    -- surrogate
        assert.is_false(bytes.is_utf8("\244\144\128\128")) -- above U+10FFFF
        assert.is_false(bytes.is_utf8("\226\130"))        -- cut short
    end)

    it("splits off only an incomplete trailing sequence that is valid so far", function()
        assert.same({ "x", "\226\130" }, { bytes.split_tail("x\226\130") })
        assert.same({ "x", "\240" }, { bytes.split_tail("x\240") })
        assert.same({ "x€", "" }, { bytes.split_tail("x€") })
        assert.same({ "x\255", "" }, { bytes.split_tail("x\255") })
        assert.same({ "x\224\128", "" }, { bytes.split_tail("x\224\128") }) -- overlong start
        -- Only the last sequence: an earlier cut one stays (it is invalid).
        assert.same({ "\226\130", "\226\130" }, { bytes.split_tail("\226\130\226\130") })
    end)

    it("replaces invalid bytes with U+FFFD and keeps valid ones", function()
        assert.equals("a" .. FFFD .. "€" .. FFFD .. FFFD, bytes.sanitize("a\255€\226\130"))
        assert.equals("ok €", bytes.sanitize("ok €"))
    end)

    it("checks an output frame: exactly one of text (UTF-8) and data (base64)", function()
        assert.is_true(bytes.check_output({ text = "a" }))
        assert.is_true(bytes.check_output({ data = "/w==" }))
        assert.is_false(bytes.check_output({}))
        assert.is_false(bytes.check_output({ text = "a", data = "YQ==" }))
        assert.is_false(bytes.check_output({ text = "\255" }))
        assert.is_false(bytes.check_output({ data = "%%" }))
    end)
end)

describe("task output frames (daemon/tasks.lua, §14.2)", function()
    local sent, task
    before_each(function()
        sent = {}
        local owner = { closed = false, transport = 11 }
        local srv = { conns = {}, _send = function(_, conn, msg) if conn == owner then sent[#sent + 1] = msg end end }
        task = tasks_mod.new(srv):create(owner)
        task:start({ name = "dev", kind = "build" })
    end)
    local function outputs()
        local t = {}
        for _, m in ipairs(sent) do if m.phase == "output" then t[#t + 1] = m end end
        return t
    end

    it("sends a chunk that is not valid UTF-8 as data, byte-exact", function()
        local raw = "cl : warning C4819: \132\148 \255\r\n"
        task:output("stderr", raw)
        local o = outputs()
        assert.equals(1, #o)
        assert.is_nil(o[1].text)
        assert.equals("stderr", o[1].stream)
        assert.equals(raw, bytes.b64decode(o[1].data))
        assert.is_true(bytes.check_output(o[1]))
    end)

    it("holds back a UTF-8 sequence split between chunks: both arrive as text", function()
        task:output("stdout", "a \226\130")
        task:output("stdout", "\172 b\n")
        local o = outputs()
        assert.equals(2, #o)
        assert.same({ "a ", "€ b\n" }, { o[1].text, o[2].text })
        assert.is_nil(o[1].data); assert.is_nil(o[2].data)
    end)

    it("holds back per stream and flushes a held tail at the task's end, before done", function()
        task:output("stdout", "x\226")
        task:output("stderr", "e\n")
        task:done(0)
        local o = outputs()
        assert.equals(3, #o)
        assert.same({ "stdout", "x" }, { o[1].stream, o[1].text })
        assert.same({ "stderr", "e\n" }, { o[2].stream, o[2].text })
        assert.same({ "stdout", "\226" }, { o[3].stream, bytes.b64decode(o[3].data) })
        assert.equals("done", sent[#sent].phase)
    end)

    it("flushes a held tail when the step ends", function()
        task.steps = { { state = "running" } }
        task:output("stdout", "\226\130")
        task:step(1, "ok")
        local o = outputs()
        assert.equals(1, #o)
        assert.equals("\226\130", bytes.b64decode(o[1].data))
    end)

    it("makes its own line text valid UTF-8 (U+FFFD)", function()
        task:line("out", "built \255 ok")
        local l = sent[#sent]
        assert.equals("line", l.phase)
        assert.equals("built " .. FFFD .. " ok", l.text)
    end)
end)

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

describe("conformance engine: output frames (§14.2)", function()
    it("refuses an output frame without exactly one valid text or data", function()
        local check = engine.check_output_frame
        assert.is_function(check)
        assert.is_true((check({ kind = "task", phase = "output", stream = "stdout", text = "a" })))
        assert.is_true((check({ kind = "task", phase = "output", stream = "stdout", data = "/w==" })))
        assert.is_false((check({ kind = "task", phase = "output", stream = "stdout", text = "\255" })))
        assert.is_false((check({ kind = "task", phase = "output", stream = "stdout", text = "a", data = "YQ==" })))
        assert.is_false((check({ kind = "task", phase = "output", stream = "stdout" })))
        assert.is_true((check({ kind = "task", phase = "line", stream = "out", text = "x" })))
    end)
end)

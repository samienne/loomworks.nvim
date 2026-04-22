--- Parser and filter tests for loomworks.device_log.
---
--- Streamer and view are integration-y (they need overseer + a real
--- buffer + window) and harder to unit-test meaningfully; those
--- paths stay covered by manual integration testing against a real
--- device. Pure parse_line / match_filter / make_prefilter are the
--- pieces that benefit most from being pinned.

local dl = require("loomworks.device_log")

describe("device_log parser", function()
    it("parses a three-segment hilog line (DOMAIN/PROC/TAG)", function()
        local line = "04-21 16:14:16.478 43865 43865 E "
            .. "A00F00/om.huawei.hmos.aidataservice.1/170000416: "
            .. "[a92ab178] SingleDirectionSyncHelper: not allow sync"
        local r = dl.parse_line(line)
        assert.is_not_nil(r)
        assert.equals("04-21 16:14:16.478", r.time)
        assert.equals(43865, r.pid)
        assert.equals(43865, r.tid)
        assert.equals("E", r.level)
        assert.equals("A00F00", r.domain)
        assert.equals("om.huawei.hmos.aidataservice.1", r.proc)
        assert.equals("170000416", r.tag)
        assert.equals("[a92ab178] SingleDirectionSyncHelper: not allow sync", r.msg)
    end)

    it("parses a two-segment hilog line (DOMAIN/TAG)", function()
        local line = "04-10 15:08:15.076     0     0 I I00000/HiLog: "
            .. "========Zeroth log of type: init"
        local r = dl.parse_line(line)
        assert.is_not_nil(r)
        assert.equals(0, r.pid)
        assert.equals("I", r.level)
        assert.equals("I00000", r.domain)
        assert.is_nil(r.proc)
        assert.equals("HiLog", r.tag)
        assert.equals("========Zeroth log of type: init", r.msg)
    end)

    it("returns nil for unparseable lines", function()
        assert.is_nil(dl.parse_line(""))
        assert.is_nil(dl.parse_line("garbage line with no timestamp"))
        assert.is_nil(dl.parse_line(nil))
    end)
end)

describe("device_log match_filter", function()
    local sample = {
        time = "04-21 16:14:16.478",
        pid = 43865, tid = 43865, level = "I",
        domain = "A00F00", proc = "com.example.myapp", tag = "MainTag",
        msg = "hello world",
    }

    it("passes when all filter fields are nil", function()
        assert.is_true(dl.match_filter({}, sample))
    end)

    it("enforces pid match when set", function()
        assert.is_true(dl.match_filter({ pid = 43865 }, sample))
        assert.is_false(dl.match_filter({ pid = 12345 }, sample))
    end)

    it("substring-matches proc", function()
        assert.is_true(dl.match_filter({ proc = "example" }, sample))
        assert.is_false(dl.match_filter({ proc = "nope" }, sample))
    end)

    it("substring-matches tag", function()
        assert.is_true(dl.match_filter({ tag = "Main" }, sample))
        assert.is_false(dl.match_filter({ tag = "Sub" }, sample))
    end)

    it("min-level is inclusive and ordered", function()
        assert.is_true(dl.match_filter({ level = "I" }, sample))
        assert.is_true(dl.match_filter({ level = "D" }, sample))
        assert.is_false(dl.match_filter({ level = "W" }, sample))
        assert.is_false(dl.match_filter({ level = "E" }, sample))
    end)

    it("regex matches against msg", function()
        assert.is_true(dl.match_filter({ regex = "hello" }, sample))
        assert.is_true(dl.match_filter({ regex = "^hello" }, sample))
        assert.is_false(dl.match_filter({ regex = "^goodbye" }, sample))
    end)

    it("raw records pass through except for regex", function()
        local raw = { raw = "ferr: broken hdc message" }
        assert.is_true(dl.match_filter({}, raw))
        assert.is_true(dl.match_filter({ level = "E" }, raw))
        assert.is_true(dl.match_filter({ regex = "broken" }, raw))
        assert.is_false(dl.match_filter({ regex = "xyzzy" }, raw))
    end)
end)

describe("device_log make_prefilter", function()
    local pre = dl.make_prefilter({ pid = 100, bundle = "com.example.myapp" })

    it("keeps records matching the app pid", function()
        assert.is_true(pre({
            pid = 100, proc = "something.else", tag = "T", msg = "",
            level = "I", time = "", tid = 0, domain = "",
        }))
    end)

    it("keeps records whose proc contains the bundle", function()
        assert.is_true(pre({
            pid = 999, proc = "com.example.myapp", tag = "T", msg = "",
            level = "I", time = "", tid = 0, domain = "",
        }))
        assert.is_true(pre({
            pid = 999, proc = "com.example.myapp.helper", tag = "T", msg = "",
            level = "I", time = "", tid = 0, domain = "",
        }))
    end)

    it("drops records with neither pid nor proc match", function()
        assert.is_false(pre({
            pid = 999, proc = "com.other.app", tag = "T", msg = "",
            level = "I", time = "", tid = 0, domain = "",
        }))
    end)

    it("always keeps raw records (diagnostic passthrough)", function()
        assert.is_true(pre({ raw = "hdc: connection lost" }))
    end)

    it("matches nothing when pid and bundle are both unset", function()
        local empty = dl.make_prefilter({})
        assert.is_false(empty({
            pid = 1, proc = "whatever", tag = "T", msg = "",
            level = "I", time = "", tid = 0, domain = "",
        }))
    end)
end)

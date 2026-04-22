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

    it("strips leading UTF-8 BOM before parsing", function()
        local line = "\xEF\xBB\xBF04-21 16:14:16.478 43865 43865 E "
            .. "A00F00/myproc/MyTag: hi"
        local r = dl.parse_line(line)
        assert.is_not_nil(r)
        assert.equals(43865, r.pid)
        assert.equals("MyTag", r.tag)
    end)

    it("strips ANSI CSI escape sequences before parsing", function()
        local line = "\27[32m04-21 16:14:16.478\27[0m 43865 43865 E "
            .. "A00F00/myproc/MyTag: hi"
        local r = dl.parse_line(line)
        assert.is_not_nil(r)
        assert.equals("MyTag", r.tag)
    end)
end)

describe("device_log _render (mirrors hilog format)", function()
    -- The LogView:_render method is an instance method, but it only
    -- touches `self` for buffer/window access on highlight/append —
    -- _render itself is pure. Exercise it via a thin stand-in that
    -- calls the method with a fake self.
    local LogView = dl._LogView
    local function render(rec)
        return LogView._render({}, rec)  -- `self` unused in _render
    end

    it("reconstructs three-segment format with right-aligned pid/tid", function()
        local rec = {
            time = "04-21 16:14:16.478",
            pid = 43865, tid = 43865, level = "E",
            domain = "A00F00", proc = "com.example.app", tag = "MyTag",
            msg = "boom",
        }
        assert.equals(
            "04-21 16:14:16.478 43865 43865 E A00F00/com.example.app/MyTag: boom",
            render(rec))
    end)

    it("reconstructs two-segment format (no proc)", function()
        local rec = {
            time = "04-10 15:08:15.076",
            pid = 0, tid = 0, level = "I",
            domain = "I00000", tag = "HiLog",
            msg = "========Zeroth log of type: init",
        }
        assert.equals(
            "04-10 15:08:15.076     0     0 I I00000/HiLog: ========Zeroth log of type: init",
            render(rec))
    end)

    it("marks unparsed records with [UNPARSED]", function()
        assert.equals("[UNPARSED] garbage", render({ raw = "garbage" }))
    end)

    it("renders headers verbatim", function()
        assert.equals("── session start ──", render({ header = "── session start ──" }))
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

describe("device_log make_prefilter — strict mode (default)", function()
    local pre = dl.make_prefilter({
        pid = 100,
        bundle = "com.example.myapp",
    })

    local function rec(pid, proc)
        return { pid = pid, proc = proc, tag = "T", msg = "",
                 level = "I", time = "", tid = 0, domain = "" }
    end

    it("keeps records with matching pid AND proc (exact)", function()
        assert.is_true(pre(rec(100, "com.example.myapp")))
    end)

    it("keeps app sub-process helpers (bundle is prefix with . or :)", function()
        assert.is_true(pre(rec(100, "com.example.myapp.worker")))
        assert.is_true(pre(rec(100, "com.example.myapp:helper")))
    end)

    it("keeps records where proc is a hilog left-truncation of bundle", function()
        -- If the bundle is longer than the ~30-char proc column,
        -- hilog drops leading characters. The proc seen in the
        -- stream must be a suffix of the full bundle.
        local long_pre = dl.make_prefilter({
            pid = 50,
            bundle = "com.company.product.verylongname",
        })
        assert.is_true(long_pre(rec(50, "ompany.product.verylongname")))
    end)

    it("drops records when only pid matches (system noise on our pid?)", function()
        -- Strict mode: pid alone isn't enough. With bundle resolved,
        -- the proc column MUST also match.
        assert.is_false(pre(rec(100, "com.other.app")))
    end)

    it("drops records when only proc matches (different pid)", function()
        -- Runtime helpers on a different pid that happen to log for
        -- the same bundle: dropped in strict mode.
        assert.is_false(pre(rec(999, "com.example.myapp")))
    end)

    it("drops records with proc that merely contains the bundle string", function()
        -- Anti-test for the old loose substring behaviour.
        assert.is_false(pre(rec(999, "xcom.example.myapp.suffix")))
    end)

    it("drops unrelated system services", function()
        assert.is_false(pre(rec(43865, "om.huawei.hmos.aidataservice.1")))
        assert.is_false(pre(rec(42843, "com.huawei.hmos.hsdr")))
    end)

    it("always keeps raw records (diagnostic passthrough)", function()
        assert.is_true(pre({ raw = "hdc: connection lost" }))
    end)

    it("matches nothing when pid and bundle are both unset", function()
        local empty = dl.make_prefilter({})
        assert.is_false(empty(rec(1, "whatever")))
    end)

    it("degrades to pid-only when bundle is missing", function()
        local p = dl.make_prefilter({ pid = 100 })
        assert.is_true(p(rec(100, "anything")))
        assert.is_false(p(rec(101, "anything")))
    end)
end)

describe("device_log make_prefilter — app-related mode", function()
    local pre = dl.make_prefilter({
        pid = 100,
        bundle = "com.example.myapp",
        mode = "app-related",
    })

    local function rec(pid, proc)
        return { pid = pid, proc = proc, tag = "T", msg = "",
                 level = "I", time = "", tid = 0, domain = "" }
    end

    it("keeps records matching pid OR proc (union)", function()
        assert.is_true(pre(rec(100, "something.else")))
        assert.is_true(pre(rec(999, "com.example.myapp")))
    end)

    it("drops records matching neither", function()
        assert.is_false(pre(rec(999, "com.huawei.service")))
    end)
end)

describe("device_log make_prefilter — all mode", function()
    it("keeps everything", function()
        local pre = dl.make_prefilter({ mode = "all" })
        assert.is_true(pre({ pid = 1, proc = "x", tag = "",
                             msg = "", level = "I", time = "",
                             tid = 0, domain = "" }))
        assert.is_true(pre({ raw = "garbage" }))
    end)
end)

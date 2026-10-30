-- The public build, launch and picker functions in `daemon` mode (spec
-- §19.16 "Public API", step 6b-alpha; loomworks.daemon.facade): the editor
-- holds no model, so `lw.build_profile`, `lw.build_target`,
-- `lw.pick_profile`, `lw.pick_target` and `lw.launch_target` act by calls
-- naming the rows of `view.Workspace/1` and the records of
-- `Launch/1.targets` by id; `lw.compile_command_for_file` and
-- `lw.create_workspace` are refused. Against an observer whose connection is
-- a recording fake (no daemon, no workspace loaded in the editor).

local observer = require("loomworks.daemon.observer")
local views = require("loomworks.views")

describe("the daemon-mode facade (§19.16 Public API, step 6b-alpha)", function()
    local lw = require("loomworks")
    local obs, sent, notes, selects, saved

    local function stub(mod, key, fn)
        saved[#saved + 1] = { mod, key, mod[key] }
        mod[key] = fn
    end

    local function fake_observer()
        local conn = { transport = 11, closed = false }
        function conn.call(_, object, iface, v, method, args, cb, env)
            sent[#sent + 1] = { object = object, iface = iface, v = v, method = method, args = args, cb = cb,
                env = env }
        end
        function conn.close(c) c.closed = true end
        local o = setmetatable({
            root = "/w", state = "connected", conn = conn, mode = "interfaces",
            _feat = { operations = "available", launch = "available", tasks = "subscribed",
                profiles = "available", workspace = "available" },
            _why = {}, _tasks = {}, _order = {}, _owned = {}, seq = 0,
            daemon = { pid = 1 },
            opts = { environ = function() return { PATH = "x" } end },
        }, observer.Observer)
        observer._current = o
        observer._selection = { mode = "daemon", source = "default", daemon = true }
        views.set(o, "header", { root = "/w", state = "loaded" })
        views.set(o, "workspace", {
            profiles = {
                { id = "p:1", key = "dev", active = true, status = "built", units = {},
                    default_target = "app: run", default_target_valid = true },
                { id = "p:2", key = "rel", active = false, status = "unconfigured", units = {} },
            },
            projects = { { id = "pr:app", key = "app", type = "shell" } },
        })
        return o
    end

    local function sent_method(method)
        for i, c in ipairs(sent) do if c.method == method then return c, i end end
        return nil
    end

    --- Answer the `Launch/1.targets` call with `targets`.
    local function answer_targets(targets)
        assert.is_true(vim.wait(2000, function() return sent_method("targets") ~= nil end, 10),
            vim.inspect({ notes = notes, sent = sent }))
        local c = sent_method("targets")
        assert.same({ id = "p:1" }, c.args.profile)
        c.cb({ outcome = "ok", targets = targets }, nil)
    end

    local RUN = { kind = "launch", project = { id = "pr:app", key = "app" }, name = "run", label = "run" }
    local LIB = { kind = "target", project = { id = "pr:app", key = "app" }, name = "lib", label = "lib" }

    before_each(function()
        sent, notes, selects, saved = {}, {}, {}, {}
        stub(vim, "notify", function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end)
        stub(vim.ui, "select", function(items, opts, cb)
            selects[#selects + 1] = { items = items, prompt = opts and opts.prompt, opts = opts, cb = cb }
        end)
        obs = fake_observer()
    end)

    after_each(function()
        pcall(function() require("loomworks.session_tracker").stop() end)
        for i = #saved, 1, -1 do
            local s = saved[i]
            s[1][s[2]] = s[3]
        end
        views.clear(obs)
        observer._current = nil
        observer._selection = nil
        obs = nil
    end)

    local function noted(text)
        for _, n in ipairs(notes) do
            if n.msg:find(text, 1, true) then return true end
        end
        return false
    end

    it("is active in daemon mode with no model", function()
        assert.is_true(require("loomworks.daemon.facade").active())
        assert.is_nil(lw.get_workspace())
    end)

    it("build_profile is a Build/1.build of the active profile row", function()
        lw.build_profile()
        assert.is_true(vim.wait(2000, function() return #sent == 1 end, 10))
        assert.same({ "/build", "build" }, { sent[1].object, sent[1].method })
        assert.same({ id = "p:1" }, sent[1].args.profile)
    end)

    it("a failed build_profile reply with no message, not notified, still tells the user", function()
        stub(require("loomworks.ui.model_calls"), "call", function(_, _, _, cb) cb({ outcome = "failed" }) end)
        lw.build_profile()
        assert.equals(1, #notes)
        assert.is_true(noted("build failed"), vim.inspect(notes))
    end)

    it("build_target is a Launch/1.build of the default target Launch/1.targets marks, by its profile", function()
        lw.build_target()
        answer_targets({ vim.tbl_extend("force", RUN, { default = true }), LIB })
        assert.is_true(vim.wait(2000, function() return sent_method("build") ~= nil end, 10))
        local c = sent_method("build")
        assert.same({ "/launch", "loomworks.Launch" }, { c.object, c.iface })
        -- (The profile's default target: the daemon builds its own, §19.16.)
        assert.same({ interactive = false, profile = { id = "p:1" } }, c.args)
        assert.same({}, selects)
    end)

    it("build_target with no default: the picker, its choice stored, then built", function()
        lw.build_target()
        answer_targets({ RUN, LIB })
        assert.is_true(vim.wait(2000, function() return #selects == 1 end, 10))
        assert.equals("None (clear target)", selects[1].items[1].label)
        assert.equals("app: lib", selects[1].opts.format_item(selects[1].items[3]))
        selects[1].cb(selects[1].items[3])
        local c = sent_method("set_default_target")
        assert.is_not_nil(c)
        assert.same({ "/profiles", "loomworks.Profiles" }, { c.object, c.iface })
        assert.same({ id = "p:1" }, c.args.profile)
        assert.same({ kind = "target", project = { id = "pr:app" }, name = "lib" }, c.args.target)
        c.cb({ outcome = "ok" }, nil)
        assert.is_true(vim.wait(2000, function() return sent_method("build") ~= nil end, 10))
        -- (Stored as the default: built as the profile's default target.)
        assert.same({ interactive = false, profile = { id = "p:1" } }, sent_method("build").args)
    end)

    it("pick_target's None removes the stored choice; nothing is built", function()
        lw.pick_target()
        answer_targets({ vim.tbl_extend("force", RUN, { default = true }) })
        assert.is_true(vim.wait(2000, function() return #selects == 1 end, 10))
        selects[1].cb(selects[1].items[1])
        local c = sent_method("set_default_target")
        assert.is_not_nil(c)
        assert.is_nil(c.args.target)
        vim.wait(50)
        assert.is_nil(sent_method("build"))
    end)

    it("launch_target starts the session tracker's run of the default target by its profile's id", function()
        lw.launch_target()
        answer_targets({ vim.tbl_extend("force", RUN, { default = true }) })
        assert.is_true(vim.wait(2000, function() return sent_method("prepare_run") ~= nil end, 10))
        local c = sent_method("prepare_run")
        assert.same({ id = "p:1" }, c.args.profile)
        assert.is_nil(c.args.project)
        assert.is_nil(c.args.target)
        assert.is_nil(c.args.kind)
    end)

    it("pick_profile lists the profile rows (no None) and sends Profiles/1.set_active", function()
        lw.pick_profile()
        assert.equals(1, #selects)
        assert.equals(2, #selects[1].items)
        for _, item in ipairs(selects[1].items) do assert.is_nil(item.label:find("None", 1, true)) end
        selects[1].cb(selects[1].items[2])
        assert.is_true(vim.wait(2000, function() return sent_method("set_active") ~= nil end, 10))
        assert.same({ id = "p:2" }, sent_method("set_active").args.profile)
    end)

    it("pick_profile on the active profile sends nothing", function()
        lw.pick_profile()
        selects[1].cb(selects[1].items[1])
        vim.wait(50)
        assert.same({}, sent)
    end)

    it("no active profile row: refused with one note, nothing sent", function()
        views.set(obs, "workspace", { profiles = { { id = "p:2", key = "rel", active = false, units = {} } },
            projects = {} })
        lw.build_profile()
        lw.build_target()
        assert.equals(2, #notes)
        assert.is_true(noted("no active profile"))
        assert.same({}, sent)
    end)

    it("compile_command_for_file is refused (D3)", function()
        local res = lw.compile_command_for_file("/w/app/main.c")
        assert.equals("refused", res.status)
        assert.equals("not available with the workspace daemon", res.message)
    end)

    it("create_workspace is refused and points to lw init (D5); nothing written", function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local ok, err = lw.create_workspace(dir, "x")
        assert.is_false(ok)
        assert.truthy(err:find("lw init", 1, true))
        assert.equals(0, vim.fn.filereadable(dir .. "/loomworks.json"))
        vim.fn.delete(dir, "rf")
    end)
end)

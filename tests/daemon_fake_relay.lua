-- A fake of the editor's relay seam (observer `opts.relay`, the shape of
-- loomworks.daemon.client.relay.connect) for the observer specs: no process,
-- it follows what a relay does (§19.10 "Connections", §19.16 "Through the
-- relay") over an in-process server or a fake daemon world:
--   * every form polls the daemon state (`o.inspect`, default the real
--     inspect.state) and connects (`o.connect`, default client.connect) to a
--     live daemon; the connection gets the relay's `welcome` additions
--     (`daemon` = its challenge + the handle's pid, start time and exe;
--     `via = "relay"`), and `conn.challenge` = `welcome.daemon`, as
--     client.relay gives it;
--   * an ordinary relay that finds no live (or starting) daemon calls
--     `o.launch(ropts)` once (counted in `f.launched`);
--   * a `welcome` that says `retiring` is never forwarded: the relay closes
--     that connection and waits it out; once that daemon is gone with none
--     other live, a no-launch / retiring relay exits 16 and an ordinary relay
--     launches; a `retiring` relay treats the named instance so from the
--     start (§19.10 "A named retiring daemon"); a `skip` relay treats the
--     named instance as not present: never connected to, never a status 16
--     (§19.10 "Skip an instance");
--   * `r.exit(code, info)` (tests) ends a relay before `welcome` with that
--     status; `r:close()` is the editor ending it (not reported).
-- `f.spawns` lists each relay as "<form>[ <instance>]"; `o.manual`: relays
-- that do nothing until the test's `r.exit`.

local uv = vim.uv or vim.loop
local client = require("loomworks.daemon.client")
local connect_mod = require("loomworks.daemon.connect")

local M = {}

local function same(a, b)
    return type(a) == "table" and type(b) == "table" and a.pid == b.pid and a.start_time == b.start_time
end

function M.new(o)
    o = o or {}
    local f = { spawns = {}, relays = {}, launched = 0 }

    function f.relay(ropts, cb)
        local r = { form = ropts.form, instance = ropts.instance, ropts = ropts }
        f.spawns[#f.spawns + 1] = ropts.form .. (ropts.instance and (" " .. ropts.instance) or "")
        f.relays[#f.relays + 1] = r
        local timer = uv.new_timer()
        local function stop_timer()
            if timer then pcall(function() timer:stop(); timer:close() end); timer = nil end
        end
        local retiring = ropts.form == "retiring" and connect_mod.parse_instance(ropts.instance) or nil
        local skip = ropts.form == "skip" and connect_mod.parse_instance(ropts.instance) or nil
        local launched_here = false
        function r.close(self)
            if self.ended then return end
            self.ended = true
            stop_timer()
        end
        function r.exit(code, info)
            if r.ended or r.done then return end
            r.done = true
            stop_timer()
            info = info or {}
            cb(nil, "exit", { code = code, line = info.line, retiring = info.retiring, form = r.form })
        end
        local function tick()
            if r.ended or r.done or r.connecting then return end
            local st = (o.inspect or require("loomworks.daemon.inspect").state)(ropts.root)
            local h = st.handle
            local live = st.kind == "live" and h ~= nil
            if live and not (retiring and same(h, retiring)) and not (skip and same(h, skip)) then
                r.connecting = true
                local copts = { client = ropts.client, role = ropts.role, on_message = ropts.on_message,
                    on_close = ropts.on_close, timeout_ms = 30000 }
                ;(o.connect or client.connect)(h.endpoint, copts, function(conn)
                    r.connecting = false
                    if r.ended or r.done then
                        if conn then conn.on_close = nil; conn:close() end
                        return
                    end
                    if not conn then return end -- tried again on the next tick
                    if conn.welcome and conn.welcome.retiring then
                        -- Waited out, never forwarded.
                        retiring = { pid = h.pid, start_time = h.start_time }
                        conn.on_close = nil
                        conn:close()
                        return
                    end
                    r.done = true
                    stop_timer()
                    local daemon = vim.tbl_extend("force", conn.challenge or {},
                        { pid = h.pid, start_time = h.start_time, exe = h.exe })
                    conn.welcome = conn.welcome or {}
                    conn.welcome.via = "relay"
                    conn.welcome.daemon = daemon
                    conn.challenge = daemon
                    conn.transport = conn.transport or client._agreed(daemon, {})
                    conn.relay = r
                    r.conn = conn
                    cb(conn)
                end)
                return
            end
            if retiring and not (live and same(h, retiring)) and st.kind ~= "live" and st.kind ~= "starting" then
                if ropts.form ~= "ordinary" then return r.exit(16) end
                retiring = nil
            end
            if ropts.form == "ordinary" and not retiring and not launched_here and st.kind ~= "live"
                and st.kind ~= "starting" then
                launched_here = true
                f.launched = f.launched + 1
                if o.launch then o.launch(ropts) end
            end
        end
        -- `o.manual`: the relay only waits for the test's `r.exit` (or a close).
        if o.manual then stop_timer() else timer:start(0, o.poll_ms or 20, vim.schedule_wrap(tick)) end
        return r
    end

    --- The relays still running (not ended, no exit, connection not closed).
    function f.running()
        local n = 0
        for _, r in ipairs(f.relays) do
            if not r.ended and not (r.done and (r.conn == nil or r.conn.closed)) then n = n + 1 end
        end
        return n
    end

    --- The last relay spawned.
    function f.last() return f.relays[#f.relays] end

    return f
end

return M

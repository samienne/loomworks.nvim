--- loomworks/proto/conformance.lua — the conformance engine (spec §19.20
--- "Schemas and conformance"): replays a golden transcript against a daemon
--- through a transport driver, validating every frame against the schemas.
---
--- A transcript file (`transcripts/<namespace>/<Rest>.<v>.json` under the
--- protocol directory, beside the interface's schema) is language-neutral
--- data, checked by `meta/transcript.schema.json`:
---
---   { "transcripts": 1, "interface": "loomworks.Tasks", "version": 1,
---     "description": "...",
---     "cases": [ { "name", "description"?, "fixture"?, "hello"?, "handshake"?,
---                  "allow"?, "steps": [ ... ] } ] }
---
--- A case runs on a fresh daemon of its `fixture` (a workspace the runner
--- prepares: `empty`, `shell`; see FIXTURES) over one connection. Unless
--- `handshake` is false, the runner first sends the default `hello` (with the
--- case's `hello` fields over it) and expects `welcome`, bound as the
--- variable `welcome`. Steps:
---
---   { "send": <frame template> }           send a frame; `"malformed": true`
---                                           skips its validation (a test of a
---                                           malformed frame)
---   { "expect": <frame pattern>, "timeout_ms"? }
---                                           the first received frame its
---                                           selector picks must match it
---   { "expect_none": <frame pattern>, "within_ms" }
---                                           no frame its selector picks
---                                           arrives within the time
---
--- Selector: an expected frame's `kind` and, where literal (or `$var`), its
--- `req_id`, `object`, `iface`, `name`, `sub_id`, `task_id` and `phase` pick
--- the earliest received, not yet consumed frame; frames of other streams
--- may interleave freely. The picked frame must then match the whole
--- pattern. At the end of a case, every received frame must have been
--- consumed or be matched by one of the case's `allow` patterns.
---
--- Patterns are partial: an object pattern names the fields it checks
--- (others are allowed — clients tolerate unknown fields), an array pattern
--- has the actual array's length. A table whose keys all start with `$` is
--- a matcher:
---
---   { "$any": true }            present, any value
---   { "$type": "<json type>" }  of that type (integer, string, object, ...)
---   { "$absent": true }         the field is absent
---   { "$bind": "<name>" }       binds the value (equal to it if already bound)
---   { "$var": "<name>[.<field>...]" }
---                               equals a bound variable (in a template:
---                               its value; with "$with": an object merged
---                               over it)
---   { "$contains": [ ... ] }    an array with a distinct element per pattern
---   { "$exact": { ... } }       an object with exactly these fields
---   { "$pattern": "<re>" }      a string matching the portable pattern subset
---   { "$len": <n> }             an array or string of that length
---
--- Matchers combine (`{ "$bind": "sub", "$type": "integer" }`). Variables the
--- runner binds before a case: `lw_version` (the binary's), `env` (the
--- client environment to send as `env`), `root` (the fixture's root as the
--- runner named it) and, after the handshake, `welcome`.
---
--- Every received frame is validated: a transport frame (transport.json)
--- against its frame schema; the `ok` of an interface call against its
--- method's result schema; an `error`'s code is a transport code or one the
--- method declares; a `signal` against its interface's signal schema, and a
--- subscribed signal's `seq` is the previous one of its object on this
--- connection + 1 (from the baseline `subscribe` returned). Frames of
--- protocol 10 (v0 replies, `model_change`, ...) are not interface frames:
--- they are not validated, only matched. The task frames of a task an
--- interface call started (its `ok` result `accepted` with a `task_id`, for
--- a method the schema declares task-streamed) are: the `start` meta must
--- name the method (`object`, `iface`, `v`, `method`) and match the
--- method's task meta schema, and the `done` must carry a `result` matching
--- its task result schema.
---
--- A driver is `{ send(frame) -> ok, err; recv(timeout_ms) -> frame | nil,
--- err; close(); now?() -> ms }`; `recv` blocks up to `timeout_ms` (0: only
--- what is already there) and returns nil + "timeout" when nothing came, nil
--- + another reason when the connection ended; `now` is a monotonic clock in
--- milliseconds (default: os.time). Pure Lua (shared): proto/* and vim.json only.

local schema = require("loomworks.proto.schema")
local documents = require("loomworks.proto.documents")

local M = {}

--- The transcript format version.
M.FORMAT = 1

--- The fixtures a runner prepares (the format's contract; their content is
--- described here, each runner creates it):
---   empty  a root with `loomworks.json` = `{"projects": {}}` and `.nvim/`
---   shell  a `shell` project `app` (path `app`, configuration `Debug`,
---          build directory `${workspace_root}/out/${variant}`, configure
---          and build commands that print a line and exit 0, slept
---          `LW_TEST_SLEEP` ms when the client environment sets it), the
---          configuration set `dev` (`app` = `Debug`) and a trusted working
---          copy with the profile `dev` and, on `app`, the launch
---          configuration `hello` (an existing program, run with one
---          argument)
M.FIXTURES = { empty = true, shell = true }

--- Default per-step timeout.
M.TIMEOUT_MS = 30000
--- How long the end of a case waits for late frames before checking that
--- every received frame was consumed or allowed.
M.SETTLE_MS = 100

--- Fields of an expected frame that select the frame it is matched to.
M.SELECT_KEYS = { "kind", "req_id", "object", "iface", "name", "sub_id", "task_id", "phase" }

local NIL = rawget(_G, "vim") and vim.NIL or nil

local function is_null(v) return v == nil or (NIL ~= nil and v == NIL) end

local function is_matcher(t)
    if type(t) ~= "table" or next(t) == nil then return false end
    for k in pairs(t) do
        if type(k) ~= "string" or k:sub(1, 1) ~= "$" then return false end
    end
    return true
end

local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return setmetatable(out, getmetatable(t))
end

local function encode(v)
    local ok, s = pcall(vim.json.encode, v)
    return ok and s or tostring(v)
end

--- A variable by dotted path (`welcome.header.root`).
--- @param vars table
--- @param name string
--- @return any value, boolean found
function M.lookup(vars, name)
    local cur = vars
    for part in tostring(name):gmatch("[^%.]+") do
        if type(cur) ~= "table" then return nil, false end
        local nxt = cur[part]
        if nxt == nil then nxt = cur[tonumber(part) or false] end
        if nxt == nil then return nil, false end
        cur = nxt
    end
    return cur, true
end

--- Expand a frame template: `{ "$var": name [, "$with": {...}] }` becomes
--- the variable's value (with the fields of `$with` over a copy of it).
--- @param t any
--- @param vars table
--- @return any|nil value, string|nil err
function M.expand(t, vars)
    if type(t) ~= "table" then return t end
    if is_matcher(t) then
        if t["$var"] == nil then return nil, "a template takes only $var matchers: " .. encode(t) end
        local v, found = M.lookup(vars, t["$var"])
        if not found then return nil, "unbound variable " .. tostring(t["$var"]) end
        if t["$with"] ~= nil then
            if type(v) ~= "table" or type(t["$with"]) ~= "table" then return nil, "$with needs objects" end
            v = copy(v)
            for k, x in pairs(t["$with"]) do v[k] = x end
        end
        return copy(v)
    end
    local out = {}
    for k, v in pairs(t) do
        local e, err = M.expand(v, vars)
        if err then return nil, err end
        out[k] = e
    end
    return setmetatable(out, getmetatable(t))
end

local function json_type_ok(name, v)
    return (schema.validate({ type = name }, v))
end

local match

--- Apply a matcher table (see the header) to `actual`.
local function match_matcher(m, actual, vars, path, present)
    for k, want in pairs(m) do
        if k == "$absent" then
            if want and present then return false, path .. ": expected absent, got " .. encode(actual) end
            if not want and not present then return false, path .. ": missing" end
        elseif not present and k ~= "$with" then
            return false, path .. ": missing"
        end
    end
    if not present then return true end
    for k, want in pairs(m) do
        if k == "$any" or k == "$absent" or k == "$with" then -- luacheck: ignore 542
        elseif k == "$type" then
            if not json_type_ok(want, actual) then
                return false, string.format("%s: expected a %s, got %s", path, tostring(want), encode(actual))
            end
        elseif k == "$bind" then
            local cur, found = M.lookup(vars, want)
            if found then
                local ok, err = match(cur, actual, vars, path)
                if not ok then return false, err .. " (variable " .. want .. ")" end
            else
                vars[want] = actual
            end
        elseif k == "$var" then
            local cur, found = M.lookup(vars, want)
            if not found then return false, path .. ": unbound variable " .. tostring(want) end
            if not schema.equal(cur, actual) then
                return false, string.format("%s: expected %s (%s), got %s", path, encode(cur), want, encode(actual))
            end
        elseif k == "$contains" then
            if type(actual) ~= "table" or not schema.is_array(actual) then
                return false, path .. ": expected an array, got " .. encode(actual)
            end
            local used = {}
            for i, p in ipairs(want) do
                local hit = false
                for j, a in ipairs(actual) do
                    if not used[j] then
                        local trial = copy(vars)
                        if match(p, a, trial, path .. "/" .. (j - 1)) then
                            used[j], hit = true, true
                            for vk, vv in pairs(trial) do vars[vk] = vv end
                            break
                        end
                    end
                end
                if not hit then
                    return false, string.format("%s: no element matches $contains[%d] %s in %s", path, i - 1,
                        encode(p), encode(actual))
                end
            end
        elseif k == "$exact" then
            if type(actual) ~= "table" then return false, path .. ": expected an object, got " .. encode(actual) end
            for ak in pairs(actual) do
                if want[ak] == nil then return false, path .. ": unexpected field " .. tostring(ak) end
            end
            local ok, err = match(want, actual, vars, path)
            if not ok then return false, err end
        elseif k == "$pattern" then
            if type(actual) ~= "string" or not schema.validate({ type = "string", pattern = want }, actual) then
                return false, string.format("%s: %s does not match %s", path, encode(actual), tostring(want))
            end
        elseif k == "$len" then
            local n = type(actual) == "string" and #actual or (type(actual) == "table" and #actual) or nil
            if n ~= want then return false, string.format("%s: expected length %s, got %s", path, tostring(want), tostring(n)) end
        else
            return false, path .. ": unknown matcher " .. k
        end
    end
    return true
end

--- Match `actual` against pattern `expected` (see the header), binding
--- variables into `vars`.
--- @param expected any
--- @param actual any
--- @param vars table
--- @param path? string
--- @return boolean ok, string|nil err
function match(expected, actual, vars, path)
    path = path or ""
    if is_matcher(expected) then return match_matcher(expected, actual, vars, path == "" and "/" or path, not is_null(actual)) end
    if type(expected) ~= "table" then
        if is_null(expected) then
            if is_null(actual) then return true end
            return false, string.format("%s: expected null, got %s", path, encode(actual))
        end
        if expected == actual then return true end
        return false, string.format("%s: expected %s, got %s", path == "" and "/" or path, encode(expected), encode(actual))
    end
    if type(actual) ~= "table" then
        return false, string.format("%s: expected %s, got %s", path == "" and "/" or path, encode(expected), encode(actual))
    end
    if schema.is_array(expected) then
        if not schema.is_array(actual) or #actual ~= #expected then
            return false, string.format("%s: expected %d elements, got %s", path, #expected, encode(actual))
        end
        for i, e in ipairs(expected) do
            local ok, err = match(e, actual[i], vars, path .. "/" .. (i - 1))
            if not ok then return false, err end
        end
        return true
    end
    for k, e in pairs(expected) do
        local a = actual[k]
        if is_matcher(e) then
            local ok, err = match_matcher(e, a, vars, path .. "/" .. tostring(k), not is_null(a))
            if not ok then return false, err end
        else
            if a == nil then return false, path .. "/" .. tostring(k) .. ": missing" end
            local ok, err = match(e, a, vars, path .. "/" .. tostring(k))
            if not ok then return false, err end
        end
    end
    return true
end
M.match = match

--- Does `frame` belong to the stream `pattern` selects (see the header)?
--- @param pattern table
--- @param frame table
--- @param vars table
--- @return boolean
function M.selects(pattern, frame, vars)
    for _, k in ipairs(M.SELECT_KEYS) do
        local want = pattern[k]
        if want ~= nil then
            if is_matcher(want) then
                if want["$var"] ~= nil then
                    local v, found = M.lookup(vars, want["$var"])
                    if found and not schema.equal(v, frame[k]) then return false end
                end
            elseif not schema.equal(want, frame[k]) then
                return false
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Frame validation
-- ---------------------------------------------------------------------------

--- @class loomworks.proto.ConformanceSession
--- @field set loomworks.proto.DocumentSet
--- @field calls table<integer, table> req_id -> the call frame sent
--- @field subs table<integer, { object: string, iface: string, v: integer }>
--- @field last_seq table<string, integer> per object: the last seq received
--- @field queue table[] received frames not consumed
--- @field vars table
local Session = {}
Session.__index = Session

--- A session over a driver.
--- @param driver table
--- @param opts? { set?: loomworks.proto.DocumentSet, vars?: table }
--- @return loomworks.proto.ConformanceSession
function M.session(driver, opts)
    opts = opts or {}
    local self = setmetatable({ driver = driver, set = opts.set or documents.set(), calls = {}, subs = {}, tasks = {},
        last_seq = {}, queue = {}, vars = opts.vars or {}, received = 0 }, Session)
    local transport = self.set:load("transport.json")
    self.transport = transport
    self.codes = {}
    for c in pairs(transport and transport.error_codes or {}) do self.codes[c] = true end
    return self
end

--- Validate a frame against its transport frame schema.
--- @param frame table
--- @return boolean ok, string|nil err
function Session:check_transport(frame)
    local frames = self.transport and self.transport.frames or {}
    if not frames[frame.kind] then return true end
    return self.set:validate("transport.json", "/frames/" .. frame.kind, frame)
end

--- The interface document of a call or signal.
function Session:_iface(iface, v)
    local doc, rel = self.set:interface(iface, v)
    if not doc then return nil, rel end
    return doc, rel
end

--- Validate one received frame (see the header). Returns true, or false +
--- the violation.
--- @param frame table
--- @return boolean ok, string|nil err
function Session:check_received(frame)
    if type(frame) ~= "table" or type(frame.kind) ~= "string" then return false, "a frame without a kind" end
    local call = (frame.kind == "ok" or frame.kind == "error") and self.calls[frame.req_id] or nil
    -- A v0 reply (no tracked interface call) is a protocol-10 frame.
    if (frame.kind == "ok" or frame.kind == "error") and not call then return true end
    local ok, err = self:check_transport(frame)
    if not ok then return false, frame.kind .. " frame: " .. tostring(err) end
    if call then
        self.calls[frame.req_id] = nil
        local doc, rel = self:_iface(call.iface, call.v)
        if frame.kind == "ok" then
            if doc and doc.methods and doc.methods[call.method] then
                local okr, rerr = self.set:validate(rel, "/methods/" .. call.method .. "/result", frame.result)
                if not okr then
                    return false, string.format("%s/%d.%s result: %s", call.iface, call.v, call.method, tostring(rerr))
                end
                -- A task-streamed method's accepted task: its frames are typed.
                local r = frame.result
                if doc.methods[call.method].task and type(r) == "table" and r.outcome == "accepted"
                    and r.task_id ~= nil then
                    self.tasks[r.task_id] = { iface = call.iface, v = call.v, method = call.method,
                        object = call.object, rel = rel }
                end
            end
            -- Track subscriptions and their seq baselines.
            if call.iface == "loomworks.Root" and call.method == "subscribe" and type(frame.result) == "table" then
                local a = call.args or {}
                self.subs[frame.result.sub_id] = { object = a.object, iface = a.iface, v = a.v }
                if type(frame.result.seq) == "number" then
                    local cur = self.last_seq[a.object]
                    if cur ~= nil and cur ~= frame.result.seq then
                        return false, string.format("subscribe baseline seq %d of %s, but %d was the last received",
                            frame.result.seq, tostring(a.object), cur)
                    end
                    self.last_seq[a.object] = frame.result.seq
                end
            end
        else
            local code = frame.error and frame.error.code
            local declared = {}
            local m = doc and doc.methods and doc.methods[call.method]
            for _, c in ipairs(m and m.errors or {}) do declared[c] = true end
            if not (self.codes[code] or declared[code]) then
                return false, string.format("%s/%d.%s error code %s is neither a transport code nor declared",
                    call.iface, call.v, call.method, tostring(code))
            end
        end
        return true
    end
    if frame.kind == "task" then return self:check_task(frame) end
    if frame.kind == "signal" then
        local doc, rel = self:_iface(frame.iface, frame.v)
        if not doc then return false, "signal of an interface without a document: " .. tostring(rel) end
        if not (doc.signals and doc.signals[frame.name]) then
            return false, string.format("%s/%d has no signal %s", frame.iface, frame.v, tostring(frame.name))
        end
        local oks, serr = self.set:validate(rel, "/signals/" .. frame.name .. "/args", frame.args)
        if not oks then return false, string.format("%s/%d signal %s: %s", frame.iface, frame.v, frame.name, tostring(serr)) end
        if frame.sub_id ~= nil then
            local sub = self.subs[frame.sub_id]
            if not sub then return false, "signal for an unknown sub_id " .. tostring(frame.sub_id) end
            if sub.object ~= frame.object or sub.iface ~= frame.iface or sub.v ~= frame.v then
                return false, "signal does not match its subscription " .. tostring(frame.sub_id)
            end
            local last = self.last_seq[frame.object] or 0
            if frame.seq ~= last + 1 then
                return false, string.format("signal seq %s of %s after %d (a gap or a repeat)", tostring(frame.seq),
                    frame.object, last)
            end
            self.last_seq[frame.object] = frame.seq
        elseif frame.object ~= "/" then
            return false, "a signal of " .. tostring(frame.object) .. " without a sub_id"
        end
    end
    return true
end

--- Validate a task frame of an interface method's task (see the header):
--- the start meta names the method and matches its task meta schema; the
--- `done` carries a `result` matching its task result schema. Tasks no
--- interface call started (protocol-10 requests) are only matched.
--- @param frame table
--- @return boolean ok, string|nil err
function Session:check_task(frame)
    local t = self.tasks[frame.task_id]
    if not t then return true end
    local base = "/methods/" .. t.method .. "/task/"
    local what = string.format("%s/%d.%s task %s", t.iface, t.v, t.method, tostring(frame.task_id))
    if frame.phase == "start" then
        local m = type(frame.meta) == "table" and frame.meta or {}
        if m.object ~= t.object or m.iface ~= t.iface or m.v ~= t.v or m.method ~= t.method then
            return false, what .. ": the start meta does not name its method"
        end
        local ok, err = self.set:validate(t.rel, base .. "meta", frame.meta)
        if not ok then return false, what .. " meta: " .. tostring(err) end
    elseif frame.phase == "done" then
        self.tasks[frame.task_id] = nil
        if frame.result == nil then return false, what .. ": done without a result" end
        local ok, err = self.set:validate(t.rel, base .. "result", frame.result)
        if not ok then return false, what .. " result: " .. tostring(err) end
    end
    return true
end

--- Receive one frame (validated, queued). Returns it, or nil + why.
--- @param timeout_ms integer
--- @return table|nil frame, string|nil err
function Session:_pull(timeout_ms)
    local frame, err = self.driver.recv(timeout_ms)
    if not frame then return nil, err or "timeout" end
    self.received = self.received + 1
    local ok, verr = self:check_received(frame)
    if not ok then error({ conformance = "invalid frame " .. encode(frame) .. ": " .. tostring(verr) }) end
    self.queue[#self.queue + 1] = frame
    return frame
end

--- Send a frame (validated against its transport schema unless malformed).
--- @param frame table
--- @param malformed? boolean
function Session:send(frame, malformed)
    if not malformed then
        local ok, err = self:check_transport(frame)
        if not ok then error({ conformance = "the transcript sends an invalid " .. tostring(frame.kind) .. ": " .. tostring(err) }) end
    end
    if frame.kind == "call" and type(frame.req_id) == "number" then self.calls[frame.req_id] = frame end
    local ok, err = self.driver.send(frame)
    if ok == false or (ok == nil and err) then error({ conformance = "send failed: " .. tostring(err) }) end
end

--- Consume the first frame `pattern` selects, waiting up to `timeout_ms`;
--- it must match. Returns the frame.
function Session:expect(pattern, timeout_ms)
    local now = self.driver.now or function() return os.time() * 1000 end
    local deadline = now() + (timeout_ms or M.TIMEOUT_MS)
    local i = 1
    while true do
        while i <= #self.queue do
            local f = self.queue[i]
            if M.selects(pattern, f, self.vars) then
                table.remove(self.queue, i)
                local ok, err = match(pattern, f, self.vars, "")
                if not ok then
                    error({ conformance = "frame " .. encode(f) .. " does not match " .. encode(pattern) .. ": " .. tostring(err) })
                end
                return f
            end
            i = i + 1
        end
        local left = deadline - now()
        if left <= 0 then break end
        local f, err = self:_pull(math.min(left, 50))
        if not f and err ~= "timeout" then
            error({ conformance = "connection " .. tostring(err) .. " while expecting " .. encode(pattern) })
        end
    end
    local pending = {}
    for _, f in ipairs(self.queue) do pending[#pending + 1] = encode(f) end
    error({ conformance = "no frame for " .. encode(pattern) .. " (unconsumed: " .. table.concat(pending, ", ") .. ")" })
end

--- No frame `pattern` selects arrives within `within_ms`.
function Session:expect_none(pattern, within_ms)
    local left = within_ms or 500
    while left > 0 do
        local slice = math.min(left, 50)
        self:_pull(slice)
        left = left - slice
    end
    for _, f in ipairs(self.queue) do
        if M.selects(pattern, f, self.vars) and match(pattern, f, copy(self.vars), "") then
            error({ conformance = "unexpected frame " .. encode(f) .. " for expect_none " .. encode(pattern) })
        end
    end
end

--- The end of a case: every received frame was consumed or is allowed.
function Session:finish(allow, settle_ms)
    -- What already arrived, then what arrives while settling.
    while self:_pull(0) do end
    local left = settle_ms or M.SETTLE_MS
    while left > 0 do
        local slice = math.min(left, 25)
        local f, err = self:_pull(slice)
        if not f and err ~= "timeout" then break end
        if not f then left = left - slice end
    end
    for _, f in ipairs(self.queue) do
        local ok = false
        for _, p in ipairs(allow or {}) do
            if M.selects(p, f, self.vars) and match(p, f, copy(self.vars), "") then
                ok = true
                break
            end
        end
        if not ok then error({ conformance = "unexpected frame " .. encode(f) }) end
    end
end

--- The default `hello` of a case (the case's `hello` fields over it).
--- @param case table
--- @param vars table
--- @return table
function M.hello(case, vars)
    local h = { kind = "hello", protocol = 11, protocol_min = 10, nonce = string.rep("0", 64),
        lw_version = vars.lw_version, client = "cli" }
    for k, v in pairs(type(case.hello) == "table" and case.hello or {}) do h[k] = v end
    return h
end

--- Run one case over a connected driver. Returns true, or false + the
--- failure (with the step).
--- @param case table
--- @param driver table
--- @param opts? { set?: loomworks.proto.DocumentSet, vars?: table, timeout_ms?: integer, settle_ms?: integer }
--- @return boolean ok, string|nil err
function M.run_case(case, driver, opts)
    opts = opts or {}
    local vars = copy(opts.vars or {})
    local s = M.session(driver, { set = opts.set, vars = vars })
    local where = "handshake"
    local ok, err = pcall(function()
        if case.handshake ~= false then
            local hello, herr = M.expand(M.hello(case, vars), vars)
            if not hello then error({ conformance = herr }) end
            s:send(hello)
            s.vars.welcome = s:expect({ kind = "welcome" }, opts.timeout_ms)
        end
        for i, step in ipairs(case.steps or {}) do
            where = "step " .. i
            if step.send ~= nil then
                local frame, eerr = M.expand(step.send, s.vars)
                if not frame then error({ conformance = eerr }) end
                s:send(frame, step.malformed == true)
            elseif step.expect ~= nil then
                s:expect(step.expect, step.timeout_ms or opts.timeout_ms)
            elseif step.expect_none ~= nil then
                s:expect_none(step.expect_none, step.within_ms)
            else
                error({ conformance = "a step without send, expect or expect_none" })
            end
        end
        where = "end"
        s:finish(case.allow, opts.settle_ms)
    end)
    if ok then return true end
    local text = type(err) == "table" and err.conformance or tostring(err)
    return false, string.format("%s: %s", where, text)
end

--- Check a decoded transcript file's shape beyond its meta-schema: its
--- interface/version name the path, its fixtures are known.
--- @param t table
--- @param rel string|nil the file's path relative to the protocol directory
--- @return string[] problems
function M.check_file(t, rel)
    local problems = {}
    if type(t) ~= "table" then return { "not an object" } end
    if t.transcripts ~= M.FORMAT then problems[#problems + 1] = "unknown format " .. tostring(t.transcripts) end
    if rel then
        local want = documents.interface_path(t.interface, t.version)
        want = want and ("transcripts/" .. want:gsub("^interfaces/", ""))
        if want ~= rel then problems[#problems + 1] = string.format("names %s/%s but lives at %s", tostring(t.interface), tostring(t.version), rel) end
    end
    for i, c in ipairs(t.cases or {}) do
        if c.fixture ~= nil and not M.FIXTURES[c.fixture] then
            problems[#problems + 1] = string.format("case %d: unknown fixture %s", i, tostring(c.fixture))
        end
    end
    return problems
end

return M

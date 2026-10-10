--- loomworks/provision/probe.lua — the editor's pre-launch probe of a
--- search-path or explicit `lw` (spec §19.16 "Pre-launch probe", step 5h.5).
---
--- Before the observer launches the workspace daemon from an `lw` it did not
--- provision itself, it runs `<binary> version --json` (the binary
--- descriptor, §16.41) — asynchronously, bounded by TIMEOUT_MS, with the
--- editor's data directory as working directory (never the workspace, which
--- may be an untrusted repository, §17) — and weighs the descriptor with the
--- plugin pin's check (loomworks.provision.needs.problems):
---
---   compatible    no structural or fatal problem (a missing feature
---                 interface only degrades that feature: listed in `degraded`)
---   incompatible  a definite failure: no transport overlap, schemas that
---                 differ from ours (older or newer), the root interface not
---                 offered
---   unknown       no descriptor (an lw older than §16.41, one with no system
---                 Lua, output that is not a descriptor, no `schemas`) or a
---                 timeout: the binary is used and the handshake decides
---
--- The verdict is cached for the editor session by the binary's realpath,
--- size and modification time, so the host-binary selection
--- (loomworks.provision.select.resolve) stays synchronous over cached
--- verdicts. The plugin-managed lw is never probed: its release was checked
--- when it was pinned.

local uv = vim.uv or vim.loop

local M = {}

local function env_ms(name)
    local v = tonumber(os.getenv(name) or "")
    return (v and v > 0) and v or nil
end

--- The probe's bound (spec: about 3 s).
M.TIMEOUT_MS = env_ms("LW_TEST_PROBE_MS") or 3000

--- @alias loomworks.provision.ProbeVerdict "compatible"|"incompatible"|"unknown"

--- @class loomworks.provision.Probe  one binary's probe result
--- @field verdict loomworks.provision.ProbeVerdict
--- @field problems string[] why it is incompatible (fatal problems), or why it is unknown (one line)
--- @field degraded string[] feature interfaces it does not offer (those features degrade)
--- @field version? string the lw version its descriptor names

--- verdicts by cache key ("<realpath>|<size>|<mtime>")
--- @type table<string, loomworks.provision.Probe>
M._cache = {}
--- callbacks of the probe in flight, by cache key (single-flight)
--- @type table<string, fun(v: loomworks.provision.Probe)[]>
M._inflight = {}

--- Forget every verdict (tests).
function M.reset()
    M._cache, M._inflight = {}, {}
end

--- The cache key of `path`: its realpath, size and modification time, or nil
--- + why when it cannot be read.
--- @param path string
--- @return string|nil key, string|nil why
function M.key(path)
    local st = uv.fs_stat(path)
    if not st then return nil, "cannot read " .. path end
    local real = uv.fs_realpath(path) or path
    local mt = st.mtime or {}
    return string.format("%s|%d|%d.%09d", real, st.size or 0, mt.sec or 0, mt.nsec or 0)
end

--- The cached verdict for `path`, or nil when it was not probed yet. A
--- binary that cannot be read is `unknown` (nothing to probe; the launch
--- then reports the real error).
--- @param path string
--- @return loomworks.provision.Probe|nil
function M.cached(path)
    local key, why = M.key(path)
    if not key then return { verdict = "unknown", problems = { why }, degraded = {} } end
    return M._cache[key]
end

--- Weigh a probe's output.
--- @param res { code: integer, stdout?: string, stderr?: string, timed_out?: boolean }
--- @return loomworks.provision.Probe
function M.classify(res)
    local function unknown(why) return { verdict = "unknown", problems = { why }, degraded = {} } end
    if res.timed_out then return unknown("lw version --json did not answer within " .. M.TIMEOUT_MS .. " ms") end
    if res.code ~= 0 then
        local line = (res.stderr or ""):match("[^\r\n]+")
        return unknown("lw version --json failed (status " .. tostring(res.code) .. ")"
            .. (line and (": " .. line) or "") .. " — an lw older than the binary descriptor")
    end
    local ok, d = pcall(vim.json.decode, res.stdout or "")
    if not ok or type(d) ~= "table" then return unknown("lw version --json printed no descriptor") end
    local p = require("loomworks.provision.needs").problems(d, { exact_schemas = true })
    if #p.structure > 0 then return unknown(table.concat(p.structure, "; ")) end
    local version = type(d.binary) == "table" and d.binary.lw_version or nil
    return {
        verdict = #p.fatal > 0 and "incompatible" or "compatible",
        problems = p.fatal, degraded = p.degraded,
        version = type(version) == "string" and version or nil,
    }
end

--- One line for a verdict: `compatible`, `incompatible: …`, `unknown: …`.
--- @param v loomworks.provision.Probe|nil
--- @return string
function M.describe(v)
    if not v then return "not probed yet" end
    local s = v.verdict
    if #v.problems > 0 then s = s .. ": " .. table.concat(v.problems, "; ") end
    if v.verdict == "compatible" and #v.degraded > 0 then
        s = s .. " (degraded: " .. table.concat(v.degraded, "; ") .. ")"
    end
    return s
end

--- Probe `path` (async). `cb(verdict)` runs on the main loop, once the
--- verdict is cached; concurrent probes of one binary share one process.
--- opts (tests inject):
---   cwd         working directory (default: the editor's data directory)
---   timeout_ms  the bound (default TIMEOUT_MS)
---   argv        the command (default `{ path, "version", "--json" }`)
--- @param path string
--- @param opts? table
--- @param cb fun(v: loomworks.provision.Probe)
function M.run(path, opts, cb)
    opts = opts or {}
    local key, why = M.key(path)
    if not key then
        return vim.schedule(function() cb({ verdict = "unknown", problems = { why }, degraded = {} }) end)
    end
    if M._cache[key] then
        local v = M._cache[key]
        return vim.schedule(function() cb(v) end)
    end
    if M._inflight[key] then
        table.insert(M._inflight[key], cb)
        return
    end
    M._inflight[key] = { cb }
    local cache, inflight = M._cache, M._inflight
    local function finish(v)
        cache[key] = v
        local cbs = inflight[key] or {}
        inflight[key] = nil
        for _, f in ipairs(cbs) do pcall(f, v) end
    end
    local timeout = opts.timeout_ms or M.TIMEOUT_MS
    local cwd = opts.cwd or vim.fn.stdpath("data")
    if not uv.fs_stat(cwd) then cwd = nil end
    local ok, err = pcall(vim.system, opts.argv or { path, "version", "--json" },
        { cwd = cwd, text = true, timeout = timeout },
        function(r)
            -- vim.system reports its own timeout as status 124 after
            -- killing the process.
            local res = { code = r.code, stdout = r.stdout, stderr = r.stderr,
                timed_out = r.code == 124 and (r.signal or 0) ~= 0 }
            vim.schedule(function() finish(M.classify(res)) end)
        end)
    if not ok then
        vim.schedule(function()
            finish({ verdict = "unknown", problems = { "cannot run " .. path .. ": " .. tostring(err) }, degraded = {} })
        end)
    end
end

return M

--- loomworks/provision/channel.lua — channel upgrades of the plugin-managed
--- `lw` (spec §19.16 "Channel upgrades", step 5h.5).
---
--- The setup option `binary.channel` ("stable" or "unstable"; unset = the
--- plugin pin only, no lookups) lets the managed lw move ahead of the pin.
--- Only the pinned managed lw resolves a channel: it runs `<pinned lw>
--- release query --channel <c> --json` (spec §16.42), which resolves the
--- channel to a release verified against its signed SHA256SUMS and returns
--- that release's host-asset hashes and descriptor. The descriptor must pass
--- the pin's interface check (loomworks.provision.needs) with the probe's
--- schema rule — schemas equal to ours, since the managed lw is what the
--- search falls through to and the editor retires a daemon with older
--- schemas (loomworks.daemon.editor_retire). A newer result that passes is
--- **accepted**: it becomes the wanted managed binary
--- (loomworks.provision.managed.wanted takes the newer of the pin and it),
--- downloaded and hash-checked against the hash the query returned.
---
--- The last result lives in `<editor data>/loomworks/channel.json` (outside
--- `loomworks/lw/`, written atomically, never pruned):
---
---     { "format": 1, "channel": "unstable", "checked": <epoch s>,
---       "accepted": { "version", "asset", "sha256", "descriptor" },
---       "rejected": { "version", "why" }, "note": "<the last check's note>" }
---
--- A changed `binary.channel` makes a check due at once and forgets the
--- rejection; an accepted release is kept (switching from unstable to stable
--- keeps a newer accepted pre-release until stable overtakes it). An
--- accepted release is re-checked against this plugin on every read, so a
--- plugin update that no longer matches it falls back to the pin.
--- This module runs no process on its own: `run` is called by the observer
--- (loomworks.daemon.observer) only; checkhealth reads the file.

local uv = vim.uv or vim.loop

local M = {}

--- The file format version.
M.FORMAT = 1

--- Seconds between two background checks (spec: at most once a day).
M.INTERVAL_S = tonumber(os.getenv("LW_TEST_CHANNEL_INTERVAL_S") or "") or 86400

--- The query's overall limit (`--timeout`, seconds) and the process bound
--- around it (ms): the fetches are bounded by lw, the process by us.
M.QUERY_TIMEOUT_S = 60
M.PROCESS_TIMEOUT_MS = (M.QUERY_TIMEOUT_S + 15) * 1000

--- The valid values of `binary.channel`.
M.CHANNELS = { stable = true, unstable = true }

--- @class loomworks.provision.ChannelAccepted  an accepted channel release
--- @field version string
--- @field asset string this host's asset
--- @field sha256 string that asset's SHA-256, from the release's signed sums
--- @field descriptor table the release's descriptor (re-checked on every read)

--- @class loomworks.provision.ChannelRecord  the content of channel.json
--- @field format integer M.FORMAT
--- @field channel string the channel the record was made for
--- @field checked integer|nil when the last check ended (epoch seconds; a failure counts)
--- @field accepted loomworks.provision.ChannelAccepted|nil
--- @field rejected { version: string, why: string }|nil a release that failed the check (not checked again)
--- @field note string|nil the last check's note (the Runtime line, checkhealth)

--- @class loomworks.provision.ChannelOutcome  one query, weighed (`classify`)
--- @field kind "accepted"|"current"|"older"|"rejected"|"failed"|"unsupported"
--- @field version string|nil the version the channel offers
--- @field wanted loomworks.provision.Wanted|nil the accepted binary (`accepted`)
--- @field accepted loomworks.provision.ChannelAccepted|nil what channel.json keeps (`accepted`)
--- @field why string|nil why it was rejected or failed
--- @field note string|nil the note to show (nil: nothing worth saying)
--- @field override string|nil a release-source override superseded the channel (the query's `channel_ignored`): what to say
--- @field again boolean|nil the release was rejected before (not weighed again)

--- Whether `binary.channel` applies to the setting at all (spec: a valid
--- channel, downloads not off, no development `binary.source`). The
--- selection reaching the managed source is the caller's to check.
--- @param setting loomworks.provision.BinarySetting|nil
--- @return boolean
function M.applies(setting)
    return type(setting) == "table" and M.CHANNELS[setting.channel] == true and setting.download ~= false
        and not setting.source
end

--- The record's path.
--- @param data? string the editor's data directory (tests inject)
--- @return string
function M.file(data) return require("loomworks.provision.managed").root(data) .. "/channel.json" end

local function valid_accepted(a)
    local fetch = require("loomworks.provision.fetch")
    if type(a) ~= "table" or type(a.descriptor) ~= "table" then return nil end
    local w = fetch.check_wanted(a)
    if not w then return nil end
    return { version = w.version, asset = w.asset, sha256 = w.sha256, descriptor = a.descriptor }
end

--- Read channel.json, or nil when it is absent or unusable (an unusable file
--- is as good as none: the next check rewrites it).
--- @param opts? { data?: string }
--- @return loomworks.provision.ChannelRecord|nil
function M.load(opts)
    opts = opts or {}
    local fd = io.open(M.file(opts.data), "rb")
    if not fd then return nil end
    local text = fd:read("*a")
    fd:close()
    local ok, d = pcall(vim.json.decode, text or "")
    if not ok or type(d) ~= "table" or d.format ~= M.FORMAT or not M.CHANNELS[d.channel] then return nil end
    local rec = { format = M.FORMAT, channel = d.channel }
    if type(d.checked) == "number" then rec.checked = d.checked end
    rec.accepted = valid_accepted(d.accepted)
    if type(d.rejected) == "table" and type(d.rejected.version) == "string" then
        rec.rejected = { version = d.rejected.version, why = tostring(d.rejected.why or "") }
    end
    if type(d.note) == "string" and d.note ~= "" then rec.note = d.note end
    return rec
end

--- Write channel.json atomically: a per-process temporary file (whatever
--- non-directory sits at that name first is unlinked, never written
--- through), renamed over it; `loomworks/` is created when missing. Keys are
--- sorted (vim.json.encode with sort_keys) so the file diffs stably.
--- @param rec loomworks.provision.ChannelRecord
--- @param opts? { data?: string }
--- @return boolean ok, string|nil err
function M.save(rec, opts)
    opts = opts or {}
    local path = M.file(opts.data)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and vim.fn.isdirectory(dir) == 0 then
        pcall(vim.fn.mkdir, dir, "p")
        if vim.fn.isdirectory(dir) == 0 then return false, "cannot create " .. dir end
    end
    local eok, text = pcall(vim.json.encode, rec, { sort_keys = true })
    if not eok then eok, text = pcall(vim.json.encode, rec) end
    if not eok then return false, tostring(text) end
    local tmp = path .. "." .. tostring(uv.os_getpid()) .. ".tmp"
    local st = uv.fs_lstat(tmp)
    if st and st.type ~= "directory" then pcall(uv.fs_unlink, tmp) end
    -- O_WRONLY|O_CREAT|O_EXCL via the string flags: never through a link.
    local fd, oerr = uv.fs_open(tmp, "wx", 420)
    if not fd then return false, tostring(oerr) end
    local wok, werr = uv.fs_write(fd, text .. "\n", 0)
    uv.fs_close(fd)
    if not wok then
        pcall(uv.fs_unlink, tmp)
        return false, tostring(werr)
    end
    local rok, rerr = uv.fs_rename(tmp, path)
    if not rok then
        pcall(uv.fs_unlink, tmp)
        return false, tostring(rerr)
    end
    return true
end

--- The record as it applies to `channel`: a record of another channel keeps
--- only its accepted release (a check is due at once; the rejection is
--- forgotten), so unstable -> stable keeps a newer accepted pre-release.
--- @param rec loomworks.provision.ChannelRecord|nil
--- @param channel string
--- @return loomworks.provision.ChannelRecord
function M.for_channel(rec, channel)
    if rec and rec.channel == channel then return rec end
    return { format = M.FORMAT, channel = channel, accepted = rec and rec.accepted or nil }
end

--- Whether a background check is due (no check for this channel yet, or the
--- last one ended at least INTERVAL_S ago; a clock set back counts as due).
--- @param rec loomworks.provision.ChannelRecord|nil
--- @param channel string
--- @param now? integer
--- @return boolean
function M.due(rec, channel, now)
    now = now or os.time()
    if not rec or rec.channel ~= channel or type(rec.checked) ~= "number" then return true end
    return now - rec.checked >= M.INTERVAL_S or now < rec.checked
end

--- The descriptor's problems for this plugin (the pin's interface check,
--- schemas exact as for the probe): an empty list when it may be used.
--- @param descriptor any
--- @return string[]
function M.problems(descriptor)
    local ok, problems = require("loomworks.provision.needs").check(descriptor, { exact_schemas = true })
    return ok and {} or problems
end

--- The accepted release of `setting.channel` that this plugin can use, as a
--- wanted record (`channel` set), or nil (channel off, no record, another
--- host asset, the release no longer passes the check).
--- @param setting loomworks.provision.BinarySetting|nil
--- @param asset string this host's asset
--- @param opts? { data?: string, load?: fun(): loomworks.provision.ChannelRecord|nil }
--- @return loomworks.provision.Wanted|nil
function M.accepted(setting, asset, opts)
    opts = opts or {}
    if not M.applies(setting) then return nil end
    local rec = opts.load and opts.load() or M.load(opts)
    local a = rec and rec.accepted
    if not a or a.asset ~= asset or #M.problems(a.descriptor) > 0 then return nil end
    return { sha256 = a.sha256, version = a.version, asset = a.asset, channel = setting.channel }
end

local function split(v)
    local core, pre = v:match("^([^%-]+)%-?(.*)$")
    local nums, ids = {}, {}
    for n in (core or v):gmatch("%d+") do nums[#nums + 1] = tonumber(n) end
    if pre and pre ~= "" then
        for id in pre:gmatch("[^%.]+") do ids[#ids + 1] = id end
    end
    return nums, ids
end

local function cmp_ident(x, y)
    local nx, ny = tonumber(x), tonumber(y)
    if nx and ny then return nx < ny and -1 or (nx > ny and 1 or 0) end
    if nx then return -1 end
    if ny then return 1 end
    return x < y and -1 or (x > y and 1 or 0)
end

--- §16.29 ordering: -1, 0 or 1 (semver; a pre-release ranks below its
--- release). The plugin's own copy: lw's comparison is binary-side.
--- @param a string
--- @param b string
--- @return integer
function M.compare(a, b)
    local an, ap = split(a)
    local bn, bp = split(b)
    for i = 1, math.max(#an, #bn) do
        local x, y = an[i] or 0, bn[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    if #ap == 0 and #bp == 0 then return 0 end
    if #ap == 0 then return 1 end
    if #bp == 0 then return -1 end
    for i = 1, math.max(#ap, #bp) do
        local x, y = ap[i], bp[i]
        if x == nil then return -1 end
        if y == nil then return 1 end
        local r = cmp_ident(x, y)
        if r ~= 0 then return r end
    end
    return 0
end

--- The query's command line (after the binary).
--- @param channel string
--- @return string[]
function M.args(channel)
    return { "release", "query", "--channel", channel, "--json", "--timeout", tostring(M.QUERY_TIMEOUT_S) }
end

--- The query's extra environment: the release-source override
--- (`binary.release_url`) and the install-folder override (spec §19.16
--- "Install location"), passed through.
--- @param opts? { release_url?: string, data?: string }
--- @return table<string, string>
function M.env(opts)
    opts = opts or {}
    local env = { LOOMWORKS_INSTALL_DIR = require("loomworks.provision.managed").root(opts.data) }
    if type(opts.release_url) == "string" and opts.release_url ~= "" then env.LOOMWORKS_RELEASE_URL = opts.release_url end
    return env
end

local function first_line(s)
    local l = type(s) == "string" and s:match("[^\r\n]+") or nil
    return l and (l:gsub("^lw: ", "")) or nil
end

--- Weigh a query's result against the current wanted binary.
--- res: { code, stdout, stderr, timed_out } (the process), or { error }.
--- ctx: { channel, current = loomworks.provision.Wanted (what is wanted now),
--- asset = this host's asset, rejected = the record's rejection,
--- pinned_version = the pinned lw's version (its notes) }.
--- @param res table
--- @param ctx table
--- @return loomworks.provision.ChannelOutcome
function M.classify(res, ctx)
    local ch, cur = ctx.channel, ctx.current
    local staying = "staying on lw v" .. tostring(cur and cur.version)
    local function failed(why)
        return { kind = "failed", why = why,
            note = "binary.channel = " .. ch .. ": could not check (" .. why .. "); " .. staying }
    end
    if res.error then return failed(tostring(res.error)) end
    if res.timed_out then return failed("lw release query did not answer within " .. M.QUERY_TIMEOUT_S .. " s") end
    if res.code ~= 0 then
        local line = first_line(res.stderr)
        -- A pinned lw older than §16.42 rejects the command as a usage error.
        if res.code == 2 and line and line:find("unknown command", 1, true) then
            return { kind = "unsupported", why = line,
                note = "binary.channel = " .. ch .. ": the pinned lw v" .. tostring(ctx.pinned_version or "?")
                    .. " has no `lw release query`; " .. staying }
        end
        return failed("lw release query failed (status " .. tostring(res.code) .. ")" .. (line and (": " .. line) or ""))
    end
    local ok, d = pcall(vim.json.decode, res.stdout or "")
    if not ok or type(d) ~= "table" then return failed("lw release query printed no JSON") end
    local fetch = require("loomworks.provision.fetch")
    if not fetch.valid_version(d.version) then return failed("no valid release version in the query") end
    local v = d.version
    local ignored = d.channel_ignored == true
        and ("a release-source override (binary.release_url / LOOMWORKS_RELEASE_URL or lw's release-url) "
            .. "supersedes binary.channel = " .. ch) or nil
    local function with_override(note)
        if not ignored then return note end
        return note and (note .. " (" .. ignored .. ")") or ignored
    end
    if cur and M.compare(v, cur.version) <= 0 then
        -- Not newer (the current one, or a withdrawn release): nothing to do.
        return { kind = M.compare(v, cur.version) == 0 and "current" or "older", version = v, note = with_override(nil) }
    end
    if ctx.rejected and ctx.rejected.version == v then
        return { kind = "rejected", version = v, why = ctx.rejected.why, again = true,
            note = with_override(ch .. " offers lw v" .. v .. ", which this plugin cannot use (" .. ctx.rejected.why
                .. "); " .. staying) }
    end
    local sha = type(d.assets) == "table" and d.assets[ctx.asset] or nil
    local w = fetch.check_wanted({ sha256 = sha, version = v, asset = ctx.asset })
    if not w then return failed("lw v" .. v .. " on " .. ch .. " has no valid " .. tostring(ctx.asset)) end
    local problems = M.problems(d.descriptor)
    if #problems > 0 then
        local why = table.concat(problems, "; ")
        return { kind = "rejected", version = v, why = why,
            note = with_override(ch .. " offers lw v" .. v .. ", which this plugin cannot use (" .. why .. "); "
                .. staying) }
    end
    w.channel = ch
    return { kind = "accepted", version = v, wanted = w, override = ignored,
        accepted = { version = w.version, asset = w.asset, sha256 = w.sha256, descriptor = d.descriptor },
        note = with_override("lw v" .. v .. " from " .. ch .. " accepted") }
end

--- The record after `out` (the check ended `now`).
--- @param rec loomworks.provision.ChannelRecord
--- @param out loomworks.provision.ChannelOutcome
--- @param now integer
--- @return loomworks.provision.ChannelRecord
function M.record(rec, out, now)
    local r = vim.deepcopy(rec)
    r.format, r.checked, r.note = M.FORMAT, now, out.note
    if out.kind == "accepted" then
        r.accepted, r.rejected = out.accepted, nil
    elseif out.kind == "rejected" then
        r.rejected = { version = out.version, why = out.why }
    end
    return r
end

--- Run `<pinned> release query --channel <c> --json` (async, bounded) with
--- the editor's data directory as working directory; `cb(res)` on the main
--- loop. opts: release_url, data, timeout_ms (tests).
--- @param pinned string the pinned managed lw (present and verified)
--- @param channel string
--- @param opts? table
--- @param cb fun(res: table)
function M.run(pinned, channel, opts, cb)
    opts = opts or {}
    local cwd = opts.cwd or vim.fn.stdpath("data")
    if not uv.fs_stat(cwd) then cwd = nil end
    local argv = { pinned }
    vim.list_extend(argv, M.args(channel))
    local ok, err = pcall(vim.system, argv,
        { cwd = cwd, text = true, timeout = opts.timeout_ms or M.PROCESS_TIMEOUT_MS, env = M.env(opts) },
        function(r)
            local res = { code = r.code, stdout = r.stdout, stderr = r.stderr,
                timed_out = r.code == 124 and (r.signal or 0) ~= 0 }
            vim.schedule(function() cb(res) end)
        end)
    if not ok then
        vim.schedule(function() cb({ error = "cannot run " .. pinned .. ": " .. tostring(err) }) end)
    end
end

--- checkhealth's lines (never queries): the channel, the last check and its
--- note, or nil when `binary.channel` is not set.
--- @param setting loomworks.provision.BinarySetting|nil
--- @param opts? { data?: string, now?: integer }
--- @return string[]|nil
function M.describe(setting, opts)
    opts = opts or {}
    if type(setting) ~= "table" or setting.channel == nil then return nil end
    if not M.applies(setting) then
        local why = not M.CHANNELS[setting.channel] and "not a channel"
            or setting.download == false and "downloads are off (binary.download = false)"
            or "binary.source is set (development)"
        return { "binary.channel = " .. tostring(setting.channel) .. ": no effect (" .. why .. ")" }
    end
    local rec = M.load(opts)
    local lines = {}
    if not rec or rec.channel ~= setting.channel or not rec.checked then
        lines[1] = "binary.channel = " .. setting.channel .. ": not checked yet (checked in daemon mode, "
            .. "at most once a day and on :LoomworksDaemon connect)"
    else
        lines[1] = "binary.channel = " .. setting.channel .. ": last checked " .. os.date("%Y-%m-%d %H:%M", rec.checked)
            .. (rec.note and (" — " .. rec.note) or "")
    end
    if rec and rec.accepted then
        local asset = require("loomworks.provision.managed").host_asset()
        local usable = asset and M.accepted(setting, asset, { load = function() return rec end })
        lines[#lines + 1] = "accepted channel release: lw v" .. rec.accepted.version
            .. (usable and "" or " (not used: another host asset, or it no longer matches this plugin)")
    end
    return lines
end

return M

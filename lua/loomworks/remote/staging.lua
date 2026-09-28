--- loomworks/remote/staging.lua — mirror a manifest onto a device with
--- digest-based incremental sync (spec §18.4) and remove a workspace's staging
--- tree (`lw device clean`, spec §16.34 / §18.12).
---
--- The sync record (per device serial and device staging root, kept in the
--- build cache as runtime state) remembers, per individually staged file, the
--- host file's size / mtime / content digest and the device-reported digest;
--- per archive set only the set digest (over every member's path, size and
--- content digest), a host stat fingerprint, the device digests of the
--- sampled members and the member paths grouped by directory — never a
--- per-member digest, which kept the record ~100 KB for a few hundred members.
--- A file is transferred only when new or its content digest changed; an
--- archive set is re-sent when its set digest changes. When the runner
--- declares `digest`, recorded files are verified against the device first
--- (a wiped / re-flashed device is re-staged). `fresh` ignores the record.
--- An archive set's tar is deleted after unpacking; a completion marker (the
--- set digest) plus a sample of the unpacked members stand in for it.
--- Files that left the manifest are removed from the device staging root.
---
--- Remote deletion safety (§18.12): every path core asks a device to remove is
--- checked to lie under `<staging_base>/<workspace>/` with a separator
--- boundary; nothing assembled from unchecked cache content is ever sent.

local manifest_mod = require("loomworks.remote.manifest")

local M = {}

local function uv() return vim.uv or vim.loop end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

--- Host-side digest of a file, reusing `prev` when size and mtime match.
--- @return { size: integer, mtime: integer, digest: string }|nil
local function local_digest(abs, prev)
    local st = uv().fs_stat(abs)
    if not st then return nil end
    local mtime = (st.mtime and (st.mtime.sec * 1000000000 + (st.mtime.nsec or 0))) or 0
    if prev and prev.size == st.size and prev.mtime == mtime and type(prev.digest) == "string" then
        return { size = st.size, mtime = mtime, digest = prev.digest }
    end
    local data = read_file(abs)
    if not data then return nil end
    return { size = st.size, mtime = mtime, digest = vim.fn.sha256(data) }
end

--- Group member paths by directory: `{ [dir] = { basename… } }` ("." for the
--- staging root itself). This is all an archive set's record keeps per member
--- — enough to remove members that later leave the set.
--- @param rels string[]
--- @return table<string, string[]>
function M.group_members(rels)
    local sorted = vim.deepcopy(rels)
    table.sort(sorted)
    local out = {}
    for _, rel in ipairs(sorted) do
        local d, b = rel:match("^(.*)/([^/]+)$")
        if not d then d, b = ".", rel end
        out[d] = out[d] or {}
        table.insert(out[d], b)
    end
    return out
end

--- The member paths an archive set's record names: the compact `members`
--- grouping, or a legacy record's per-member `locals` map.
--- @param a table archive record
--- @return string[] rels
function M.member_rels(a)
    local rels = {}
    if type(a) ~= "table" then return rels end
    if type(a.members) == "table" then
        for d, names in pairs(a.members) do
            if type(d) == "string" and type(names) == "table" then
                for _, n in ipairs(names) do
                    if type(n) == "string" then rels[#rels + 1] = d == "." and n or (d .. "/" .. n) end
                end
            end
        end
    elseif type(a.locals) == "table" then
        for rel in pairs(a.locals) do
            if type(rel) == "string" then rels[#rels + 1] = rel end
        end
    end
    return rels
end

--- Rewrite a sync record in the compact form (in place): an archive set keeps
--- only its set digest, marker, the device digests of its sampled members, a
--- host stat fingerprint and its member paths grouped by directory — never a
--- per-member digest (a changed member changes the set digest, which is what
--- re-sends it). A legacy record's per-member `locals` become `members`.
--- @param rec table|nil a (serial, staging root) sync record
--- @return table|nil rec
function M.compact_record(rec)
    if type(rec) ~= "table" or type(rec.archives) ~= "table" then return rec end
    for _, a in pairs(rec.archives) do
        if type(a) == "table" and type(a.locals) == "table" then
            a.members = M.group_members(M.member_rels(a))
            a.locals = nil
        end
    end
    return rec
end

--- Host stat fingerprint of an archive set's members (path, size, mtime):
--- when it matches the recorded one the recorded set digest is reused without
--- reading any member (as a staged file's digest is reused on size + mtime).
--- @param members { rel: string, abs: string }[]
--- @return string|nil fingerprint, table<string, table>|nil stats, integer bytes
local function stat_fingerprint(members)
    local parts, stats, bytes = {}, {}, 0
    for _, m in ipairs(members) do
        local st = uv().fs_stat(m.abs)
        if not st then return nil, nil, bytes end
        local sec = st.mtime and st.mtime.sec or 0
        local nsec = st.mtime and st.mtime.nsec or 0
        parts[#parts + 1] = m.rel .. "\0" .. st.size .. "\0" .. sec .. "." .. nsec
        stats[m.rel] = st
        bytes = bytes + st.size
    end
    return vim.fn.sha256(table.concat(parts, "\n")), stats, bytes
end

--- Parse `<hex digest>  <path>` lines.
local function parse_digests(lines)
    local out = {}
    for _, l in ipairs(lines or {}) do
        local hex, path = l:match("^\\?(%x+)%s+%*?(.+)$")
        if hex and path then out[path] = hex:lower() end
    end
    return out
end

local function fmt_bytes(n)
    if n >= 1024 * 1024 then return string.format("%.1f MB", n / (1024 * 1024)) end
    if n >= 1024 then return string.format("%.1f KB", n / 1024) end
    return tostring(n) .. " B"
end
M.fmt_bytes = fmt_bytes

--- Run a digest over device paths (chunked). Returns path → hex, or nil + err.
local function device_digests(transport, paths)
    local prefix = transport.runner.digest
    local out = {}
    local chunk = 64
    for i = 1, #paths, chunk do
        local argv = {}
        for _, a in ipairs(prefix) do argv[#argv + 1] = a end
        for j = i, math.min(i + chunk - 1, #paths) do argv[#argv + 1] = paths[j] end
        local status, lines = transport:shell(argv)
        if status == nil then return nil, lines end
        for p, h in pairs(parse_digests(lines)) do out[p] = h end
    end
    return out
end

--- Ask the device to remove paths — only ones under `ws_prefix` (§18.12).
local function device_remove(transport, paths, ws_prefix, recursive)
    if #paths == 0 then return true end
    local argv = { "rm", recursive and "-rf" or "-f" }
    for _, p in ipairs(paths) do
        if not manifest_mod.device_path_under(p, ws_prefix) then
            return nil, "refusing to remove device path outside " .. ws_prefix .. ": " .. tostring(p)
        end
        argv[#argv + 1] = p
    end
    local status, lines = transport:shell(argv)
    if status == nil then return nil, lines end
    if status ~= 0 then
        return nil, "removing staged files failed (status " .. status .. "): " .. table.concat(lines, " ")
    end
    return true
end

local function device_mkdirs(transport, dirs)
    if #dirs == 0 then return true end
    local argv = { "mkdir", "-p" }
    for _, d in ipairs(dirs) do argv[#argv + 1] = d end
    local status, lines = transport:shell(argv)
    if status == nil then return nil, lines end
    if status ~= 0 then return nil, "creating staging directories failed: " .. table.concat(lines, " ") end
    return true
end

--- Unpacked members of an archive set verified on later runs (with its marker).
M.ARCHIVE_SAMPLE = 8

--- A deterministic, evenly spread sample of an archive set's members (sorted
--- by path; first and last always included).
--- @param members { rel: string }[]
--- @return string[] rels
function M.sample_members(members)
    local rels = {}
    for _, m in ipairs(members or {}) do rels[#rels + 1] = m.rel end
    table.sort(rels)
    local n = math.min(M.ARCHIVE_SAMPLE, #rels)
    local out, seen = {}, {}
    for k = 0, n - 1 do
        local idx = (n == 1) and 1 or (1 + math.floor(k * (#rels - 1) / (n - 1)))
        if not seen[idx] then seen[idx] = true; out[#out + 1] = rels[idx] end
    end
    return out
end

--- @class loomworks.StageReport
--- @field sent integer files transferred
--- @field sent_bytes integer
--- @field unchanged integer files already current
--- @field removed integer files removed from the device
--- @field archives_sent integer
--- @field archives_unchanged integer
--- @field archive_bytes integer bytes of archive members (sent or unchanged)
--- @field verified boolean the record was verified against the device

--- Stage a manifest.
--- o:
---   transport  remote/transport instance (runner + serial)
---   manifest   loomworks.Manifest
---   ws_prefix  string device workspace prefix (deletion boundary)
---   root       string device staging root for the unit
---   record     table|nil the previous sync record for (serial, root)
---   fresh      boolean  ignore the record (full re-stage)
---   tmp_dir    string   host directory for temporary archives
---   on_progress fun(msg)|nil
--- @param o table
--- @return table|nil new_record, loomworks.StageReport|string report_or_err
function M.stage(o)
    local t, man, root = o.transport, o.manifest, o.root
    if not manifest_mod.device_path_under(root, o.ws_prefix) or root == o.ws_prefix then
        return nil, "invalid staging root " .. tostring(root)
    end
    local prev = (not o.fresh and type(o.record) == "table") and vim.deepcopy(o.record) or {}
    prev.files = type(prev.files) == "table" and prev.files or {}
    prev.archives = type(prev.archives) == "table" and prev.archives or {}
    -- Host-side knowledge of each archive set (stat fingerprint, set digest,
    -- legacy per-member digests), kept even when device verification below
    -- drops the set: a wiped device re-sends it without re-hashing members.
    local host_sets = {}
    for key, a in pairs(prev.archives) do
        if type(a) == "table" then
            host_sets[key] = { stat = a.stat, digest = a.digest,
                locals = type(a.locals) == "table" and a.locals or nil }
        end
    end
    local report = { sent = 0, sent_bytes = 0, unchanged = 0, removed = 0,
        archives_sent = 0, archives_unchanged = 0, archive_bytes = 0, verified = false }
    local function remote(rel) return root .. "/" .. rel end

    -- (0) Archives kept on the device by the earlier scheme (the whole tar
    -- under `.loomworks/`, no marker): removed below; their sets re-sent once.
    local legacy_tars = {}
    for key, a in pairs(prev.archives) do
        if type(a) ~= "table" or type(a.marker) ~= "string" then
            if type(a) == "table" and type(a.tar) == "string" and manifest_mod.clean_rel(a.tar) then
                legacy_tars[#legacy_tars + 1] = a.tar
            end
            prev.archives[key] = nil
        end
    end

    -- (1) Verify the record against the device when the runner can digest: a
    -- staged file by its digest; an archive set by its completion marker plus
    -- a sample of its unpacked members.
    if t.runner.digest and (next(prev.files) or next(prev.archives)) then
        local paths = {}
        for rel, e in pairs(prev.files) do
            if manifest_mod.clean_rel(rel) and e.remote then paths[#paths + 1] = remote(rel) end
        end
        for _, a in pairs(prev.archives) do
            if manifest_mod.clean_rel(a.marker) then paths[#paths + 1] = remote(a.marker) end
            for rel in pairs(type(a.sample) == "table" and a.sample or {}) do
                if manifest_mod.clean_rel(rel) then paths[#paths + 1] = remote(rel) end
            end
        end
        table.sort(paths)
        local got, err = device_digests(t, paths)
        if not got then return nil, err end
        for rel, e in pairs(prev.files) do
            if got[remote(rel)] ~= e.remote then prev.files[rel] = nil end
        end
        for key, a in pairs(prev.archives) do
            local ok = manifest_mod.clean_rel(a.marker) and got[remote(a.marker)] == a.remote
            for rel, hex in pairs(type(a.sample) == "table" and a.sample or {}) do
                if got[remote(rel)] ~= hex then ok = false end
            end
            if not ok then prev.archives[key] = nil end
        end
        report.verified = true
    end

    -- (2) Decide what to send.
    local new = { files = {}, archives = {} }
    local to_send, in_manifest = {}, {}
    for _, f in ipairs(man.files) do
        if not manifest_mod.clean_rel(f.rel) then return nil, "invalid staged path " .. tostring(f.rel) end
        in_manifest[f.rel] = true
        local old = prev.files[f.rel]
        local d = local_digest(f.abs, old)
        if not d then return nil, "cannot read " .. f.abs end
        if old and old.digest == d.digest and old.remote then
            new.files[f.rel] = { size = d.size, mtime = d.mtime, digest = d.digest, remote = old.remote }
            report.unchanged = report.unchanged + 1
        else
            to_send[#to_send + 1] = { f = f, d = d }
        end
    end

    -- Archive sets: member-list digest.
    local archive_plan = {}
    for i, a in ipairs(man.archives) do
        local rels = {}
        for _, m in ipairs(a.members) do
            if not manifest_mod.clean_rel(m.rel) then return nil, "invalid staged path " .. tostring(m.rel) end
            rels[#rels + 1] = m.rel
        end
        local host = host_sets[a.key] or {}
        local fp, _, bytes = stat_fingerprint(a.members)
        local set_digest
        if fp and host.stat == fp and type(host.digest) == "string" then
            -- Nothing changed on the host (path, size, mtime): reuse the digest.
            set_digest = host.digest
            report.archive_bytes = report.archive_bytes + bytes
        else
            -- The set digest covers every member's content, so a changed
            -- member re-sends the set. A legacy record's per-member digests
            -- are reused on size + mtime (once; the record is then compact).
            local parts = {}
            for _, m in ipairs(a.members) do
                local d = local_digest(m.abs, host.locals and host.locals[m.rel] or nil)
                if not d then return nil, "cannot read " .. m.abs end
                parts[#parts + 1] = m.rel .. "\0" .. d.size .. "\0" .. d.digest
                report.archive_bytes = report.archive_bytes + d.size
            end
            set_digest = vim.fn.sha256(table.concat(parts, "\n"))
        end
        local members = M.group_members(rels)
        local old = prev.archives[a.key]
        local stem = ".loomworks/archive-" .. vim.fn.sha256(a.key):sub(1, 12)
        if old and old.digest == set_digest and old.remote then
            new.archives[a.key] = { digest = set_digest, marker = old.marker, remote = old.remote,
                sample = old.sample, stat = fp, members = members }
            report.archives_unchanged = report.archives_unchanged + 1
        else
            archive_plan[#archive_plan + 1] = { idx = i, set = a, digest = set_digest,
                tar = stem .. ".tar", marker = stem .. ".ok", stat = fp, members = members, old = old }
        end
    end

    -- (3) Remove files that left the manifest (and archive members that left
    -- their set).
    local removals = {}
    for rel in pairs(prev.files) do
        if not in_manifest[rel] and manifest_mod.clean_rel(rel) then removals[#removals + 1] = remote(rel) end
    end
    local live_members = {}
    for _, a in ipairs(man.archives) do for _, m in ipairs(a.members) do live_members[m.rel] = true end end
    for key, a in pairs(prev.archives) do
        local still = new.archives[key] ~= nil
        for _, rel in ipairs(M.member_rels(a)) do
            if not live_members[rel] and not in_manifest[rel] and manifest_mod.clean_rel(rel) then
                removals[#removals + 1] = remote(rel)
            end
        end
        if not still and manifest_mod.clean_rel(a.marker) then
            local kept = false
            for _, pl in ipairs(archive_plan) do if pl.marker == a.marker then kept = true end end
            if not kept then removals[#removals + 1] = remote(a.marker) end
        end
    end
    for _, rel in ipairs(legacy_tars) do removals[#removals + 1] = remote(rel) end
    table.sort(removals)
    if #removals > 0 then
        local ok, err = device_remove(t, removals, o.ws_prefix, false)
        if not ok then return nil, err end
        report.removed = #removals
    end

    -- (4) Directories, transfers, executable bit.
    local dirs, seen = {}, {}
    local function need_dir(rel)
        local d = rel:match("^(.*)/[^/]+$")
        local p = d and remote(d) or root
        if not seen[p] then seen[p] = true; dirs[#dirs + 1] = p end
    end
    for _, s in ipairs(to_send) do need_dir(s.f.rel) end
    for _, pl in ipairs(archive_plan) do need_dir(pl.tar) end
    if #dirs > 0 then
        table.sort(dirs)
        local ok, err = device_mkdirs(t, dirs)
        if not ok then return nil, err end
    end
    local artifact_sent = false
    for _, s in ipairs(to_send) do
        if o.on_progress then o.on_progress("push " .. s.f.rel) end
        local ok, err = t:push(s.f.abs, remote(s.f.rel))
        if not ok then return nil, err end
        report.sent = report.sent + 1
        report.sent_bytes = report.sent_bytes + s.d.size
        new.files[s.f.rel] = { size = s.d.size, mtime = s.d.mtime, digest = s.d.digest, remote = s.d.digest }
        if s.f.kind == "artifact" then artifact_sent = true end
    end
    if artifact_sent or o.fresh then
        local status, lines = t:shell({ "chmod", "755", remote(man.artifact) })
        if status == nil then return nil, lines end
        if status ~= 0 then return nil, "marking the program executable failed: " .. table.concat(lines, " ") end
    end

    -- (5) Archive sets: one tar each, unpacked on the device, then deleted
    -- (keeping it doubled the space). A small completion marker holding the
    -- set's digest is written after a successful unpack; the marker plus a
    -- sample of the unpacked members is what later runs verify.
    for _, pl in ipairs(archive_plan) do
        local tmp = o.tmp_dir .. "/archive-" .. pl.idx .. ".tar"
        vim.fn.mkdir(o.tmp_dir, "p")
        local ok, err = require("loomworks.remote.tar").write(tmp, pl.set.members)
        if not ok then return nil, err end
        if o.on_progress then o.on_progress("push archive " .. pl.set.key) end
        local pushed, perr = t:push(tmp, remote(pl.tar))
        local st = uv().fs_stat(tmp)
        os.remove(tmp)
        if not pushed then return nil, perr end
        local status, lines = t:shell({ "tar", "-xf", remote(pl.tar), "-C", root })
        if status == nil then return nil, lines end
        if status ~= 0 then
            return nil, "unpacking archive set '" .. pl.set.key .. "' failed (status " .. status .. "): "
                .. table.concat(lines, " ")
        end
        local rok, rerr = device_remove(t, { remote(pl.tar) }, o.ws_prefix, false)
        if not rok then return nil, rerr end
        local mtmp = o.tmp_dir .. "/archive-" .. pl.idx .. ".ok"
        local mf = io.open(mtmp, "wb")
        if not mf then return nil, "cannot write " .. mtmp end
        mf:write(pl.digest)
        mf:close()
        local mpushed, merr = t:push(mtmp, remote(pl.marker))
        os.remove(mtmp)
        if not mpushed then return nil, merr end
        report.archives_sent = report.archives_sent + 1
        report.sent_bytes = report.sent_bytes + (st and st.size or 0)
        new.archives[pl.set.key] = { digest = pl.digest, marker = pl.marker, remote = pl.digest,
            sample = {}, stat = pl.stat, members = pl.members }
    end

    -- (6) Record the device-side digests of what was just sent.
    if t.runner.digest then
        local paths, map = {}, {}
        for _, s in ipairs(to_send) do
            local p = remote(s.f.rel); paths[#paths + 1] = p; map[p] = { kind = "file", rel = s.f.rel }
        end
        for _, pl in ipairs(archive_plan) do
            local p = remote(pl.marker); paths[#paths + 1] = p; map[p] = { kind = "marker", key = pl.set.key }
            for _, rel in ipairs(M.sample_members(pl.set.members)) do
                p = remote(rel); paths[#paths + 1] = p; map[p] = { kind = "sample", key = pl.set.key, rel = rel }
            end
        end
        if #paths > 0 then
            local got, err = device_digests(t, paths)
            if not got then return nil, err end
            for p, what in pairs(map) do
                local hex = got[p]
                if not hex then return nil, "staged file missing on the device after transfer: " .. p end
                if what.kind == "file" then new.files[what.rel].remote = hex
                elseif what.kind == "marker" then new.archives[what.key].remote = hex
                else new.archives[what.key].sample[what.rel] = hex end
            end
        end
    end
    return new, report
end

--- One-line staging summary (spec §16.34 example).
--- @param serial string
--- @param r loomworks.StageReport
--- @return string
function M.summary(serial, r)
    local parts = {}
    if r.sent > 0 then
        parts[#parts + 1] = string.format("%d changed file%s (%s)", r.sent, r.sent == 1 and "" or "s",
            fmt_bytes(r.sent_bytes))
    else
        parts[#parts + 1] = "no changed files"
    end
    if r.archives_sent + r.archives_unchanged > 0 then
        parts[#parts + 1] = string.format("%s archive %s", fmt_bytes(r.archive_bytes),
            r.archives_sent > 0 and "sent" or "unchanged")
    end
    if r.removed > 0 then parts[#parts + 1] = r.removed .. " removed" end
    return "staging on " .. serial .. ": " .. table.concat(parts, ", ")
end

--- Remove a workspace's whole staging tree from a device (`lw device clean`),
--- then — best-effort — the staging base itself when that left it empty.
--- The base is only ever removed with `rmdir` (which refuses a non-empty
--- directory), never recursively; a base that is not an absolute path of
--- plain segments is left alone.
--- @param transport table
--- @param ws_prefix string `<staging_base>/<workspace>`
--- @param staging_base string runner staging base
--- @return boolean|nil ok, string|nil err, boolean|nil base_removed
function M.clean(transport, ws_prefix, staging_base)
    local base = staging_base:gsub("/+$", "")
    -- The prefix must be exactly one segment below the staging base.
    if not manifest_mod.device_path_under(ws_prefix, base) or ws_prefix:gsub("/+$", "") == base then
        return nil, "refusing to remove " .. tostring(ws_prefix) .. ": not a workspace staging root under " .. base
    end
    local ok, err = device_remove(transport, { ws_prefix }, ws_prefix, true)
    if not ok then return nil, err end
    local removed = false
    -- device_path_under(base, base) checks: absolute, no "." / ".." segment,
    -- no control characters. "/" itself is never a candidate.
    if base ~= "" and base:match("^/[^/]") and manifest_mod.device_path_under(base, base) then
        local status = transport:shell({ "rmdir", base })
        removed = status == 0
    end
    return true, nil, removed
end

return M

--- loomworks/provision/bundle.lua — the managed lw's release bundle slot
--- (spec §19.16 "The managed bundle").
---
---     <stdpath("data")>/loomworks/bundle/<sha256>/lua-<version>/
---
--- `<sha256>` is the zip's SHA-256. A slot is written once, never modified:
--- the verified zip (loomworks.provision.unzip) is written into a staging
--- directory `.stage-<sha256>.<pid>.<n>/lua-<version>/` created by an
--- exclusive mkdir, which is then renamed to `<sha256>`. A slot is present
--- only when `<sha256>` and `lua-<version>` are real directories (lstat) and
--- `lua-<version>/loomworks/cli.lua` is a regular file; any other state is
--- never used, repaired or removed.
---
--- Deletion safety (CLAUDE.md "Deletion Safety"): the only removal here is
--- of this process's own staging directory of a failed attempt — that exact
--- path, a real directory whose realpath is a direct child of the realpath of
--- `loomworks/bundle` (itself a real directory), its contents removed without
--- following a link (a link or junction inside is unlinked). Never a slot,
--- never anything another process left (pruning is paused,
--- samienne/loomworks#101).

local uv = vim.uv or vim.loop

local M = {}

local function is_win() return package.config:sub(1, 1) == "\\" end

local function lstat_type(p)
    local st = uv.fs_lstat(p)
    return st and st.type or nil
end

--- The rename of a staging directory onto its slot is retried on Windows
--- while it is held (an antivirus scanning new files): attempts, delay (ms).
M.RENAME_ATTEMPTS = 6
M.RENAME_DELAY_MS = 100

--- Staging directories of this process so far (their names are unique).
M._seq = 0

--- The state of the bundle slot of `sha256` for release `version`:
--- "present", "absent" (nothing at the slot's path) or "other" (+ why);
--- with the slot's path.
--- @param sha256 string
--- @param version string
--- @param opts? { data?: string }
--- @return "present"|"absent"|"other" state, string|nil slot, string|nil why
function M.state(sha256, version, opts)
    opts = opts or {}
    local managed = require("loomworks.provision.managed")
    local slot = managed.bundle_slot(sha256, opts)
    if not slot then return "other", nil, "invalid bundle hash " .. tostring(sha256) end
    if not require("loomworks.provision.fetch").valid_version(version) then
        return "other", slot, "invalid release version " .. tostring(version)
    end
    local bdir = managed.bundle_dir(opts.data)
    local bt = lstat_type(bdir)
    if bt == nil then return "absent", slot end
    if bt ~= "directory" then return "other", slot, bdir .. " is not a real directory" end
    local st = lstat_type(slot)
    if st == nil then return "absent", slot end
    if st ~= "directory" then return "other", slot, "it is not a real directory" end
    local lua = slot .. "/lua-" .. version
    if lstat_type(lua) ~= "directory" then return "other", slot, "lua-" .. version .. " is not a real directory in it" end
    if lstat_type(lua .. "/loomworks/cli.lua") ~= "file" then
        return "other", slot, "lua-" .. version .. "/loomworks/cli.lua is not a regular file in it"
    end
    return "present", slot
end

local function canon(p)
    p = tostring(p):gsub("\\", "/"):gsub("/+$", "")
    if is_win() then p = p:lower() end
    return p
end

--- Remove this process's own staging directory `stage` (deletion safety:
--- see the header). `bdir` is `loomworks/bundle`. Does nothing to any other
--- path; a link or junction inside is unlinked, never followed.
--- @param stage string
--- @param bdir string
--- @return boolean ok, string|nil why
function M.remove_stage(stage, bdir)
    if type(stage) ~= "string" or type(bdir) ~= "string" then return false, "no staging directory" end
    local name = stage:sub(#bdir + 2)
    if stage:sub(1, #bdir + 1) ~= bdir .. "/" or not name:match("^%.stage%-%x+%.%d+%.%d+$")
        or #name:match("^%.stage%-(%x+)") ~= 64 then
        return false, stage .. " is not a staging directory of " .. bdir
    end
    local t = lstat_type(stage)
    if t == nil then return true end
    if t ~= "directory" then return false, stage .. " is not a real directory: left as it is" end
    if lstat_type(bdir) ~= "directory" then return false, bdir .. " is not a real directory" end
    local rb, rs = uv.fs_realpath(bdir), uv.fs_realpath(stage)
    if not rb or not rs or canon(rs) ~= canon(rb) .. "/" .. canon(name) then
        return false, stage .. " does not resolve to a direct child of " .. bdir
    end
    local function rm_tree(dir)
        local h = uv.fs_scandir(dir)
        if h then
            while true do
                local n = uv.fs_scandir_next(h)
                if not n then break end
                local p = dir .. "/" .. n
                if lstat_type(p) == "directory" then
                    rm_tree(p)
                else
                    -- A file, or a link / junction: unlinked, never followed.
                    pcall(uv.fs_unlink, p)
                    -- (A directory junction libuv could not unlink: rmdir
                    -- removes the junction itself, never its target.)
                    if lstat_type(p) == "link" then pcall(uv.fs_rmdir, p) end
                end
            end
        end
        pcall(uv.fs_rmdir, dir)
    end
    rm_tree(stage)
    if lstat_type(stage) then return false, "cannot remove " .. stage end
    return true
end

--- Create directory `p` (0755) that must not exist yet (an exclusive mkdir).
local function mkdir_new(p)
    local ok, err = uv.fs_mkdir(p, 493)
    if not ok then return false, "cannot create " .. p .. ": " .. tostring(err) end
    return true
end

--- Write `content` into a newly created regular file `p` (O_EXCL: never
--- through an existing file or link); every byte, or a failure.
local function write_new(p, content)
    local fd, err = uv.fs_open(p, "wx", 420)
    if not fd then return false, "cannot create " .. p .. ": " .. tostring(err) end
    local n, werr = uv.fs_write(fd, content, 0)
    uv.fs_close(fd)
    if type(n) ~= "number" then return false, "cannot write " .. p .. ": " .. tostring(werr) end
    if n ~= #content then
        return false, string.format("cannot write %s: short write (%d of %d bytes)", p, n, #content)
    end
    return true
end

--- Install the bundle zip at `zip_path` into the slot of `w.bundle_sha256`
--- for release `w.version`. The file is read once: the SHA-256 of that very
--- buffer must be `w.bundle_sha256`, and that buffer is what is unzipped.
--- Every entry is checked and
--- inflated (loomworks.provision.unzip) before anything is written; the
--- staging directory is renamed onto the slot, never replacing a non-empty
--- directory: a slot another editor installed meanwhile is used. On a
--- failure this process's staging directory is removed and nothing is
--- installed. `cb(slot)` or `cb(nil, err)`.
--- opts: data, win, rename (fun(from, to) → ok, err, code; tests),
--- read (fun(path) → data|nil, err; tests), source (the zip's name in a
--- hash mismatch; default the asset name)
--- @param zip_path string
--- @param w loomworks.provision.Wanted
--- @param opts? table
--- @param cb fun(slot: string|nil, err: string|nil)
function M.install(zip_path, w, opts, cb)
    opts = opts or {}
    local managed = require("loomworks.provision.managed")
    local win = opts.win
    if win == nil then win = is_win() end
    local sha = w.bundle_sha256
    local bdir = managed.bundle_dir(opts.data)
    local slot = managed.bundle_slot(sha, opts)
    local data, rerr
    if opts.read then data, rerr = opts.read(zip_path)
    else
        local f = io.open(zip_path, "rb")
        if f then data = f:read("*a"); f:close() else rerr = "cannot read " .. zip_path end
    end
    if not data then return cb(nil, rerr) end
    local got = require("loomworks.provision.sha256").hex(data)
    if got:lower() ~= sha then
        return cb(nil, string.format("%s has SHA-256 %s, expected %s (not installed)",
            opts.source or managed.bundle_asset(w.version), got, sha))
    end
    local unzip = require("loomworks.provision.unzip")
    local entries, uerr = unzip.read(data)
    data = nil
    if not entries then return cb(nil, "the bundle " .. managed.bundle_asset(w.version) .. " is refused: " .. tostring(uerr)) end
    local has_cli = false
    for _, e in ipairs(entries) do
        if e.type == "file" and e.name == "loomworks/cli.lua" then has_cli = true end
    end
    if not has_cli then
        return cb(nil, "the bundle " .. managed.bundle_asset(w.version) .. " is refused: it has no loomworks/cli.lua")
    end
    M._seq = M._seq + 1
    local stage = bdir .. "/.stage-" .. sha .. "." .. tostring(uv.os_getpid()) .. "." .. tostring(M._seq)
    local function fail(err)
        M.remove_stage(stage, bdir)
        cb(nil, err)
    end
    local ok, err = mkdir_new(stage)
    if not ok then return cb(nil, err) end -- not ours: never removed
    local lua = stage .. "/lua-" .. w.version
    ok, err = mkdir_new(lua)
    if not ok then return fail(err) end
    -- Directories first (entries and the parents files imply), then files.
    local made = {}
    local function ensure_dir(rel)
        if made[rel] then return true end
        local parent = rel:match("^(.*)/[^/]+$")
        if parent then
            local okp, perr = ensure_dir(parent)
            if not okp then return false, perr end
        end
        local okd, derr = mkdir_new(lua .. "/" .. rel)
        if not okd then return false, derr end
        made[rel] = true
        return true
    end
    for _, e in ipairs(entries) do
        if e.type == "directory" then
            ok, err = ensure_dir(e.name)
            if not ok then return fail(err) end
        end
    end
    for _, e in ipairs(entries) do
        if e.type == "file" then
            local parent = e.name:match("^(.*)/[^/]+$")
            ok, err = ensure_dir(parent)
            if not ok then return fail(err) end
            ok, err = write_new(lua .. "/" .. e.name, e.content)
            if not ok then return fail(err) end
        end
    end
    entries = nil
    local rename = opts.rename or uv.fs_rename
    local attempt = 0
    local function try()
        attempt = attempt + 1
        if M.state(sha, w.version, opts) == "present" then
            -- Another editor installed it meanwhile: use it.
            M.remove_stage(stage, bdir)
            return cb(slot)
        end
        local rok, rename_err, code = rename(stage, slot)
        if rok then
            local s, _, why = M.state(sha, w.version, opts)
            if s ~= "present" then return cb(nil, "the bundle slot " .. slot .. " is not usable after the install: " .. tostring(why)) end
            return cb(slot)
        end
        if win and attempt < M.RENAME_ATTEMPTS and (code == "EACCES" or code == "EPERM" or code == "EBUSY") then
            return vim.defer_fn(try, M.RENAME_DELAY_MS * attempt)
        end
        if M.state(sha, w.version, opts) == "present" then
            M.remove_stage(stage, bdir)
            return cb(slot)
        end
        fail("cannot install " .. slot .. ": " .. tostring(rename_err))
    end
    try()
end

return M

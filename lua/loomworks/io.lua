local M = {}

local uv = vim.uv or vim.loop

--- Read a file synchronously.
--- @param path string
--- @return string|nil content, string|nil err
function M.read_file(path)
    -- Inside a transaction (loomworks.txn, spec §19.4) a staged workspace file
    -- reads as its staged bytes.
    if M._txn_hook then
        local hit, data = M._txn_hook.read(path)
        if hit then return data, nil end
    end
    local fd, err = uv.fs_open(path, "r", 438) -- 0666
    if not fd then return nil, err end
    local stat, stat_err = uv.fs_fstat(fd)
    if not stat then
        uv.fs_close(fd)
        return nil, stat_err
    end
    local data, read_err = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    if not data then return nil, read_err end
    return data, nil
end

--- Create `path` EXCLUSIVELY (O_CREAT|O_EXCL: never through an existing file,
--- a hard link to another file, or a symbolic link — whose target is never
--- opened) and write `data` to it, flushed. Returns true, or false + error +
--- the error code ("EEXIST" when something already has that name).
--- @param path string
--- @param data string
--- @param mode? integer
--- @return boolean ok, string|nil err, string|nil code
function M.write_exclusive(path, data, mode)
    local fd, err, code = uv.fs_open(path, "wx", mode or 438)
    if not fd then return false, err, code end
    local _, werr = uv.fs_write(fd, data, 0)
    pcall(uv.fs_fsync, fd)
    uv.fs_close(fd)
    if werr then
        pcall(uv.fs_unlink, path)
        return false, werr
    end
    return true
end

--- Write a temporary file at a FIXED name (`<target>.tmp`, the name crash
--- recovery and stray-file cleanup know): whatever sits at that name first
--- is removed — a leftover of a crashed write, or a link someone planted in a
--- shared `.nvim/` (unlinking a link removes only the link, never its
--- target) — then the file is created exclusively. A directory there is left
--- alone (the create then fails).
--- @param tmp string
--- @param data string
--- @param mode? integer
--- @return boolean ok, string|nil err
function M.write_fresh(tmp, data, mode)
    local st = uv.fs_lstat(tmp)
    if st and st.type ~= "directory" then pcall(uv.fs_unlink, tmp) end
    local ok, err = M.write_exclusive(tmp, data, mode)
    return ok, err
end

--- Write data to path atomically:
---   1. Write to path..".tmp" (created exclusively, M.write_fresh)
---   2. fsync the fd
---   3. If path exists, rename path -> path..".bak" (unless `opts.backup` is
---      false: an export written for the user leaves no `.bak` beside it)
---   4. Rename tmp -> path (with retry on Windows)
--- @param path string
--- @param data string
--- @param opts? { backup: boolean|nil }
--- @return boolean ok, string|nil err
function M.write_file_atomic(path, data, opts)
    -- Inside a transaction (loomworks.txn, spec §19.4) a workspace file is
    -- staged to `<path>.txn-<id>`; the commit replaces the target.
    if M._txn_hook then
        local handled, ok, err = M._txn_hook.write(path, data, opts)
        if handled then return ok, err end
    end
    local tmp = path .. ".tmp"

    local okw, werr = M.write_fresh(tmp, data, 438)
    if not okw then return false, "write tmp: " .. tostring(werr or "unknown") end

    if uv.fs_stat(path) and not (opts and opts.backup == false) then
        uv.fs_rename(path, path .. ".bak")
    end

    -- Rename tmp -> target, with retry for Windows lock contention
    local max_retries = 5
    local retry_delay_ms = 50
    for i = 1, max_retries do
        local ok, rename_err, code = uv.fs_rename(tmp, path)
        if ok then return true, nil end
        if code ~= "EACCES" and code ~= "EPERM" then
            return false, "rename: " .. (rename_err or "unknown")
        end
        if i < max_retries then
            uv.sleep(retry_delay_ms)
        end
    end
    return false, "rename failed after retries (file locked?)"
end

--- Read JSON from path. Falls back to path..".bak" on failure.
--- @param path string
--- @return table|nil data, string|nil err
function M.read_json(path)
    local content, read_err = M.read_file(path)
    if content then
        local ok, decoded = pcall(vim.json.decode, content)
        if ok and type(decoded) == "table" then
            return decoded, nil
        end
    end

    local bak = path .. ".bak"
    local bak_content, bak_err = M.read_file(bak)
    if not bak_content then
        return nil, read_err or bak_err or "file not found"
    end

    local ok, decoded = pcall(vim.json.decode, bak_content)
    if ok and type(decoded) == "table" then
        vim.notify("loomworks: loaded from backup: " .. bak, vim.log.levels.WARN)
        return decoded, nil
    end

    return nil, "failed to decode JSON from both " .. path .. " and " .. bak
end

--- Naively pretty-print a compact JSON string with 2-space indentation.
--- @param json string compact JSON
--- @return string pretty JSON
function M._pretty_json(json)
    local indent = 0
    local buf = {}
    local in_string = false
    local i = 1
    local len = #json

    while i <= len do
        local c = json:sub(i, i)

        if in_string then
            buf[#buf + 1] = c
            if c == "\\" then
                i = i + 1
                buf[#buf + 1] = json:sub(i, i)
            elseif c == '"' then
                in_string = false
            end
        elseif c == '"' then
            in_string = true
            buf[#buf + 1] = c
        elseif c == "{" or c == "[" then
            indent = indent + 1
            buf[#buf + 1] = c
            buf[#buf + 1] = "\n"
            buf[#buf + 1] = string.rep("  ", indent)
        elseif c == "}" or c == "]" then
            indent = indent - 1
            buf[#buf + 1] = "\n"
            buf[#buf + 1] = string.rep("  ", indent)
            buf[#buf + 1] = c
        elseif c == "," then
            buf[#buf + 1] = ","
            buf[#buf + 1] = "\n"
            buf[#buf + 1] = string.rep("  ", indent)
        elseif c == ":" then
            buf[#buf + 1] = ": "
        elseif c ~= " " and c ~= "\n" and c ~= "\r" and c ~= "\t" then
            buf[#buf + 1] = c
        end

        i = i + 1
    end

    return table.concat(buf) .. "\n"
end

--- Encode `v` as compact JSON with object keys in SORTED order at every depth,
--- so rewriting unchanged data yields byte-identical output (user.json and
--- loomworks.json are rewritten on every mutation; hash-order keys made each
--- rewrite a noisy diff). Scalars, empty tables (whose `{}` vs `[]` shape the
--- host encoder decides via `vim.empty_dict()`), `vim.NIL`, and any table that
--- is neither a contiguous list nor a key/value object are delegated to
--- `vim.json.encode`, so shapes and escaping stay exactly the host's.
--- @param v any
--- @return string
function M.encode_sorted(v)
    if type(v) ~= "table" or next(v) == nil then
        return vim.json.encode(v)
    end
    local n, all_int = 0, true
    for k in pairs(v) do
        n = n + 1
        if type(k) ~= "number" then all_int = false end
    end
    if all_int then
        for i = 1, n do
            if v[i] == nil then return vim.json.encode(v) end -- sparse: host rules
        end
        local parts = {}
        for i = 1, n do parts[i] = M.encode_sorted(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local by_str = {}
    for k, val in pairs(v) do by_str[tostring(k)] = val end
    local parts = {}
    for i, k in ipairs(keys) do
        parts[i] = vim.json.encode(k) .. ":" .. M.encode_sorted(by_str[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

--- Write table as JSON atomically — pretty-printed, keys sorted
--- (`encode_sorted`) for stable diffs.
--- @param path string
--- @param tbl table
--- @return boolean ok, string|nil err
function M.write_json(path, tbl)
    local pretty, err = M.encode_json(tbl)
    if not pretty then return false, err end
    return M.write_file_atomic(path, pretty)
end

--- The exact text `write_json` writes for `tbl`: sorted keys at every depth,
--- two-space indentation, trailing line feed (spec §2). One encoder for every
--- workspace file and for `lw export` (§16.39), so an export is byte-compatible
--- with the file a publish writes.
--- @param tbl table
--- @return string|nil text, string|nil err
function M.encode_json(tbl)
    local ok, encoded = pcall(M.encode_sorted, tbl)
    if not ok then return nil, "json encode: " .. tostring(encoded) end
    return M._pretty_json(encoded)
end

--- Write a loomworks state file under `.nvim/` (working copy, build cache,
--- health cache) as JSON signed with the machine key (spec §17.3): the same
--- sorted, pretty encoding as `write_json`, with the signature member first.
--- When the key is unavailable the file is still written, unsigned (it will be
--- refused or discarded on the next read — never trusted) and the error is
--- returned as a third value so callers can report it.
--- @param path string
--- @param kind "user"|"cache"|"health"
--- @param tbl table
--- The fourth return value is the exact bytes written (on success), so a
--- caller can record its disk baseline without re-reading the file (a re-read
--- could pick up another process's write — spec §2.7).
--- @return boolean ok, string|nil err, string|nil sign_err, string|nil written
function M.write_json_signed(path, kind, tbl)
    local pretty, err = M.encode_json(tbl)
    if not pretty then return false, err end
    local signed, sign_err = require("loomworks.trust").sign(kind, pretty)
    local bytes = signed or pretty
    local wok, werr = M.write_file_atomic(path, bytes)
    return wok, werr, sign_err, wok and bytes or nil
end

--- The deepest existing directory on `path` (itself or an ancestor), or nil.
local function deepest_existing_dir(path)
    local p = path
    while p and p ~= "" do
        if vim.fn.isdirectory(p) == 1 then return p end
        p = p:match("^(.*)[/\\][^/\\]*$")
    end
    return nil
end

--- mkdir -p that tolerates the concurrent-create race. `vim.fn.mkdir(p, "p")`
--- checks, then creates, one component at a time: when another process (the
--- CLI and the editor configuring two profiles that share a brand-new parent)
--- creates a component in between, it throws E739 "file already exists" and
--- stops there. A lost race is not a failure: if the directory now exists that
--- is success, and if only an ancestor appeared (progress was made) the create
--- is retried from there. A failure that makes no progress (a file in the way,
--- no permission) is still reported.
--- @param path string
--- @return true|nil ok, string|nil err
function M.mkdir_p(path)
    local reached = deepest_existing_dir(path)
    while true do
        local ok, res = pcall(vim.fn.mkdir, path, "p")
        if (ok and res ~= 0) or vim.fn.isdirectory(path) == 1 then return true end
        if ok then return nil, "cannot create directory " .. path end
        local now = deepest_existing_dir(path)
        -- Terminates: each retry needs a strictly deeper existing ancestor.
        if now == nil or (reached and #now <= #reached) then return nil, tostring(res) end
        reached = now
    end
end

--- Ensure a directory exists (mkdir -p equivalent; race-tolerant, see mkdir_p).
--- @param path string
--- @return boolean ok, string|nil err
function M.ensure_dir(path)
    local stat = uv.fs_stat(path)
    if stat and stat.type == "directory" then return true, nil end
    local ok, err = M.mkdir_p(path)
    if not ok then return false, err end
    return true, nil
end

--- Deletion never follows links and never goes through a shell: every entry
--- is examined with `lstat`, a symlink / junction is removed as a link (its
--- target is left alone), and a read-only file (e.g. git objects in a fetched
--- dependency) is made writable and retried. Removing by path through
--- `cmd /c rd` or `rm -rf` would hand the path to a command interpreter (on
--- Windows `&`, `^`, `%` in a directory name change the command) and `rd`
--- cannot delete read-only files.

--- Remove a non-directory entry (file or link). Returns ok, err.
local function unlink_entry(path, st)
    local ok, err = uv.fs_unlink(path)
    if ok then return true end
    if st and st.type == "link" then
        -- A directory symlink / junction on Windows may need rmdir.
        local ok2 = uv.fs_rmdir(path)
        if ok2 then return true end
    elseif tostring(err):match("^EPERM") or tostring(err):match("^EACCES") then
        pcall(uv.fs_chmod, path, 438) -- 0666: clear read-only
        local ok3, err3 = uv.fs_unlink(path)
        if ok3 then return true end
        err = err3
    end
    return false, "unlink " .. path .. ": " .. tostring(err or "unknown")
end

--- Recursively remove a directory tree (synchronously). Links are removed,
--- never followed; a missing path is success.
--- @param dir string
--- @return boolean ok, string|nil err
function M.rm_rf(dir)
    local stat = uv.fs_lstat(dir)
    if not stat then return true, nil end
    if stat.type ~= "directory" then
        local ok, err = unlink_entry(dir, stat)
        if not ok then return false, err end
        return true, nil
    end

    local errors = {}
    local handle = uv.fs_scandir(dir)
    while handle do
        local name = uv.fs_scandir_next(handle)
        if not name then break end
        local ok, err = M.rm_rf(dir .. "/" .. name)
        if not ok then errors[#errors + 1] = err end
    end

    local ok, err = uv.fs_rmdir(dir)
    if not ok then errors[#errors + 1] = "rmdir " .. dir .. ": " .. (err or "unknown") end

    if #errors > 0 then
        return false, table.concat(errors, "; ")
    end
    return true, nil
end

--- Asynchronous tree removal over libuv's threadpool (no subprocess, no
--- shell). `done(err|nil)`; a missing path is success.
--- @param path string
--- @param done fun(err: string|nil)
local function rm_tree_async(path, done)
    uv.fs_lstat(path, function(lerr, st)
        if not st then
            if lerr and not tostring(lerr):match("^ENOENT") then
                return done("lstat " .. path .. ": " .. tostring(lerr))
            end
            return done(nil)
        end
        if st.type ~= "directory" then
            -- Unlink is quick; keep the retry logic in one (sync) place.
            local ok, err = unlink_entry(path, st)
            return done(ok and nil or err)
        end
        uv.fs_scandir(path, function(serr, req)
            if serr or not req then
                return done("scandir " .. path .. ": " .. tostring(serr))
            end
            local names = {}
            while true do
                local name = uv.fs_scandir_next(req)
                if not name then break end
                names[#names + 1] = name
            end
            local errors, pending = {}, #names
            local function finish()
                uv.fs_rmdir(path, function(rerr)
                    if rerr then errors[#errors + 1] = "rmdir " .. path .. ": " .. tostring(rerr) end
                    done(#errors > 0 and table.concat(errors, "; ") or nil)
                end)
            end
            if pending == 0 then return finish() end
            for _, name in ipairs(names) do
                rm_tree_async(path .. "/" .. name, function(e)
                    if e then errors[#errors + 1] = e end
                    pending = pending - 1
                    if pending == 0 then finish() end
                end)
            end
        end)
    end)
end

--- Recursively remove a directory/file asynchronously (libuv filesystem
--- calls — never a shell command built from the path). Links are removed,
--- not followed. Returns a Future.
--- @param dir string
--- @param callback? fun(ok: boolean, err: string|nil) legacy callback (deprecated)
--- @return loomworks.Future
function M.rm_rf_async(dir, callback)
    local future_mod = require("loomworks.future")
    if not uv.fs_lstat(dir) then
        if callback then callback(true, nil) end
        return future_mod.resolved(true)
    end

    local f = future_mod.create(function(resolve, reject)
        rm_tree_async(dir, function(err)
            vim.schedule(function()
                if err then reject(err) else resolve(true) end
            end)
        end)
    end)

    if callback then
        f:next(function() callback(true, nil) end)
         :catch(function(err) callback(false, err) end)
    end
    return f
end

--- Read a file asynchronously. Returns a Future.
--- @param path string
--- @param callback? fun(content: string|nil, err: string|nil) legacy callback (deprecated)
--- @return loomworks.Future
function M.read_file_async(path, callback)
    local future_mod = require("loomworks.future")
    local f = future_mod.create(function(resolve, reject)
        uv.fs_open(path, "r", 438, function(err, fd)
            if not fd then reject(err or "open failed"); return end
            uv.fs_fstat(fd, function(stat_err, file_stat)
                if not file_stat then
                    uv.fs_close(fd)
                    reject(stat_err or "stat failed")
                    return
                end
                uv.fs_read(fd, file_stat.size, 0, function(read_err, data)
                    uv.fs_close(fd)
                    if not data then reject(read_err or "read failed")
                    else resolve(data) end
                end)
            end)
        end)
    end)

    if callback then
        f:next(function(content) callback(content, nil) end)
         :catch(function(err) callback(nil, err) end)
    end
    return f
end

--- Read multiple files in parallel. Returns a Future.
--- @param paths string[]
--- @param callback? fun(results: table<string, string|nil>) legacy callback (deprecated)
--- @return loomworks.Future
function M.read_files_async(paths, callback)
    local future_mod = require("loomworks.future")
    if #paths == 0 then
        if callback then callback({}) end
        return future_mod.resolved({})
    end

    local file_futures = {}
    for _, path in ipairs(paths) do
        local captured_path = path
        file_futures[#file_futures + 1] = M.read_file_async(captured_path)
            :next(function(content) return { path = captured_path, content = content } end)
            :catch(function() return { path = captured_path, content = nil } end)
    end

    local f = future_mod.when_all(file_futures):next(function(wrapped)
        local results = {}
        for _, r in ipairs(wrapped) do
            local entry = r[1]
            results[entry.path] = entry.content
        end
        return results
    end)

    if callback then
        f:next(function(results) callback(results) end)
    end
    return f
end

return M

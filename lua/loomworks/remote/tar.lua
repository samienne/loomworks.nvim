--- loomworks/remote/tar.lua — write an uncompressed archive in the portable
--- tape-archive format (POSIX ustar, with a pax `path` record for names that
--- do not fit), for staging an archive set as ONE transfer (spec §18.4).
---
--- Entries: a directory entry for every parent directory (so extractors that
--- do not create leading directories still work), then each regular file
--- (mode 0644, streamed in chunks — never read whole into memory).

local M = {}

local BLOCK = 512

local function octal(n, width)
    -- width includes the trailing NUL
    return string.format("%0" .. (width - 1) .. "o", n) .. "\0"
end

local function field(s, width)
    s = s or ""
    if #s > width then s = s:sub(1, width) end
    return s .. string.rep("\0", width - #s)
end

--- Split a path into (prefix, name) that fit ustar's 155/100 fields, or nil.
local function split_ustar(path)
    if #path <= 100 then return "", path end
    for i = #path, 1, -1 do
        if path:sub(i, i) == "/" then
            local prefix, name = path:sub(1, i - 1), path:sub(i + 1)
            if #prefix <= 155 and #name <= 100 and #name > 0 then return prefix, name end
        end
    end
    return nil
end

local function header(name, prefix, size, typeflag, mode, mtime)
    local h = field(name, 100)
        .. octal(mode, 8) .. octal(0, 8) .. octal(0, 8)
        .. octal(size, 12) .. octal(mtime or 0, 12)
        .. "        " -- checksum placeholder (8 spaces)
        .. typeflag
        .. field("", 100)
        .. "ustar\0" .. "00"
        .. field("", 32) .. field("", 32)
        .. octal(0, 8) .. octal(0, 8)
        .. field(prefix, 155)
        .. field("", 12)
    local sum = 0
    for i = 1, #h do sum = sum + h:byte(i) end
    local chk = string.format("%06o", sum) .. "\0 "
    return h:sub(1, 148) .. chk .. h:sub(157)
end

--- A pax extended header carrying `path`.
local function pax_record(path)
    local body = " path=" .. path .. "\n"
    local len = #body + 1
    while #tostring(len) + #body ~= len do len = #tostring(len) + #body end
    return tostring(len) .. body
end

local function pad(n)
    local r = n % BLOCK
    return r == 0 and "" or string.rep("\0", BLOCK - r)
end

--- Write an archive.
--- @param out_path string host path of the archive to create
--- @param entries { rel: string, abs: string }[] regular files; `rel` uses "/"
--- @return boolean|nil ok, string|nil err
function M.write(out_path, entries)
    local f, oerr = io.open(out_path, "wb")
    if not f then return nil, "cannot create archive " .. out_path .. ": " .. tostring(oerr) end
    local mtime = os.time()
    local function put_header(path, size, typeflag, mode)
        local prefix, name = split_ustar(path)
        if not prefix then
            local rec = pax_record(path)
            f:write(header("PaxHeader", "", #rec, "x", 420, mtime))
            f:write(rec)
            f:write(pad(#rec))
            prefix, name = "", path:sub(-100)
        end
        f:write(header(name, prefix, size, typeflag, mode, mtime))
    end
    local dirs, seen = {}, {}
    for _, e in ipairs(entries) do
        local acc = ""
        for seg in e.rel:gmatch("([^/]+)/") do
            acc = acc .. seg .. "/"
            if not seen[acc] then seen[acc] = true; dirs[#dirs + 1] = acc end
        end
    end
    table.sort(dirs)
    for _, d in ipairs(dirs) do put_header(d, 0, "5", 493) end
    for _, e in ipairs(entries) do
        local src, serr = io.open(e.abs, "rb")
        if not src then
            f:close()
            os.remove(out_path)
            return nil, "cannot read " .. e.abs .. ": " .. tostring(serr)
        end
        local size = src:seek("end")
        src:seek("set", 0)
        put_header(e.rel, size, "0", 420)
        while true do
            local chunk = src:read(1024 * 1024)
            if not chunk then break end
            f:write(chunk)
        end
        src:close()
        f:write(pad(size))
    end
    f:write(string.rep("\0", BLOCK * 2))
    f:close()
    return true
end

return M

--- loomworks/provision/unzip.lua — read the release bundle zip
--- (`loomworks-lua-<version>.zip`) without an external tool (spec §19.16
--- "The managed bundle").
---
--- A small reader over the zip's central directory: every entry is listed
--- and checked (`M.list`) before anything is inflated, and inflated and
--- CRC-checked (`M.extract`) before anything is written — the caller
--- (loomworks.provision.bundle) writes only once every entry passed. Stored
--- (0) and deflate (8) entries only; the inflate is the vendored pure-Lua
--- LibDeflate (loomworks.provision.libdeflate). No zip64, no encryption, no
--- multi-disk archives: none is a release bundle.
---
--- An entry passes only when it
---   * is a regular file or a directory (no link, no other type: Unix mode
---     bits, or the DOS/NTFS attributes' reparse-point bit);
---   * has a name of `/`-separated segments, none empty, `.` or `..`, with no
---     leading `/`, no `\`, `:` or NUL, its first segment `loomworks`;
---   * has a name no other entry repeats case-insensitively;
---   * lies wholly inside the archive, its local header naming it as the
---     central directory does;
---   * inflates to its recorded size and matches its CRC-32;
--- and the entries' recorded (uncompressed) sizes total at most `MAX_TOTAL`,
--- checked before anything is inflated.

local bit = require("bit")

local M = {}

--- The one top-level directory a bundle's entries live under.
M.TOP = "loomworks"

--- The most the entries of one bundle may total uncompressed (bytes). The
--- release bundle is about 1.3 MB zipped; an archive past this is refused
--- before anything is inflated.
M.MAX_TOTAL = 64 * 1024 * 1024

local function u16(s, i)
    local a, b = s:byte(i, i + 1)
    if not b then return nil end
    return a + b * 256
end

local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local crc_table
--- CRC-32 (IEEE 802.3, as zip uses) of `s`, as a non-negative integer.
--- @param s string
--- @return integer
function M.crc32(s)
    if not crc_table then
        crc_table = {}
        for i = 0, 255 do
            local r = i
            for _ = 1, 8 do
                if bit.band(r, 1) == 1 then r = bit.bxor(bit.rshift(r, 1), 0xEDB88320)
                else r = bit.rshift(r, 1) end
            end
            crc_table[i] = r
        end
    end
    local crc = 0xFFFFFFFF
    for i = 1, #s do
        crc = bit.bxor(crc_table[bit.band(bit.bxor(crc, s:byte(i)), 0xFF)], bit.rshift(crc, 8))
    end
    return bit.bxor(crc, 0xFFFFFFFF) % 4294967296
end

--- Whether `name` (an entry's name, a directory's without its trailing `/`)
--- is acceptable; nil + why otherwise.
--- @param name string
--- @return boolean|nil ok, string|nil why
function M.check_name(name)
    if name == "" then return nil, "an entry has an empty name" end
    if name:find("%z") then return nil, "entry name contains NUL" end
    if name:find("\\", 1, true) then return nil, "entry " .. name .. " contains a backslash" end
    if name:find(":", 1, true) then return nil, "entry " .. name .. " contains ':'" end
    if name:sub(1, 1) == "/" then return nil, "entry " .. name .. " is absolute" end
    local segs = vim.split(name, "/", { plain = true })
    for _, s in ipairs(segs) do
        if s == "" or s == "." or s == ".." then
            return nil, "entry " .. name .. " has an empty, '.' or '..' segment"
        end
    end
    if segs[1] ~= M.TOP then return nil, "entry " .. name .. " is not under " .. M.TOP .. "/" end
    return true
end

--- The entry's type from its attributes: "file", "directory" or nil + why.
local function entry_type(made_by, ext, name)
    local host = math.floor(made_by / 256)
    local is_dir_name = name:sub(-1) == "/"
    if host == 3 or host == 19 then -- Unix, OS X: st_mode in the high 16 bits
        local fmt = bit.band(math.floor(ext / 65536), 0xF000)
        if fmt == 0x8000 then
            if is_dir_name then return nil, "entry " .. name .. " is a file named like a directory" end
            return "file"
        elseif fmt == 0x4000 then
            if not is_dir_name then return nil, "entry " .. name .. " is a directory not named like one" end
            return "directory"
        elseif fmt == 0xA000 then
            return nil, "entry " .. name .. " is a symbolic link"
        elseif fmt ~= 0 then
            return nil, "entry " .. name .. " is not a regular file or directory"
        end
    else
        -- DOS / NTFS attributes in the low byte(s): a reparse point (0x400)
        -- is a link or junction.
        if bit.band(ext, 0x400) ~= 0 then return nil, "entry " .. name .. " is a link (reparse point)" end
        if bit.band(ext, 0x10) ~= 0 and not is_dir_name then
            return nil, "entry " .. name .. " is a directory not named like one"
        end
    end
    return is_dir_name and "directory" or "file"
end

--- @class loomworks.provision.ZipEntry
--- @field name string the entry's path, without a directory's trailing `/`
--- @field type "file"|"directory"
--- @field method integer 0 stored, 8 deflate
--- @field crc integer
--- @field csize integer
--- @field usize integer
--- @field offset integer 1-based offset of its data in the archive

--- List and check every entry of the zip `data` (nothing is inflated): the
--- entries in central-directory order, or nil + why.
--- @param data string the whole archive
--- @return loomworks.provision.ZipEntry[]|nil entries, string|nil why
function M.list(data)
    if type(data) ~= "string" then return nil, "no archive" end
    local n = #data
    -- The end-of-central-directory record: its comment is at most 65535 bytes.
    local eocd
    for i = n - 21, math.max(1, n - 21 - 65535), -1 do
        if u32(data, i) == 0x06054b50 and i + 22 + u16(data, i + 20) - 1 == n then
            eocd = i
            break
        end
    end
    if not eocd then return nil, "not a zip archive (no end of central directory; truncated?)" end
    local disk, cd_disk = u16(data, eocd + 4), u16(data, eocd + 6)
    local count_disk, count = u16(data, eocd + 8), u16(data, eocd + 10)
    local cd_size, cd_off = u32(data, eocd + 12), u32(data, eocd + 16)
    if disk ~= 0 or cd_disk ~= 0 or count_disk ~= count then return nil, "multi-disk archives are not supported" end
    if count == 0xFFFF or cd_size == 0xFFFFFFFF or cd_off == 0xFFFFFFFF then
        return nil, "zip64 archives are not supported"
    end
    if cd_off + cd_size > eocd - 1 then return nil, "the central directory lies outside the archive (truncated?)" end
    local entries, seen = {}, {}
    local total = 0
    local p = cd_off + 1
    for _ = 1, count do
        if p + 46 - 1 > eocd - 1 or u32(data, p) ~= 0x02014b50 then
            return nil, "malformed central directory (truncated?)"
        end
        local made_by, flags, method = u16(data, p + 4), u16(data, p + 8), u16(data, p + 10)
        local crc, csize, usize = u32(data, p + 16), u32(data, p + 20), u32(data, p + 24)
        local nlen, xlen, clen = u16(data, p + 28), u16(data, p + 30), u16(data, p + 32)
        local ext, loff = u32(data, p + 38), u32(data, p + 42)
        local raw = data:sub(p + 46, p + 46 + nlen - 1)
        if #raw ~= nlen then return nil, "malformed central directory (truncated?)" end
        p = p + 46 + nlen + xlen + clen
        if p - 1 > eocd - 1 then return nil, "malformed central directory (truncated?)" end
        if bit.band(flags, 1) ~= 0 then return nil, "entry " .. raw .. " is encrypted" end
        if method ~= 0 and method ~= 8 then
            return nil, "entry " .. raw .. " uses compression method " .. method .. " (only stored and deflate)"
        end
        if csize == 0xFFFFFFFF or usize == 0xFFFFFFFF or loff == 0xFFFFFFFF then
            return nil, "zip64 archives are not supported"
        end
        local t, terr = entry_type(made_by, ext, raw)
        if not t then return nil, terr end
        local name = t == "directory" and raw:sub(1, -2) or raw
        local ok, why = M.check_name(name)
        if not ok then return nil, why end
        local key = name:lower()
        if seen[key] then return nil, "entry " .. name .. " repeats " .. seen[key] .. " (case-insensitively)" end
        seen[key] = name
        if t == "file" and not name:find("/", 1, true) then
            return nil, "entry " .. name .. " is not under " .. M.TOP .. "/"
        end
        if t == "directory" and usize ~= 0 then return nil, "directory entry " .. name .. " has data" end
        total = total + usize
        if total > M.MAX_TOTAL then
            return nil, string.format("the entries total more than the limit of %d bytes uncompressed", M.MAX_TOTAL)
        end
        -- The local header: inside the archive, naming the same entry.
        local l = loff + 1
        if l + 30 - 1 > cd_off or u32(data, l) ~= 0x04034b50 then
            return nil, "entry " .. name .. " has no local header (truncated?)"
        end
        local lnlen, lxlen = u16(data, l + 26), u16(data, l + 28)
        if data:sub(l + 30, l + 30 + lnlen - 1) ~= raw then
            return nil, "entry " .. name .. ": the local header names another entry"
        end
        local off = l + 30 + lnlen + lxlen
        if off + csize - 1 > cd_off then return nil, "entry " .. name .. " lies outside the archive (truncated?)" end
        entries[#entries + 1] = { name = name, type = t, method = method, crc = crc, csize = csize,
            usize = usize, offset = off }
    end
    return entries
end

--- The content of a listed file entry, inflated and checked against its
--- size and CRC-32; nil + why.
--- @param data string the whole archive
--- @param e loomworks.provision.ZipEntry
--- @return string|nil content, string|nil why
function M.extract(data, e)
    local raw = data:sub(e.offset, e.offset + e.csize - 1)
    if #raw ~= e.csize then return nil, "entry " .. e.name .. " is truncated" end
    local out
    if e.method == 0 then
        out = raw
    else
        local ok, res = pcall(function()
            return require("loomworks.provision.libdeflate"):DecompressDeflate(raw)
        end)
        if not ok or type(res) ~= "string" then return nil, "entry " .. e.name .. " does not inflate" end
        out = res
    end
    if #out ~= e.usize then
        return nil, string.format("entry %s inflates to %d bytes, recorded %d", e.name, #out, e.usize)
    end
    if M.crc32(out) ~= e.crc then return nil, "entry " .. e.name .. " fails its CRC-32" end
    return out
end

--- List, check and extract every entry (synchronously): each with
--- `content` (a file's), or nil + why — nothing partial.
--- @param data string
--- @return loomworks.provision.ZipEntry[]|nil entries, string|nil why
function M.read(data)
    local entries, why = M.list(data)
    if not entries then return nil, why end
    for _, e in ipairs(entries) do
        if e.type == "file" then
            local c, err = M.extract(data, e)
            if not c then return nil, err end
            e.content = c
        end
    end
    return entries
end

return M

-- Dev tool: pack a loomworks module plugin checkout into a source archive zip
-- the shape `lw module install` expects (spec §16.20) — everything under one
-- top-level `<name>-<version>/` directory, exactly like a GitHub codeload zip.
-- Prints the archive's SHA-256 and a ready-to-paste index entry.
--
-- Run with luvi (from the loomworks.nvim repo root):
--   luvi scripts/dev/pack-module -- <checkout-dir> <name> <version> <out-dir>
--
-- e.g.  luvi scripts/dev/pack-module -- \
--          ../loomworks-module-ohos.nvim harmony 0.1.0 ./.lw-module-dev
--
-- Produces <out-dir>/<name>-<version>.zip. Use it in a local index so
-- `lw module install <name>` can install without publishing anything:
--   { "schema": 1, "modules": { "<name>": { ...the printed entry... } } }

local uv = require("uv")
local miniz = require("miniz")
local ossl = require("openssl")

local args = { ... }
local checkout, name, version, outdir = args[1], args[2], args[3], args[4]
if not (checkout and name and version and outdir) then
  io.stderr:write("usage: luvi scripts/dev/pack-module -- " ..
    "<checkout-dir> <name> <version> <out-dir>\n")
  os.exit(2)
end

-- Directories not shipped in the archive (mirrors what matters; install keeps
-- only the `lua/` tree regardless, but a lean archive is nicer).
local SKIP = { [".git"] = true, [".github"] = true, ["tests"] = true }

local function norm(p) return (p:gsub("\\", "/")) end
checkout = norm(checkout):gsub("/+$", "")

local top = name .. "-" .. version
local writer = miniz.new_writer()
local count = 0

local function add_dir(rel)
  local abs = rel == "" and checkout or (checkout .. "/" .. rel)
  local scan = uv.fs_scandir(abs)
  if not scan then return end
  local names = {}
  while true do
    local n = uv.fs_scandir_next(scan)
    if not n then break end
    names[#names + 1] = n
  end
  table.sort(names)
  for _, n in ipairs(names) do
    local child_rel = rel == "" and n or (rel .. "/" .. n)
    local child_abs = checkout .. "/" .. child_rel
    local st = uv.fs_stat(child_abs)
    if st and st.type == "directory" then
      if not (rel == "" and SKIP[n]) then add_dir(child_rel) end
    elseif st then
      local f = assert(io.open(child_abs, "rb"))
      local data = f:read("*a"); f:close()
      writer:add(top .. "/" .. child_rel, data or "")
      count = count + 1
    end
  end
end

add_dir("")
local bytes = writer:finalize()

-- mkdir -p outdir
outdir = norm(outdir):gsub("/+$", "")
do
  local acc = ""
  if outdir:sub(1, 1) == "/" then acc = "/" end
  local drive = outdir:match("^(%a:)/")
  if drive then acc = drive .. "/" end
  for seg in outdir:gsub("^%a:/", ""):gsub("^/", ""):gmatch("[^/]+") do
    acc = (acc == "" or acc:sub(-1) == "/") and (acc .. seg) or (acc .. "/" .. seg)
    if not uv.fs_stat(acc) then uv.fs_mkdir(acc, tonumber("755", 8)) end
  end
end

local zippath = outdir .. "/" .. name .. "-" .. version .. ".zip"
local out = assert(io.open(zippath, "wb"))
out:write(bytes); out:close()

local sha = ossl.digest.digest("sha256", bytes, false)

io.write(string.format("packed %d files -> %s\n", count, zippath))
io.write(string.format("sha256: %s\n\n", sha))
io.write("index entry:\n")
io.write(string.format(
  '  "%s": {\n' ..
  '    "version": "%s",\n' ..
  '    "api_version": 1,\n' ..
  '    "url": "%s",\n' ..
  '    "sha256": "%s"\n' ..
  '  }\n',
  name, version, zippath, sha))

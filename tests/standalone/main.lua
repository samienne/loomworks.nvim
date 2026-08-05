-- Standalone (luvi-hosted) test runner for the host bootstrap modules
-- (boot.verify, boot.json). These depend on luvi's OpenSSL, so they cannot run
-- under the nvim/busted suite; run this with:  make test-standalone
-- (which does `luvi tests/standalone` from the repo root, so cwd is the root).

local uv = require("uv")
local root = uv.cwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local verify = require("boot.verify")
local json = require("boot.json")
local paths = require("boot.paths")
local download = require("boot.download")
local update = require("boot.update")
local install = require("boot.install")
local modules = require("boot.modules")
local miniz = require("miniz")

local FX = root .. "/tests/fixtures/dist/"
local function readfile(p)
  local f = assert(io.open(p, "rb"), "cannot open " .. p)
  local s = f:read("*a"); f:close(); return s
end

-- tiny test harness -----------------------------------------------------------
local pass, fail = 0, 0
local function ok(cond, name)
  if cond then pass = pass + 1; print("  ok   " .. name)
  else fail = fail + 1; print("  FAIL " .. name) end
end
local function eq(a, b, name) ok(a == b, name .. "  (got " .. tostring(a) .. ")") end

-- fixtures --------------------------------------------------------------------
local manifest_bytes = readfile(FX .. "manifest.json")
local sig            = readfile(FX .. "manifest.json.sig")
local wrongsig       = readfile(FX .. "manifest.json.wrongsig")
local test_pub       = readfile(FX .. "test_ec_pub.pem")

print("boot.json")
do
  local v = json.decode('{"a":1,"b":[true,false,null,"x\\ny"],"c":{"d":-2.5e1}}')
  ok(type(v) == "table", "decodes nested object")
  eq(v.a, 1, "number")
  eq(v.b[1], true, "array true")
  eq(v.b[4], "x\ny", "string escape")
  eq(v.c.d, -25.0, "nested exponent number")
  local bad, err = json.decode('{"a":}')
  ok(bad == nil and type(err) == "string", "rejects malformed json")
  local bad2 = json.decode('{"a":1} trailing')
  ok(bad2 == nil, "rejects trailing data")
end

print("boot.verify — signature")
do
  -- The embedded default key IS the test key in this slice, so no explicit key
  -- needed; also exercise the explicit-key path.
  local m, err = verify.load_manifest(manifest_bytes, sig)
  ok(m ~= nil, "valid manifest+sig loads (embedded key)" .. (err and (" — " .. err) or ""))
  if m then eq(m.version, "0.0.0-test", "manifest version") end

  local m2 = verify.load_manifest(manifest_bytes, sig, test_pub)
  ok(m2 ~= nil, "valid manifest+sig loads (explicit key)")

  local m3, err3 = verify.load_manifest(manifest_bytes, wrongsig)
  ok(m3 == nil and type(err3) == "string", "wrong-key signature rejected")

  local tampered = manifest_bytes:gsub("0%.0%.0%-test", "9.9.9-evil")
  local m4, err4 = verify.load_manifest(tampered, sig)
  ok(m4 == nil and type(err4) == "string", "tampered manifest rejected")

  local m5, err5 = verify.load_manifest(manifest_bytes, "")
  ok(m5 == nil and type(err5) == "string", "empty signature rejected")
end

print("boot.verify — host compat + artifacts")
do
  local m = assert(verify.load_manifest(manifest_bytes, sig))
  ok(verify.host_compatible(m), "min_host_version 1 <= host 1")

  local future = { version = "2", min_host_version = verify.HOST_VERSION + 5, artifacts = {} }
  local okc, errc = verify.host_compatible(future)
  ok(not okc and type(errc) == "string", "future min_host_version refused")

  local name = "loomworks-lua-0.0.0-test.zip"
  local bytes = readfile(FX .. name)
  ok(verify.verify_artifact(bytes, name, m), "artifact hash matches")
  ok(not verify.verify_artifact(bytes .. "x", name, m), "tampered artifact rejected")
  ok(not verify.verify_artifact(bytes, "nope.zip", m), "unknown artifact rejected")
  ok(verify.verify_artifact_file(FX .. name, name, m), "artifact file on disk verifies")
end

print("boot.download — local fetch")
do
  local bytes = download.fetch(FX .. "manifest.json")
  ok(bytes == manifest_bytes, "fetch(local path) returns exact file bytes")
  local miss = download.fetch(FX .. "does-not-exist")
  ok(miss == nil, "fetch(missing local) returns nil")
end

print("boot.update — extract_zip")
do
  local dest = root .. "/tests/.tmp-extract"
  paths.rm_rf(dest)
  local okx, ex = update.extract_zip(FX .. "loomworks-lua-0.0.0-test.zip", dest)
  ok(okx, "extract_zip ok" .. (ex and (" — " .. ex) or ""))
  local m = io.open(dest .. "/loomworks/_release_marker.lua", "rb")
  ok(m ~= nil, "nested file extracted")
  if m then m:close() end
  paths.rm_rf(dest)
end

print("boot.update — rename_with_retry (Windows AV/indexer lock)")
do
  -- Transient EPERM (Defender holds a freshly-extracted file): rename fails a
  -- few times, then succeeds — the retry must ride it out, not abort.
  local calls = 0
  local moved = update.rename_with_retry("src", "dst", {
    sleep = function() end,  -- don't actually wait in the test
    rename = function()
      calls = calls + 1
      if calls < 4 then return nil, "EPERM: operation not permitted" end
      return true
    end,
  })
  ok(moved == true, "retries past a transient rename failure")
  eq(calls, 4, "kept trying until the rename succeeded")

  -- A persistent failure still surfaces (bounded attempts), with the error.
  local n = 0
  local pok, perr = update.rename_with_retry("src", "dst", {
    sleep = function() end,
    attempts = 5,
    rename = function() n = n + 1; return nil, "EACCES" end,
  })
  ok(pok == false and perr == "EACCES", "gives up after the attempt budget, returns the error")
  eq(n, 5, "respects the attempt budget")
end

print("boot.update — self_update (isolated sandbox, local release)")
do
  local sandbox = root .. "/tests/.tmp-update"
  paths.rm_rf(sandbox)
  paths.mkdirp(sandbox)
  -- Redirect the data dir + config to a sandbox and point the release URL at
  -- the local fixtures dir, so the whole flow is hermetic (no network).
  uv.os_setenv("LOCALAPPDATA", sandbox)     -- data dir on Windows
  uv.os_setenv("XDG_DATA_HOME", sandbox)    -- data dir elsewhere
  uv.os_setenv("APPDATA", sandbox)          -- config dir on Windows
  uv.os_setenv("XDG_CONFIG_HOME", sandbox)  -- config dir elsewhere
  uv.os_setenv("LOOMWORKS_RELEASE_URL", FX:gsub("/$", ""))

  local data = paths.data_dir()
  local res, err = update.self_update({})
  ok(res ~= nil, "self_update installs" .. (err and (" — " .. err) or ""))
  if res then
    eq(res.version, "0.0.0-test", "installed version")
    ok(res.updated == true, "reports updated=true")
    local m = io.open(data .. "/lua-0.0.0-test/loomworks/_release_marker.lua", "rb")
    ok(m ~= nil, "release activated at lua-<ver>/loomworks/")
    if m then m:close() end
  end
  local res2 = update.self_update({})
  ok(res2 and res2.updated == false, "second run is a no-op (already installed)")

  -- tampered manifest at the mirror must be rejected (no install)
  local good = readfile(FX .. "manifest.json")
  local badmirror = sandbox .. "/badmirror"
  paths.mkdirp(badmirror)
  local function put(name, bytes) local f = io.open(badmirror .. "/" .. name, "wb"); f:write(bytes); f:close() end
  put("manifest.json", (good:gsub("0%.0%.0%-test", "6.6.6-evil")))
  put("manifest.json.sig", readfile(FX .. "manifest.json.sig"))
  uv.os_setenv("LOOMWORKS_RELEASE_URL", badmirror)
  local bad, berr = update.self_update({})
  ok(bad == nil and type(berr) == "string", "tampered mirror rejected (signature)")

  local info = update.version_info(data .. "/lua-0.0.0-test", "release")
  eq(info.bundle, "0.0.0-test", "version_info parses bundle version")

  paths.rm_rf(sandbox)
end

print("boot.install — mechanics")
do
  local sb = root .. "/tests/.tmp-install"
  paths.rm_rf(sb); paths.mkdirp(sb)

  -- copy_binary
  local src, dst = sb .. "/src.bin", sb .. "/nested/dst.bin"
  local f = io.open(src, "wb"); f:write("BIN\0ARY\0DATA"); f:close()
  ok(install.copy_binary(src, dst) == true, "copy_binary ok (creates parents)")
  local g = io.open(dst, "rb"); local d = g:read("*a"); g:close()
  ok(d == "BIN\0ARY\0DATA", "copied bytes match exactly")

  -- dir_on_path
  local sep = paths.is_windows and ";" or ":"
  uv.os_setenv("PATH", "/foo" .. sep .. "/bar/" .. sep .. "/baz")
  ok(install.dir_on_path("/bar"), "dir_on_path finds a member (trailing slash ok)")
  ok(not install.dir_on_path("/nope"), "dir_on_path rejects a non-member")

  -- append_path_line (idempotent)
  local rc = sb .. "/rcfile"
  local line = 'export PATH="/x/bin:$PATH"'
  ok(install.append_path_line(rc, line) == true, "append_path_line adds")
  ok(install.append_path_line(rc, line) == false, "append_path_line idempotent")
  local rf = io.open(rc, "r"); local rc_body = rf:read("*a"); rf:close()
  ok(rc_body:find(line, 1, true) ~= nil, "PATH line written")

  -- shell_rc picks the right file by $SHELL
  uv.os_setenv("SHELL", "/usr/bin/zsh")
  ok(install.shell_rc():match("/%.zshrc$"), "shell_rc: zsh -> .zshrc")
  uv.os_setenv("SHELL", "/bin/bash")
  ok(install.shell_rc():match("/%.bashrc$"), "shell_rc: bash -> .bashrc")

  -- guard: refuse to install bare luvi
  local g, gerr = install.install({ exe_path = "/some/dir/luvi.exe", no_bundle = true })
  ok(g == nil and type(gerr) == "string" and gerr:find("luvi"), "refuses to install bare luvi")

  -- --dry-run writes nothing (exe_path stands in for a real fused host)
  uv.os_setenv("LOCALAPPDATA", sb)
  uv.os_setenv("HOME", sb)
  local rep = install.install({ exe_path = sb .. "/lw", dry_run = true, no_bundle = true, no_modify_path = true })
  ok(type(rep) == "table" and #rep > 0, "install --dry-run returns a report")
  ok(not io.open(install.target_path(), "rb"), "install --dry-run wrote no binary")

  -- A failed bundle fetch must FAIL the install. Exiting 0 here leaves a
  -- binary that cannot run anything, and the job dies later at an unrelated
  -- command with "no loomworks release is installed".
  do
    local update_mod = require("boot.update")
    local real = update_mod.self_update
    update_mod.self_update = function()
      return nil, "curl failed (56) for https://example/bundle: Connection reset"
    end
    local f2 = io.open(sb .. "/lw2", "wb"); f2:write("HOST"); f2:close()
    local rep2, err2 = install.install({ exe_path = sb .. "/lw2", no_modify_path = true })
    update_mod.self_update = real
    ok(type(err2) == "string" and err2:find("bundle fetch failed", 1, true) ~= nil,
      "install reports an error when the bundle fetch fails")
    ok(type(rep2) == "table", "install still returns its progress report on failure")
    local joined = table.concat(rep2 or {}, "\n")
    ok(joined:find("Connection reset", 1, true) ~= nil,
      "the underlying fetch error is surfaced, not swallowed")
    ok(joined:find("Done.", 1, true) == nil,
      "a failed install must not claim it is done")
  end

  paths.rm_rf(sb)
end

print("boot.download — transient failures are retried, permanent ones are not")
do
  -- curl -f exits 22 for every HTTP status >= 400, so the classifier has to
  -- read the status out of stderr to tell "no such release" (never going to
  -- work) from "briefly unwell" (worth another go).
  ok(download.is_transient(56, "curl: (56) Recv failure: Connection reset"),
    "connection reset is transient")
  ok(download.is_transient(28, "curl: (28) Operation timed out"),
    "timeout is transient")
  ok(download.is_transient(22, "The requested URL returned error: 503"),
    "503 is transient")
  ok(download.is_transient(22, "The requested URL returned error: 429"),
    "429 invites a retry")
  ok(not download.is_transient(22, "The requested URL returned error: 404"),
    "404 is permanent — retrying only delays a certain failure")
  ok(not download.is_transient(22, "The requested URL returned error: 403"),
    "403 is permanent")
  ok(not download.is_transient(0, ""), "success is not a retry candidate")
end

print("boot.modules — acquisition (hermetic, local index + archive)")
do
  -- Close every probe handle: a leaked read handle on Windows makes the file
  -- delete-pending, so a later rm_rf of its directory fails ENOTEMPTY.
  local function exists(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
  end
  local sb = root .. "/tests/.tmp-modules"
  paths.rm_rf(sb); paths.mkdirp(sb)
  -- Sandbox the data dir so installs land under the temp tree, not the user's.
  uv.os_setenv("LOCALAPPDATA", sb)
  uv.os_setenv("XDG_DATA_HOME", sb)
  uv.os_setenv("APPDATA", sb)
  uv.os_setenv("XDG_CONFIG_HOME", sb)
  uv.os_setenv("LOOMWORKS_MODULE_INDEX", "")  -- start unset

  -- Build a GitHub-style archive zip: everything under one top dir, module +
  -- an SDK provider it brings, plus a spec/ file that must be dropped on install.
  local function make_archive(destzip, top)
    local w = miniz.new_writer()
    w:add(top .. "/lua/loomworks/modules/faketool.lua",
      "return { id='faketool', api_version=1 }\n")
    w:add(top .. "/lua/loomworks/sdks/fakesdk.lua", "return { id='fakesdk' }\n")
    w:add(top .. "/spec/modules/faketool.md", "# faketool\n")
    local f = assert(io.open(destzip, "wb")); f:write(w:finalize()); f:close()
  end
  local zip = sb .. "/faketool-0.0.1.zip"
  make_archive(zip, "loomworks-module-faketool.nvim-0.0.1")
  local sha = verify.sha256_hex(readfile(zip))

  local entry = {
    name = "faketool", version = "0.0.1", api_version = 1,
    url = zip, sha256 = sha, repo = "fake/faketool",
    brings = { sdks = { "fakesdk" } },
  }

  -- compatibility gate
  ok(modules.compatible(entry, 1), "compatible when api matches host")
  ok(not modules.compatible({ api_version = 2 }, 1), "incompatible when api differs")
  local newer = modules.incompatible_reason({ name = "x", api_version = 2 }, 1)
  ok(newer:find("update lw", 1, true) ~= nil, "future api -> 'update lw'")
  local older = modules.incompatible_reason({ name = "x", api_version = 1 }, 2)
  ok(older:find("no release compatible", 1, true) ~= nil, "past api -> 'no compatible release'")

  -- install: verifies hash, keeps only lua/, records meta
  local res, err = modules.install(entry)
  ok(res ~= nil, "install succeeds" .. (err and (" — " .. err) or ""))
  local base = paths.modules_dir() .. "/faketool"
  ok(exists(base .. "/lua/loomworks/modules/faketool.lua"),
    "module file installed under <data>/modules/faketool/lua")
  ok(exists(base .. "/lua/loomworks/sdks/fakesdk.lua"),
    "the SDK the module brings is installed too")
  ok(not exists(base .. "/spec/modules/faketool.md"),
    "non-lua/ archive content (spec/) is dropped")
  local meta = paths.read_module_meta(base)
  eq(meta.version, "0.0.1", "meta records version")
  eq(meta.api_version, 1, "meta records api_version")
  eq((meta.sha256 or ""):lower(), sha:lower(), "meta records the verified sha256")

  -- discovery: installed_modules + module_lua_roots see it
  local found
  for _, m in ipairs(paths.installed_modules()) do if m.name == "faketool" then found = m end end
  ok(found ~= nil, "installed_modules lists faketool")
  local roots = paths.module_lua_roots()
  local has_root = false
  for _, r in ipairs(roots) do if r == base .. "/lua" then has_root = true end end
  ok(has_root, "module_lua_roots includes the install's lua root")

  -- the shim glob (module discovery) sees it via _G.__loomworks_module_roots
  _G.__loomworks_module_roots = roots
  local vim = require("loomworks.shim")
  local hits = vim.api.nvim_get_runtime_file("lua/loomworks/modules/*.lua", true)
  local shim_saw = false
  for _, p in ipairs(hits) do if p:find("faketool.lua", 1, true) then shim_saw = true end end
  ok(shim_saw, "shim runtime_files glob finds an acquired module")

  -- End-to-end through the REAL registry: modules.list() globs (shim) AND
  -- require()s each hit via M.get. Regression guard for the id-extraction bug —
  -- the install path holds "modules" twice (…/modules/<id>/lua/loomworks/
  -- modules/<id>.lua), so a greedy capture used to yield a slash-laden id that
  -- failed to load and silently dropped the module.
  local mod_searcher = function(modname)
    local rel = modname:gsub("%.", "/")
    for _, rt in ipairs(_G.__loomworks_module_roots or {}) do
      for _, c in ipairs({ rt .. "/" .. rel .. ".lua", rt .. "/" .. rel .. "/init.lua" }) do
        local fh = io.open(c, "r")
        if fh then local s = fh:read("*a"); fh:close(); return loadstring(s, "@" .. c) end
      end
    end
    return "\n\tno acquired-module file for '" .. modname .. "'"
  end
  table.insert(package.loaders or package.searchers, mod_searcher)
  local listed = require("loomworks.modules").list()
  local in_list = false
  for _, id in ipairs(listed) do if id == "faketool" then in_list = true end end
  ok(in_list, "modules.list() resolves an acquired module (id extracted correctly)")
  _G.__loomworks_module_roots = nil

  -- tamper: a hash mismatch installs nothing
  modules.remove("faketool")
  local bad = { name = "faketool", version = "0.0.1", api_version = 1,
    url = zip, sha256 = string.rep("0", 64) }
  local br, berr = modules.install(bad)
  ok(br == nil and type(berr) == "string" and berr:find("mismatch", 1, true) ~= nil,
    "sha256 mismatch is rejected")
  ok(not exists(base .. "/lua/loomworks/modules/faketool.lua"),
    "a rejected install leaves nothing behind")

  -- name safety: a traversing name must be refused by install, remove, and the
  -- index validator — it would otherwise write/delete outside the modules dir.
  ok(modules.valid_name("harmony") and modules.valid_name("mod_2.0-x"),
    "valid_name accepts plain names")
  ok(not modules.valid_name("../evil") and not modules.valid_name("a/b")
    and not modules.valid_name("..") and not modules.valid_name(".hidden")
    and not modules.valid_name(""),
    "valid_name rejects separators, '..', dotfiles, empty")
  local ev, everr = modules.install({ name = "../evil", version = "1",
    api_version = 1, url = zip, sha256 = sha })
  ok(ev == nil and type(everr) == "string" and everr:find("unsafe", 1, true) ~= nil,
    "install refuses a traversing module name")
  local rv, rverr = modules.remove("../evil")
  ok(rv == nil and type(rverr) == "string" and rverr:find("unsafe", 1, true) ~= nil,
    "remove refuses a traversing module name")
  ok(select(1, modules.load_index({ url = (function()
      local p = sb .. "/evilidx.json"
      local f = assert(io.open(p, "wb"))
      f:write('{"schema":1,"modules":{"../evil":{"version":"1","api_version":1,'
        .. '"url":"u","sha256":"ab"}}}')
      f:close(); return p
    end)() })) == nil,
    "load_index rejects an entry whose name would traverse")

  -- archive with no lua/ tree is refused
  local nolua = sb .. "/nolua.zip"
  do
    local w = miniz.new_writer()
    w:add("top/readme.md", "hi\n")
    local f = assert(io.open(nolua, "wb")); f:write(w:finalize()); f:close()
  end
  local n2, ne = modules.install({ name = "nolua", version = "1", api_version = 1,
    url = nolua, sha256 = verify.sha256_hex(readfile(nolua)) })
  ok(n2 == nil and type(ne) == "string" and ne:find("lua/", 1, true) ~= nil,
    "an archive with no lua/ tree is refused")

  -- load_index: validates shape, resolves entries; rejects a broken index
  local idxfile = sb .. "/index.json"
  do
    local f = assert(io.open(idxfile, "wb"))
    f:write(json.encode({ schema = 1, modules = {
      faketool = { version = "0.0.1", api_version = 1, url = zip, sha256 = sha,
        description = "fake", brings = { sdks = { "fakesdk" } } },
    } }))
    f:close()
  end
  local idx, ie = modules.load_index({ url = idxfile })
  ok(idx ~= nil, "load_index parses a valid local index" .. (ie and (" — " .. ie) or ""))
  if idx then
    local e = modules.entry(idx, "faketool")
    ok(e ~= nil and e.name == "faketool", "entry() resolves + tags the name")
    ok(select(1, modules.entry(idx, "ghost")) == nil, "entry() nil for unknown module")
  end
  local badidx = sb .. "/bad.json"
  do local f = assert(io.open(badidx, "wb"))
     f:write('{"modules":{"x":{"url":"u"}}}'); f:close() end
  ok(select(1, modules.load_index({ url = badidx })) == nil,
    "load_index rejects an entry missing sha256/version/api_version")

  -- status merges installed + available
  modules.install(entry)
  local st = modules.status(idx, 1)
  local row
  for _, r in ipairs(st) do if r.name == "faketool" then row = r end end
  ok(row and row.installed and row.available, "status merges installed + available")
  ok(row and row.compatible == true, "status marks compatible")

  -- remove is idempotent
  ok(modules.remove("faketool") == true, "remove ok")
  ok(not exists(base .. "/lua/loomworks/modules/faketool.lua"), "remove deletes the tree")
  ok(modules.remove("faketool") == true, "remove is idempotent when absent")

  paths.rm_rf(sb)
end

print("loomworks.shim — vim.fn surface used on the build/test path")
do
  -- Regression: the meson test runner calls vim.fn.environ(); it was missing
  -- from the shim, so `lw test` on meson crashed (masked as "no test runner").
  -- These run under luvi (the real shim), which nvim-hosted busted can't catch.
  local vim = require("loomworks.shim")
  ok(type(vim.fn.environ) == "function", "vim.fn.environ exists")
  local env = vim.fn.environ()
  ok(type(env) == "table", "vim.fn.environ() returns a table")
  ok(env.PATH ~= nil or env.Path ~= nil, "vim.fn.environ() includes PATH")
  ok(type(vim.fn.exepath) == "function" and type(vim.fn.getcwd) == "function",
    "vim.fn.exepath / getcwd present")
end

local function slurp(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

print("boot.pin — parse / serialize / asset selection")
do
  local pin = require("boot.pin")
  eq(pin.host_asset("Linux", "x86_64"), "lw-linux-x86_64", "linux/x86_64 asset")
  eq(pin.host_asset("Darwin", "arm64"), "lw-macos-arm64", "macos/arm64 asset")
  eq(pin.host_asset("MINGW64_NT-10.0", "x86_64"), "lw-windows-x86_64.exe", "windows/x86_64 asset")
  eq(pin.host_asset("Linux", "amd64"), "lw-linux-x86_64", "amd64 normalizes to x86_64")
  eq(pin.host_asset("Darwin", "aarch64"), "lw-macos-arm64", "aarch64 normalizes to arm64")
  ok(select(1, pin.host_asset("Linux", "arm64")) == nil, "linux/arm64 unsupported (no wrong-asset)")
  ok(select(1, pin.host_asset("Plan9", "x86_64")) == nil, "unknown OS rejected")

  local text = "version = 1.2.3\nsha256_lw-linux-x86_64 = ABCDEF\n" ..
    "# a comment\nsha256_loomworks-lua-1.2.3.zip = 00ff\n"
  local p = pin.parse(text)
  ok(p ~= nil, "parses a pin")
  eq(p and p.version, "1.2.3", "version parsed")
  eq(p and p.hashes["lw-linux-x86_64"], "abcdef", "host-binary hash lowercased")
  eq(p and p.hashes["loomworks-lua-1.2.3.zip"], "00ff", "bundle hash parsed")
  ok(select(1, pin.parse("sha256_x = y")) == nil, "pin without version rejected")

  local rt = pin.parse(pin.serialize("9.9.9", { ["lw-linux-x86_64"] = "DEAD", b = "beef" }))
  eq(rt.version, "9.9.9", "serialize round-trips version")
  eq(rt.hashes["lw-linux-x86_64"], "dead", "serialize round-trips + lowercases")
  eq(pin.bundle_asset("9.9.9"), "loomworks-lua-9.9.9.zip", "bundle asset name")
end

print("boot.pin — redirect decision")
do
  local pin = require("boot.pin")
  local P = { version = "2.0.0", hashes = {} }
  local function act(o) return (pin.decide(o)) end
  eq(act({ command = "build", pin = P, self_version = "1.0.0" }), "redirect",
    "pin != self -> redirect")
  eq(act({ command = "build", pin = P, self_version = "2.0.0" }), "in-process",
    "pin == self -> in-process (fast path, no download)")
  eq(act({ command = "build", pin = P, self_version = "1.0.0", no_pin = true }), "bypass",
    "--no-pin bypasses")
  eq(act({ command = "build", pin = P, self_version = "1.0.0", lw_override = true }), "bypass",
    "LOOMWORKS_LW bypasses")
  eq(act({ command = "build", pin = P, self_version = "1.0.0", dev = true }), "bypass",
    "dev source bypasses")
  eq(act({ command = "build", pin = P, self_version = "1.0.0", pinned_sentinel = "2.0.0" }),
    "in-process", "sentinel -> never redirect (anti-recursion)")
  eq(act({ command = "version", pin = P, self_version = "1.0.0" }), "in-process",
    "host command not redirected")
  eq(act({ command = "status", pin = P, self_version = "1.0.0" }), "in-process",
    "status not redirected")
  eq(act({ command = "build", pin = nil, self_version = "1.0.0" }), "no-pin",
    "no pin -> no redirect")
  for _, c in ipairs({ "build", "run", "test", "clean", "configure" }) do
    ok(pin.is_redirect_command(c), c .. " is a redirect command")
  end
  ok(not pin.is_redirect_command("publish"), "publish is not a redirect command")
  ok(not pin.is_redirect_command("bootstrap"), "bootstrap is not a redirect command")
end

print("boot.update — versioned_base URL shapes")
do
  eq(update.versioned_base("1.2.3", { url = update.DEFAULT_RELEASE_URL }),
    "https://github.com/samienne/loomworks.nvim/releases/download/v1.2.3",
    "GitHub default -> versioned download path")
  eq(update.versioned_base("1.2.3", { url = "/tmp/mirror" }), "/tmp/mirror",
    "local mirror stays flat")
  eq(update.versioned_base("1.2.3", { url = "https://example.com/mirror" }),
    "https://example.com/mirror", "custom http mirror stays flat")
end

print("boot.update — ensure_version (repo-local bundle, flat mirror)")
do
  local sb = root .. "/tests/.tmp-ensure"; paths.rm_rf(sb); paths.mkdirp(sb)
  local mirror = sb .. "/mirror"; paths.mkdirp(mirror)
  local repo = sb .. "/repo"; paths.mkdirp(repo)
  local ver = "7.7.7-test"
  local bundle = "loomworks-lua-" .. ver .. ".zip"
  do
    local w = miniz.new_writer()
    w:add("loomworks/cli.lua", "return {}\n")
    local f = assert(io.open(mirror .. "/" .. bundle, "wb")); f:write(w:finalize()); f:close()
  end
  local bundle_sha = verify.sha256_hex(readfile(mirror .. "/" .. bundle))
  uv.os_setenv("LOOMWORKS_RELEASE_URL", mirror)

  eq(update.versioned_base(ver), mirror, "versioned_base(mirror) is flat")

  local dir, err = update.ensure_version(ver, { root = repo, bundle_sha256 = bundle_sha })
  ok(dir ~= nil, "ensure_version provisions" .. (err and (" — " .. err) or ""))
  eq(dir, repo .. "/.nvim/cache/lua-" .. ver, "extracted to repo-local .nvim/cache/lua-<ver>")
  ok(slurp(dir .. "/loomworks/cli.lua") ~= nil, "bundle extracted (cli.lua present)")

  -- idempotent: a second call reuses without touching the mirror
  uv.os_setenv("LOOMWORKS_RELEASE_URL", mirror .. "/gone")
  local dir2 = update.ensure_version(ver, { root = repo, bundle_sha256 = bundle_sha })
  eq(dir2, dir, "ensure_version idempotent (no refetch)")
  uv.os_setenv("LOOMWORKS_RELEASE_URL", mirror)

  -- hash mismatch aborts and leaves nothing behind
  local repo2 = sb .. "/repo2"; paths.mkdirp(repo2)
  local bad, berr = update.ensure_version(ver, { root = repo2, bundle_sha256 = string.rep("0", 64) })
  ok(bad == nil and type(berr) == "string", "bundle hash mismatch aborts")
  ok(not uv.fs_stat(repo2 .. "/.nvim/cache/lua-" .. ver .. "/loomworks/cli.lua"),
    "a rejected provision leaves nothing behind")

  paths.rm_rf(sb)
end

print("boot.update — ensure_host_binary (pinned host binary, flat mirror)")
do
  local sb = root .. "/tests/.tmp-hostbin"; paths.rm_rf(sb); paths.mkdirp(sb)
  local mirror = sb .. "/mirror"; paths.mkdirp(mirror)
  uv.os_setenv("LOOMWORKS_RELEASE_URL", mirror)
  local asset = "lw-linux-x86_64"
  local body = "FAKE-LW-BINARY\n"
  do local f = assert(io.open(mirror .. "/" .. asset, "wb")); f:write(body); f:close() end
  local sha = verify.sha256_hex(body)
  local dest = sb .. "/cache/lw-1.0.0-" .. asset

  local ok1 = update.ensure_host_binary("1.0.0", asset, sha, dest)
  ok(ok1 == true, "ensure_host_binary downloads + verifies")
  ok(slurp(dest) == body, "cached binary bytes match")

  uv.os_setenv("LOOMWORKS_RELEASE_URL", mirror .. "/gone")
  ok(update.ensure_host_binary("1.0.0", asset, sha, dest) == true, "idempotent when cached")
  uv.os_setenv("LOOMWORKS_RELEASE_URL", mirror)

  local dest2 = sb .. "/cache/lw-1.0.0-bad"
  local bad, berr = update.ensure_host_binary("1.0.0", asset, string.rep("0", 64), dest2)
  ok(bad == nil and type(berr) == "string", "host-binary hash mismatch aborts")
  ok(not uv.fs_stat(dest2), "bad download deleted")

  ok(select(1, update.ensure_host_binary("1.0.0", asset, nil, dest2)) == nil,
    "refuses with no pinned sha256 (hash is always mandatory)")

  paths.rm_rf(sb)
end

print("boot.bootstrap — pin authoring (flat mirror, signed SHA256SUMS)")
do
  local bootstrap = require("boot.bootstrap")
  local pin = require("boot.pin")
  local ossl = require("openssl")
  local priv = ossl.pkey.read(readfile(FX .. "test_ec_priv.pem"), true, "pem")
  local function sign(data) return priv:sign(data, "sha256") end

  local sb = root .. "/tests/.tmp-bootstrap"; paths.rm_rf(sb); paths.mkdirp(sb)
  local mirror = sb .. "/mirror"; paths.mkdirp(mirror)
  local repo = sb .. "/repo"; paths.mkdirp(repo)
  local ver = "3.4.5-test"

  local function stage(version, tag)
    local exp, lines = {}, {}
    local list = { "lw-linux-x86_64", "lw-macos-arm64", "lw-windows-x86_64.exe",
      pin.bundle_asset(version) }
    for _, a in ipairs(list) do
      local bodyv = tag .. ":" .. a .. "\n"
      local f = assert(io.open(mirror .. "/" .. a, "wb")); f:write(bodyv); f:close()
      local h = verify.sha256_hex(bodyv); exp[a] = h
      lines[#lines + 1] = h .. "  " .. a
    end
    local sums = table.concat(lines, "\n") .. "\n"
    do local f = assert(io.open(mirror .. "/SHA256SUMS", "wb")); f:write(sums); f:close() end
    do local f = assert(io.open(mirror .. "/SHA256SUMS.sig", "wb")); f:write(sign(sums)); f:close() end
    return exp
  end

  uv.os_setenv("LOOMWORKS_RELEASE_URL", mirror)
  local exp = stage(ver, "V1")

  local map, ferr = bootstrap.fetch_hashes(ver)
  ok(map ~= nil, "fetch_hashes (signed) returns the map" .. (ferr and (" — " .. ferr) or ""))
  eq(map and map["lw-linux-x86_64"], exp["lw-linux-x86_64"], "hash comes from SHA256SUMS")

  -- a bad signature on the hash list is rejected (nothing trusted)
  do local f = assert(io.open(mirror .. "/SHA256SUMS.sig", "wb"))
     f:write(readfile(FX .. "manifest.json.sig")); f:close() end
  ok(select(1, bootstrap.fetch_hashes(ver)) == nil, "wrong SHA256SUMS signature rejected")
  stage(ver, "V1")  -- restore the good, matching signed list

  local rep, berr = bootstrap.bootstrap(repo, nil, { version = ver })
  ok(rep ~= nil, "bootstrap succeeds" .. (berr and (" — " .. berr) or ""))
  local p = pin.read(repo)
  ok(p ~= nil, "lw.pin written + parseable")
  eq(p and p.version, ver, "pin version")
  eq(p and p.hashes["lw-windows-x86_64.exe"], exp["lw-windows-x86_64.exe"],
    "pin carries the windows host-binary hash")
  eq(p and p.hashes[pin.bundle_asset(ver)], exp[pin.bundle_asset(ver)],
    "pin carries the BUNDLE hash")
  ok(slurp(repo .. "/lw.sh") ~= nil and slurp(repo .. "/lw.cmd") ~= nil, "launchers written")
  local gi = slurp(repo .. "/.gitignore")
  ok(gi ~= nil and gi:find(".nvim/cache/", 1, true) ~= nil, "gitignore has the cache entry")

  -- idempotent gitignore append that preserves existing content
  do local f = assert(io.open(repo .. "/.gitignore", "wb")); f:write("build/\n.nvim/cache/\n"); f:close() end
  eq(bootstrap.ensure_gitignore(repo), "present", "gitignore append is idempotent")
  local gi2 = slurp(repo .. "/.gitignore")
  ok(gi2:find("build/", 1, true) ~= nil, "existing .gitignore content preserved")
  eq(select(2, gi2:gsub("%.nvim/cache/", "")), 1, "cache entry not duplicated")

  -- a release missing a required asset is a clean error (no partial pin)
  do
    local m2 = sb .. "/mirror2"; paths.mkdirp(m2)
    local partial = exp["lw-linux-x86_64"] .. "  lw-linux-x86_64\n"
    do local f = assert(io.open(m2 .. "/SHA256SUMS", "wb")); f:write(partial); f:close() end
    do local f = assert(io.open(m2 .. "/SHA256SUMS.sig", "wb")); f:write(sign(partial)); f:close() end
    uv.os_setenv("LOOMWORKS_RELEASE_URL", m2)
    ok(select(1, bootstrap.bootstrap(sb .. "/repo3", nil, { version = ver })) == nil,
      "bootstrap errors when the release lacks a required asset")
    uv.os_setenv("LOOMWORKS_RELEASE_URL", mirror)
  end

  -- update repoints the pin at a new version
  local ver2 = "3.5.0-test"
  local exp2 = stage(ver2, "V2")
  local urep, uerr = bootstrap.update(repo, { version = ver2 })
  ok(urep ~= nil, "update rewrites the pin" .. (uerr and (" — " .. uerr) or ""))
  local p2 = pin.read(repo)
  eq(p2 and p2.version, ver2, "pin updated to the new version")
  eq(p2 and p2.hashes[pin.bundle_asset(ver2)], exp2[pin.bundle_asset(ver2)],
    "pin bundle hash updated")

  -- update to an unfetchable release fails cleanly, leaving the pin intact
  uv.os_setenv("LOOMWORKS_RELEASE_URL", sb .. "/nope")
  ok(select(1, bootstrap.update(repo, { version = "9.9.9-nope" })) == nil,
    "update to an unfetchable release fails cleanly")
  eq(pin.read(repo).version, ver2, "failed update leaves the pin intact")

  paths.rm_rf(sb)
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

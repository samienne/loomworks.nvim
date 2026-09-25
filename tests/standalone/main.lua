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
  local bad, berr, binfo = update.self_update({})
  ok(bad == nil and type(berr) == "string", "tampered mirror rejected (signature)")
  eq(binfo, nil, "an unverified manifest yields no host-update target")

  -- A release that raises min_host_version must not strand the host (§16.32):
  -- the (signature-verified) manifest still names the release, so self_update
  -- returns it as a host-update target alongside the error.
  do
    local ossl = require("openssl")
    local priv = ossl.pkey.read(readfile(FX .. "test_ec_priv.pem"), true, "pem")
    local newer = sandbox .. "/newhostmirror"
    paths.mkdirp(newer)
    local mj = good:gsub('"min_host_version": %d+',
      '"min_host_version": ' .. (verify.HOST_VERSION + 1)):gsub("0%.0%.0%-test", "0.0.1-test")
    local function putn(name, bytes) local f = io.open(newer .. "/" .. name, "wb"); f:write(bytes); f:close() end
    putn("manifest.json", mj)
    putn("manifest.json.sig", priv:sign(mj, "sha256"))
    uv.os_setenv("LOOMWORKS_RELEASE_URL", newer)
    local r3, e3, i3 = update.self_update({})
    ok(r3 == nil and type(e3) == "string" and e3:find("needs host version", 1, true) ~= nil,
      "incompatible release refused  (got " .. tostring(e3) .. ")")
    ok(type(i3) == "table" and i3.host_incompatible == true and i3.version == "0.0.1-test",
      "incompatible release returned as a host-update target")
    ok(uv.fs_stat(data .. "/lua-0.0.1-test") == nil, "incompatible bundle not installed")
  end

  local info = update.version_info(data .. "/lua-0.0.0-test", "release")
  eq(info.bundle, "0.0.0-test", "version_info parses bundle version")
  -- Committed source carries no release version (fuse_host.sh injects it).
  eq(info.release_version, nil, "source host has no embedded release version")
  -- The label agrees with host_update's dev-build detection (one predicate):
  -- only a real dev build says "dev build"; an unversioned RELEASE-style host
  -- (bootstrap-only fuse, i.e. a pre-identity release) is an unknown release —
  -- self-update WILL replace it, so calling it a dev build would contradict
  -- "a development build never replaces itself".
  local dinfo = update.version_info(data .. "/lua-0.0.0-test", "release", { dev_build = true })
  local line = update.version_line(dinfo, "stable")
  ok(line:find("host: dev build (v" .. verify.HOST_VERSION .. ")", 1, true) ~= nil,
    "version line reports a dev build for an unversioned dev build  (got " .. line .. ")")
  local uline = update.version_line(info, "stable")
  ok(uline:find("host: unknown release (v" .. verify.HOST_VERSION .. ")", 1, true) ~= nil,
    "version line reports an unknown release for an unversioned release host  (got " .. uline .. ")")
  local hu = require("boot.host_update")
  ok(hu.dev_build({ exe = "/x/lw", fused_system_lua = true }) ~= nil, "dev_build: fused system Lua")
  ok(hu.dev_build({ exe = "C:/tools/luvi.exe" }) ~= nil, "dev_build: bare luvi source run")
  eq(hu.dev_build({ exe = "/x/lw" }), nil, "dev_build: bootstrap-only fuse is not a dev build")
  local line2 = update.version_line({ host_version = 1, release_version = "0.1.29",
    source = "release", bundle = "0.1.29" }, "unstable")
  ok(line2:find("host: 0.1.29 (v1)", 1, true) ~= nil
    and line2:find("channel: unstable", 1, true) ~= nil,
    "version line leads with the embedded release version")

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

  -- copy_binary over an existing target: staged + swapped, never written in
  -- place (a running installed lw cannot be opened for writing on Windows).
  local f2 = io.open(src, "wb"); f2:write("NEWER"); f2:close()
  ok(install.copy_binary(src, dst) == true, "copy_binary replaces an existing target")
  local g2 = io.open(dst, "rb"); local d2 = g2:read("*a"); g2:close()
  ok(d2 == "NEWER", "replaced bytes match")
  ok(uv.fs_stat(dst .. ".new") == nil, "no staged .new left behind")
  -- A target that refuses in-place writes (as a running Windows exe does) is
  -- still replaced: the swap renames it aside instead of opening it.
  local renamed = {}
  local fake_fs = {
    rename = function(a, b)
      renamed[#renamed + 1] = a .. " -> " .. b
      return uv.fs_rename(a, b)
    end,
    exists = function(p) return uv.fs_stat(p) ~= nil end,
    unlink = function(p) return uv.fs_unlink(p) end,
  }
  local f3 = io.open(src, "wb"); f3:write("NEWEST"); f3:close()
  ok(install.copy_binary(src, dst, { fs = fake_fs, is_windows = true, sleep = function() end }) == true,
     "windows-style replace succeeds")
  ok(renamed[1] == dst .. " -> " .. dst .. ".old", "running target renamed aside to .old first")
  local g3 = io.open(dst, "rb"); local d3 = g3:read("*a"); g3:close()
  ok(d3 == "NEWEST", "new binary in place after rename-aside")
  pcall(uv.fs_unlink, dst .. ".old")

  -- dir_on_path
  local sep = paths.is_windows and ";" or ":"
  -- Restore PATH afterwards: later tests spawn real programs (the vim.system
  -- timeout test runs `sleep`), which a fake PATH would hide on Unix.
  -- Read it via os_environ(): os_getenv() returns nil for a PATH longer than
  -- luv's default buffer (common on Windows), which would lose it entirely.
  local saved_path
  for k, v in pairs(uv.os_environ()) do
    if k:upper() == "PATH" then saved_path = v end
  end
  uv.os_setenv("PATH", "/foo" .. sep .. "/bar/" .. sep .. "/baz")
  ok(install.dir_on_path("/bar"), "dir_on_path finds a member (trailing slash ok)")
  ok(not install.dir_on_path("/nope"), "dir_on_path rejects a non-member")
  if saved_path then uv.os_setenv("PATH", saved_path) end

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

print("SECURITY — malicious lw.pin version cannot redirect the fetch or rm outside cache")
do
  local pin = require("boot.pin")
  local bootstrap = require("boot.bootstrap")

  -- valid_version whitelist (the trust boundary)
  ok(pin.valid_version("0.1.0"), "accepts 0.1.0")
  ok(pin.valid_version("0.0.0-test"), "accepts a prerelease tag")
  ok(pin.valid_version("1.2.3+build.5"), "accepts build metadata")
  ok(not pin.valid_version("/../../../attacker/evil/releases/download/v1"),
    "rejects a path-traversal version")
  ok(not pin.valid_version("1..2"), "rejects `..`")
  ok(not pin.valid_version("1.0\\evil"), "rejects a backslash")
  ok(not pin.valid_version("1 0"), "rejects whitespace")
  ok(not pin.valid_version(""), "rejects empty")
  ok(not pin.valid_version("../x"), "rejects a leading ../")

  -- pin.parse refuses a malicious version outright (never yields it downstream)
  local evil = "version = /../../../../attacker/evil/releases/download/v1\n" ..
    "sha256_lw-linux-x86_64 = " .. string.rep("a", 64) .. "\n"
  ok(select(1, pin.parse(evil)) == nil, "pin.parse refuses a traversal version")
  ok(select(1, pin.parse("version = a\\b\n")) == nil, "pin.parse refuses a backslash version")
  ok(select(1, pin.parse("version = a b\n")) == nil, "pin.parse refuses a whitespace version")

  -- A committed malicious lw.pin: pin.read -> nil, so the redirect makes no fetch
  local sb = root .. "/tests/.tmp-sec"; paths.rm_rf(sb); paths.mkdirp(sb)
  do local f = assert(io.open(sb .. "/lw.pin", "wb")); f:write(evil); f:close() end
  ok(pin.read(sb) == nil, "pin.read refuses a malicious committed pin")
  eq(pin.decide({ command = "build", pin = pin.read(sb), self_version = "9.9.9" }),
    "no-pin", "redirect refuses: a malicious pin yields no redirect (no fetch)")

  -- versioned_base never emits a traversal URL
  ok(not pcall(update.versioned_base, "/../../evil", { url = update.DEFAULT_RELEASE_URL }),
    "versioned_base errors on a traversal version (URL never built)")

  -- ensure_version / ensure_host_binary refuse BEFORE any fetch or rm: a victim
  -- dir OUTSIDE .nvim/cache survives (deletion-safety).
  local repo = sb .. "/repo"; paths.mkdirp(repo .. "/.nvim/cache")
  local victim = sb .. "/victim"; paths.mkdirp(victim)
  do local f = assert(io.open(victim .. "/keep.txt", "wb")); f:write("KEEP"); f:close() end
  uv.os_setenv("LOOMWORKS_RELEASE_URL", sb .. "/mirror")
  local d, e = update.ensure_version("../../victim",
    { root = repo, bundle_sha256 = string.rep("a", 64) })
  ok(d == nil and type(e) == "string", "ensure_version refuses a traversal version")
  ok(uv.fs_stat(victim .. "/keep.txt") ~= nil,
    "victim dir OUTSIDE .nvim/cache is untouched (no traversal rm)")
  local b, be = update.ensure_host_binary("x/../../evil", "lw-linux-x86_64",
    string.rep("a", 64), repo .. "/.nvim/cache/x")
  ok(b == nil and type(be) == "string", "ensure_host_binary refuses a traversal version")

  -- authoring refuses a bad version too
  ok(select(1, bootstrap.fetch_hashes("/../../evil")) == nil,
    "fetch_hashes refuses a bad version (no SHA256SUMS fetch)")

  paths.rm_rf(sb)
end

print("boot.paths — version_gt semver ordering (pre-releases below releases, §16.29)")
do
  ok(paths.version_gt("0.2.0", "0.2.0-beta.1"), "a full release > its pre-release")
  ok(not paths.version_gt("0.2.0-beta.1", "0.2.0"), "a pre-release < its release")
  ok(paths.version_gt("0.2.0-beta.2", "0.2.0-beta.1"), "beta.2 > beta.1 (numeric identifier)")
  ok(paths.version_gt("0.2.0-beta.10", "0.2.0-beta.2"), "beta.10 > beta.2 (numeric, not lexical)")
  ok(paths.version_gt("0.2.0-rc.1", "0.2.0-beta.1"), "rc > beta (lexical identifier)")
  ok(paths.version_gt("1.10.0", "1.9.0"), "1.10.0 > 1.9.0 (numeric core, not lexical)")
  ok(paths.version_gt("0.2.0", "0.1.9"), "a higher core wins")
  ok(not paths.version_gt("0.2.0", "0.2.0"), "equal is not strictly greater")
  ok(paths.version_gt("0.2.0", "0.2.0-rc.1+build.7"), "build metadata ignored; pre-release still lower")
end

print("boot.paths — installed_releases + gc rank pre-releases below releases")
do
  local sb = root .. "/tests/.tmp-relorder"; paths.rm_rf(sb); paths.mkdirp(sb)
  uv.os_setenv("LOCALAPPDATA", sb); uv.os_setenv("XDG_DATA_HOME", sb)
  for _, v in ipairs({ "0.1.0", "0.2.0-beta.1", "0.2.0" }) do
    paths.mkdirp(paths.data_dir() .. "/lua-" .. v)
  end
  local rels = paths.installed_releases()
  eq(rels[1] and rels[1].ver, "0.2.0", "newest = the full release")
  eq(rels[2] and rels[2].ver, "0.2.0-beta.1", "pre-release ranked directly below its release")
  eq(rels[3] and rels[3].ver, "0.1.0", "older release last")
  update.gc(1, nil)  -- keep only the single newest release
  ok(uv.fs_stat(paths.data_dir() .. "/lua-0.2.0"), "gc keeps the newest full release")
  ok(not uv.fs_stat(paths.data_dir() .. "/lua-0.2.0-beta.1"), "gc removes the pre-release below it")
  ok(not uv.fs_stat(paths.data_dir() .. "/lua-0.1.0"), "gc removes the older release")
  paths.rm_rf(sb)
end

print("boot.update — channel resolution precedence + validation (§16.29)")
do
  local sb = root .. "/tests/.tmp-channel"; paths.rm_rf(sb); paths.mkdirp(sb)
  -- Sandbox the CONFIG dir so read_config reads our file, not the user's.
  uv.os_setenv("APPDATA", sb); uv.os_setenv("XDG_CONFIG_HOME", sb)
  uv.os_setenv("LOOMWORKS_CHANNEL", "")  -- start unset
  local function put_cfg(body)
    paths.mkdirp((paths.config_file():gsub("/[^/]*$", "")))
    local f = assert(io.open(paths.config_file(), "wb")); f:write(body); f:close()
  end

  eq(update.resolve_channel({}), "stable", "default channel is stable")
  put_cfg('{"channel":"unstable"}')
  eq(update.resolve_channel({}), "unstable", "config `channel` is read")
  uv.os_setenv("LOOMWORKS_CHANNEL", "stable")
  eq(update.resolve_channel({}), "stable", "LOOMWORKS_CHANNEL overrides config")
  eq(update.resolve_channel({ channel = "unstable" }), "unstable", "opts.channel overrides env")

  uv.os_setenv("LOOMWORKS_CHANNEL", "")
  local c, e = update.resolve_channel({ channel = "bogus" })
  ok(c == nil and type(e) == "string" and e:find("unknown update channel", 1, true) ~= nil,
    "unknown channel rejected with a clear error")
  put_cfg('{"channel":"weird"}')
  ok(select(1, update.resolve_channel({})) == nil, "unknown channel from config rejected")
  paths.rm_rf(sb)
end

print("boot.update — unstable resolution picks newest non-draft (incl. pre-release)")
do
  local sb = root .. "/tests/.tmp-unstable"; paths.rm_rf(sb); paths.mkdirp(sb)
  local api = sb .. "/releases.json"
  local function put(p, body) local f = assert(io.open(p, "wb")); f:write(body); f:close() end
  -- Newest-first, as the API returns it: a draft on top must be skipped, and a
  -- pre-release IS eligible (that is what unstable means).
  put(api, '[{"draft":true,"tag_name":"v9.9.9"},'
    .. '{"draft":false,"prerelease":true,"tag_name":"v0.2.0-beta.1"},'
    .. '{"draft":false,"prerelease":false,"tag_name":"v0.2.0"}]')
  local saved = update.RELEASES_API_URL
  update.RELEASES_API_URL = api  -- bare path -> download.fetch reads it locally
  local ver, e = update.resolve_unstable_version()
  eq(ver, "0.2.0-beta.1",
    "newest NON-draft (pre-release included, draft skipped)" .. (e and (" — " .. e) or ""))

  put(api, '[{"draft":false,"tag_name":"v../../evil"}]')
  local bad, be = update.resolve_unstable_version()
  ok(bad == nil and type(be) == "string" and be:find("unsafe", 1, true) ~= nil,
    "a traversing/malformed API tag is rejected before any URL is built")

  put(api, '[]')
  ok(select(1, update.resolve_unstable_version()) == nil, "an empty release list is a clean error")

  update.RELEASES_API_URL = saved
  paths.rm_rf(sb)
end

print("boot.update — resolve_newest_version peeks a version without downloading a bundle (§16.31)")
do
  local sb = root .. "/tests/.tmp-newest"; paths.rm_rf(sb); paths.mkdirp(sb)
  uv.os_setenv("LOCALAPPDATA", sb); uv.os_setenv("XDG_DATA_HOME", sb)
  uv.os_setenv("APPDATA", sb); uv.os_setenv("XDG_CONFIG_HOME", sb)
  uv.os_setenv("LOOMWORKS_CHANNEL", "")
  uv.os_setenv("LOOMWORKS_RELEASE_URL", "")
  local function put(p, body) local f = assert(io.open(p, "wb")); f:write(body); f:close() end

  local savedOrigin, savedApi = update.DEFAULT_RELEASE_URL, update.RELEASES_API_URL
  update.DEFAULT_RELEASE_URL = (FX:gsub("/$", ""))  -- stable base = flat fixtures mirror

  -- stable: the version is whatever the base manifest.json names (no bundle fetch).
  eq(update.resolve_newest_version({}), "0.0.0-test",
    "stable resolves the manifest version without downloading the bundle")

  -- unstable: newest release the API names (pre-releases included), API reused.
  local api = sb .. "/releases.json"
  put(api, '[{"draft":false,"prerelease":true,"tag_name":"v0.3.0-rc.1"}]')
  update.RELEASES_API_URL = api
  eq(update.resolve_newest_version({ channel = "unstable" }), "0.3.0-rc.1",
    "unstable reuses the releases API (pre-release included)")

  -- a release-url override supersedes the channel: peek the mirror manifest,
  -- never the API (point the API at a missing file to prove it is untouched).
  update.RELEASES_API_URL = sb .. "/nonexistent.json"
  eq(update.resolve_newest_version({ channel = "unstable", url = (FX:gsub("/$", "")) }),
    "0.0.0-test", "an override peeks the mirror manifest, not the API")

  -- offline / missing manifest is a clean error (the caller degrades silently).
  update.DEFAULT_RELEASE_URL = sb .. "/no-such-mirror"
  ok(select(1, update.resolve_newest_version({})) == nil,
    "a missing manifest is a clean error, not a crash")

  update.DEFAULT_RELEASE_URL = savedOrigin
  update.RELEASES_API_URL = savedApi
  paths.rm_rf(sb)
end

print("boot.update — unstable self_update installs the API-named release + still verifies")
do
  local sb = root .. "/tests/.tmp-unstable-run"; paths.rm_rf(sb); paths.mkdirp(sb)
  uv.os_setenv("LOCALAPPDATA", sb); uv.os_setenv("XDG_DATA_HOME", sb)
  uv.os_setenv("APPDATA", sb); uv.os_setenv("XDG_CONFIG_HOME", sb)
  uv.os_setenv("LOOMWORKS_RELEASE_URL", "")  -- NO override, so the channel applies
  uv.os_setenv("LOOMWORKS_CHANNEL", "")
  local function put(p, body) local f = assert(io.open(p, "wb")); f:write(body); f:close() end

  -- Point the "default origin" at the local fixtures (a flat mirror) and the
  -- releases API at a local JSON naming the fixture version. versioned_base of a
  -- local base is flat, so the whole unstable path stays hermetic (no network).
  local api = sb .. "/releases.json"
  put(api, '[{"draft":false,"prerelease":true,"tag_name":"v0.0.0-test"}]')
  local savedOrigin, savedApi = update.DEFAULT_RELEASE_URL, update.RELEASES_API_URL
  update.DEFAULT_RELEASE_URL = (FX:gsub("/$", ""))
  update.RELEASES_API_URL = api

  local res, err = update.self_update({ channel = "unstable" })
  ok(res ~= nil, "unstable self_update installs" .. (err and (" — " .. err) or ""))
  if res then eq(res.version, "0.0.0-test", "installed the pre-release the API named") end
  -- No override here, so the channel genuinely applies — nothing to warn about.
  if res then eq(res.channel_overridden, nil,
    "unstable without an override does not flag an ignored channel") end

  -- Verification is NOT weakened on unstable: a tampered manifest still aborts.
  local good = readfile(FX .. "manifest.json")
  local badmirror = sb .. "/badmirror"; paths.mkdirp(badmirror)
  put(badmirror .. "/manifest.json", (good:gsub("0%.0%.0%-test", "6.6.6-evil")))
  put(badmirror .. "/manifest.json.sig", readfile(FX .. "manifest.json.sig"))
  update.DEFAULT_RELEASE_URL = badmirror
  local bad, berr = update.self_update({ channel = "unstable", force = true })
  ok(bad == nil and type(berr) == "string", "tampered unstable manifest rejected (signature)")

  update.DEFAULT_RELEASE_URL = savedOrigin
  update.RELEASES_API_URL = savedApi
  paths.rm_rf(sb)
end

print("boot.update — a release-url mirror override bypasses the channel (no API query)")
do
  local sb = root .. "/tests/.tmp-override"; paths.rm_rf(sb); paths.mkdirp(sb)
  uv.os_setenv("LOCALAPPDATA", sb); uv.os_setenv("XDG_DATA_HOME", sb)
  uv.os_setenv("APPDATA", sb); uv.os_setenv("XDG_CONFIG_HOME", sb)
  uv.os_setenv("LOOMWORKS_CHANNEL", "")
  -- Override points at the fixtures mirror; the API URL is a path that does NOT
  -- exist, so a (wrong) channel query would make the install fail loudly.
  uv.os_setenv("LOOMWORKS_RELEASE_URL", (FX:gsub("/$", "")))
  local savedApi = update.RELEASES_API_URL
  update.RELEASES_API_URL = sb .. "/nonexistent-releases.json"

  local res, err = update.self_update({ channel = "unstable" })
  ok(res ~= nil, "override + unstable installs from the mirror, API untouched" ..
    (err and (" — " .. err) or ""))
  if res then eq(res.version, "0.0.0-test", "version came from the mirror manifest, not the API") end
  -- The supersede is BY DESIGN (§16.29) but must be VISIBLE: the requested
  -- non-default channel was ignored, so self_update flags it for the CLI to warn.
  if res then eq(res.channel_overridden, "unstable",
    "self_update reports the requested --channel was superseded by the override") end

  -- Negative: stable channel + the same override is NO conflict (both resolve to
  -- the override), so there is nothing to warn about.
  local res2 = update.self_update({ channel = "stable", force = true })
  if res2 then eq(res2.channel_overridden, nil,
    "stable + override does not flag an ignored channel (no conflict)") end

  update.RELEASES_API_URL = savedApi
  uv.os_setenv("LOOMWORKS_RELEASE_URL", "")
  paths.rm_rf(sb)
end

print("boot.host_update — decide (who may self-replace, §16.32)")
do
  local hu = require("boot.host_update")
  local base = { exe = "/home/u/.local/bin/lw", target_version = "2.0.0" }
  local function with(t)
    local o = {}
    for k, v in pairs(base) do o[k] = v end
    for k, v in pairs(t) do o[k] = v end
    return o
  end
  eq(hu.decide(with({})), "swap", "unknown running version -> swap")
  eq(hu.decide(with({ running_version = "1.0.0" })), "swap", "older release -> swap")
  eq(hu.decide(with({ running_version = "2.0.0" })), "current", "same release -> no swap")
  -- Upgrade-only: a running host newer than the target is never downgraded
  -- (e.g. a channel switch unstable -> stable resolves an older release).
  local a_old, r_old = hu.decide(with({ running_version = "2.1.0" }))
  eq(a_old, "skip", "older target (channel switch) -> no downgrade")
  ok(r_old:find("2.1.0 is newer than 2.0.0; not downgrading", 1, true) ~= nil,
    "downgrade skip names both versions  (got " .. tostring(r_old) .. ")")
  eq(hu.decide(with({ running_version = "1.9.9" })), "swap", "newer target -> swap")
  -- Prerelease ordering is semver-aware: a beta orders below its release.
  eq(hu.decide(with({ running_version = "0.1.29-beta.7", target_version = "0.1.29" })), "swap",
    "0.1.29-beta.7 -> 0.1.29 is an upgrade")
  eq(hu.decide(with({ running_version = "0.1.29", target_version = "0.1.29-beta.7" })), "skip",
    "0.1.29 -> 0.1.29-beta.7 is a downgrade")
  eq(hu.decide(with({ running_version = "0.1.10", target_version = "0.1.9" })), "skip",
    "numeric core ordering (0.1.10 > 0.1.9)")
  eq(hu.decide(with({ no_host = true })), "skip", "--no-host -> skip")
  eq(hu.decide(with({ pinned = true })), "skip", "pinned context -> skip")
  eq(hu.decide(with({ exe = "/repo/.nvim/cache/lw-1.0.0-lw-linux-x86_64" })), "skip",
    "repo-local pinned launcher cache -> skip")
  eq(hu.decide(with({ exe = "C:\\repo\\.nvim\\cache\\lw-1.0.0-lw-windows-x86_64.exe" })), "skip",
    "pinned cache on Windows (backslashes) -> skip")
  eq(hu.decide(with({ exe = "C:/tools/luvi.exe" })), "skip", "bare luvi source run -> skip")
  eq(hu.decide(with({ dev = true })), "skip", "development source -> skip")
  eq(hu.decide(with({ fused_system_lua = true })), "skip", "dev build (fused system Lua) -> skip")
end

print("boot.host_update — update_host (signed SHA256SUMS, local mirror)")
do
  local hu = require("boot.host_update")
  local ossl = require("openssl")
  local priv = ossl.pkey.read(readfile(FX .. "test_ec_priv.pem"), true, "pem")
  local function put(p, body) local f = assert(io.open(p, "wb")); f:write(body); f:close() end
  local function exists(p) return uv.fs_stat(p) ~= nil end

  local sb = root .. "/tests/.tmp-hostupd"; paths.rm_rf(sb); paths.mkdirp(sb)
  local mirror = sb .. "/mirror"; paths.mkdirp(mirror)
  local bindir = sb .. "/bin"; paths.mkdirp(bindir)
  -- update_host forward-slashes the exe path; match it so the seams compare equal.
  local exe = (bindir .. "/lw"):gsub("\\", "/")
  local asset, ver = "lw-linux-x86_64", "2.0.0-test"
  local NEW, OLD = "NEW-HOST-BINARY\n", "OLD-HOST-BINARY\n"

  -- Stage a release in the (flat) mirror: the host asset + a signed hash list.
  -- `hash_body` lets a test publish a hash that does not match the asset. A
  -- real release's list always names its own version-bearing bundle
  -- (loomworks-lua-<ver>.zip); that line binds the list to the release.
  local function bundle_line(v)
    return verify.sha256_hex("bundle-" .. v) .. "  loomworks-lua-" .. v .. ".zip\n"
  end
  local function stage(opts)
    opts = opts or {}
    paths.rm_rf(mirror); paths.mkdirp(mirror)
    put(mirror .. "/" .. asset, opts.asset_body or NEW)
    local sums = opts.sums
      or (verify.sha256_hex(opts.hash_body or NEW) .. "  " .. asset .. "\n" .. bundle_line(ver))
    put(mirror .. "/SHA256SUMS", sums)
    put(mirror .. "/SHA256SUMS.sig", opts.sig or priv:sign(sums, "sha256"))
  end
  local function reset_exe() paths.rm_rf(exe .. ".old"); paths.rm_rf(exe .. ".new"); put(exe, OLD) end
  local function run(o)
    local t = { target_version = ver, exe = exe, asset = asset, url = mirror,
      sleep = function() end, attempts = 2 }
    for k, v in pairs(o or {}) do t[k] = v end
    return hu.update_host(t)
  end

  -- Unix happy path: atomic rename over the target.
  stage(); reset_exe()
  local r = run({ is_windows = false })
  eq(r.status, "replaced", "unix: host replaced" .. (r.status ~= "replaced" and (" — " .. tostring(r.message)) or ""))
  eq(slurp(exe), NEW, "unix: target now holds the verified new binary")
  ok(not exists(exe .. ".new") and not exists(exe .. ".old"), "unix: no staging leftovers")
  do  -- the default write probe (O_EXCL create + unlink) leaves nothing behind
    local names, req = {}, uv.fs_scandir(bindir)
    while req do
      local n = uv.fs_scandir_next(req)
      if not n then break end
      names[#names + 1] = n
    end
    eq(table.concat(names, ","), "lw", "write probe cleaned up (only the host remains)")
  end
  eq(r.from, nil, "unknown running version reported as nil")
  eq(r.to, ver, "reports the target release")

  -- Windows: the running exe cannot be overwritten, only renamed. Simulate that
  -- with a rename seam that refuses to replace an existing `exe`; the dance
  -- (exe -> exe.old, new -> exe) must still succeed.
  local function win_fs(extra)
    local fs = {
      rename = function(a, b)
        if b == exe and exists(exe) then return nil, "EPERM: running executable" end
        if extra and extra.rename then
          local okx, ex = extra.rename(a, b)
          if okx ~= nil or ex ~= nil then return okx, ex end
        end
        return uv.fs_rename(a, b)
      end,
      unlink = function(p) return uv.fs_unlink(p) end,
      exists = exists,
      writable = function() return true end,
    }
    return fs
  end
  stage(); reset_exe()
  local ru = run({ is_windows = false, fs = win_fs() })
  eq(ru.status, "warning", "a plain rename over a running exe fails (the Windows problem)")
  eq(slurp(exe), OLD, "…and leaves the original in place")
  ok(not exists(exe .. ".new"), "…and discards the staged binary")
  reset_exe()
  local rw = run({ is_windows = true, fs = win_fs() })
  eq(rw.status, "replaced", "windows: rename-aside dance replaces the running exe" ..
    (rw.status ~= "replaced" and (" — " .. tostring(rw.message)) or ""))
  eq(slurp(exe), NEW, "windows: new binary in place")
  eq(slurp(exe .. ".old"), OLD, "windows: running binary renamed aside to .old")
  -- .old cleanup at next startup (best-effort, silent)
  hu.cleanup_old(exe)
  ok(not exists(exe .. ".old"), "cleanup_old removes the leftover .old")
  hu.cleanup_old(exe)  -- nothing to remove: must not error
  ok(true, "cleanup_old is silent when there is no .old")
  hu.cleanup_old(exe, { unlink = function() error("locked") end })
  ok(true, "cleanup_old swallows an unlink failure")

  -- Windows: the second rename fails -> the first is rolled back.
  stage(); reset_exe()
  local rb = run({ is_windows = true, fs = win_fs({
    rename = function(a, b)
      if a == exe .. ".new" then return nil, "EACCES: simulated" end
    end,
  }) })
  eq(rb.status, "warning", "windows: failed move-into-place is a warning")
  eq(slurp(exe), OLD, "windows: rollback restores the original exe")
  ok(not exists(exe .. ".old"), "windows: no .old left after rollback")
  ok(not exists(exe .. ".new"), "windows: staged binary discarded after rollback")

  -- Windows: a leftover .old still in use blocks the swap cleanly.
  stage(); reset_exe(); put(exe .. ".old", "STUCK")
  local rs = run({ is_windows = true, fs = {
    rename = function(a, b) return uv.fs_rename(a, b) end,
    unlink = function() return nil, "EBUSY" end,
    exists = exists, writable = function() return true end,
  } })
  eq(rs.status, "warning", "windows: an in-use leftover .old aborts the swap")
  eq(slurp(exe), OLD, "…original untouched")
  paths.rm_rf(exe .. ".old")

  -- Integrity: a published hash that does not match the asset -> error, and the
  -- installed binary is never touched.
  stage({ hash_body = "SOMETHING-ELSE" }); reset_exe()
  local rv = run({ is_windows = false })
  eq(rv.status, "error", "hash mismatch is an integrity error")
  eq(slurp(exe), OLD, "hash mismatch leaves the original untouched")
  ok(not exists(exe .. ".new") and not exists(exe .. ".new.dl"), "hash mismatch discards the download")

  -- Integrity: a hash list signed by the wrong key -> error, nothing downloaded.
  stage({ sig = readfile(FX .. "manifest.json.sig") }); reset_exe()
  local rsig = run({ is_windows = false })
  eq(rsig.status, "error", "bad SHA256SUMS signature is an integrity error")
  eq(slurp(exe), OLD, "bad signature leaves the original untouched")

  -- Replay: a GENUINE signed list from an older release served for a newer
  -- target (its signature verifies, its host hash matches that older host)
  -- must be refused — the list does not name the target's own bundle.
  stage({ sums = verify.sha256_hex(NEW) .. "  " .. asset .. "\n" .. bundle_line("1.0.0") })
  reset_exe()
  local rr = run({ is_windows = false })
  eq(rr.status, "error", "replayed older signed SHA256SUMS is an integrity error")
  ok(tostring(rr.message):find("loomworks-lua-" .. ver .. ".zip", 1, true) ~= nil,
    "replay error names the missing release entry  (got " .. tostring(rr.message) .. ")")
  eq(slurp(exe), OLD, "replay: original untouched")
  ok(not exists(exe .. ".new"), "replay: nothing downloaded")

  -- Obtain failures (bundle update already succeeded) are warnings.
  stage({ sums = "abc123  some-other-asset\n" .. bundle_line(ver) }); reset_exe()
  eq(run({ is_windows = false }).status, "warning", "asset missing from the signed list -> warning")
  paths.rm_rf(mirror .. "/SHA256SUMS")
  eq(run({ is_windows = false }).status, "warning", "mirror without SHA256SUMS -> warning")
  eq(slurp(exe), OLD, "…original untouched")

  -- Unwritable install location -> warning with a manual command, no download.
  stage(); reset_exe()
  local rn = run({ is_windows = false, fs = {
    rename = function() error("must not rename") end,
    unlink = function(p) return uv.fs_unlink(p) end,
    exists = exists, writable = function() return false end,
  } })
  eq(rn.status, "warning", "unwritable location -> warning (exit 0)")
  ok(type(rn.manual) == "string" and rn.manual:find(asset, 1, true) ~= nil
    and rn.manual:find(ver, 1, true) ~= nil, "warning names the asset + release to fetch manually")
  eq(slurp(exe), OLD, "unwritable: original untouched")
  ok(not exists(exe .. ".new"), "unwritable: nothing downloaded")

  -- Same version -> no swap and no fetch (mirror points nowhere).
  reset_exe()
  local rc = run({ running_version = ver, url = sb .. "/nowhere" })
  eq(rc.status, "current", "same release -> current, nothing fetched")
  eq(slurp(exe), OLD, "same release: untouched")

  -- Older target (running host newer) -> skipped, nothing fetched or touched.
  reset_exe()
  local rd = run({ running_version = "9.0.0", url = sb .. "/nowhere" })
  eq(rd.status, "skipped", "older target -> skipped (no downgrade), nothing fetched")
  eq(slurp(exe), OLD, "no downgrade: untouched")

  -- --no-host / pinned / dev -> skipped without touching anything.
  eq(run({ no_host = true, url = sb .. "/nowhere" }).status, "skipped", "--no-host skips")
  eq(run({ pinned = true, url = sb .. "/nowhere" }).status, "skipped", "pinned context skips")
  eq(run({ dev = true, url = sb .. "/nowhere" }).status, "skipped", "dev source skips")
  eq(run({ fused_system_lua = true, url = sb .. "/nowhere" }).status, "skipped", "dev build skips")
  eq(slurp(exe), OLD, "skips leave the host untouched")

  -- Unsafe target version never reaches a URL or path.
  eq(run({ target_version = "../../evil" }).status, "error", "unsafe target version refused")

  paths.rm_rf(sb)
end

print("suggestions._host_facts — lw binary facts on the real luvi host (§16.31/§16.32)")
do
  -- Under the real luvi runtime the health update check must see a host (the
  -- nvim busted suite only ever sees `nil` — no luvi there). Running as bare
  -- `luvi tests/standalone` this is a source run: a dev build, never flagged.
  require("loomworks.shim")
  local facts = require("loomworks.suggestions")._host_facts()
  ok(type(facts) == "table", "_host_facts sees the luvi host")
  if type(facts) == "table" then
    eq(facts.self_update, true, "bootstrap has host self-update")
    eq(facts.dev_build, true, "bare luvi runtime is a dev build (shared predicate)")
    eq(facts.release_version, verify.RELEASE_VERSION, "release identity from boot.verify")
  end
end

print("environment inventory under the shim (§16.33)")
do
  -- The inventory's contributors must load in the standalone host: modules,
  -- SDK providers and the host-neutral LSP / DAP companions (the editor-only
  -- integration files are never required here).
  require("loomworks.shim")
  local saved_root = _G.__loomworks_luaroot
  _G.__loomworks_luaroot = root .. "/lua"
  local inv = require("loomworks.inventory")
  inv._contributors = nil
  local by = {}
  for _, c in ipairs(inv.contributors()) do by[c.kind .. ":" .. c.id] = c end
  for _, id in ipairs({ "clangd", "qmlls", "codelldb", "cppdbg", "pwa_node" }) do
    local c = by["integration:" .. id]
    ok(c ~= nil and c.rejected == nil, "companion " .. id .. " loads headlessly"
      .. (c and c.rejected and (" — " .. c.rejected) or ""))
  end
  ok(by["module:cmake"] ~= nil and by["module:cmake"].api ~= nil, "cmake module contributes")
  ok(package.loaded["loomworks.integrations.lsp.clangd"] == nil, "editor-only clangd integration not loaded")
  inv._contributors = nil
  _G.__loomworks_luaroot = saved_root

  -- vim.system honours `timeout` (the per-probe ceiling): the child is killed
  -- and reports 124, like nvim.
  local is_win = package.config:sub(1, 1) == "\\"
  local argv = is_win and { "ping", "-n", "30", "127.0.0.1" } or { "sleep", "30" }
  local t0 = uv.hrtime()
  local res = vim.system(argv, { text = true, timeout = 300 }):wait()
  local ms = (uv.hrtime() - t0) / 1e6
  eq(res.code, 124, "vim.system timeout kills the child (code 124)")

  -- A stale loop clock (the loop idle for a while, as after a workspace load)
  -- must not time every probe out at once.
  local spin = os.clock() + 0.6
  while os.clock() < spin do end
  local results = inv.probe_all({ {
    id = "slowish", category = "build tools", label = "slowish",
    probe = function(_, done)
      local t = uv.new_timer()
      t:start(100, 0, function() t:close(); done({ status = "found" }) end)
    end,
  } }, inv.context(nil, { timeout_ms = 400 }))
  eq(results[1] and results[1].status, "found", "probe timeout measured from now, not a stale loop clock")
  ok(ms >= 250 and ms < 10000, string.format("…promptly (%.0f ms)", ms))
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

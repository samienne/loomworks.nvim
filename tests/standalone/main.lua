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

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

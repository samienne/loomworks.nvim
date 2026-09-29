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

print("boot.verify — the committed source embeds the PRODUCTION release key")
do
  -- A source build (`make install`, `lw --dev`) used to embed the TEST key, so
  -- it could not verify a real release's SHA256SUMS: `lw bootstrap` / `update`
  -- failed with a bare "signature does not verify" (spec §16.12).
  local function body(pem) return (pem:gsub("\r", ""):gsub("%s+$", "")) end
  local prod = readfile(root .. "/keys/loomworks-release.pub.pem")
  eq(body(verify.PUBLIC_KEY_PEM), body(prod),
    "verify.PUBLIC_KEY_PEM is keys/loomworks-release.pub.pem")
  ok(body(verify.PUBLIC_KEY_PEM) ~= body(test_pub), "the embedded key is not the test key")
  eq(verify.key_id(prod), verify.RELEASE_KEY_ID, "RELEASE_KEY_ID is the production key's fingerprint")
  -- the README's copies (the out-of-band channel, §16.15) are the same key
  local readme = readfile(root .. "/README.md"):gsub("\r", "")
  local n, same = 0, 0
  for blk in readme:gmatch("%-%-%-%-%-BEGIN PUBLIC KEY%-%-%-%-%-.-%-%-%-%-%-END PUBLIC KEY%-%-%-%-%-") do
    n = n + 1; if blk == body(prod) then same = same + 1 end
  end
  ok(n > 0 and n == same, "every README public key block is the production key (" .. same .. "/" .. n .. ")")
  -- a failed check names the trusted key and the likely cause
  local _, perr = verify.verify_detached("data", readfile(FX .. "manifest.json.sig"))
  ok(perr and perr:find("does not verify", 1, true) and perr:find(verify.RELEASE_KEY_ID, 1, true)
    and perr:find("not an official loomworks release", 1, true),
    "production-key failure names the release key + likely causes  (" .. tostring(perr) .. ")")
  local _, terr = verify.verify_detached("data", readfile(FX .. "manifest.json.sig"), test_pub)
  ok(terr and terr:find("NOT the loomworks release key", 1, true)
    and terr:find(verify.key_id(test_pub), 1, true),
    "test-key failure says the host does not carry the release key  (" .. tostring(terr) .. ")")
end
-- Everything below verifies TEST-signed fixtures: supply the test key
-- explicitly for the rest of the suite (the embedded default is production).
verify.PUBLIC_KEY_PEM = test_pub

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
  -- The suite-level default is the test key (set above); also exercise the
  -- explicit-key path.
  local m, err = verify.load_manifest(manifest_bytes, sig)
  ok(m ~= nil, "valid manifest+sig loads (suite default key)" .. (err and (" — " .. err) or ""))
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
  -- `—` / `·` came out as mojibake in Windows consoles: the host prints this
  -- before system Lua sets the console encoding (spec §16.7).
  ok(line2:match("^[%w%p ]+$") ~= nil, "version line is ASCII  (got " .. line2 .. ")")
  ok(line2:find("pinned", 1, true) == nil, "no pin field outside pinned context")
  -- In pinned context the PIN decides what runs, not the channel setting: the
  -- beta.1 field test showed `channel: stable` for a repo pinned to a
  -- prerelease. The line names the pin, says prerelease, and drops the channel.
  local pline = update.version_line({ host_version = 1, release_version = "0.1.36-beta.1",
    source = "release", bundle = "0.1.36-beta.1" }, "stable",
    { file = "/repo/lw.pin", version = "0.1.36-beta.1" })
  ok(pline:find("| pinned: 0.1.36-beta.1 (prerelease) by /repo/lw.pin", 1, true) ~= nil,
    "pinned context: names the pinned version, prerelease, and the pin  (got " .. pline .. ")")
  ok(pline:find("channel", 1, true) == nil, "pinned context: no channel  (got " .. pline .. ")")
  local sline = update.version_line({ host_version = 1, release_version = "0.1.35",
    source = "release", bundle = "0.1.35" }, "unstable", { file = "/repo/lw.pin", version = "0.1.35" })
  ok(sline:find("| pinned: 0.1.35 by /repo/lw.pin", 1, true) ~= nil and not sline:find("prerelease", 1, true)
    and not sline:find("channel", 1, true), "a release pin: no prerelease mark, no channel  (got " .. sline .. ")")
  ok(paths.is_prerelease("0.1.36-beta.1") and paths.is_prerelease("1.0.0-rc.1+b")
    and not paths.is_prerelease("0.1.35") and not paths.is_prerelease("1.2.3+build.4"),
    "is_prerelease: a semver pre-release identifier (build metadata ignored)")

  -- A release host with NO bundle installed (and no system Lua fused in) used
  -- to claim "bundle: bundled (fused)" while every other command said "no
  -- loomworks release is installed". It must say there is none, and how to get it.
  local none = update.version_info(nil, nil, { fused_system_lua = false })
  eq(none.source, "none", "no bundle: source is none")
  local nline = update.version_line(none, "unstable")
  ok(nline:find("bundle: none installed (run `lw self-update`)", 1, true) ~= nil
    and nline:find("fused", 1, true) == nil,
    "no bundle: version line says none installed + self-update  (got " .. nline .. ")")
  local fz = update.version_info(nil, nil, { fused_system_lua = true, dev_build = true })
  eq(fz.source, "fused", "fused dev build: source is fused")
  eq(fz.bundle, "bundled (fused)", "fused dev build: bundle is bundled (fused)")

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
  local rjoined = table.concat(rep or {}, "\n")
  ok(rjoined:find("Run `lw self-update` when ready", 1, true) ~= nil,
    "--no-bundle on a release host: fetch the bundle later with self-update")
  -- `make install` fuses the whole tree and installs with --no-bundle: telling
  -- that build to "run lw self-update when ready" was wrong — self-update never
  -- replaces a development build, and a release bundle it installs takes
  -- precedence over the fused code.
  local drep = install.install({ exe_path = sb .. "/lw", dry_run = true, no_bundle = true,
    no_modify_path = true, fused_system_lua = true })
  local djoined = table.concat(drep or {}, "\n")
  ok(djoined:find("carries its own system Lua", 1, true) ~= nil
    and djoined:find("when ready", 1, true) == nil,
    "--no-bundle on a fused dev build: no self-update advice  (got " .. djoined .. ")")

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

print("boot.help — host-level help works without a bundle")
do
  -- `lw help` / `-h` / `--help` / `lw <cmd> --help` failed with "no loomworks
  -- release is installed" on a fresh release binary, so nobody could learn
  -- what `install` / `self-update` do. The host answers them itself.
  local hok, help = pcall(require, "boot.help")
  ok(hok, "boot.help loads")
  if hok then
    local HINT = "run `lw self-update`"
    local function t(args) return (help.for_args(args)) end
    for _, args in ipairs({ { "help" }, { "--help" }, { "-h" }, { "--no-input", "help" } }) do
      local s = t(args) or ""
      ok(s:find("self-update", 1, true) and s:find("install [-y]", 1, true)
        and s:find("version", 1, true) and s:find("bootstrap", 1, true)
        and s:find(HINT, 1, true),
        "`lw " .. table.concat(args, " ") .. "` prints host usage + the self-update hint")
    end
    local inst = t({ "install", "--help" }) or ""
    ok(inst:find("lw install [-y]", 1, true) and inst:find("--dry-run", 1, true)
      and inst:find("--no-bundle", 1, true),
      "`lw install --help` prints install's host help  (got " .. inst .. ")")
    -- A host command's help IS its full help (the CLI reuses it), so it carries
    -- no "full help needs the bundle" note — which confused pinned-launcher users.
    for _, cmd in ipairs({ "install", "self-update", "version", "bootstrap", "update" }) do
      local s = t({ "help", cmd }) or ""
      ok(s ~= "" and not s:find("Full help needs", 1, true) and not s:find("full help", 1, true),
        "`lw help " .. cmd .. "` is complete, with no bundle note")
      ok(s:match("^[%w%p%s]*$") ~= nil, "`lw help " .. cmd .. "` is ASCII")
    end
    local upd = t({ "help", "update" }) or ""
    ok(upd:find("deprecated", 1, true) and upd:find("lw bootstrap install --latest", 1, true)
      and upd:find("lw bootstrap install --version <x.y.z>", 1, true) and upd:find("--force", 1, true),
      "`lw help update` states the deprecation and the equivalent bootstrap forms")
    local bsi = t({ "help", "bootstrap", "install" }) or ""
    ok(bsi:find("lw bootstrap install", 1, true) and bsi:find("--pin-only", 1, true)
      and not bsi:find("Which launcher", 1, true) and bsi:find("`lw help bootstrap` for the whole command", 1, true),
      "`lw help bootstrap install` prints only the install part (no bundle needed)")
    local bsu = t({ "bootstrap", "upgrade", "--help" }) or ""
    ok(bsu:find("lw bootstrap upgrade", 1, true) and not bsu:find("--pin-only  ", 1, true),
      "`lw bootstrap upgrade --help` prints the upgrade part")
    local bs = t({ "help", "bootstrap" }) or ""
    ok(bs:find(".\\lw.cmd <cmd>", 1, true) and bs:find("Git Bash", 1, true)
      and bs:find(".gitattributes", 1, true), "`lw help bootstrap` says which launcher to use + the metadata")
    -- In a pinned repository, the note for a bundle command names the launcher.
    local pinned = help.for_args({ "build", "--help" }, { pinned = true }) or ""
    ok(pinned:find("./lw.sh help <command>", 1, true) and pinned:find(".\\lw.cmd help <command>", 1, true)
      and not pinned:find(HINT, 1, true),
      "pinned repo: the full-help note names the launcher, not self-update  (got " .. pinned .. ")")
    local su = t({ "help", "self-update" }) or ""
    ok(su:find("lw self-update [--force] [--channel", 1, true) and su:find("--no-host", 1, true),
      "`lw help self-update` prints self-update's host help")
    ok((t({ "version", "-h" }) or ""):find("lw version", 1, true),
      "`lw version -h` prints version's host help")
    ok((t({ "update", "--help" }) or ""):find("lw.pin", 1, true),
      "`lw update --help` prints update's host help")
    local other = t({ "build", "--help" }) or ""
    ok(other:find("`lw build`", 1, true) and other:find("install [-y]", 1, true)
      and other:find(HINT, 1, true),
      "`lw build --help` prints host usage, saying build needs the bundle  (got " .. other .. ")")
    ok(t({ "build" }) == nil, "no help requested -> nil")
    ok(t({}) == nil, "bare lw -> nil")
    ok(t({ "run", "app", "--", "--help" }) == nil, "--help after `--` belongs to the program")
  end
end

print("host-level output is ASCII (spec §16.7): no non-ASCII in host string literals")
do
  -- The host prints before system Lua sets the console encoding, so every
  -- string literal in main.lua and boot/*.lua (what the host can print) must be
  -- ASCII. Comments may use anything. A small Lua lexer: comments, quoted and
  -- long-bracket strings.
  local function string_literals(src)
    local out, i, n = {}, 1, #src
    while i <= n do
      local c = src:sub(i, i)
      if src:sub(i, i + 1) == "--" then
        local eq = src:match("^%-%-%[(=*)%[", i)
        if eq then
          local _, e = src:find("]" .. eq .. "]", i + 4 + #eq, true)
          i = (e or n) + 1
        else
          local e = src:find("\n", i, true)
          i = (e or n) + 1
        end
      elseif src:match("^%[=*%[", i) then
        local eq = src:match("^%[(=*)%[", i)
        local s0 = i + 2 + #eq
        local _, e = src:find("]" .. eq .. "]", s0, true)
        out[#out + 1] = src:sub(s0, (e or n) - 2 - #eq)
        i = (e or n) + 1
      elseif c == '"' or c == "'" then
        local j = i + 1
        while j <= n do
          local d = src:sub(j, j)
          if d == "\\" then j = j + 2
          elseif d == c or d == "\n" then break
          else j = j + 1 end
        end
        out[#out + 1] = src:sub(i + 1, j - 1)
        i = j + 1
      else
        i = i + 1
      end
    end
    return out
  end
  local files = { root .. "/lua/main.lua" }
  local h = uv.fs_scandir(root .. "/lua/boot")
  while h do
    local name = uv.fs_scandir_next(h)
    if not name then break end
    if name:match("%.lua$") then files[#files + 1] = root .. "/lua/boot/" .. name end
  end
  local bad = {}
  for _, f in ipairs(files) do
    for _, lit in ipairs(string_literals(readfile(f))) do
      if lit:find("[\128-\255]") then
        bad[#bad + 1] = f:match("[^/]+$") .. ": " .. lit:sub(1, 60)
      end
    end
  end
  ok(#files > 5 and #bad == 0, "host string literals are ASCII" ..
    (#bad > 0 and (" -- " .. table.concat(bad, " | ")) or ""))
end

print("boot.install — replacing an existing installed binary asks first")
do
  -- A downloaded (e.g. pre-release) lw run with `install` used to overwrite the
  -- installed one silently — here a dev build — with no word about what it
  -- replaced. It must describe what is there and ask; -y skips the question;
  -- non-interactive without -y refuses; identical content is "already installed".
  local sb = (root .. "/tests/.tmp-install-replace"):gsub("\\", "/")
  paths.rm_rf(sb); paths.mkdirp(sb)
  uv.os_setenv("LOCALAPPDATA", sb)
  uv.os_setenv("HOME", sb)
  local dest = install.target_path()
  local function put(p, bytes)
    paths.mkdirp(p:match("^(.*)/[^/]*$"))
    local f = assert(io.open(p, "wb")); f:write(bytes); f:close()
  end
  local function fused(files)  -- a fake fused host: junk "exe" + appended zip
    local w = miniz.new_writer()
    for name, body in pairs(files) do w:add(name, body) end
    return "MZ-not-really-an-exe" .. w:finalize()
  end
  local dev_bytes = fused({ ["loomworks/cli.lua"] = "return {}", ["boot/verify.lua"] = "M.RELEASE_VERSION = nil\n" })
  local new_bytes = fused({ ["boot/verify.lua"] = 'M.RELEASE_VERSION = "0.1.33-beta.3"\n' })
  local src = sb .. "/download/lw-new"
  put(src, new_bytes)
  local base = { exe_path = src, no_bundle = true, no_modify_path = true }
  local function with(extra)
    local o = {}
    for k, v in pairs(base) do o[k] = v end
    for k, v in pairs(extra) do o[k] = v end
    return o
  end

  -- describe_binary: cheap, never executes the file
  local d = install.describe_binary and install.describe_binary(dest) or nil
  ok(d == nil, "describe_binary: nil for a missing file")
  put(dest, dev_bytes)
  d = install.describe_binary and install.describe_binary(dest)
  ok(type(d) == "string" and d:find(#dev_bytes .. " bytes", 1, true) ~= nil
    and d:find("modified ", 1, true) ~= nil,
    "describe_binary: size + mtime  (got " .. tostring(d) .. ")")
  ok(type(d) == "string" and d:find("development build", 1, true) ~= nil,
    "describe_binary: recognises a dev build (fused system Lua)  (got " .. tostring(d) .. ")")
  local d2 = install.describe_binary and install.describe_binary(src)
  ok(type(d2) == "string" and d2:find("lw 0.1.33-beta.3", 1, true) ~= nil,
    "describe_binary: reads a release host's embedded version  (got " .. tostring(d2) .. ")")

  -- non-interactive without -y: refuse, leave the installed binary alone
  local asked = 0
  local function ask(answer) return function() asked = asked + 1; return answer end end
  local r, e = install.install(with({ no_input = true }))
  ok(r == nil and type(e) == "string" and e:find(dest, 1, true) ~= nil
    and e:find("-y", 1, true) ~= nil,
    "non-interactive replace without -y is refused, naming the target and -y  (got " .. tostring(e) .. ")")
  ok(readfile(dest) == dev_bytes, "refused install left the existing binary untouched")

  -- interactive: the question describes what is there; "no" cancels
  local question
  r, e = install.install(with({ ask = function(q) question = q; asked = asked + 1; return false end }))
  ok(asked == 1 and type(question) == "string" and question:find(dest, 1, true) ~= nil
    and question:find("development build", 1, true) ~= nil
    and question:find(#dev_bytes .. " bytes", 1, true) ~= nil,
    "asks before replacing, describing the existing binary  (got " .. tostring(question) .. ")")
  ok(r == nil and type(e) == "string" and e:find("cancelled", 1, true) ~= nil,
    "declining cancels the install  (got " .. tostring(e) .. ")")
  ok(readfile(dest) == dev_bytes, "declined install left the existing binary untouched")

  -- --dry-run describes, never asks, changes nothing
  asked = 0
  r = install.install(with({ dry_run = true, ask = ask(true) }))
  local joined = table.concat(r or {}, "\n")
  ok(asked == 0 and joined:find("would replace existing " .. dest, 1, true) ~= nil,
    "--dry-run reports the replacement without asking  (got " .. joined .. ")")
  ok(readfile(dest) == dev_bytes, "--dry-run changed nothing")

  -- "yes" replaces, and the report says what was replaced
  r, e = install.install(with({ ask = ask(true) }))
  joined = table.concat(r or {}, "\n")
  ok(e == nil and joined:find("replaced", 1, true) ~= nil,
    "confirmed install replaces and says so  (got " .. joined .. tostring(e) .. ")")
  ok(readfile(dest) == new_bytes, "confirmed install placed the new binary")

  -- identical content: already installed, no question even non-interactively
  asked = 0
  r, e = install.install(with({ no_input = true, ask = ask(false) }))
  joined = table.concat(r or {}, "\n")
  ok(e == nil and asked == 0 and joined:find("already installed", 1, true) ~= nil,
    "identical binary: already installed, nothing asked  (got " .. joined .. tostring(e) .. ")")

  -- -y skips the question, even non-interactively
  put(dest, dev_bytes)
  asked = 0
  r, e = install.install(with({ assume_yes = true, no_input = true, ask = ask(false) }))
  ok(e == nil and asked == 0, "-y replaces without asking  (got " .. tostring(e) .. ")")
  ok(readfile(dest) == new_bytes, "-y placed the new binary")

  -- fresh target: nothing to confirm
  paths.rm_rf(sb .. "/Microsoft"); paths.rm_rf(sb .. "/.local")
  asked = 0
  r, e = install.install(with({ no_input = true, ask = ask(false) }))
  ok(e == nil and asked == 0 and uv.fs_stat(dest) ~= nil,
    "a fresh install needs no confirmation  (got " .. tostring(e) .. ")")

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

print("boot.download — a fetch returns when curl exits, even with other live loop handles")
do
  -- Inside a workspace the CLI process keeps other handles alive (timers,
  -- watchers). The runner must pump until ITS process is done, not until the
  -- whole loop drains — or `lw health` hangs forever after the update check.
  -- A repeating timer stands in for them; it gives up after 5 s (so a
  -- regression fails here instead of hanging the suite).
  local t0, hung = uv.now(), false
  local t = uv.new_timer()
  t:start(100, 100, function()
    if uv.now() - t0 > 5000 then hung = true; t:stop(); t:close() end
  end)
  local code, out = download._run("curl", { "--version" })
  local elapsed = uv.now() - t0
  if not t:is_closing() then t:stop(); t:close() end
  uv.run("nowait")
  ok(not hung and elapsed < 5000, "runner returned while another handle was live (" .. elapsed .. " ms)")
  ok(code == 0 and type(out) == "string" and out:find("curl", 1, true) ~= nil,
    "the runner still collects curl's exit code and full stdout")
end

print("boot.download — per-call curl limits (the health update check's quick profile)")
do
  local saved_run, saved_delay = download._run, download.RETRY_DELAY_MS
  download.RETRY_DELAY_MS = 0
  local calls
  download._run = function(cmd, args)
    calls[#calls + 1] = table.concat(args, " ")
    return 28, "", "curl: (28) Connection timed out"
  end
  local function has(s, sub) return s:find(sub, 1, true) ~= nil end

  calls = {}
  local body, err = download.fetch("https://example.invalid/m.json",
    { connect_timeout = 5, max_time = 10, attempts = 1 })
  ok(body == nil and type(err) == "string", "a failed quick fetch returns nil, err")
  eq(#calls, 1, "quick fetch: a single attempt (no retry)")
  ok(has(calls[1], "--connect-timeout 5") and has(calls[1], "--max-time 10"),
    "quick fetch passes --connect-timeout/--max-time to curl")

  calls = {}
  download.fetch("https://example.invalid/m.json")
  eq(#calls, download.MAX_ATTEMPTS, "default fetch keeps retrying transient failures")
  ok(not has(calls[1], "--connect-timeout") and not has(calls[1], "--max-time"),
    "default fetch (self-update/install) adds no time limits")

  -- resolve_newest_version threads opts.fetch into the one fetch it makes, on
  -- both the stable manifest peek and the unstable releases-API query.
  uv.os_setenv("LOOMWORKS_RELEASE_URL", "")
  local saved_origin = update.DEFAULT_RELEASE_URL
  update.DEFAULT_RELEASE_URL = "https://example.invalid/releases/latest/download"
  local quick = { connect_timeout = 5, max_time = 10, attempts = 1 }
  calls = {}
  local v, ve = update.resolve_newest_version({ channel = "stable", fetch = quick })
  ok(v == nil and type(ve) == "string", "stable peek failure is nil, err")
  ok(#calls == 1 and has(calls[1], "--max-time 10"), "stable peek uses the caller's fetch limits")
  calls = {}
  update.resolve_newest_version({ channel = "unstable", fetch = quick })
  ok(#calls == 1 and has(calls[1], "--connect-timeout 5"), "unstable API query uses the caller's fetch limits")
  update.DEFAULT_RELEASE_URL = saved_origin

  download._run, download.RETRY_DELAY_MS = saved_run, saved_delay
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
  -- Plugin code (device runners, modules) runs under this shim too.
  eq(vim.pesc("a.b%c-d*e+f?g[h]^$(x)"), "a%.b%%c%-d%*e%+f%?g%[h%]%^%$%(x%)", "vim.pesc escapes pattern magic")
  eq(("x__LW_EXIT_n.1=3"):match(vim.pesc("__LW_EXIT_n.1") .. "=(%d+)$"), "3", "vim.pesc output is a literal pattern")
end

-- A throwaway git repository for tests of pin management's git steps. Its
-- config pins the Windows-like behaviour (no file-mode tracking) so the
-- index-only exec-bit path runs on every platform, and no autocrlf noise.
local function git(dir, ...)
  local code, out, err = require("boot.repo_meta")._git(dir, { ... })
  return code, out or "", err or ""
end
local function git_init(dir)
  paths.mkdirp(dir)
  git(dir, "init", "-q")
  git(dir, "config", "core.filemode", "false")
  git(dir, "config", "core.autocrlf", "false")
  git(dir, "config", "user.email", "t@example.com")
  git(dir, "config", "user.name", "t")
  git(dir, "config", "commit.gpgsign", "false")
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

print("boot.update — ensure_version (machine-local pinned bundle, flat mirror)")
do
  local sb = root .. "/tests/.tmp-ensure"; paths.rm_rf(sb); paths.mkdirp(sb)
  local mirror = sb .. "/mirror"; paths.mkdirp(mirror)
  local repo = sb .. "/repo"; paths.mkdirp(repo)
  local data = (sb .. "/data"):gsub("\\", "/")
  uv.os_setenv("LOOMWORKS_DATA_DIR", data)
  local ver = "7.7.7-test"
  local bundle = "loomworks-lua-" .. ver .. ".zip"
  do
    local w = miniz.new_writer()
    w:add("loomworks/cli.lua", "return 'verified'")
    local f = assert(io.open(mirror .. "/" .. bundle, "wb")); f:write(w:finalize()); f:close()
  end
  local bundle_sha = verify.sha256_hex(readfile(mirror .. "/" .. bundle))
  uv.os_setenv("LOOMWORKS_RELEASE_URL", mirror)

  eq(update.versioned_base(ver), mirror, "versioned_base(mirror) is flat")

  -- A repository-shipped "already provisioned" bundle (the old repo-local
  -- location) must never be trusted because it exists.
  paths.mkdirp(repo .. "/.nvim/cache/lua-" .. ver .. "/loomworks")
  do
    local f = assert(io.open(repo .. "/.nvim/cache/lua-" .. ver .. "/loomworks/cli.lua", "wb"))
    f:write("return 'planted'"); f:close()
  end

  local dir, err = update.ensure_version(ver, { root = repo, bundle_sha256 = bundle_sha })
  ok(dir ~= nil, "ensure_version provisions" .. (err and (" — " .. err) or ""))
  eq(dir, data .. "/pinned/" .. bundle_sha .. "/lua-" .. ver,
    "extracted to the machine-local <data>/pinned/<sha256>/lua-<ver>")
  ok(dir ~= nil and not dir:find(repo, 1, true), "never the repo-local .nvim/cache location")
  eq(slurp(dir .. "/loomworks/cli.lua"), "return 'verified'", "the verified bundle's content, not a planted one")
  eq(update.pinned_bundle_dir(ver, bundle_sha:upper()), dir, "pinned_bundle_dir keys by lower-case hash")

  -- Redirect guard for a pinned host that predates machine-local provisioning
  -- (it would load <pin root>/.nvim/cache/lua-<ver> when present).
  local legacy = repo .. "/.nvim/cache/lua-" .. ver
  ok(select(1, update.check_legacy_pinned_bundle(legacy, dir)) == nil,
    "legacy guard: a planted repo-local bundle is refused")
  ok(update.check_legacy_pinned_bundle(sb .. "/nope", dir) == true,
    "legacy guard: an absent repo-local bundle is fine")
  do
    local f = assert(io.open(legacy .. "/loomworks/cli.lua", "wb")); f:write("return 'verified'"); f:close()
  end
  ok(update.check_legacy_pinned_bundle(legacy, dir) == true,
    "legacy guard: a byte-identical repo-local bundle is fine")
  paths.mkdirp(legacy .. "/loomworks/modules")
  do
    local f = assert(io.open(legacy .. "/loomworks/modules/extra.lua", "wb")); f:write("return {}"); f:close()
  end
  ok(select(1, update.check_legacy_pinned_bundle(legacy, dir)) == nil,
    "legacy guard: an extra file in the repo-local bundle is refused")
  ok(uv.fs_stat(legacy .. "/loomworks/modules/extra.lua") ~= nil,
    "legacy guard never deletes repository files")

  -- idempotent: a second call reuses without touching the mirror
  uv.os_setenv("LOOMWORKS_RELEASE_URL", mirror .. "/gone")
  local dir2 = update.ensure_version(ver, { root = repo, bundle_sha256 = bundle_sha })
  eq(dir2, dir, "ensure_version idempotent (no refetch)")
  uv.os_setenv("LOOMWORKS_RELEASE_URL", mirror)

  -- hash mismatch aborts and leaves nothing behind; a different pinned hash
  -- never reuses the directory provisioned for another hash
  local other = string.rep("0", 64)
  local bad, berr = update.ensure_version(ver, { root = repo, bundle_sha256 = other })
  ok(bad == nil and type(berr) == "string", "bundle hash mismatch aborts")
  ok(not uv.fs_stat(update.pinned_bundle_dir(ver, other)), "a rejected provision leaves nothing behind")
  ok(select(1, update.ensure_version(ver, { bundle_sha256 = "abc" })) == nil,
    "refuses a pinned hash that is not a sha256")

  -- the redirect's host binary is cached machine-locally too
  local bp = update.pinned_binary_path("1.2.3", "lw-linux-x86_64")
  eq(bp, data .. "/pinned/lw-1.2.3-lw-linux-x86_64", "pinned host binary path is machine-local")

  uv.os_unsetenv("LOOMWORKS_DATA_DIR")
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
  -- Its own git repository: bootstrap stages lw.sh (exec bit), which must
  -- never reach the loomworks checkout the suite runs in.
  git_init(repo)
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

  local rep, berr = bootstrap.install(repo, { version = ver })
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
    ok(select(1, bootstrap.install(sb .. "/repo3", { version = ver })) == nil,
      "bootstrap errors when the release lacks a required asset")
    uv.os_setenv("LOOMWORKS_RELEASE_URL", mirror)
  end

  -- update repoints the pin at a new version
  local ver2 = "3.5.0-test"
  local exp2 = stage(ver2, "V2")
  local urep, uerr = bootstrap.install(repo, { version = ver2 })
  ok(urep ~= nil, "update rewrites the pin" .. (uerr and (" — " .. uerr) or ""))
  local p2 = pin.read(repo)
  eq(p2 and p2.version, ver2, "pin updated to the new version")
  eq(p2 and p2.hashes[pin.bundle_asset(ver2)], exp2[pin.bundle_asset(ver2)],
    "pin bundle hash updated")

  -- update to an unfetchable release fails cleanly, leaving the pin intact
  uv.os_setenv("LOOMWORKS_RELEASE_URL", sb .. "/nope")
  ok(select(1, bootstrap.install(repo, { version = "9.9.9-nope" })) == nil,
    "update to an unfetchable release fails cleanly")
  eq(pin.read(repo).version, ver2, "failed update leaves the pin intact")

  paths.rm_rf(sb)
end

print("boot.bootstrap — repository metadata, launcher generations, reporting, pruning (§16.24)")
do
  local bootstrap = require("boot.bootstrap")
  local launcher = require("boot.launcher")
  local repo_meta = require("boot.repo_meta")
  local pin = require("boot.pin")
  local ossl = require("openssl")
  local priv = ossl.pkey.read(readfile(FX .. "test_ec_priv.pem"), true, "pem")
  local function sign(data) return priv:sign(data, "sha256") end
  local function put(p, bytes)
    paths.mkdirp(p:match("^(.*)/[^/]*$"))
    local f = assert(io.open(p, "wb")); f:write(bytes); f:close()
  end
  local function has(lines, needle)
    for _, l in ipairs(lines or {}) do
      if l:find(needle, 1, true) then return true end
    end
    return false
  end
  local function show(lines) return table.concat(lines or {}, " | ") end

  local sb = root .. "/tests/.tmp-bsmeta"; paths.rm_rf(sb); paths.mkdirp(sb)
  local mirror = sb .. "/mirror"; paths.mkdirp(mirror)
  -- One flat mirror serving every staged version's hashes.
  local lines = {}
  local function stage(version)
    for _, a in ipairs({ "lw-linux-x86_64", "lw-macos-arm64", "lw-windows-x86_64.exe",
        pin.bundle_asset(version) }) do
      local body = version .. ":" .. a .. "\n"
      put(mirror .. "/" .. a, body)
      lines[#lines + 1] = verify.sha256_hex(body) .. "  " .. a
    end
    local sums = table.concat(lines, "\n") .. "\n"
    put(mirror .. "/SHA256SUMS", sums)
    put(mirror .. "/SHA256SUMS.sig", sign(sums))
  end
  uv.os_setenv("LOOMWORKS_RELEASE_URL", mirror)
  local V1, V2 = "1.0.0-test", "1.1.0-test"
  stage(V1)

  -- ---- bootstrap in a git repo (Windows-like: core.filemode=false) ---------
  local repo = sb .. "/repo"; git_init(repo)
  local rep, err = bootstrap.install(repo, { version = V1 })
  ok(rep ~= nil, "bootstrap succeeds" .. (err and (" — " .. err) or ""))
  ok(has(rep, "signature verified"), "bootstrap says the signed hash list was verified  (" .. show(rep) .. ")")
  ok(has(rep, "./lw.sh <cmd>") and has(rep, ".\\lw.cmd <cmd>"),
    "bootstrap output names ./lw.sh and .\\lw.cmd")
  local ga = slurp(repo .. "/.gitattributes") or ""
  ok(ga:find("lw.sh text eol=lf", 1, true) and ga:find("lw.cmd text eol=crlf", 1, true)
    and ga:find("lw.pin text eol=lf", 1, true), "bootstrap writes the three eol rules to .gitattributes")
  local _, stg = git(repo, "ls-files", "--stage", "--", "lw.sh", "lw.cmd", "lw.pin")
  local modes = launcher.parse_ls_stage(stg)
  eq(modes["lw.sh"], "100755", "bootstrap stages lw.sh as executable (index-only exec bit)")
  ok(modes["lw.cmd"] == nil and modes["lw.pin"] == nil, "lw.cmd and lw.pin are NOT staged")
  ok(has(rep, "staged lw.sh as executable"), "the staging is reported")
  local _, attr = git(repo, "check-attr", "text", "eol", "--", "lw.sh", "lw.cmd", "lw.pin")
  local a = launcher.parse_check_attr(attr)
  ok(launcher.attrs_ok("lw.sh", a["lw.sh"]) and launcher.attrs_ok("lw.cmd", a["lw.cmd"])
    and launcher.attrs_ok("lw.pin", a["lw.pin"]), "git sees the effective eol attributes")

  -- a re-run appends nothing (idempotent) and reports no metadata change
  local ga_before, gi_before = slurp(repo .. "/.gitattributes"), slurp(repo .. "/.gitignore")
  local rep2 = bootstrap.install(repo, { version = V1 })
  eq(slurp(repo .. "/.gitattributes"), ga_before, "re-bootstrap leaves .gitattributes alone")
  eq(slurp(repo .. "/.gitignore"), gi_before, "re-bootstrap leaves .gitignore alone")
  ok(rep2 and has(rep2, "lw.pin already at " .. V1) and not has(rep2, "wrote lw.sh"),
    "re-bootstrap reports nothing rewritten  (" .. show(rep2) .. ")")

  -- ---- update: change-only reporting ---------------------------------------
  local noop = bootstrap.install(repo, { version = V1 })
  ok(noop and #noop == 1 and noop[1]:find("already at " .. V1 .. " - no changes", 1, true)
    and noop[1]:find("signature verified", 1, true),
    "a no-op update says 'already at X - no changes' and nothing else  (" .. show(noop) .. ")")
  stage(V2)
  local up = bootstrap.install(repo, { version = V2 })
  ok(up and up[1] == "lw.pin: " .. V1 .. " -> " .. V2 ..
    "; hashes from the signed SHA256SUMS, signature verified",
    "a moved pin reports old -> new + signature verified  (" .. show(up) .. ")")
  ok(not has(up, "refreshed") and not has(up, "wrote lw"),
    "unchanged launchers are not reported as refreshed")
  ok(up and up[1]:match("^[%w%p ]+$") ~= nil, "update output is ASCII")
  -- No nested parentheses in any report line (beta.1 had "(... (signature verified))").
  for _, l in ipairs(up or {}) do
    ok(not l:find("%([^)]*%("), "no nested parentheses: " .. l)
  end
  -- A run that moves nothing but still changes something (here: a launcher
  -- rewritten) leads with the same "already at" wording as a no-op.
  put(repo .. "/lw.sh", (launcher.render("sh"):gsub("\n", "\r\n")))
  local same = bootstrap.install(repo, { version = V2 })
  ok(same and same[1] == "lw.pin already at " .. V2 .. "; hashes from the signed SHA256SUMS, signature verified",
    "pin unchanged + other changes: the same 'already at' line  (" .. show(same) .. ")")
  local hint = bootstrap.install(repo, { version = V1, self_version = "1.0.0-test" })
  ok(hint and not has(hint, "once more"), "no older-host hint when the host is the target")
  local hint2 = bootstrap.install(repo, { version = V2, self_version = "1.0.0-test" })
  ok(hint2 and has(hint2, "once more to take " .. V2),
    "an older host moving the pin says to run the update once more  (" .. show(hint2) .. ")")

  -- ---- launcher generations -------------------------------------------------
  -- a known earlier generation is refreshed and says which one it was
  local old_cmd = "@echo off\r\nrem an old launcher\r\n"
  launcher.GENERATIONS.cmd[verify.sha256_hex(launcher.normalize(old_cmd))] =
    { gen = 0, releases = "9.9-test", defects = { { severity = "breaks", text = "x" } } }
  put(repo .. "/lw.cmd", old_cmd)
  local r1 = bootstrap.install(repo, { version = V2 })
  ok(has(r1, "refreshed lw.cmd: replaced the launcher written by lw 9.9-test"),
    "a known generation is refreshed  (" .. show(r1) .. ")")
  eq(slurp(repo .. "/lw.cmd"), launcher.render("cmd"), "lw.cmd rewritten to the current template")
  -- content that is no known generation is kept unless --force
  put(repo .. "/lw.sh", "#!/bin/sh\necho my own launcher\n")
  local r2 = bootstrap.install(repo, { version = V2 })
  ok(has(r2, "kept lw.sh") and has(r2, "--force"), "an unknown lw.sh is kept, naming --force  (" .. show(r2) .. ")")
  eq(slurp(repo .. "/lw.sh"), "#!/bin/sh\necho my own launcher\n", "the hand-edited lw.sh is untouched")
  local r3 = bootstrap.install(repo, { version = V2, force = true })
  ok(has(r3, "replaced lw.sh (--force)"), "--force replaces it")
  eq(slurp(repo .. "/lw.sh"), launcher.render("sh"), "lw.sh is the current template again")
  -- the current template with CRLF endings is rewritten with LF
  put(repo .. "/lw.sh", (launcher.render("sh"):gsub("\n", "\r\n")))
  local r4 = bootstrap.install(repo, { version = V2 })
  ok(has(r4, "rewrote lw.sh with LF line endings"), "a CRLF lw.sh is rewritten with LF  (" .. show(r4) .. ")")
  ok(not (slurp(repo .. "/lw.sh") or ""):find("\r", 1, true), "lw.sh is LF again")
  -- an lw.pin checked out with CR LF (lw.sh's sed would read `version = x\r`)
  put(repo .. "/lw.pin", (slurp(repo .. "/lw.pin"):gsub("\n", "\r\n")))
  local r5 = bootstrap.install(repo, { version = V2 })
  ok(has(r5, "rewrote lw.pin with LF line endings") and not has(r5, "hashes updated"),
    "a CRLF lw.pin is rewritten with LF  (" .. show(r5) .. ")")
  ok(not (slurp(repo .. "/lw.pin") or ""):find("\r", 1, true), "lw.pin is LF again")
  -- classify
  eq(launcher.classify("sh", launcher.LW_SH, verify.sha256_hex).status, "current", "classify: current")
  local c1 = launcher.classify("cmd", "x", verify.sha256_hex)
  eq(c1.status, "unknown", "classify: unknown content")

  -- ---- exec bit on a TRACKED lw.sh committed without it ---------------------
  do
    local r = sb .. "/tracked"; git_init(r)
    put(r .. "/lw.sh", launcher.render("sh"))
    git(r, "add", "--", "lw.sh"); git(r, "commit", "-q", "-m", "x")
    local _, s0 = git(r, "ls-files", "--stage", "--", "lw.sh")
    eq(launcher.parse_ls_stage(s0)["lw.sh"], "100644", "(setup) lw.sh committed as 100644")
    local rr = bootstrap.install(r, { version = V2 })
    local _, s1 = git(r, "ls-files", "--stage", "--", "lw.sh")
    eq(launcher.parse_ls_stage(s1)["lw.sh"], "100755", "bootstrap sets +x on a tracked 100644 lw.sh")
    ok(has(rr, "set lw.sh executable in the git index"), "and reports it  (" .. show(rr) .. ")")
  end

  -- ---- .gitignore coverage: committed rules count, personal ones do not -----
  do
    local r = sb .. "/ign1"; git_init(r)
    put(r .. "/.gitignore", "/.nvim/**\n")
    bootstrap.install(r, { version = V2 })
    eq(slurp(r .. "/.gitignore"), "/.nvim/**\n",
      "a committed rule already ignoring .nvim/ (any form git accepts) -> nothing appended")

    local r2 = sb .. "/ign2"; git_init(r2)
    put(r2 .. "/.git/info/exclude", ".nvim/\n")
    local excl = sb .. "/personal-excludes"; put(excl, ".nvim/\n")
    git(r2, "config", "core.excludesFile", excl)
    local rr = bootstrap.install(r2, { version = V2 })
    ok((slurp(r2 .. "/.gitignore") or ""):find(".nvim/cache/", 1, true) ~= nil,
      "an ignore rule only in info/exclude or core.excludesFile does not count -> appended")
    ok(has(rr, "added .nvim/cache/ to .gitignore"), "the append is reported")

    local r3 = sb .. "/ign3"; git_init(r3)
    put(r3 .. "/.gitattributes", "*.sh text eol=lf\n*.cmd text eol=crlf\n*.pin text eol=lf\n")
    local rr3 = bootstrap.install(r3, { version = V2 })
    eq(slurp(r3 .. "/.gitattributes"), "*.sh text eol=lf\n*.cmd text eol=crlf\n*.pin text eol=lf\n",
      "equivalent pattern rules satisfy the attributes check -> nothing appended")
    ok(not has(rr3, "line-ending rules"), "nothing reported for attributes  (" .. show(rr3) .. ")")
  end

  -- ---- appends match the file's line endings; no duplicate header (beta.1) ---
  do
    local function bare_lf(s) return (s:gsub("\r\n", "")):find("\n", 1, true) ~= nil end
    -- core.autocrlf=true checkout: .gitattributes is CRLF in the working copy
    -- and already has the repo's own comment + two of the three rules.
    local r = sb .. "/crlf"; git_init(r); git(r, "config", "core.autocrlf", "true")
    local ga0 = "# launchers need fixed line endings\r\nlw.sh text eol=lf\r\nlw.cmd text eol=crlf\r\n" ..
      "\r\n# other\r\n*.png binary\r\n"
    put(r .. "/.gitattributes", ga0)
    put(r .. "/.gitignore", "build/\r\n")
    local rr = bootstrap.install(r, { version = V2 })
    local ga = slurp(r .. "/.gitattributes") or ""
    ok(not bare_lf(ga), "a CRLF .gitattributes stays CRLF (no mixed endings)  (" .. ga:gsub("\r", "\\r"):gsub("\n", "\\n") .. ")")
    eq(ga, "# launchers need fixed line endings\r\nlw.sh text eol=lf\r\nlw.cmd text eol=crlf\r\n" ..
      "lw.pin text eol=lf\r\n\r\n# other\r\n*.png binary\r\n",
      "the missing rule goes right after the last launcher rule, with no second header")
    ok(has(rr, "lw.pin to .gitattributes"), "the added rule is reported  (" .. show(rr) .. ")")
    local gi = slurp(r .. "/.gitignore") or ""
    ok(not bare_lf(gi) and gi:find(".nvim/cache/\r\n", 1, true) ~= nil,
      "a CRLF .gitignore gets a CRLF append  (" .. gi:gsub("\r", "\\r"):gsub("\n", "\\n") .. ")")

    -- A NEW file follows what git would check out: CRLF under autocrlf=true …
    local r2 = sb .. "/crlf-new"; git_init(r2); git(r2, "config", "core.autocrlf", "true")
    bootstrap.install(r2, { version = V2 })
    local ga2 = slurp(r2 .. "/.gitattributes") or ""
    ok(ga2:find("lw.sh text eol=lf\r\n", 1, true) and not bare_lf(ga2),
      "a new .gitattributes is CRLF when git checks text out as CRLF")
    ok(select(2, ga2:gsub("# loomworks:", "")) == 1, "a new file gets exactly one header")
    local gi2 = slurp(r2 .. "/.gitignore") or ""
    ok(gi2 ~= "" and not bare_lf(gi2), "a new .gitignore is CRLF too")
    -- … and LF otherwise.
    local r3 = sb .. "/lf-new"; git_init(r3)
    bootstrap.install(r3, { version = V2 })
    local ga3 = slurp(r3 .. "/.gitattributes") or ""
    ok(ga3 ~= "" and not ga3:find("\r", 1, true), "a new .gitattributes is LF when git keeps LF")
    -- An LF file with none of the rules gets the header + all three, LF.
    local r4 = sb .. "/lf-none"; git_init(r4); git(r4, "config", "core.autocrlf", "true")
    put(r4 .. "/.gitattributes", "*.png binary\n")
    bootstrap.install(r4, { version = V2 })
    eq(slurp(r4 .. "/.gitattributes"), "*.png binary\n\n# loomworks: repo-local launcher line endings\n" ..
      "lw.sh text eol=lf\nlw.cmd text eol=crlf\nlw.pin text eol=lf\n",
      "an LF file stays LF even under autocrlf; the first rules bring the header")
  end

  -- ---- no git: textual fallbacks, no staging --------------------------------
  do
    local saved = repo_meta._git
    repo_meta._git = function() return nil, "git not found" end
    local r = sb .. "/nogit"; paths.mkdirp(r)
    put(r .. "/.gitignore", ".nvim/\n")
    local rr, e = bootstrap.install(r, { version = V2 })
    repo_meta._git = saved
    ok(rr ~= nil, "bootstrap works without git" .. (e and (" — " .. e) or ""))
    eq(slurp(r .. "/.gitignore"), ".nvim/\n", "without git, a `.nvim/` line covers the cache -> nothing appended")
    ok((slurp(r .. "/.gitattributes") or ""):find("lw.cmd text eol=crlf", 1, true) ~= nil,
      "without git, the attribute rules are still written")
    ok(not has(rr, "staged"), "without git, nothing is staged")
  end

  -- ---- pruning the launcher cache --------------------------------------------
  do
    local cache = repo .. "/.nvim/cache"
    local old = cache .. "/lw-" .. V1 .. "-lw-linux-x86_64"
    local old_win = cache .. "/lw-0.9.0-lw-windows-x86_64.exe"
    local keep = cache .. "/lw-" .. V2 .. "-lw-linux-x86_64"
    local running = cache .. "/lw-0.8.0-lw-macos-arm64"
    put(old, "old"); put(old_win, "oldw"); put(keep, "keep"); put(running, "run")
    put(cache .. "/lw.marker", "m")
    put(cache .. "/lw-0.7.0-lw-bogus-asset", "b")           -- unknown asset
    put(cache .. "/lw-0.6.0-lw-linux-x86_64.dl.123", "p")    -- partial download
    paths.mkdirp(cache .. "/lw-0.5.0-lw-linux-x86_64")       -- a directory
    put(cache .. "/lw-0.5.0-lw-linux-x86_64/inner", "i")
    local outside = sb .. "/outside-lw-0.4.0-lw-linux-x86_64"; put(outside, "o")
    local rr = bootstrap.install(repo, { version = V2, running_exe = running })
    ok(has(rr, "removed 2 old pinned lw binaries"), "prune reports what it removed  (" .. show(rr) .. ")")
    ok(not uv.fs_stat(old) and not uv.fs_stat(old_win), "older cached binaries removed")
    ok(uv.fs_stat(keep) ~= nil, "the pinned version's binary is kept")
    ok(uv.fs_stat(running) ~= nil, "the running executable is never pruned")
    ok(uv.fs_stat(cache .. "/lw.marker") and uv.fs_stat(cache .. "/lw-0.7.0-lw-bogus-asset")
      and uv.fs_stat(cache .. "/lw-0.6.0-lw-linux-x86_64.dl.123")
      and uv.fs_stat(cache .. "/lw-0.5.0-lw-linux-x86_64/inner") and uv.fs_stat(outside),
      "only exact cached-binary names that are regular files are candidates")
    -- a no-op update still prunes (a binary busy last time is collected later)
    put(old, "old")
    local rn = bootstrap.install(repo, { version = V2, running_exe = running })
    ok(not uv.fs_stat(old) and has(rn, "removed 1 old pinned lw binary"),
      "a no-op update prunes too  (" .. show(rn) .. ")")

    -- a cache dir that is a link/junction out of the repo is never pruned
    local r = sb .. "/linked"; paths.mkdirp(r .. "/.nvim")
    local target = sb .. "/elsewhere"; put(target .. "/lw-0.1.0-lw-linux-x86_64", "t")
    local okl = uv.fs_symlink(target, r .. "/.nvim/cache", { junction = true, dir = true })
    if okl then
      local n = repo_meta.prune_cache(r, V2, nil)
      eq(n, 0, "prune refuses a linked cache dir")
      ok(uv.fs_stat(target .. "/lw-0.1.0-lw-linux-x86_64") ~= nil, "nothing outside the repo removed")
    else
      ok(true, "(symlink/junction not creatable here; linked-cache check skipped)")
    end
    eq(repo_meta.prune_cache(nil, V2), 0, "prune with a nil root does nothing")
    eq(repo_meta.prune_cache(sb .. "/does-not-exist", V2), 0, "prune without a cache dir does nothing")
  end

  -- cached_binary_version (the name rule)
  local assets = {}
  for _, a2 in pairs(pin.HOST_ASSETS) do assets[#assets + 1] = a2 end
  eq(launcher.cached_binary_version("lw-0.1.33-beta.3-lw-linux-x86_64", assets, pin.valid_version),
    "0.1.33-beta.3", "cached name with a pre-release version")
  eq(launcher.cached_binary_version("lw-..-lw-linux-x86_64", assets, pin.valid_version), nil,
    "an unsafe version in a cached name is not a candidate")
  eq(launcher.cached_binary_version("lw-1.0.0-lw-linux-x86_64.dl.9", assets, pin.valid_version), nil,
    "a partial download is not a candidate")

  paths.rm_rf(sb)
end

print("boot.bootstrap — install converge, version selection, --pin-only, status page, aliases (§16.24)")
do
  local bootstrap = require("boot.bootstrap")
  local launcher = require("boot.launcher")
  local check = require("boot.launcher_check")
  local pin = require("boot.pin")
  local ossl = require("openssl")
  local priv = ossl.pkey.read(readfile(FX .. "test_ec_priv.pem"), true, "pem")
  local function sign(data) return priv:sign(data, "sha256") end
  local function put(p, bytes)
    paths.mkdirp(p:match("^(.*)/[^/]*$"))
    local f = assert(io.open(p, "wb")); f:write(bytes); f:close()
  end
  local function has(lines, needle)
    for _, l in ipairs(lines or {}) do
      if l:find(needle, 1, true) then return true end
    end
    return false
  end
  local function show(lines) return table.concat(lines or {}, " | ") end

  local sb = root .. "/tests/.tmp-bscmds"; paths.rm_rf(sb); paths.mkdirp(sb)
  local mirror = sb .. "/mirror"; paths.mkdirp(mirror)
  local lines = {}
  local function stage(version)
    for _, a in ipairs({ "lw-linux-x86_64", "lw-macos-arm64", "lw-windows-x86_64.exe",
        pin.bundle_asset(version) }) do
      local body = version .. ":" .. a .. "\n"
      put(mirror .. "/" .. a, body)
      lines[#lines + 1] = verify.sha256_hex(body) .. "  " .. a
    end
    local sums = table.concat(lines, "\n") .. "\n"
    put(mirror .. "/SHA256SUMS", sums)
    put(mirror .. "/SHA256SUMS.sig", sign(sums))
  end
  uv.os_setenv("LOOMWORKS_RELEASE_URL", mirror)
  local V1, V2, V3 = "2.0.0-test", "2.1.0-test", "2.2.0-beta.1"
  stage(V1); stage(V2); stage(V3)
  local function newest_is(v, seen)
    return function(o) if seen then seen[#seen + 1] = o end return v end
  end

  -- ---- BUG: plain `lw bootstrap` re-pinned to the running host's version ------
  do
    local r = sb .. "/keep"; git_init(r)
    ok(bootstrap.install(r, { version = V1 }) ~= nil, "(setup) pinned at " .. V1)
    local rep = bootstrap.install(r, { host_version = V2 })
    eq(pin.read(r).version, V1, "plain install in a pinned repo keeps the pin (a newer host never bumps it)")
    ok(rep and rep[1]:find("lw.pin already at " .. V1, 1, true), "and says so  (" .. show(rep) .. ")")
    -- --version is the explicit way
    bootstrap.install(r, { version = V2 })
    eq(pin.read(r).version, V2, "--version moves the pin")
  end

  -- ---- BUG: `lw update` read only the stable base, ignoring the channel -------
  do
    local r = sb .. "/latest"; git_init(r)
    bootstrap.install(r, { version = V1 })
    local seen = {}
    local rep, err = bootstrap.install(r, { latest = true, channel = "unstable",
      resolve_newest = newest_is(V3, seen) })
    ok(rep ~= nil, "--latest succeeds" .. (err and (" - " .. err) or ""))
    eq(seen[1] and seen[1].channel, "unstable", "--latest resolves the newest release on the requested channel")
    eq(pin.read(r).version, V3, "--latest pins the channel's newest")
    -- the channel setting / environment is honoured too (no --channel)
    uv.os_setenv("LOOMWORKS_CHANNEL", "unstable")
    local seen2 = {}
    bootstrap.install(r, { latest = true, resolve_newest = newest_is(V3, seen2) })
    uv.os_unsetenv("LOOMWORKS_CHANNEL")
    eq(seen2[1] and seen2[1].channel, "unstable", "--latest follows LOOMWORKS_CHANNEL")
    -- never backwards: the pin (a pre-release newer than stable) is kept
    local back = bootstrap.install(r, { latest = true, channel = "stable", resolve_newest = newest_is(V2) })
    eq(pin.read(r).version, V3, "--latest never moves the pin backwards")
    ok(has(back, "is newer than the newest stable release " .. V2) and has(back, "--version"),
      "and names --version for a deliberate downgrade  (" .. show(back) .. ")")
    local e1 = select(2, bootstrap.install(r, { latest = true, channel = "nightly" }))
    ok(e1 and e1:find("nightly", 1, true), "an unknown channel is an error  (" .. tostring(e1) .. ")")
  end

  -- ---- version selection without a pin ---------------------------------------
  do
    local r = sb .. "/fresh"; git_init(r)
    local _, e = bootstrap.install(r, {})
    ok(e and e:find("--version", 1, true) and e:find("--latest", 1, true),
      "a dev build with no pin refuses, naming --version and --latest  (" .. tostring(e) .. ")")
    ok(not uv.fs_stat(r .. "/lw.pin"), "and writes nothing")
    local rep = bootstrap.install(r, { host_version = V1 })
    eq(pin.read(r).version, V1, "no pin: the running host's release version")
    ok(has(rep, "wrote lw.pin: version " .. V1) and has(rep, "Check it any time with `lw bootstrap`"),
      "first install closes with how to run + check  (" .. show(rep) .. ")")
    local again = bootstrap.install(r, { host_version = V1 })
    ok(again and #again == 1 and again[1]:find("- no changes", 1, true), "a second run changes nothing")
  end

  -- ---- converge from a broken state -------------------------------------------
  do
    local r = sb .. "/broken"; git_init(r)
    bootstrap.install(r, { version = V1 })
    -- drop a hash, delete lw.cmd, strip the attributes
    local t = slurp(r .. "/lw.pin"):gsub("[^\n]*lw%-macos%-arm64[^\n]*\n", "")
    put(r .. "/lw.pin", t)
    os.remove(r .. "/lw.cmd")
    put(r .. "/.gitattributes", "")
    local rep = bootstrap.install(r, {})
    eq(pin.read(r).version, V1, "repair keeps the version")
    ok(pin.read(r).hashes["lw-macos-arm64"] ~= nil, "the missing hash is restored")
    ok(uv.fs_stat(r .. "/lw.cmd") ~= nil, "the missing launcher is written")
    ok((slurp(r .. "/.gitattributes") or ""):find("lw.cmd text eol=crlf", 1, true), "the rules are back")
    ok(has(rep, "lw.pin: " .. V1 .. " hashes updated") and has(rep, "wrote lw.cmd"),
      "and reports it  (" .. show(rep) .. ")")
  end

  -- ---- --pin-only ---------------------------------------------------------------
  do
    local r = sb .. "/pinonly"; git_init(r)
    local rep = bootstrap.install(r, { version = V1, pin_only = true })
    ok(uv.fs_stat(r .. "/lw.pin") and not uv.fs_stat(r .. "/lw.sh") and not uv.fs_stat(r .. "/lw.cmd"),
      "--pin-only writes lw.pin and no launcher")
    eq(slurp(r .. "/.gitattributes"), "# loomworks: repo-local launcher line endings\nlw.pin text eol=lf\n",
      "--pin-only adds only lw.pin's attribute rule")
    ok(not uv.fs_stat(r .. "/.gitignore"), "--pin-only adds no ignore rule")
    local _, stg = git(r, "ls-files", "--stage")
    eq(stg, "", "--pin-only stages nothing")
    ok(has(rep, "globally installed lw runs the pinned release"), "and explains how a pin-only repo runs  (" .. show(rep) .. ")")
    -- the checks treat the absent launchers as intended
    local res = check.run_checks(r, { git = function(c, a) return require("boot.repo_meta")._git(c, a) end,
      sha256 = verify.sha256_hex })
    eq(res.mode, "pin-only", "mode inferred: pin-only")
    local titles = {}
    for _, f in ipairs(res.findings) do titles[#titles + 1] = f.kind .. "|" .. f.title end
    ok(not table.concat(titles, "\n"):find("missing", 1, true), "no 'missing launcher' finding  (" .. table.concat(titles, "; ") .. ")")
    -- a finding in pin-only mode is fixed with --pin-only
    put(r .. "/.gitattributes", "")
    local res2 = check.run_checks(r, { git = function(c, a) return require("boot.repo_meta")._git(c, a) end,
      sha256 = verify.sha256_hex })
    local attr
    for _, f in ipairs(res2.findings) do if f.id == "attributes" then attr = f end end
    ok(attr and attr.title:find("lw.pin", 1, true) and not attr.title:find("lw.sh", 1, true)
      and attr.remedy:find("bootstrap install --pin-only", 1, true),
      "a pin-scoped finding's fix is install --pin-only  (" .. tostring(attr and attr.remedy) .. ")")
    -- existing launchers are neither refreshed nor deleted by --pin-only
    put(r .. "/lw.sh", "#!/bin/sh\necho mine\n")
    local rep2 = bootstrap.install(r, { version = V2, pin_only = true })
    eq(slurp(r .. "/lw.sh"), "#!/bin/sh\necho mine\n", "--pin-only leaves an existing launcher alone")
    ok(has(rep2, "kept lw.sh as it is (--pin-only)"), "and says so  (" .. show(rep2) .. ")")
    eq(pin.read(r).version, V2, "--pin-only still moves the pin with --version")
    -- a later plain install adds the launchers, keeping the pin
    os.remove(r .. "/lw.sh")
    local rep3 = bootstrap.install(r, {})
    ok(uv.fs_stat(r .. "/lw.sh") and uv.fs_stat(r .. "/lw.cmd"), "plain install adds the launchers")
    eq(pin.read(r).version, V2, "keeping the pin")
    ok(has(rep3, "wrote lw.sh") and has(rep3, "./lw.sh <cmd>"), "reports the new launchers  (" .. show(rep3) .. ")")
  end

  -- ---- the deprecated `lw update` alias: needs a pin --------------------------
  do
    local _, e = bootstrap.install(sb .. "/nopin-update", { require_pin = true, latest = true })
    ok(e and e:find("no lw.pin found", 1, true) and e:find("lw bootstrap install", 1, true),
      "`lw update` without a pin refuses, naming `lw bootstrap install`  (" .. tostring(e) .. ")")
  end

  -- ---- argument grammar ----------------------------------------------------------
  do
    local P = pin.parse_bootstrap_args
    local o = P({ "bootstrap" }, "bootstrap")
    ok(o and o.sub == nil, "plain `lw bootstrap` is the status page")
    o = P({ "--no-input", "bootstrap", "--json", "--check" }, "bootstrap")
    ok(o and o.json and o.check and o.sub == nil, "status page flags (global flags tolerated)")
    local _, e = P({ "bootstrap", "--version", "0.1.36" }, "bootstrap")
    ok(e and e:find("`lw bootstrap install --version 0.1.36`", 1, true),
      "old `lw bootstrap --version X` is a usage error naming install  (" .. tostring(e) .. ")")
    _, e = P({ "bootstrap", "--force" }, "bootstrap")
    ok(e and e:find("bootstrap install --force", 1, true), "old `lw bootstrap --force` too")
    o = P({ "bootstrap", "install", "--version=1.2.3", "--pin-only", "--force" }, "bootstrap")
    ok(o and o.sub == "install" and o.version == "1.2.3" and o.pin_only and o.force, "install flags (--version=X form)")
    o = P({ "bootstrap", "upgrade", "--channel", "unstable" }, "bootstrap")
    ok(o and o.sub == "upgrade" and o.latest and o.channel == "unstable", "upgrade = install --latest (+ --channel)")
    _, e = P({ "bootstrap", "install", "--version", "1", "--latest" }, "bootstrap")
    ok(e ~= nil, "--version with --latest is a usage error")
    _, e = P({ "bootstrap", "install", "--channel", "unstable" }, "bootstrap")
    ok(e ~= nil, "--channel without --latest is a usage error")
    _, e = P({ "bootstrap", "frobnicate" }, "bootstrap")
    ok(e and e:find("install, upgrade", 1, true), "an unknown sub-command is a usage error")
    _, e = P({ "bootstrap", "install", "--json" }, "bootstrap")
    ok(e ~= nil, "--json belongs to the status page")
    o = P({ "update" }, "update")
    ok(o and o.sub == "install" and o.latest and o.require_pin, "`lw update` = install --latest, needs a pin")
    o = P({ "update", "--version", "1.2.3", "--force" }, "update")
    ok(o and o.version == "1.2.3" and not o.latest and o.force, "`lw update --version X` = install --version X")
    _, e = P({ "update", "--pin-only" }, "update")
    ok(e ~= nil, "`lw update` takes only its old flags")
  end

  -- ---- status page ------------------------------------------------------------------
  do
    local json = require("boot.json")
    -- no pin
    local r = sb .. "/st-none"; git_init(r)
    local st = bootstrap.status(r, { host_version = V1, resolve_newest = newest_is(V2) })
    local text = table.concat(st.lines, "\n")
    eq(st.exit, 0, "status page exits 0 without a pin")
    ok(text:find("(no lw.pin)", 1, true) and text:find("What you can do:\n  lw bootstrap install ", 1, true)
      and text:find("pin this repo to lw " .. V1, 1, true),
      "no pin: leads with `lw bootstrap install`  (" .. text .. ")")
    ok(text:find("only reports now", 1, true), "no pin: the migration note")
    ok(text:match("^[%w%p%s]*$") ~= nil, "status page is ASCII")
    eq(bootstrap.status(r, { check = true, offline = true }).exit, 1, "--check exits 1 without a pin")
    ok(uv.fs_stat(r .. "/lw.pin") == nil, "the status page writes nothing")
    -- a subdirectory of the repository says it is not the root
    paths.mkdirp(r .. "/sub")
    local sub = table.concat(bootstrap.status(r .. "/sub", { offline = true }).lines, "\n")
    ok(sub:find("not the repository root", 1, true), "a subdirectory is flagged  (" .. sub .. ")")
    local subrep = bootstrap.install(r .. "/sub", { version = V1, pin_only = true })
    ok(has(subrep, "is not the repository root"), "an install there says so too  (" .. show(subrep) .. ")")
    os.remove(r .. "/sub/lw.pin"); os.remove(r .. "/sub/.gitattributes")

    -- pinned, healthy, a newer release on the channel
    local h = sb .. "/st-ok"; git_init(h)
    bootstrap.install(h, { version = V1 })
    git(h, "add", "-A"); git(h, "commit", "-q", "-m", "x")
    local st2 = bootstrap.status(h, { invoked = "launcher", self_version = V1, resolve_newest = newest_is(V2) })
    local t2 = table.concat(st2.lines, "\n")
    ok(t2:find(V2 .. " is available on the stable channel", 1, true), "newer release named  (" .. t2 .. ")")
    ok(t2:find("pinned; lw.sh / lw.cmd current", 1, true), "healthy: the shared affirmation")
    ok(t2:find("./lw.sh bootstrap upgrade", 1, true) and t2:find("once more to take " .. V2, 1, true),
      "the invoked (launcher) form + the run-it-once-more hint")
    ok(not t2:find("only reports now", 1, true), "no migration note when pinned")
    eq(bootstrap.status(h, { check = true, resolve_newest = newest_is(V2) }).exit, 0,
      "--check passes on a healthy pin with a newer release available")
    -- offline: not checked, never a failure
    local t3 = table.concat(bootstrap.status(h, { resolve_newest = function() return nil, "offline" end }).lines, "\n")
    ok(t3:find("not checked - offline", 1, true), "a failed release check reads 'not checked'")
    -- json
    local doc = bootstrap.status(h, { resolve_newest = newest_is(V2) }).doc
    local enc = json.encode(doc)
    local back = json.decode(enc)
    ok(back and back.mode == "launchers" and back.pin.version == V1 and back.update.status == "available"
      and back.update.newest == V2 and back.summary.actionable == 0 and back.launchers["lw.sh"].generation == "current",
      "--json document  (" .. enc:sub(1, 300) .. ")")
    ok(enc:find('"missing_hashes":[]', 1, true) ~= nil, "empty arrays encode as []")

    -- pin-only with a finding
    local po = sb .. "/st-po"; git_init(po)
    bootstrap.install(po, { version = V1, pin_only = true })
    put(po .. "/.gitattributes", "")
    local st4 = bootstrap.status(po, { resolve_newest = newest_is(V1) })
    local t4 = table.concat(st4.lines, "\n")
    ok(t4:find("none - pin only", 1, true) and t4:find("* no line-ending rule for lw.pin", 1, true)
      and t4:find("lw bootstrap install --pin-only", 1, true),
      "pin-only + finding: fix with --pin-only  (" .. t4 .. ")")
    ok(t4:find("add lw.sh / lw.cmd", 1, true), "pin-only: how to add the launchers")
    eq(bootstrap.status(po, { check = true, resolve_newest = newest_is(V1) }).exit, 1,
      "--check exits 1 on an actionable finding")
  end

  -- ---- BUG: two implementations of the committed-ignore rule --------------------
  do
    local saved = check.cache_ignored_by_repo
    local calls = 0
    check.cache_ignored_by_repo = function(...) calls = calls + 1; return saved(...) end
    local r = sb .. "/ign"; git_init(r)
    put(r .. "/.gitignore", "/.nvim/**\n")
    local rm = require("boot.repo_meta")
    local writer = rm.cache_ignored_by_repo(r, rm.toplevel(r))
    put(r .. "/lw.pin", "version = 1.0.0\n"); put(r .. "/lw.sh", launcher.render("sh"))
    local res = check.run_checks(r, { git = function(c, a) return rm._git(c, a) end, sha256 = verify.sha256_hex })
    check.cache_ignored_by_repo = saved
    eq(writer, true, "the writer sees the committed rule")
    eq(res.git and res.git.ignore, "repo", "the checks see the same")
    eq(calls, 2, "writer and checks go through the one rule (launcher_check.cache_ignored_by_repo)")
  end

  -- ---- BUG: pin management provisioned the pinned bundle first ------------------
  -- `./lw.sh bootstrap` (pinned context: LOOMWORKS_PINNED set) must not
  -- download the bundle — it needs no system Lua, and a pin whose bundle entry
  -- is wrong must still be repairable through the launcher.
  do
    local work = sb .. "/pinned-ctx"
    local repo = work .. "/proj"; git_init(repo)
    local hashes = {}
    for _, a in pairs(pin.HOST_ASSETS) do hashes[a] = string.rep("a", 64) end
    hashes[pin.bundle_asset(V1)] = string.rep("b", 64)   -- no such bundle anywhere
    put(repo .. "/lw.pin", pin.serialize(V1, hashes))
    local home = work .. "/home"; paths.mkdirp(home)
    local env = {}
    local override = { LOCALAPPDATA = home, XDG_DATA_HOME = home, APPDATA = home, XDG_CONFIG_HOME = home,
      LOOMWORKS_PINNED = V1, LW_ROOT = repo, LOOMWORKS_RELEASE_URL = work .. "/empty-mirror" }
    for k, v in pairs(uv.os_environ()) do
      if override[k] == nil and k ~= "LOOMWORKS_LUA" and k ~= "LOOMWORKS_LW" then env[#env + 1] = k .. "=" .. v end
    end
    for k, v in pairs(override) do env[#env + 1] = k .. "=" .. v end
    local logf = work .. "/out.txt"
    local fd = assert(uv.fs_open(logf, "w", 420))
    local done, code = false, nil
    local rel = "../../../../lua"   -- luvi joins a bundle path onto its cwd
    local h = uv.spawn(uv.exepath(), { args = { rel, "--", "bootstrap", "--check" }, cwd = repo, env = env,
      stdio = { nil, fd, fd } }, function(c) code = c; done = true end)
    ok(h ~= nil, "spawned a source-run host in pinned context")
    if h then
      local t = uv.new_timer()
      t:start(60000, 0, function() if not done then pcall(uv.process_kill, h, "sigterm") end end)
      while not done do uv.run("once") end
      t:stop(); t:close(); h:close()
    end
    uv.fs_close(fd)
    local out = slurp(logf) or ""
    ok(not out:find("could not provision pinned bundle", 1, true),
      "`./lw.sh bootstrap` does not provision the pinned bundle  (" .. out:sub(1, 300) .. ")")
    ok(out:find("lw.pin -> lw " .. V1, 1, true) and out:find("./lw.sh bootstrap", 1, true),
      "it prints the status page in the launcher form (exit " .. tostring(code) .. ")")
  end

  uv.os_unsetenv("LOOMWORKS_RELEASE_URL")
  paths.rm_rf(sb)
end

print("boot.bootstrap — lw.cmd calls Windows system tools by absolute path (PATH-shadowing)")
do
  local bootstrap = require("boot.bootstrap")

  -- Static: every external system tool in lw.cmd is invoked by its absolute
  -- %SystemRoot%\System32 path, never by a bare name that PATH could shadow
  -- (Git's usr/bin/find ahead of System32 broke the download in CI).
  local SYS32 = [[%SystemRoot%\System32\]]
  local tools = { "find", "findstr", "certutil", "curl", "where", "ping" }
  local bare = {}
  for line in (bootstrap.LW_CMD .. "\n"):gmatch("([^\n]*)\n") do
    if not line:match("^%s*rem[%s$]") and not line:match("^%s*rem$") then
      for _, t in ipairs(tools) do
        local init = 1
        while true do
          local s, e = line:find("%f[%w_%-]" .. t .. "%f[^%w_%-]", init)
          if not s then break end
          local pre = line:sub(1, s - 1)
          local absolute = pre:sub(-#SYS32) == SYS32
          -- the literal word inside an echo message is not an invocation
          local in_echo = pre:match("echo[^|&]*$") ~= nil
          if not absolute and not in_echo then bare[#bare + 1] = t .. " in: " .. line end
          init = e + 1
        end
      end
    end
  end
  ok(#bare == 0, "lw.cmd invokes no system tool by bare name" ..
    (#bare > 0 and (" — " .. table.concat(bare, " | ")) or ""))

  -- Every message line ends without a trailing space: `echo text 1>&2` and
  -- `( echo text & ...)` echo the space before the redirect / `&` / `)`
  -- (the beta.1 fetch line did). The redirect goes first: `1>&2 echo text`.
  local trailing = {}
  for line in (bootstrap.LW_CMD .. "\n"):gmatch("([^\n]*)\n") do
    if not line:match("^%s*rem[%s$]") then
      local i = line:find("echo[ (]")
      if i and not line:find("^echo%(", i) then
        -- the echoed text: up to the first unescaped &, |, ) or end of line
        local rest, text = line:sub(i + 5), ""
        local j = 1
        while j <= #rest do
          local c = rest:sub(j, j)
          if c == "^" then text = text .. rest:sub(j, j + 1); j = j + 2
          elseif c == "&" or c == "|" or c == ")" then break
          else text = text .. c; j = j + 1 end
        end
        if text:find("1>&2", 1, true) or text:find("%s$") then trailing[#trailing + 1] = line end
      end
    end
  end
  ok(#trailing == 0, "no lw.cmd message ends in a trailing space" ..
    (#trailing > 0 and (" -- " .. table.concat(trailing, " | ")) or ""))

  -- Dynamic (Windows only): run the generated lw.cmd with a PATH whose first
  -- entry holds fake find/findstr/certutil/curl/where that lie (exit 0, no
  -- output). The pinned-version validation, the local-mirror copy and the
  -- sha256 check must still behave exactly as with the real System32 tools.
  if package.config:sub(1, 1) == "\\" then
    local sysroot = (os.getenv("SystemRoot") or [[C:\Windows]])
    local cmdexe = sysroot .. [[\System32\cmd.exe]]
    local sb = root .. "/tests/.tmp-lwcmd"; paths.rm_rf(sb); paths.mkdirp(sb)
    local fake = sb .. "/fakebin"; paths.mkdirp(fake)
    -- `lie` is the exit status every fake returns: 0 claims a match (findstr
    -- would reject a valid version, find would send a local mirror to curl),
    -- 1 claims no match (findstr would let an invalid version through).
    local function plant_fakes(lie)
      for _, t in ipairs(tools) do
        local f = assert(io.open(fake .. "/" .. t .. ".bat", "wb"))
        f:write("@exit /b " .. lie .. "\r\n"); f:close()
      end
    end
    local mirror = sb .. "/mirror"; paths.mkdirp(mirror)
    local asset = "lw-windows-x86_64.exe"
    -- the "pinned host binary" is a copy of cmd.exe, so forwarding is observable
    local body = readfile(cmdexe)
    do local f = assert(io.open(mirror .. "/" .. asset, "wb")); f:write(body); f:close() end
    local want = verify.sha256_hex(body)

    local function run_launcher(repo, version, args)
      paths.mkdirp(repo)
      do local f = assert(io.open(repo .. "/lw.cmd", "wb")); f:write(require("boot.launcher").render("cmd")); f:close() end
      do local f = assert(io.open(repo .. "/lw.pin", "wb"))
         f:write("version=" .. version .. "\nsha256_" .. asset .. "=" .. want .. "\n"); f:close() end
      local env = {}
      for k, v in pairs(uv.os_environ()) do
        local uk = k:upper()
        if uk ~= "PATH" and uk ~= "LOOMWORKS_LW" and uk ~= "LOOMWORKS_RELEASE_URL" then
          env[#env + 1] = k .. "=" .. v
        end
      end
      env[#env + 1] = "PATH=" .. fake:gsub("/", "\\") .. ";" .. sysroot .. [[\System32]]
      env[#env + 1] = "LOOMWORKS_RELEASE_URL=" .. mirror
      local out = {}
      local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
      local code
      local argv = { "/d", "/c", (repo:gsub("/", "\\")) .. [[\lw.cmd]] }
      for _, a in ipairs(args) do argv[#argv + 1] = a end
      local h = uv.spawn(cmdexe, { args = argv, env = env, cwd = repo, stdio = { nil, stdout, stderr } },
        function(c) code = c end)
      local function rd(_, d) if d then out[#out + 1] = d end end
      stdout:read_start(rd); stderr:read_start(rd)
      uv.run()
      if h and not h:is_closing() then h:close() end
      return code, table.concat(out)
    end

    plant_fakes(0)
    local ver = "7.8.9-test"
    local code, out = run_launcher(sb .. "/good", ver, { "/c", "exit", "7" })
    ok(not out:find("invalid pinned version", 1, true),
      "fake findstr on PATH does not reject a valid version  (" .. out .. ")")
    eq(code, 7, "launcher fetched, verified and forwarded to the pinned binary despite fake tools on PATH")
    ok(uv.fs_stat(sb .. "/good/.nvim/cache/lw-" .. ver .. "-" .. asset) ~= nil,
      "pinned binary cached from the local mirror")

    plant_fakes(1)
    local bcode, bout = run_launcher(sb .. "/bad", "1.0/evil", { "/c", "exit", "0" })
    ok(bcode ~= 0 and bout:find("invalid pinned version", 1, true) ~= nil,
      "an invalid pinned version is still rejected  (" .. tostring(bcode) .. ": " .. bout .. ")")

    paths.rm_rf(sb)
  end
end

print("boot.launcher — launchers retry a failed download, fetch quietly, name the pin (§16.22)")
do
  local bootstrap = require("boot.bootstrap")
  local pin = require("boot.pin")
  local is_win = package.config:sub(1, 1) == "\\"

  -- A local HTTP server that answers the first `fail_first` requests with 503.
  local function flaky_server(body, fail_first)
    local srv = uv.new_tcp()
    assert(srv:bind("127.0.0.1", 0))
    local port = srv:getsockname().port
    local state = { hits = 0 }
    srv:listen(16, function()
      local c = uv.new_tcp(); srv:accept(c)
      local buf = ""
      c:read_start(function(_, data)
        if not data then if not c:is_closing() then c:close() end return end
        buf = buf .. data
        if buf:find("\r\n\r\n", 1, true) then
          c:read_stop()
          state.hits = state.hits + 1
          local resp
          if state.hits <= fail_first then
            resp = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          else
            resp = "HTTP/1.1 200 OK\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\n\r\n" .. body
          end
          c:write(resp, function() c:shutdown(function() if not c:is_closing() then c:close() end end) end)
        end
      end)
    end)
    return port, state, srv
  end

  -- Spawn a launcher and pump the loop until it exits (the server lives in the
  -- same loop, so a plain uv.run() would never return).
  local function run(file, argv, env, cwd)
    local out = {}
    local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
    local code
    local h = uv.spawn(file, { args = argv, env = env, cwd = cwd, stdio = { nil, stdout, stderr } },
      function(c) code = c end)
    local function rd(_, d) if d then out[#out + 1] = d end end
    stdout:read_start(rd); stderr:read_start(rd)
    while code == nil do uv.run("once") end
    for _ = 1, 50 do if not uv.run("nowait") then break end end
    if h and not h:is_closing() then h:close() end
    if not stdout:is_closing() then stdout:close() end
    if not stderr:is_closing() then stderr:close() end
    return code, table.concat(out)
  end
  local function base_env(extra)
    local env = {}
    for k, v in pairs(uv.os_environ()) do
      local uk = k:upper()
      if uk ~= "LOOMWORKS_LW" and uk ~= "LOOMWORKS_RELEASE_URL" then env[#env + 1] = k .. "=" .. v end
    end
    for _, kv in ipairs(extra) do env[#env + 1] = kv end
    return env
  end

  local sb = root .. "/tests/.tmp-lwretry"; paths.rm_rf(sb); paths.mkdirp(sb)
  local ver = "5.6.7-test"

  if is_win then
    local sysroot = (os.getenv("SystemRoot") or [[C:\Windows]])
    local cmdexe = sysroot .. [[\System32\cmd.exe]]
    local asset = "lw-windows-x86_64.exe"
    local body = readfile(cmdexe) -- the "pinned host binary": forwarding is observable
    local want = verify.sha256_hex(body)
    local function setup(repo)
      paths.mkdirp(repo)
      local f = assert(io.open(repo .. "/lw.cmd", "wb")); f:write(require("boot.launcher").render("cmd")); f:close()
      f = assert(io.open(repo .. "/lw.pin", "wb"))
      f:write("version=" .. ver .. "\nsha256_" .. asset .. "=" .. want .. "\n"); f:close()
    end

    local port, state, srv = flaky_server(body, 2)
    local repo = sb .. "/ok"; setup(repo)
    local code, out = run(cmdexe, { "/d", "/c", (repo:gsub("/", "\\")) .. [[\lw.cmd]], "/c", "exit", "7" },
      base_env({ "LOOMWORKS_RELEASE_URL=http://127.0.0.1:" .. port }), repo)
    srv:close()
    eq(code, 7, "lw.cmd: two 503s, then success -> fetched, verified and forwarded")
    eq(state.hits, 3, "lw.cmd: three attempts")
    ok(out:find("download attempt 1 failed; retrying", 1, true)
      and out:find("download attempt 2 failed; retrying", 1, true),
      "lw.cmd: each retry is announced  (" .. out .. ")")
    ok(out:find("fetching pinned lw " .. ver .. " (" .. asset .. ") for ", 1, true)
      and out:find("lw.pin...", 1, true), "lw.cmd: the fetch line names the pin")
    ok(not out:find("% Total", 1, true) and not out:find("Dload", 1, true),
      "lw.cmd: no curl progress meter")
    ok(out:match("^[%w%p%s]*$") ~= nil, "lw.cmd: output is ASCII")
    ok(not out:find(" \r?\n") and not out:find(" $"), "lw.cmd: no line ends in a space  ("
      .. out:gsub(" \r?\n", "<SP>|") .. ")")
    -- a second run finds the cached, verified binary and prints nothing of its own
    local code2, out2 = run(cmdexe, { "/d", "/c", (repo:gsub("/", "\\")) .. [[\lw.cmd]], "/c", "exit", "3" },
      base_env({ "LOOMWORKS_RELEASE_URL=http://127.0.0.1:1" }), repo)
    eq(code2, 3, "lw.cmd: cached run forwards")
    eq(out2, "", "lw.cmd: a cached run adds no output")

    local port2, state2, srv2 = flaky_server(body, 99)
    local repo2 = sb .. "/fail"; setup(repo2)
    local code3, out3 = run(cmdexe, { "/d", "/c", (repo2:gsub("/", "\\")) .. [[\lw.cmd]], "/c", "exit", "0" },
      base_env({ "LOOMWORKS_RELEASE_URL=http://127.0.0.1:" .. port2 }), repo2)
    srv2:close()
    ok(code3 ~= 0, "lw.cmd: a download that keeps failing exits non-zero")
    eq(state2.hits, 3, "lw.cmd: gives up after three attempts")
    ok(out3:find("download failed after 3 attempts", 1, true) ~= nil,
      "lw.cmd: says the attempts were exhausted  (" .. out3 .. ")")
    ok(not out3:find(" \r?\n") and not out3:find(" $"), "lw.cmd: failure lines end without a space")
    ok(not uv.fs_stat(repo2 .. "/.nvim/cache/lw-" .. ver .. "-" .. asset)
      and not uv.fs_stat(repo2 .. "/.nvim/cache/lw-" .. ver .. "-" .. asset .. ".dl"),
      "lw.cmd: nothing left in the cache")
  else
    local asset = assert(pin.detect_asset())
    local body = "#!/bin/sh\nexit 7\n"
    local want = verify.sha256_hex(body)
    local sh = require("boot.exe").resolve("sh")
    local function setup(repo)
      paths.mkdirp(repo)
      local f = assert(io.open(repo .. "/lw.sh", "wb")); f:write(require("boot.launcher").render("sh")); f:close()
      f = assert(io.open(repo .. "/lw.pin", "wb"))
      f:write("version = " .. ver .. "\nsha256_" .. asset .. " = " .. want .. "\n"); f:close()
    end
    local port, state, srv = flaky_server(body, 2)
    local repo = sb .. "/ok"; setup(repo)
    local code, out = run(sh, { repo .. "/lw.sh" },
      base_env({ "LOOMWORKS_RELEASE_URL=http://127.0.0.1:" .. port }), repo)
    srv:close()
    eq(code, 7, "lw.sh: two 503s, then success -> fetched, verified and exec'd")
    eq(state.hits, 3, "lw.sh: three attempts")
    ok(out:find("download attempt 1 failed; retrying", 1, true)
      and out:find("download attempt 2 failed; retrying", 1, true),
      "lw.sh: each retry is announced  (" .. out .. ")")
    ok(out:find("fetching pinned lw " .. ver .. " (" .. asset .. ") for " .. repo, 1, true) ~= nil,
      "lw.sh: the fetch line names the pin")
    ok(not out:find("% Total", 1, true) and not out:find("Dload", 1, true), "lw.sh: no progress meter")
    local code2, out2 = run(sh, { repo .. "/lw.sh" }, base_env({}), repo)
    eq(code2, 7, "lw.sh: cached run execs")
    eq(out2, "", "lw.sh: a cached run adds no output")

    local port2, state2, srv2 = flaky_server(body, 99)
    local repo2 = sb .. "/fail"; setup(repo2)
    local code3, out3 = run(sh, { repo2 .. "/lw.sh" },
      base_env({ "LOOMWORKS_RELEASE_URL=http://127.0.0.1:" .. port2 }), repo2)
    srv2:close()
    ok(code3 ~= 0, "lw.sh: a download that keeps failing exits non-zero")
    eq(state2.hits, 3, "lw.sh: gives up after three attempts")
    ok(out3:find("download failed after 3 attempts", 1, true) ~= nil,
      "lw.sh: says the attempts were exhausted  (" .. out3 .. ")")
    ok(not uv.fs_stat(repo2 .. "/.nvim/cache/lw-" .. ver .. "-" .. asset), "lw.sh: nothing left in the cache")
  end
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

print("SECURITY — host Lua search paths never reach the current directory")
do
  local luapath = require("boot.luapath")
  local win = luapath.sanitize(
    [[.\?.lua;C:\bin\lua\?.lua;C:\sys\lua\?.lua;?.lua;lua\?\init.lua;\\srv\share\?.lua;!\lua\?.lua;\rooted\?.lua;;]],
    { is_windows = true, exclude_dirs = { "C:\\bin" } })
  eq(win, [[C:\sys\lua\?.lua;\\srv\share\?.lua]],
    "windows: only absolute entries outside the exe dir survive")
  local posix = luapath.sanitize("./?.lua;/usr/share/lua/5.1/?.lua;/opt/lw/lua/?.lua;lua/?.lua;;",
    { is_windows = false, exclude_dirs = { "/opt/lw" } })
  eq(posix, "/usr/share/lua/5.1/?.lua", "posix: only absolute entries outside the exe dir survive")
  eq(luapath.sanitize(".\\?.dll;C:\\bin\\?.dll;C:\\bin\\loadall.dll",
    { is_windows = true, exclude_dirs = { "C:/BIN/" } }), "",
    "cpath: cwd and exe-dir entries removed (case/separator-insensitive)")

  -- End to end: a source-run host (`luvi <repo>/lua -- …`, the fused-bundle
  -- fallback path) started inside a directory that carries loomworks/cli.lua
  -- and loomworks/shim.lua must run its own code, never those files.
  local work = root .. "/tests/.tmp-cwdshadow"
  local home = work .. "/home"
  paths.rm_rf(work)
  paths.mkdirp(work .. "/proj/loomworks")
  paths.mkdirp(home)
  local marker = work .. "/SHADOWED"
  local shadow = ("local f = io.open(%q, 'w') f:write('x') f:close()\nreturn {}\n"):format(marker)
  for _, name in ipairs({ "cli.lua", "shim.lua" }) do
    local f = assert(io.open(work .. "/proj/loomworks/" .. name, "w")); f:write(shadow); f:close()
  end
  local env = {}
  local override = { LOCALAPPDATA = home, XDG_DATA_HOME = home, APPDATA = home, XDG_CONFIG_HOME = home }
  for k, v in pairs(uv.os_environ()) do
    local drop = override[k] or k == "LOOMWORKS_LUA" or k == "LOOMWORKS_PINNED" or k == "LOOMWORKS_LW"
    if not drop then env[#env + 1] = k .. "=" .. v end
  end
  for k, v in pairs(override) do env[#env + 1] = k .. "=" .. v end
  -- Capture into a file (a libuv pipe does not reliably receive a luvi child's
  -- C-stdio output on Windows).
  local logf = work .. "/out.txt"
  local fd = assert(uv.fs_open(logf, "w", 420))
  local done, code = false, nil
  local h = uv.spawn(uv.exepath(), {
    -- luvi joins a bundle path onto its cwd, so name the source dir relatively.
    args = { "../../../lua", "--", "help" }, cwd = work .. "/proj", env = env,
    stdio = { nil, fd, fd },
  }, function(c) code = c; done = true end)
  ok(h ~= nil, "spawned a source-run host")
  if h then
    local t = uv.new_timer()
    t:start(60000, 0, function() if not done then pcall(uv.process_kill, h, "sigterm") end end)
    while not done do uv.run("once") end
    t:stop(); t:close(); h:close()
  end
  uv.fs_close(fd)
  local lf = io.open(logf, "rb")
  local text = lf and lf:read("*a") or ""
  if lf then lf:close() end
  ok(not uv.fs_stat(marker), "cwd-relative loomworks/*.lua was not executed")
  ok(text:find("Usage", 1, true) ~= nil and code == 0,
    "the host's own CLI ran (exit " .. tostring(code) .. ")" ..
    ((code ~= 0 or not text:find("Usage", 1, true)) and (" :: " .. text:sub(1, 400)) or ""))
  paths.rm_rf(work)
end

print("SECURITY — bare program names never resolve from the current directory")
do
  -- Benign probe: a copy of a harmless system tool renamed `lwprobe`, placed
  -- in a scratch dir that becomes the cwd.
  local is_win = package.config:sub(1, 1) == "\\"
  local probe = is_win and "lwprobe.exe" or "lwprobe"
  local sb = root .. "/tests/.tmp-exe"; paths.rm_rf(sb); paths.mkdirp(sb)
  local src = is_win and ((os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32\\whoami.exe")
    or "/bin/true"
  ok(uv.fs_copyfile(src, sb .. "/" .. probe) == true, "probe copied")
  if not is_win then uv.fs_chmod(sb .. "/" .. probe, 493) end
  local bexe = require("boot.exe")
  local saved = uv.cwd()
  uv.chdir(sb)
  local sep = is_win and ";" or ":"
  local saved_path = os.getenv("PATH")
  local r1, e1 = bexe.resolve("lwprobe")
  ok(r1 == nil and tostring(e1):find("not found on PATH", 1, true) ~= nil,
    "boot.exe: a cwd-only program is not resolved")
  eq(vim.fn.exepath("lwprobe"), "", "shim exepath: a cwd-only program is not resolved")
  eq(vim.fn.executable("lwprobe"), 0, "shim executable: a cwd-only program is not executable")
  local res = vim.system({ "lwprobe" }, { text = true }):wait()
  eq(res.code, 127, "shim vim.system: a cwd-only program is not spawned")
  ok(tostring(res.stderr):find("not found on PATH", 1, true) ~= nil, "…with a clear error")
  eq(vim.fn.jobstart({ "lwprobe" }, {}), -1, "shim jobstart: a cwd-only program is not spawned")
  -- Relative / empty PATH entries are ignored (they mean "the cwd").
  uv.os_setenv("PATH", "." .. sep .. sep .. (saved_path or ""))
  ok(bexe.resolve("lwprobe") == nil, "boot.exe: '.' and empty PATH entries ignored")
  eq(vim.fn.exepath("lwprobe"), "", "shim: '.' and empty PATH entries ignored")
  if saved_path then uv.os_setenv("PATH", saved_path) end
  -- An absolute PATH entry does resolve, to an absolute path.
  local p = vim.system({ "lwprobe" }, { text = true, env = { PATH = sb } }):wait()
  eq(p.code, 0, "shim vim.system: resolved via the child's absolute PATH entry")
  ok(bexe.resolve(sb .. "/lwprobe") ~= nil, "boot.exe: an existing absolute path is accepted")
  -- A shell-style explicit relative path runs relative to the child's cwd only.
  local q = vim.system({ "./lwprobe" }, { text = true, cwd = sb }):wait()
  eq(q.code, 0, "shim vim.system: ./prog resolves against the child cwd")
  uv.chdir(saved)
  paths.rm_rf(sb)
end

print("loomworks.trust — machine signatures under the standalone host (§17.3)")
do
  -- The editor host computes the same values (tests/workspace_trust_spec.lua):
  -- the same key + content yields the same signature, so the CLI and the
  -- editor on one machine read each other's `.nvim` files.
  require("loomworks.shim")
  local trust = require("loomworks.trust")
  local ossl = require("openssl")
  local dir = uv.os_tmpdir():gsub("\\", "/") .. "/lw-trust-" .. tostring(uv.hrtime())
  uv.fs_mkdir(dir, 448)
  local kf = io.open(dir .. "/trust.key", "wb")
  kf:write("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\n"); kf:close()
  trust._set_key_path(dir .. "/trust.key")
  local content = '{\n  "_meta": {\n    "version": 2\n  },\n  "name": "fixture"\n}\n'
  local signed = trust.sign("user", content)
  eq(trust.split(signed), "c127ba0466fe01f413302d041f7f58b60aabba5b43a5ff8ed3bfd214934415f1",
    "trust.sign: same signature as the editor host")
  eq((trust.verify("user", signed)), "valid", "trust.verify: valid under the standalone host")
  -- The pure-Lua HMAC agrees with OpenSSL on binary keys and messages.
  local key = ""
  for i = 0, 63 do key = key .. string.char((i * 37 + 11) % 256) end
  for _, msg in ipairs({ "", "abc", string.rep("\0\255\10", 50), ("x"):rep(1000) }) do
    eq(trust.hmac_sha256_hex(key, msg), ossl.hmac.hmac("sha256", msg, key, false),
      "trust.hmac_sha256_hex == OpenSSL HMAC (" .. #msg .. " bytes)")
  end
  -- A fresh key is created with owner-only permissions (non-Windows).
  trust._set_key_path(dir .. "/new/trust.key")
  ok(trust.key() ~= nil, "trust.key: created on first use")
  if package.config:sub(1, 1) ~= "\\" then
    local st = uv.fs_stat(dir .. "/new/trust.key")
    eq(st.mode % 64, 0, "trust.key: no group/other permission bits")
  end
  trust._set_key_path(nil)
  os.remove(dir .. "/new/trust.key"); uv.fs_rmdir(dir .. "/new")
  os.remove(dir .. "/trust.key"); uv.fs_rmdir(dir)
end

print("loomworks.shim — vim.fn.jobstart / jobwait / jobstop (nvim job semantics)")
do
  -- A platform module lists devices with `vim.fn.jobstart` (buffered stdout +
  -- on_exit), so the standalone host needs nvim's job API. Benign commands
  -- only (the platform shell echoing / exiting).
  local vim = require("loomworks.shim")
  local is_win = package.config:sub(1, 1) == "\\"
  local function sh(script) -- run `script` in the platform shell
    if is_win then return { "cmd", "/d", "/c", script } end
    return { "sh", "-c", script }
  end
  local function strip_cr(list)
    local r = {}
    for i, l in ipairs(list or {}) do r[i] = (l:gsub("\r$", "")) end
    return r
  end
  local two_lines = is_win and "echo one&echo two" or "printf 'one\\ntwo\\n'"

  -- Buffered stdout: one call with every line (trailing "" = final newline),
  -- before on_exit(job_id, code, "exit").
  local events, got, exit_args = {}, nil, nil
  local id = vim.fn.jobstart(sh(two_lines), {
    stdout_buffered = true,
    on_stdout = function(j, data, ev) events[#events + 1] = "stdout"; got = { j = j, data = data, ev = ev } end,
    on_exit = function(j, code, ev) events[#events + 1] = "exit"; exit_args = { j = j, code = code, ev = ev } end,
  })
  ok(type(id) == "number" and id > 0, "jobstart returns a job id > 0")
  local waited = vim.fn.jobwait({ id }, 10000)
  eq(waited[1], 0, "jobwait returns the exit code")
  eq(table.concat(events, ","), "stdout,exit", "buffered: on_stdout once, then on_exit")
  eq(table.concat(strip_cr(got and got.data), "|"), "one|two|", "buffered stdout lines (trailing '' for the final newline)")
  eq(got and got.ev, "stdout", "on_stdout event name")
  eq(got and got.j, id, "on_stdout receives the job id")
  eq(exit_args and exit_args.code, 0, "on_exit code")
  eq(exit_args and exit_args.ev, "exit", "on_exit event name")
  eq(exit_args and exit_args.j, id, "on_exit receives the job id")

  -- Unbuffered: chunks joined with nvim's partial-line rule reproduce the
  -- output; EOF arrives as { "" }.
  local chunks, eof = {}, false
  local acc = { "" }
  local id2 = vim.fn.jobstart(sh(two_lines), {
    on_stdout = function(_, data)
      if #data == 1 and data[1] == "" then eof = true; return end
      acc[#acc] = acc[#acc] .. data[1]
      for i = 2, #data do acc[#acc + 1] = data[i] end
      chunks[#chunks + 1] = data
    end,
  })
  vim.fn.jobwait({ id2 }, 10000)
  ok(#chunks >= 1 and eof, "unbuffered: data chunks then an EOF { \"\" }")
  eq(table.concat(strip_cr(acc), "|"), "one|two|", "unbuffered: partial-line joining reproduces the output")

  -- Exit code, stderr, env and cwd.
  local code
  local id3 = vim.fn.jobstart(sh("exit 3"), { on_exit = function(_, c) code = c end })
  eq(vim.fn.jobwait({ id3 }, 10000)[1], 3, "jobwait: non-zero exit code")
  eq(code, 3, "on_exit: non-zero exit code")
  local err_lines
  local id4 = vim.fn.jobstart(sh(is_win and "echo oops 1>&2" or "echo oops 1>&2"), {
    stderr_buffered = true, on_stderr = function(_, d, ev) err_lines = { d = d, ev = ev } end,
  })
  vim.fn.jobwait({ id4 }, 10000)
  ok(err_lines and (err_lines.d[1] or ""):find("oops", 1, true) ~= nil and err_lines.ev == "stderr",
    "on_stderr (buffered) receives stderr lines")
  local env_opts = {
    env = { LWJOBTEST = "xyz" }, stdout_buffered = true,
  }
  local id5 = vim.fn.jobstart(sh(is_win and "echo %LWJOBTEST%" or "echo $LWJOBTEST"), env_opts)
  vim.fn.jobwait({ id5 }, 10000)
  eq(strip_cr(env_opts.stdout)[1], "xyz", "env extends the environment; buffered output without a callback lands in opts.stdout")
  local sb = root .. "/tests/.tmp-job"; paths.rm_rf(sb); paths.mkdirp(sb)
  local cwd_opts = { cwd = sb, stdout_buffered = true }
  local id6 = vim.fn.jobstart(is_win and { "cmd", "/d", "/c", "cd" } or { "pwd" }, cwd_opts)
  vim.fn.jobwait({ id6 }, 10000)
  local printed = (strip_cr(cwd_opts.stdout)[1] or ""):gsub("\\", "/"):lower()
  ok(printed:find("tests/.tmp-job", 1, true) ~= nil, "cwd option: the job runs in cwd (" .. printed .. ")")
  paths.rm_rf(sb)

  -- A string command runs through the platform shell.
  local str_opts = { stdout_buffered = true }
  local id8 = vim.fn.jobstart(is_win and "echo a b&echo c" or "echo a b; echo c", str_opts)
  eq(vim.fn.jobwait({ id8 }, 10000)[1], 0, "string cmd: exit 0")
  eq(table.concat(strip_cr(str_opts.stdout), "|"), "a b|c|", "string cmd: runs through the shell")

  -- The callbacks fire while a caller pumps the loop with vim.wait.
  local done = false
  vim.fn.jobstart(sh("exit 0"), { on_exit = function() done = true end })
  ok(vim.wait(10000, function() return done end), "on_exit fires under vim.wait")

  -- Timeout, stop, and bad ids.
  local long = is_win and { "ping", "-n", "30", "127.0.0.1" } or { "sleep", "30" }
  local id7 = vim.fn.jobstart(long, {})
  eq(vim.fn.jobwait({ id7 }, 100)[1], -1, "jobwait: -1 on timeout")
  eq(vim.fn.jobstop(id7), 1, "jobstop: 1 for a running job")
  local stopped = vim.fn.jobwait({ id7 }, 10000)[1]
  ok(stopped ~= -1 and stopped ~= 0, "jobwait after jobstop: the job ended (" .. tostring(stopped) .. ")")
  eq(vim.fn.jobstop(id7), 0, "jobstop: 0 for a finished job")
  eq(vim.fn.jobwait({ 987654 }, 10)[1], -3, "jobwait: -3 for an unknown id")

  -- Failures: an unresolvable program is never spawned (-1); bad args are 0.
  eq(vim.fn.jobstart({ "lw-no-such-program-xyz" }, {}), -1, "jobstart: -1 when the program is not executable")
  eq(vim.fn.jobstart({}, {}), 0, "jobstart: 0 for an empty argv")
end

print("remote execution under the shim (spec §18)")
do
  -- The executor, transport and sentinel protocol rely on vim.schedule /
  -- vim.wait / uv pipes; run them under the real shim (luvi host).
  local vim = require("loomworks.shim")
  package.path = root .. "/?.lua;" .. package.path
  local se = require("loomworks.remote.spec_exec")
  local is_win = package.config:sub(1, 1) == "\\"
  local sh = is_win and ((os.getenv("SystemRoot") or "C:/Windows"):gsub("\\", "/") .. "/System32/cmd.exe") or "/bin/sh"
  local args = is_win and { "/d", "/c", "echo one& (echo two)1>&2& exit 3" }
    or { "-c", "echo one; echo two 1>&2; exit 3" }
  local job, fail = se.run({ cmd = sh, args = args }, { label = "probe" })
  eq(job.lines[1], "one", "spec_exec: stdout line, CRLF normalised")
  eq(job.err_lines[1], "two", "spec_exec: stderr line")
  eq(job.code, 3, "spec_exec: exit status")
  ok(fail and fail:find("probe failed (exit 3)", 1, true) ~= nil, "spec_exec: failure names the step")
  local long = is_win and { "/d", "/c", "ping -n 30 127.0.0.1 >nul" } or { "-c", "sleep 30" }
  local tjob, tfail = se.run({ cmd = sh, args = long }, { label = "hang", timeout = 0.5 })
  ok(tjob.timed_out and tfail:find("timed out", 1, true) ~= nil, "spec_exec: hard timeout kills the step")
  local rel = se.run({ cmd = "sh", args = {} }, { label = "rel" })
  ok(rel.spawn_error ~= nil, "spec_exec: a bare program name is refused")

  local fx = require("tests.remote_fixtures")
  local dev = fx.device()
  local runner = fx.fake_runner_table()
  local t = require("loomworks.remote.transport").new({ runner = runner, serial = "SER1", backend = dev:backend() })
  dev.boards.SER1.files["/x/prog"] = { data = "p" }
  dev.behaviors.prog = function() return { out = { "hello" }, exit = 7 } end
  local req = { argv = { "/x/prog", "a b" }, cwd = "/x", env = { K = "v" }, library_dirs = { "/x" },
    nonce = require("loomworks.remote.transport").nonce() }
  local seen = {}
  local ejob, st = t:start_exec(req, { on_output = function(_, l) seen[#seen + 1] = l end })
  ejob:wait()
  eq(st.status, 7, "transport: status comes from the nonce sentinel")
  eq(table.concat(seen, "|"), "hello", "transport: sentinel / pid lines are not program output")
  local refused = t:start_exec({ argv = { "/x/prog" }, cwd = "/x", env = { ["A-B"] = "1" }, nonce = "n1" })
  eq(refused, nil, "transport: a non-portable env name is refused before any spec")
end

print("editor-only LSP integrations under the shim")
do
  -- Regression (real device run): a CLI configure nudged the LSP layer, which
  -- discovered the integrations; qmlls called vim.filetype.add at load and the
  -- shim has no vim.filetype, printing a stray load error.
  local vim = require("loomworks.shim")
  local okq, qerr = pcall(require, "loomworks.integrations.lsp.qmlls")
  ok(okq, "qmlls integration loads without vim.filetype" .. (okq and "" or (" — " .. tostring(qerr))))
  local okc, cerr = pcall(require, "loomworks.integrations.lsp.clangd")
  ok(okc, "clangd integration loads under the shim" .. (okc and "" or (" — " .. tostring(cerr))))
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

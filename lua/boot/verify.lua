-- Release-bundle verifier for the host bootstrap.
--
-- Trust chain: an embedded public key verifies a detached ECDSA-P256 + SHA-256
-- signature over the exact bytes of `manifest.json`; the (now-trusted) manifest
-- carries a SHA-256 for every release artifact, so each downloaded artifact is
-- checked against the manifest by hash. Integrity rests on the signature, never
-- on the transport: an intercepted or cert-relaxed download is accepted iff its
-- signature verifies.
--
-- This module lives in the bootstrap, never in the bundle it verifies — a
-- bundle update can never weaken its own check. It depends only on luvi's
-- OpenSSL (`require("openssl")`) and `boot.json`; it never touches the `vim`
-- shim (which is part of the bundle).

local ossl = require("openssl")
local json = require("boot.json")

local M = {}

-- The capability version this host provides. A bundle whose `min_host_version`
-- exceeds this is refused; bump when the host's runtime surface changes in a
-- way bundles can rely on.
M.HOST_VERSION = 1

-- The release version this host binary was built as (spec §16.32), injected by
-- scripts/release/fuse_host.sh at release-fuse time. nil in the committed
-- source: a development build or a source run has no release identity, and
-- `lw version` reports it as a dev build (or, for a bootstrap-only fuse
-- without a version, an unknown release) rather than guessing. Self-update
-- compares it to the target release to decide whether to replace the host.
-- fuse_host.sh matches this exact line — keep it a single `= nil` assignment.
M.RELEASE_VERSION = nil

-- Trusted public key: the PRODUCTION loomworks release key
-- (keys/loomworks-release.pub.pem), embedded in the committed source so every
-- build -- a release host, a `make install` / `lw --dev` build from a working
-- tree -- verifies official releases (spec §16.12). A public key is not secret.
-- Tests that verify test-signed artifacts pass their key explicitly (the
-- `pubkey_pem` parameters below, or a host fused for the test with
-- scripts/release/fuse_host.sh, which substitutes this block). Nothing at run
-- time -- no environment value, setting or repository file -- changes it.
M.PUBLIC_KEY_PEM = [[-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE8MhoZlT5ww82JmplPiRyta32R8HY
meq3+ZL1wAo7PHHBnHHzXIE+Kab49ClyLvDUGsOR3LG+kU1lH6nxunmO2A==
-----END PUBLIC KEY-----]]

-- Fingerprint (SHA-256 of the DER public key, first 16 hex digits) of the
-- production release key. NOT substituted by fuse_host.sh, so a host fused with
-- another key (a test fuse) can tell that it does not carry the release key and
-- say so when a signature fails. `openssl pkey -pubin -outform der | sha256sum`.
M.RELEASE_KEY_ID = "f03ee2f4bba18602"

--- Lowercase hex SHA-256 of `bytes`.
function M.sha256_hex(bytes)
  return ossl.digest.digest("sha256", bytes, false)
end

--- Verify a detached ECDSA-P256 + SHA-256 signature `sig` (DER bytes) over
--- `data`, against `pubkey_pem` (defaults to the embedded key).
--- @return boolean ok, string|nil err
function M.verify_detached(data, sig, pubkey_pem)
  pubkey_pem = pubkey_pem or M.PUBLIC_KEY_PEM
  if type(data) ~= "string" or type(sig) ~= "string" or #sig == 0 then
    return false, "missing data or signature"
  end
  local ok, pub = pcall(ossl.pkey.read, pubkey_pem, false, "pem")
  if not ok or not pub then return false, "cannot read public key" end
  local vok, res = pcall(function() return pub:verify(data, sig, "sha256") end)
  if not vok then return false, "verify error: " .. tostring(res) end
  if res == true then return true end
  return false, "signature does not verify" .. M.key_note(pubkey_pem)
end

--- Short fingerprint of a PEM public key: the first 16 hex digits of the
--- SHA-256 of its DER encoding (what `openssl pkey -pubin -outform der |
--- sha256sum` prints). nil when the PEM cannot be decoded.
--- @param pem string
--- @return string|nil
function M.key_id(pem)
  if type(pem) ~= "string" then return nil end
  local b64 = pem:gsub("%-%-%-%-%-[^\n]-%-%-%-%-%-", ""):gsub("%s", "")
  local ok, der = pcall(ossl.base64, b64, false)
  if not ok or type(der) ~= "string" or der == "" then return nil end
  return M.sha256_hex(der):sub(1, 16)
end

--- The explanation appended to a failed signature check: which key this lw
--- trusts, whether it is the loomworks release key, and the likely causes
--- (spec §16.12) -- never only "does not verify".
--- @param pubkey_pem string|nil the key the check used (default: embedded)
--- @return string
function M.key_note(pubkey_pem)
  local id = M.key_id(pubkey_pem or M.PUBLIC_KEY_PEM) or "unreadable"
  if id == M.RELEASE_KEY_ID then
    return " against the loomworks release key (" .. id .. "); the file is " ..
      "corrupt or not an official loomworks release (if LOOMWORKS_RELEASE_URL " ..
      "or the release-url setting points at a mirror, check what it serves)"
  end
  return " against key " .. id .. ", which is NOT the loomworks release key (" ..
    M.RELEASE_KEY_ID .. "): this lw was built with a test key and cannot " ..
    "verify official releases; use a release lw or rebuild it from source"
end

--- Validate the decoded manifest's shape. Returns the manifest or nil, err.
local function validate_manifest(m)
  if type(m) ~= "table" then return nil, "manifest is not an object" end
  if m.version == nil or type(m.version) ~= "string" then
    return nil, "manifest missing string 'version'"
  end
  if type(m.min_host_version) ~= "number" then
    return nil, "manifest missing numeric 'min_host_version'"
  end
  if type(m.artifacts) ~= "table" then
    return nil, "manifest missing 'artifacts' object"
  end
  for name, a in pairs(m.artifacts) do
    if type(a) ~= "table" or type(a.sha256) ~= "string" or not a.sha256:match("^%x+$") then
      return nil, "artifact '" .. tostring(name) .. "' missing a hex 'sha256'"
    end
  end
  return m
end

--- Verify `manifest_bytes` against `sig_bytes`, then decode + validate it.
--- The signature check happens on the raw bytes BEFORE decoding, so parsing
--- only ever runs on trusted input.
--- @return table|nil manifest, string|nil err
function M.load_manifest(manifest_bytes, sig_bytes, pubkey_pem)
  local ok, err = M.verify_detached(manifest_bytes, sig_bytes, pubkey_pem)
  if not ok then return nil, "manifest signature: " .. err end
  local decoded, derr = json.decode(manifest_bytes)
  if decoded == nil or decoded == json.null then return nil, derr or "manifest is empty" end
  return validate_manifest(decoded)
end

--- Whether this host can run `manifest`.
--- @return boolean ok, string|nil err
function M.host_compatible(manifest)
  if manifest.min_host_version > M.HOST_VERSION then
    return false, string.format(
      "release %s needs host version >= %d, but this host is version %d; " ..
      "update the lw binary",
      tostring(manifest.version), manifest.min_host_version, M.HOST_VERSION)
  end
  return true
end

--- Verify one artifact's bytes against the manifest by SHA-256 (and size).
--- @return boolean ok, string|nil err
function M.verify_artifact(bytes, name, manifest)
  local a = manifest.artifacts and manifest.artifacts[name]
  if not a then return false, "artifact '" .. tostring(name) .. "' not in manifest" end
  if a.size and #bytes ~= a.size then
    return false, string.format("artifact '%s' size %d != manifest %d", name, #bytes, a.size)
  end
  local got = M.sha256_hex(bytes)
  if got:lower() ~= a.sha256:lower() then
    return false, string.format("artifact '%s' sha256 mismatch", name)
  end
  return true
end

--- Read a file as bytes, or nil + err.
function M.read_file(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local s = f:read("*a"); f:close()
  return s
end

--- Verify an artifact file on disk against the manifest.
function M.verify_artifact_file(path, name, manifest)
  local bytes, err = M.read_file(path)
  if not bytes then return false, "cannot read '" .. path .. "': " .. tostring(err) end
  return M.verify_artifact(bytes, name, manifest)
end

--- Verify a file's SHA-256 against a known hex digest — the pinned-hash check
--- (boot.pin's committed hash is the trust anchor, so no manifest is involved).
--- @return boolean ok, string|nil err
function M.verify_file_sha256(path, expected)
  if type(expected) ~= "string" or not expected:match("^%x+$") then
    return false, "no valid pinned sha256"
  end
  local bytes, err = M.read_file(path)
  if not bytes then return false, "cannot read '" .. path .. "': " .. tostring(err) end
  if M.sha256_hex(bytes):lower() ~= expected:lower() then return false, "sha256 mismatch" end
  return true
end

return M

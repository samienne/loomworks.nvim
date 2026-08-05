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

-- Trusted public key, embedded at build time. THIS IS A TEST KEY — the release
-- build (CI) replaces it with the production public key. Verifying against a
-- test key means only test-signed bundles are accepted, which is the intent
-- until the real key is wired in.
M.PUBLIC_KEY_PEM = [[-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEof9ebYzGUMr12vgj5aRy7+CwNFi6
h8GUtZ2fZzTEL2I4/4KEbeDlX4NJb6A70kWSftOh7dtmr3YXg9PHOrj10A==
-----END PUBLIC KEY-----]]

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
  return false, "signature does not verify"
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

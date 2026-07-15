#!/bin/sh
# Regenerate the distribution verifier test fixtures. Needs the openssl CLI.
# Run from anywhere; operates on its own directory.
#
# The keypair here is TEST-ONLY (see README.md). If you regenerate the keypair,
# also update the embedded test public key in ../../../lua/boot/verify.lua so
# the "embedded key" test case keeps passing.
set -eu
cd "$(dirname "$0")"

# test-only ECDSA P-256 keypair — reuse the existing one if present so the key
# embedded in lua/boot/verify.lua stays valid. Delete the .pem files to mint a
# fresh key (then update the embedded key — see the note printed at the end).
if [ ! -f test_ec_priv.pem ]; then
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out test_ec_priv.pem 2>/dev/null
  openssl pkey -in test_ec_priv.pem -pubout -out test_ec_pub.pem 2>/dev/null
  NEW_KEY=1
fi

# stand-in release artifact: a REAL zip holding a minimal loomworks tree, so
# the extraction / self-update tests can unpack and inspect it. Built with
# python (dev-time only; CI runs the committed fixtures, never this script).
py=$(command -v python || command -v python3)
"$py" - <<'PY'
import zipfile
with zipfile.ZipFile("loomworks-lua-0.0.0-test.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("loomworks/_release_marker.lua", 'return "0.0.0-test"\n')
    z.writestr("loomworks/sub/note.txt", "hello from the release bundle\n")
PY
sha=$(openssl dgst -sha256 -r loomworks-lua-0.0.0-test.zip | cut -d' ' -f1)
size=$(wc -c < loomworks-lua-0.0.0-test.zip | tr -d ' ')

# manifest — the exact bytes below are what gets signed. `bundle` names the Lua
# release zip among the artifacts (used by boot.update).
cat > manifest.json <<JSON
{
  "schema": 1,
  "version": "0.0.0-test",
  "min_host_version": 1,
  "bundle": "loomworks-lua-0.0.0-test.zip",
  "artifacts": {
    "loomworks-lua-0.0.0-test.zip": { "sha256": "$sha", "size": $size }
  }
}
JSON

# detached signature over the manifest, plus a wrong-key signature
openssl dgst -sha256 -sign test_ec_priv.pem -out manifest.json.sig manifest.json
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out .wrong.pem 2>/dev/null
openssl dgst -sha256 -sign .wrong.pem -out manifest.json.wrongsig manifest.json
rm -f .wrong.pem

echo "regenerated fixtures in $(pwd)"
if [ "${NEW_KEY:-}" = "1" ]; then
  echo "NOTE: minted a NEW keypair — update the embedded key in lua/boot/verify.lua"
  echo "      to match test_ec_pub.pem:"
  cat test_ec_pub.pem
fi

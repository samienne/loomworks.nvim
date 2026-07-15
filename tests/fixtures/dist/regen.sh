#!/bin/sh
# Regenerate the distribution verifier test fixtures. Needs the openssl CLI.
# Run from anywhere; operates on its own directory.
#
# The keypair here is TEST-ONLY (see README.md). If you regenerate the keypair,
# also update the embedded test public key in ../../../lua/boot/verify.lua so
# the "embedded key" test case keeps passing.
set -eu
cd "$(dirname "$0")"

# test-only ECDSA P-256 keypair
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out test_ec_priv.pem 2>/dev/null
openssl pkey -in test_ec_priv.pem -pubout -out test_ec_pub.pem 2>/dev/null

# stand-in release artifact + its digest/size
printf 'fake loomworks-lua bundle contents\n' > loomworks-lua-0.0.0-test.zip
sha=$(openssl dgst -sha256 -r loomworks-lua-0.0.0-test.zip | cut -d' ' -f1)
size=$(wc -c < loomworks-lua-0.0.0-test.zip | tr -d ' ')

# manifest — the exact bytes below are what gets signed
cat > manifest.json <<JSON
{
  "schema": 1,
  "version": "0.0.0-test",
  "min_host_version": 1,
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
echo "NOTE: update the embedded key in lua/boot/verify.lua to match test_ec_pub.pem:"
cat test_ec_pub.pem

#!/usr/bin/env bash
# Build the platform-independent release bundle + signed manifest (spec §16.12).
#
#   build_bundle.sh <version> <out_dir> <signing_key.pem> [min_host_version]
#
# Produces in <out_dir>:
#   loomworks-lua-<version>.zip   the system Lua (lua/loomworks/** -> loomworks/…)
#                                 + the release notes (CHANGELOG.md ->
#                                 loomworks/CHANGELOG.md, spec §16.37)
#   manifest.json                 version, min_host_version, bundle name, sha256s
#   manifest.json.sig             ECDSA-P256+SHA-256 signature over manifest.json
#
# The signing key is an EC (P-256) private key PEM. The matching public key is
# what the host embeds (see scripts/release/fuse_host.sh).
set -euo pipefail

version="${1:?usage: build_bundle.sh <version> <out_dir> <key.pem> [min_host_version]}"
out="${2:?missing out_dir}"
key="${3:?missing signing key}"
min_host="${4:-1}"   # minimum host version this bundle requires (<= host HOST_VERSION)

repo="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$out"
bundle="loomworks-lua-${version}.zip"

# The release notes ride inside the signed archive (spec §16.37).
[ -f "$repo/CHANGELOG.md" ] || { echo "build_bundle.sh: $repo/CHANGELOG.md is missing" >&2; exit 1; }

# Deterministic zip of lua/loomworks -> loomworks/… (fixed order + timestamps),
# so identical input yields an identical hash. Python's zipfile is miniz-readable.
# The protocol's schema documents (spec 19.20) ride along as loomworks/protocol/
# (transport.json, meta/, interfaces/; not the frozen snapshots), served by
# the daemon's Root.schema.
python3 - "$repo/lua/loomworks" "$out/$bundle" "$repo/CHANGELOG.md" "$repo/spec/protocol" <<'PY'
import sys, os, zipfile
src, outzip, notes, proto = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
base = os.path.dirname(src)  # .../lua
files = []
for r, _, fs in os.walk(src):
    for f in fs:
        p = os.path.join(r, f)
        files.append((os.path.relpath(p, base).replace(os.sep, "/"), p))
files.append(("loomworks/CHANGELOG.md", notes))
files.append(("loomworks/protocol/transport.json", os.path.join(proto, "transport.json")))
for sub in ("meta", "interfaces"):
    for r, _, fs in os.walk(os.path.join(proto, sub)):
        for f in fs:
            if f.endswith(".json"):
                p = os.path.join(r, f)
                files.append(("loomworks/protocol/" + os.path.relpath(p, proto).replace(os.sep, "/"), p))
files.sort()
with zipfile.ZipFile(outzip, "w", zipfile.ZIP_DEFLATED) as z:
    for arc, p in files:
        zi = zipfile.ZipInfo(arc, date_time=(1980, 1, 1, 0, 0, 0))
        zi.compress_type = zipfile.ZIP_DEFLATED
        zi.external_attr = 0o644 << 16
        with open(p, "rb") as fh:
            z.writestr(zi, fh.read())
print("wrote", outzip)
PY

sha="$(openssl dgst -sha256 -r "$out/$bundle" | cut -d' ' -f1)"
size="$(wc -c < "$out/$bundle" | tr -d ' ')"

cat > "$out/manifest.json" <<JSON
{
  "schema": 1,
  "version": "${version}",
  "min_host_version": ${min_host},
  "bundle": "${bundle}",
  "artifacts": {
    "${bundle}": { "sha256": "${sha}", "size": ${size} }
  }
}
JSON

openssl dgst -sha256 -sign "$key" -out "$out/manifest.json.sig" "$out/manifest.json"

echo "built ${bundle} (${size} bytes) + signed manifest in ${out}"

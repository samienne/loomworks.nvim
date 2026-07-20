# Release signing keys

The standalone `lw` host verifies release bundles with an **ECDSA P-256**
public key embedded at build time (spec §16.12). This directory holds the
**public** key; the matching **private** key is a CI secret and is never
committed.

## One-time setup (maintainer)

Generate the keypair offline:

```sh
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out loomworks-release.key
openssl pkey -in loomworks-release.key -pubout -out keys/loomworks-release.pub.pem
```

Then:

1. **Commit** `keys/loomworks-release.pub.pem` (public — safe to commit). CI
   injects it into `boot/verify.lua` when fusing each host binary
   (`scripts/release/fuse_host.sh`).
2. **Store the private key** as the GitHub Actions secret
   `LOOMWORKS_SIGNING_KEY` (paste the full contents of `loomworks-release.key`).
   CI signs `manifest.json` with it (`scripts/release/build_bundle.sh`).
3. Keep `loomworks-release.key` offline (a password manager / hardware token).
   Do **not** commit it.

Until this key exists, the committed source and tests use a throwaway **test**
key (`tests/fixtures/dist/test_ec_pub.pem`); real releases require the steps
above. Rotating the key means shipping a new host binary (the old key is baked
into old hosts).

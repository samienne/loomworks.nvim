# Distribution verifier test fixtures

These back `tests/standalone/main.lua` (run via `make test-standalone`), which
exercises `lua/boot/verify.lua` — the release-bundle verifier (spec §16.12).

- `test_ec_priv.pem` / `test_ec_pub.pem` — a **throwaway, test-only** ECDSA
  P-256 keypair. It signs nothing real; it exists solely so the verifier test
  is hermetic (no key generation at test time). **Not a secret.** The
  production signing key is generated offline and lives only as a CI secret;
  the production *public* key replaces the embedded test key in
  `boot/verify.lua` at release-build time.
- `manifest.json` — a sample release manifest.
- `manifest.json.sig` — a valid ECDSA-P256+SHA-256 signature over the exact
  bytes of `manifest.json`, made with `test_ec_priv.pem`.
- `manifest.json.wrongsig` — a signature from a *different* key (negative test).
- `loomworks-lua-0.0.0-test.zip` — a stand-in release artifact whose SHA-256 is
  recorded in the manifest.

Regenerate all of the above with `./regen.sh` (needs the `openssl` CLI).

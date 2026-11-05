# Release-signature test fixtures

`test_ec_priv.pem` / `test_ec_pub.pem` are a **throwaway, test-only** ECDSA
P-256 keypair used by `tests/provision_pin_spec.lua` to sign a stand-in
release's `SHA256SUMS` hermetically. They sign nothing real. **Not a secret.**

Regenerate with the `openssl` CLI:

    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out test_ec_priv.pem
    openssl pkey -in test_ec_priv.pem -pubout -out test_ec_pub.pem

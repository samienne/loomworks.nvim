# typescript module

How the typescript module implements the core module contract
(`specification.md` §9). Section numbers in this file are local.

## 1. Detection and identity

- **Marker files**: `tsconfig.json` first, then `package.json` with
  a `typescript` dependency.
- **Keyed tools**: no. The module has a single default tool.
- **Languages**: `"typescript"`.

## 2. Variant mapping

| Variant type | Configuration (in order of preference) |
|--------------|----------------------------------------|
| `"debug"` | `"development"`, then `"default"` |
| `"release"` | `"production"`, then `"default"` |
| `"release_debug"` | — |

Single-config fallback applies.

## 3. V1 scope

In v1, the module is a **shim**: it reports project detection and
participates in configuration sets, but does not provide build
tasks of its own. Launch configs of `command` type (core §9.7) are
the primary way to run TypeScript entry points, typically via
`node` with `${build_dir}` on `NODE_PATH`.

## 4. Launch integration

Typical TypeScript launch config:

```json
"App": {
    "typescript": {},
    "launch": {
        "debug": {
            "command": "node",
            "args": ["assets/scripts/app.js"],
            "working_dir": "${workspace_root}/App",
            "env": {
                "NODE_PATH": "${workspace_root}/App/Debug"
            }
        }
    }
}
```

## 5. LSP integration

Not yet implemented — BACKLOG.md tracks a future `ts_ls` / `vtsls`
integration with tsconfig switching per profile.

## 6. Debug integration

Module language is `"typescript"`. Default adapter is `pwa-node`.
See [`spec/integrations/debug/pwa-node.md`](../integrations/debug/pwa-node.md)
for the command-to-runtimeExecutable transform.

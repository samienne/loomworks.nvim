# typescript module

How the typescript module implements the core module contract
(`specification.md` §8). Section numbers in this file are local.

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
tasks of its own. Launch configs of `command` type (core §8.7) are
the primary way to run TypeScript entry points, typically via
`node` with `${build_dir}` on `NODE_PATH`.

The configure / build / clean tasks the module does return (`npm install`,
`npm run <script>`, `npx tsc --build [<tsconfig>]`) run through the command
interpreter on Windows (`cmd /c`), which re-parses its arguments. Every
argument — in particular the npm script name (from `scripts` in the
configuration) and the tsconfig path (from the configuration or a
`tsconfig.<variant>.json` file in the project) — must consist only of
letters, digits and `. _ : / \ @ -`; anything else fails the task with the
offending argument named, rather than being passed to the interpreter.

The build task applies the build request's raw args (core §8.1 `build_args`)
before that wrapping and under the same check: `npm run <script> -- <args>`
or `npx tsc --build … <args>`. Target selection (`build_targets`) is not
supported.

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

## 7. Environment inventory

Declares `exe:node` and `exe:npm` (build tools; search-path lookup, then
`--version`). `exe:node` is shared with the pwa-node adapter. A project requires
both — its tasks run through them.

npm's version is read from the `package.json` (name `npm`) of the installation
the found `npm` launches — `<dir>/node_modules/npm/` next to `npm.cmd` on
Windows; the package containing the `bin/npm` symlink's target (or the sibling
`../lib/node_modules/npm/`) on Unix — so a health run does not spawn npm (on
Windows `npm.cmd` starts node twice, and npm may write a debug log per run).
Only when no such manifest is found does the probe run `npm --version`.

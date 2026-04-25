# pwa-node debug adapter

js-debug's Node.js mode. Default adapter for the `typescript`
language. Also covers plain JavaScript launch configs.

> **Note:** Adapter pluggability is on the BACKLOG. This file
> documents the adapter-specific request-shape transformation
> currently implemented in `lua/loomworks/debug.lua`.

## 1. Adapter name

`adapter = "pwa-node"`.

## 2. Languages

Default for `typescript`. Default mapping in `debug.lua`:
`["typescript"] = "pwa-node"`.

## 3. Config shape — request-shape transform

JS adapters do not take a `program` + `args` pair the same way native
adapters do. `debug.lua` recognises pwa-node (and pwa-chrome) as
"JS adapters" and rewrites the spec accordingly:

```
spec: { program = <command>, args = { <entry>, ...rest } }

becomes:

config = {
    type = "pwa-node",
    request = "launch",
    name = ...,
    runtimeExecutable = <command>,    -- spec.program
    program = <entry>,                 -- spec.args[1]
    args = <rest>,                     -- spec.args[2..]
    sourceMaps = true,
    console = "integratedTerminal",
    cwd = ..., env = ...,
}
```

The terminal-based console is mandatory for the `on_pid` callback to
work — `runInTerminal` is what gives loomworks the PID needed for
multi-adapter attach.

## 4. Source maps

`sourceMaps = true` is set unconditionally. Lets the adapter resolve
`.ts` → `.js` mapping for stop-at-line and call-frame URLs without
extra config from the user.

## 5. Multi-adapter attach (TS + native)

For launch configs whose `debug` array is `["typescript", "c++"]`:

1. pwa-node is the **primary** — launched first via `dap.run`.
2. The `on_pid` callback receives the runtime's PID from the
   `runInTerminal` response.
3. codelldb (or cppdbg) is then launched as `request = "attach"` with
   that PID, attaching to the same process.

Both sessions stay alive in dap; stops/steps in either pause the
process for the other.

## 6. Mason install

Standard Mason check via `dap.adapters["pwa-node"]`.

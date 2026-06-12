# codelldb debug adapter

Native C/C++/Rust/Zig debugger using LLDB under the hood. Default
adapter for the `c++` language.

> **Note:** Debug adapters are not yet pluggable through a registry
> (BACKLOG.md "Pluggable debug adapter architecture"). Until that
> refactor lands, this file documents adapter-specific behavior
> implemented inside `lua/loomworks/debug.lua`. After the refactor it
> will move to `lua/loomworks/integrations/debug/codelldb.lua`.

## 1. Adapter name

`adapter = "codelldb"`.

## 2. Languages

Resolves for `c++`. Default mapping in `debug.lua`:
`["c++"] = "codelldb"`.

## 3. Config shape

Native launch — `program` is the executable, `args` is the argv tail.
`cwd` and `env` pass through. No request-shape transformation
(`debug.lua`'s JS-adapter transform does not apply).

```
{
    type = "codelldb",
    request = "launch",       -- or "attach" with .pid
    name = ...,
    program = <abs path to executable>,
    args = { ... },
    cwd = ...,
    env = { ... },
}
```

When `spec.request == "attach"`, `config.pid = spec.attach_pid`,
`config.program` is kept for symbol resolution.

## 4. Path resolution

If `program` is a bare command name (not absolute, not Windows
`X:\...`), `debug.lua` resolves it via `vim.fn.exepath()` before
passing to dap. Avoids "program not found" errors for users who put
their build dir on PATH.

## 5. Mason install

If codelldb is not registered in `dap.adapters`, `debug.run` shows a
notification with the Mason install hint and returns `false`. Caller
falls back to non-debug launch.


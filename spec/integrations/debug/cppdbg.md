# cppdbg debug adapter

Microsoft's C/C++ debug adapter (vscode-cpptools). Alternative to
codelldb for `c++` on platforms where the user prefers GDB or has an
existing cppdbg setup.

> **Note:** Adapter pluggability is on the BACKLOG. This file
> documents current adapter-specific behavior in
> `lua/loomworks/debug.lua`.

## 1. Adapter name

`adapter = "cppdbg"`.

## 2. Languages

Selectable for `c++` via `user.json` `debug.adapters` mapping
(`{"c++": "cppdbg"}`). Not the default — codelldb is.

## 3. Config shape

Same native shape as codelldb. `debug.lua` does no request-shape
transformation. The `extra` field is the standard escape hatch for
adapter-specific knobs (e.g., `setupCommands`, `MIMode`,
`miDebuggerPath`).

## 4. Path resolution

Same behavior as codelldb: bare command names resolve via PATH.

## 5. Mason install

Standard Mason check. Loomworks does not vendor a copy.

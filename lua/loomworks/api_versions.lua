--- Pinned API versions for each loomworks plugin-interface category.
---
--- Plugins that ship a module / SDK / LSP integration / debug
--- adapter must declare `M.api_version = N` matching the constant
--- here. Registry-side gatekeepers (modules.get, sdks.get, ...)
--- do an exact-equality check on load and refuse to register
--- mismatched plugins, surfacing a clear error so the user knows
--- to update one side or the other.
---
--- No backwards compatibility — the strict check is intentional.
--- A mismatch means a contract drift that's easier to fix loudly
--- than to paper over with shim layers.
---
--- **When to bump**: a version bumps when the contract surface
--- changes in a way that breaks existing implementations —
--- required field added, function signature changed, return shape
--- changed, capability flag semantics shifted. Adding a new
--- optional field with a sensible default does NOT require a bump
--- (since old plugins continue to satisfy the contract).
---
--- The strict-equality enforcement makes false bumps painful (every
--- plugin breaks), which naturally discourages drive-by version
--- bumps.

return {
    --- Module interface (lua/loomworks/modules/*.lua).
    --- Covers: id, languages, capability flags (has_keyed_tools,
    --- has_options, has_devices), detect, info, map_variant,
    --- progress_parser, the device sub-interface (gated by
    --- has_devices), the keyed-tool sub-interface (gated by
    --- has_keyed_tools).
    module = 1,

    --- SDK provider interface (lua/loomworks/sdks/*.lua).
    --- Covers: id, detect, query_capabilities, kits_from_sdk,
    --- display_name / display_name_for.
    sdk = 1,
}

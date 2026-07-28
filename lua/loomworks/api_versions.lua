--- Pinned API versions for each loomworks plugin-interface category.
---
--- Plugins declare `M.api_version = N` matching the constant here; the
--- registry does an exact-equality check on load and refuses mismatched
--- plugins with a clear error. No backwards compatibility. Bump when the
--- contract surface changes in a way that breaks existing implementations
--- (required field added, signature/return shape changed, flag semantics
--- shifted); a new optional field with a default does not require a bump.

return {
    --- Module interface (lua/loomworks/modules/*.lua).
    module = 1,

    --- SDK provider interface (lua/loomworks/sdks/*.lua).
    sdk = 1,
}

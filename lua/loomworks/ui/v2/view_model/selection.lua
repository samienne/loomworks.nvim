--- loomworks/ui/v2/view_model/selection.lua — Selection state.
---
--- Owns the overview cursor position and the optional pin. Both are
--- references into the overview presentation: a `{ section, row }`
--- index pair when the source is the cursor, and a stable
--- `{ kind, key }` ref when pinned (pin survives presentation rebuilds).
---
--- The inspector reads `effective_ref()` to decide what to show.

--- @class loomworks.uiv2.Selection
--- @field _cursor { section: integer, row: integer }
--- @field _pinned { kind: string, key: string }|nil
local Selection = {}
Selection.__index = Selection

--- @return loomworks.uiv2.Selection
function Selection.new()
    return setmetatable({
        _cursor = { section = 1, row = 1 },
        _pinned = nil,
    }, Selection)
end

--- Move the cursor to a (section, row) pair in the overview presentation.
--- @param section integer 1-based section index
--- @param row integer 1-based row index within the section
function Selection:cursor_to(section, row)
    self._cursor = { section = section, row = row }
end

--- @return { section: integer, row: integer }
function Selection:cursor()
    return self._cursor
end

--- Pin the inspector to a stable ref so cursor moves don't change the inspector.
--- @param ref { kind: string, key: string }|nil
function Selection:pin(ref)
    self._pinned = ref
end

--- @return { kind: string, key: string }|nil
function Selection:pinned()
    return self._pinned
end

function Selection:unpin()
    self._pinned = nil
end

return Selection

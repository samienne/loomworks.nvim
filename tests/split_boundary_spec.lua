--- Guard test for the plugin/binary split (ARCHITECTURE.md "Plugin/binary
--- boundary"). Static scan only: no workspace, no build.
---
---   tests/split/boundary.lua   which side every lua/ module is on
---   tests/split/allowlist.lua  today's coupling, which may only shrink
---   tests/split/scan.lua       the scanner (and its documented blind spots)

local scan = dofile((debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
    :gsub("split_boundary_spec%.lua$", "split/scan.lua")))
local allow = dofile(scan.root .. "/tests/split/allowlist.lua")

local SEE = "See ARCHITECTURE.md \"Plugin/binary boundary\"."
local RULE = "The Neovim plugin may reach the `lw` binary's code only through the "
    .. "daemon protocol; it must not gain new requires of binary-side modules or new "
    .. "reach-ins to domain objects. " .. SEE

local function fail(title, lines, hint)
    error(("%s\n  %s\n%s"):format(title, table.concat(lines, "\n  "), hint), 0)
end

local current = scan.current()

describe("plugin/binary boundary", function()
    it("classifies every module under lua/ exactly once", function()
        if #current.unclassified > 0 then
            fail("Modules on no side of the plugin/binary split:", current.unclassified,
                "Add a pattern for each to tests/split/boundary.lua (plugin, shared or "
                .. "binary). " .. SEE)
        end
        if #current.ambiguous > 0 then
            fail("Modules matched by more than one side:", current.ambiguous,
                "Make the patterns in tests/split/boundary.lua disjoint. " .. SEE)
        end
        assert.is_true(current.counts.plugin > 0 and current.counts.binary > 0)
    end)

    it("adds no plugin->binary or shared->binary require edges (ratchet 1)", function()
        local new, stale = {}, {}
        local allowed = allow.edges or {}
        for _, rel in ipairs(scan.sorted_keys(current.edges)) do
            local ok = {}
            for _, t in ipairs(allowed[rel] or {}) do ok[t] = true end
            for _, t in ipairs(current.edges[rel]) do
                if not ok[t] then new[#new + 1] = rel .. " -> " .. t end
            end
        end
        for _, rel in ipairs(scan.sorted_keys(allowed)) do
            local now = {}
            for _, t in ipairs(current.edges[rel] or {}) do now[t] = true end
            for _, t in ipairs(allowed[rel]) do
                if not now[t] then stale[#stale + 1] = rel .. " -> " .. t end
            end
        end
        if #new > 0 then
            fail("New require of a binary-side module from plugin/shared code:", new, RULE)
        end
        if #stale > 0 then
            fail("Allow-listed edges that no longer exist:", stale,
                "Good: delete them from `edges` in tests/split/allowlist.lua so the "
                .. "list keeps shrinking. " .. SEE)
        end
    end)

    it("adds no dynamic requires in plugin/shared code", function()
        local diff = {}
        local keys, seen = {}, {}
        for _, t in ipairs({ current.dynamic, allow.dynamic or {} }) do
            for rel in pairs(t) do
                if not seen[rel] then seen[rel] = true; keys[#keys + 1] = rel end
            end
        end
        table.sort(keys)
        for _, rel in ipairs(keys) do
            local now, rec = current.dynamic[rel] or 0, (allow.dynamic or {})[rel] or 0
            if now ~= rec then
                diff[#diff + 1] = ("%s: %d now, %d recorded"):format(rel, now, rec)
            end
        end
        if #diff > 0 then
            fail("Dynamic require sites changed (target not statically checkable):", diff,
                "A new one must be shown not to load binary-side code, then recorded; a "
                .. "removed one is deleted from `dynamic` in tests/split/allowlist.lua. "
                .. SEE)
        end
    end)

    it("does not raise domain reach-ins per plugin file (ratchet 2)", function()
        local rose, dropped = {}, {}
        local ceil = allow.reach_ins or {}
        for _, rel in ipairs(scan.sorted_keys(current.reach_ins)) do
            local now, max = current.reach_ins[rel], ceil[rel] or 0
            if now > max then
                rose[#rose + 1] = ("%s: %d sites, ceiling %d"):format(rel, now, max)
            end
        end
        for _, rel in ipairs(scan.sorted_keys(ceil)) do
            local now = current.reach_ins[rel] or 0
            if now < ceil[rel] then
                dropped[#dropped + 1] = ("%s: %d sites, ceiling %d"):format(rel, now, ceil[rel])
            end
        end
        if #rose > 0 then
            fail("More `core:` / `get_workspace(` / `._workspace` reach-ins than recorded:",
                rose, RULE)
        end
        if #dropped > 0 then
            fail("Reach-ins dropped below the recorded ceiling:", dropped,
                "Good: lower (or delete) the number in `reach_ins` in "
                .. "tests/split/allowlist.lua so it cannot creep back. " .. SEE)
        end
    end)
end)

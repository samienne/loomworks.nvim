--- loomworks/daemon/snapshot.lua — serialize a Workspace to the wire, and
--- hydrate a projection Workspace from it (DAEMON.md §2: one deserializer, two
--- sources).
---
--- The daemon owns the authoritative Workspace and the disk-reading half
--- (`merge.merge` / `module.info` / tool detection). Over the wire it sends the
--- SAME three file-shaped tables the on-disk deserializer consumes — the shared
--- baseline (`_shared_baseline`), the working copy (`_serialize_user`), and the
--- cache (`_serialize_cache`) — plus the resolved `tools_by_type` so the client
--- does NOT re-detect toolchains. The client then runs the identical
--- `Workspace:remerge` path (the same code external file changes use), so
--- `data_model.refresh` rebuilds every domain object, provenance, intent view,
--- and Tool object with no re-detection.
---
--- `merge.merge` (invoked inside remerge) reads the PROJECT sources
--- (CMakeLists.txt, presets). The daemon and its clients are co-located on one
--- host, so the client reads the same project files locally — that is the
--- project, not one of the three workspace files, and both sides see it
--- identically. Only the toolchain detection (expensive, machine-scoped) crosses
--- the wire.

local M = {}

--- Serialize a live Workspace into the wire snapshot payload.
--- @param workspace table the authoritative Workspace
--- @return table snapshot { config, user, cache, tools_by_type, name }
function M.serialize(workspace)
    return {
        -- The raw parsed loomworks.json baseline, kept verbatim in memory. Sent
        -- directly (not re-derived via _serialize_config, which would emit only
        -- currently-published items and lose baseline fidelity).
        config = workspace._shared_baseline,
        user = workspace:_serialize_user(),
        cache = workspace:_serialize_cache(),
        tools_by_type = workspace:get_tools_by_type() or {},
        name = workspace.name,
    }
end

--- Build a projection Workspace from a wire snapshot, reusing the identical
--- assembly + remerge path the on-disk loader uses.
--- @param core table a Core (its `_deps` supply the module registry, merge, normalize, log)
--- @param root string workspace root (project sources are read locally from here)
--- @param snap table a snapshot produced by M.serialize
--- @return table workspace the projection Workspace
function M.hydrate(core, root, snap)
    local Workspace = require("loomworks.workspace").Workspace
    local ws = Workspace.new(core, {
        root = root,
        name = snap.name,
        config = snap.config,
        user = snap.user,
        cache = snap.cache,
    })
    -- Install the daemon-resolved toolchains so remerge resolves Tool objects
    -- from the shipped detection results instead of scanning.
    ws._tools_by_type = snap.tools_by_type or {}
    ws._tool_state = "scanned"
    ws:remerge(snap.config, snap.cache, snap.user)
    return ws
end

return M

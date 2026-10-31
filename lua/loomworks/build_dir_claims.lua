--- loomworks/build_dir_claims.lua — one build directory per configuration
--- (core §1.7 "One build directory per configuration", invariant 22).
---
--- Pure: given the build directories resolved for every profile's
--- ProfileProjects (one claim each), decides which configurations collide and
--- which of them keeps each directory. Used by the load (data_model), by the
--- workspace's targeted rebuilds and skeleton paths, and by the commands that
--- refuse to create a collision (Workspace:_new_build_dir_collision).

local M = {}

--- @class loomworks.BuildDirClaim
--- @field project_key string
--- @field config_name string the configuration's name
--- @field tool_key string|nil the (primary) tool key it was resolved with
--- @field config_key string the unit's config_key (configuration + tool key)
--- @field abs string the resolved build directory (absolute)
--- @field shared boolean the module reported the directory as a shared tree

--- The refusal message of a refused configuration (core §1.7).
--- @param dir string the directory as shown
--- @param pk string project key
--- @param cfg string configuration name
--- @param owner_pk string
--- @param owner_cfg string
--- @return string
function M.message(dir, pk, cfg, owner_pk, owner_cfg)
    return "Build directory " .. dir .. " of " .. pk .. "/" .. cfg
        .. " is already used by " .. owner_pk .. "/" .. owner_cfg .. "; "
        .. pk .. "/" .. cfg .. " cannot be built until its build directory resolves elsewhere."
end

--- A directory as shown in the message: relative to the workspace root when
--- under it, else as resolved.
--- @param abs string
--- @param root string|nil
--- @return string
local function display(abs, root)
    if root and root ~= "" then
        local prefix = root:gsub("[/\\]+$", "") .. "/"
        local a = abs:gsub("\\", "/")
        local p = prefix:gsub("\\", "/")
        if a:sub(1, #p) == p and #a > #p then return a:sub(#p + 1) end
    end
    return abs
end

--- (project key, configuration name) byte order.
local function pair_less(a, b)
    if a.project_key ~= b.project_key then return a.project_key < b.project_key end
    return a.config_name < b.config_name
end

--- Resolve the claims.
--- @param claims loomworks.BuildDirClaim[]
--- @param entries table<string, table>|nil the cache's `build_dirs` (key → entry)
--- @param key_of fun(dir: string): string|nil the directory identity (`_build_dir_identity`)
--- @param opts? { root?: string, entry_dir?: fun(key: string, entry: table): string|nil }
--- @return table<loomworks.BuildDirClaim, string> refused claim → message
--- @return { message: string, project_key: string, config_name: string }[] refusals one per refused configuration and directory, ordered
function M.resolve(claims, entries, key_of, opts)
    opts = opts or {}
    local groups, order = {}, {}
    for _, c in ipairs(claims) do
        local id = c.abs and c.abs ~= "" and key_of(c.abs) or nil
        if id then
            local g = groups[id]
            if not g then
                g = { id = id, abs = c.abs, pairs = {}, pair_list = {} }
                groups[id] = g
                order[#order + 1] = id
            end
            local pk = c.project_key .. "\0" .. c.config_name
            local p = g.pairs[pk]
            if not p then
                p = { project_key = c.project_key, config_name = c.config_name, claims = {} }
                g.pairs[pk] = p
                g.pair_list[#g.pair_list + 1] = p
            end
            p.claims[#p.claims + 1] = c
        end
    end
    table.sort(order)

    local refused, refusals = {}, {}
    local entry_ids  -- lazily: entry → directory identity
    for _, id in ipairs(order) do
        local g = groups[id]
        local list = g.pair_list
        if #list > 1 then
            table.sort(list, pair_less)
            -- Claimants: one configuration, or a shared tree's configurations
            -- (same project, same tool, both reported shared) together.
            local parent = {}
            for i = 1, #list do parent[i] = i end
            local function find(i)
                while parent[i] ~= i do i = parent[i] end
                return i
            end
            for i = 1, #list do
                for j = i + 1, #list do
                    local a, b = list[i], list[j]
                    if a.project_key == b.project_key then
                        local linked = false
                        for _, ca in ipairs(a.claims) do
                            for _, cb in ipairs(b.claims) do
                                if ca.shared and cb.shared and ca.tool_key == cb.tool_key then
                                    linked = true
                                end
                            end
                        end
                        if linked then parent[find(j)] = find(i) end
                    end
                end
            end
            local claimants, by_root = {}, {}
            for i, p in ipairs(list) do
                local r = find(i)
                local cl = by_root[r]
                if not cl then
                    cl = { pairs = {} }  -- first pair = the claimant's first configuration
                    by_root[r] = cl
                    claimants[#claimants + 1] = cl
                end
                cl.pairs[#cl.pairs + 1] = p
            end
            if #claimants > 1 then
                -- The cache entries for this directory name their owner.
                if not entry_ids then
                    entry_ids = {}
                    for key, e in pairs(entries or {}) do
                        if type(e) == "table" then
                            local dir = e.build_dir
                            if not dir and opts.entry_dir then dir = opts.entry_dir(key, e) end
                            entry_ids[#entry_ids + 1] = { e = e, id = dir and key_of(dir) or nil }
                        end
                    end
                end
                local named = {}
                for _, cl in ipairs(claimants) do
                    for _, ei in ipairs(entry_ids) do
                        if ei.id == id then
                            for _, p in ipairs(cl.pairs) do
                                if p.project_key == ei.e.project_key then
                                    for _, c in ipairs(p.claims) do
                                        if c.config_key == ei.e.config_key then named[cl] = true end
                                    end
                                end
                            end
                        end
                    end
                end
                local owner
                for _, cl in ipairs(claimants) do
                    if (next(named) == nil or named[cl])
                            and (not owner or pair_less(cl.pairs[1], owner.pairs[1])) then
                        owner = cl
                    end
                end
                local o = owner.pairs[1]
                local dir = display(g.abs, opts.root)
                for _, cl in ipairs(claimants) do
                    if cl ~= owner then
                        for _, p in ipairs(cl.pairs) do
                            local msg = M.message(dir, p.project_key, p.config_name,
                                o.project_key, o.config_name)
                            for _, c in ipairs(p.claims) do refused[c] = msg end
                            refusals[#refusals + 1] = { message = msg,
                                project_key = p.project_key, config_name = p.config_name }
                        end
                    end
                end
            end
        end
    end
    return refused, refusals
end

return M

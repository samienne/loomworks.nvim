--- loomworks/dependency.lua — Dependency resolution utilities.

local M = {}

--- Topologically sort ProfileProject objects by their project dependencies.
--- Projects with no dependencies come first. Uses Kahn's algorithm.
--- @param pps loomworks.ProfileProject[]
--- @return loomworks.ProfileProject[] sorted
--- @return string|nil error message (circular dependency)
function M.toposort(pps)
    -- Build lookup: project object → ProfileProject
    local pp_by_project = {}
    local has_any_deps = false
    for _, pp in ipairs(pps) do
        if pp._project then
            pp_by_project[pp._project] = pp
            if pp._project.depends_on then
                has_any_deps = true
            end
        end
    end

    -- Fast path: no dependencies → just sort alphabetically
    if not has_any_deps then
        table.sort(pps, function(a, b) return a.project_key < b.project_key end)
        return pps, nil
    end

    -- Build adjacency and in-degree from Project.depends_on references
    local in_degree = {}
    local dependents = {} -- project → list of projects that depend on it
    for _, pp in ipairs(pps) do
        local project = pp._project
        if not project then goto continue end
        in_degree[project] = 0
        dependents[project] = dependents[project] or {}
        ::continue::
    end

    for _, pp in ipairs(pps) do
        local project = pp._project
        if not project or not project.depends_on then goto continue end
        for _, dep in ipairs(project.depends_on) do
            -- Only count dependencies that are in this profile's projects
            if pp_by_project[dep] then
                in_degree[project] = (in_degree[project] or 0) + 1
                dependents[dep] = dependents[dep] or {}
                dependents[dep][#dependents[dep] + 1] = project
            end
        end
        ::continue::
    end

    -- Kahn's algorithm
    local queue = {}
    for project, degree in pairs(in_degree) do
        if degree == 0 then
            queue[#queue + 1] = project
        end
    end
    -- Stable sort: alphabetical within same dependency level
    table.sort(queue, function(a, b) return a.key < b.key end)

    local sorted = {}
    while #queue > 0 do
        local project = table.remove(queue, 1)
        local pp = pp_by_project[project]
        if pp then
            sorted[#sorted + 1] = pp
        end
        for _, dependent in ipairs(dependents[project] or {}) do
            in_degree[dependent] = in_degree[dependent] - 1
            if in_degree[dependent] == 0 then
                queue[#queue + 1] = dependent
            end
        end
        -- Re-sort for stability
        table.sort(queue, function(a, b) return a.key < b.key end)
    end

    -- Append items without a project reference (shouldn't happen in practice)
    for _, pp in ipairs(pps) do
        if not pp._project then
            sorted[#sorted + 1] = pp
        end
    end

    -- Check for cycles (only among items that have projects)
    local with_project = 0
    for _, pp in ipairs(pps) do
        if pp._project then with_project = with_project + 1 end
    end
    if #sorted - (#pps - with_project) < with_project then
        -- Fall back to alphabetical on cycle
        table.sort(pps, function(a, b) return a.project_key < b.project_key end)
        return pps, "circular dependency detected"
    end

    return sorted, nil
end

return M

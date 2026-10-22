--- loomworks/ui/helpers.lua — Shared rendering helpers for status sections.

local M = {}

--- Format a progress update as a compact string like "[2/10]".
--- @param p loomworks.ProgressUpdate|nil
--- @return string
function M.format_progress(p)
    if not p then return "" end
    if p.current and p.total and p.total > 0 then
        local str = " [" .. p.current .. "/" .. p.total .. "]"
        if p.message then str = str .. " " .. p.message end
        return str
    elseif p.message then
        return " " .. p.message
    end
    return ""
end

--- Format elapsed seconds as a compact duration like "1m23s" or "42s".
--- @param seconds number|nil
--- @return string
function M.format_elapsed(seconds)
    if not seconds then return "" end
    local s = math.floor(seconds)
    if s < 60 then
        return " " .. s .. "s"
    end
    local m = math.floor(s / 60)
    s = s % 60
    if m < 60 then
        return " " .. m .. "m" .. string.format("%02d", s) .. "s"
    end
    local h = math.floor(m / 60)
    m = m % 60
    return " " .. h .. "h" .. string.format("%02d", m) .. "m"
end

M.STATUS_HL = {
    unconfigured     = "LoomworksUnconfigured",
    configured       = "LoomworksConfigured",
    built            = "LoomworksBuilt",
    failed_configure = "LoomworksFailed",
    failed_build     = "LoomworksFailed",
    configuring      = "LoomworksRunning",
    building         = "LoomworksRunning",
    deleting         = "LoomworksDeleting",
    cleaning         = "LoomworksDeleting",
    unknown          = "LoomworksUnknown",
}

M.STATUS_ICON = {
    unconfigured     = "○",
    configured       = "◐",
    built            = "✓",
    failed_configure = "✗",
    failed_build     = "✗",
    unknown          = "?",
}

--- Marker color (separate from row text color). Mapped to the
--- standard Diagnostic groups so the marker reads as severity
--- independent of the row's entity color (profiles green,
--- projects blue, etc.).
M.STATUS_MARKER_HL = {
    unconfigured     = "Comment",
    configured       = "Comment",
    built            = "DiagnosticOk",
    failed_configure = "DiagnosticError",
    failed_build     = "DiagnosticError",
    deleting         = "DiagnosticError",
    cleaning         = "DiagnosticError",
    configuring      = "DiagnosticWarn",
    building         = "DiagnosticWarn",
    unknown          = "DiagnosticWarn",
}

--- Get the marker highlight group for a status. Falls back to
--- `Comment` (calm) when the status is unknown to the table.
--- @param status string
--- @return string
function M.status_marker_hl(status)
    return M.STATUS_MARKER_HL[status] or "Comment"
end

--- Format a status label with its icon prefix.
--- Running/deleting states use the spinner so no icon is added.
--- Composite labels (e.g. "1 building, 1 failed") pass through unchanged.
--- @param status string
--- @return string
function M.format_status(status)
    local icon = M.STATUS_ICON[status]
    if icon then
        return icon .. " " .. status
    end
    return status
end

--- Get the status icon as a tree marker (icon + trailing space).
--- Returns "○ " for unknown/composite statuses.
--- @param status string
--- @return string marker
function M.status_marker(status)
    return (M.STATUS_ICON[status] or "○") .. " "
end

--- The status of a unit as the workspace view carries it (`state`,
--- `deleting_reason`; view_state.lua) with its running step's progress,
--- which is not in the view (API.md §14.4): the label, its highlight, the
--- progress text and whether it spins.
--- @param u table a unit's live state from `loomworks.view.Workspace/1`
--- @param prog? { progress?: { current?: integer, total?: integer, message?: string }, elapsed?: number }
---        the running step's progress and elapsed seconds (the page's progress source)
--- @return string status, string hl_group, string progress_str, boolean is_spinning
function M.unit_status(u, prog)
    local state = u.state or "unconfigured"
    if state == "deleting" then
        return u.deleting_reason or "deleting", M.STATUS_HL.deleting, "", true
    end
    if state == "configuring" or state == "building" then
        prog = prog or {}
        local progress_str = M.format_progress(prog.progress) .. M.format_elapsed(prog.elapsed)
        return state, M.STATUS_HL[state] or "DiagnosticWarn", progress_str, true
    end
    -- Map ConfigUnit state names back to cache state names for HL lookup.
    local cache_state = state
    if state == "configure_failed" then cache_state = "failed_configure" end
    if state == "build_failed" then cache_state = "failed_build" end
    return cache_state, M.STATUS_HL[cache_state] or "Comment", "", false
end

--- Render a unit's build directory and targets as leaf lines (its status is
--- on the parent node's line).
--- @param tree loomworks.Tree
--- @param build_dir string|nil
--- @param targets table<string, table>|nil by name: { type, artifact?, dependencies? }
--- @param fold_prefix? string prefix for foldable sub-nodes (e.g. "App:Debug:ninja-gcc-12")
function M.render_unit_details(tree, build_dir, targets, fold_prefix)
    if build_dir then
        tree:leaf("Build dir: " .. build_dir, "Comment")
    end
    -- The toolchain (generator/compiler/SDK kit) is shown once per profile in
    -- the profile-level Toolchain row, so it's not repeated per config here.
    if targets and next(targets) then
        M.render_targets(tree, targets, fold_prefix)
    end
end

--- Map target type to compact display labels.
local TARGET_TYPE_LABELS = {
    executable       = "Executables",
    static_library   = "Static Libraries",
    shared_library   = "Shared Libraries",
    module_library   = "Module Libraries",
    object_library   = "Object Libraries",
    interface_library = "Interface Libraries",
    npm_script       = "Scripts",
    launch_config    = "Launch Configs",
}

--- Display order for target type groups.
local TARGET_TYPE_ORDER = {
    "executable", "npm_script", "launch_config",
    "static_library", "shared_library",
    "module_library", "object_library", "interface_library",
}

--- Render targets sub-tree, grouped by type.
--- @param tree loomworks.Tree
--- @param targets table<string, loomworks.CachedTarget>
--- @param fold_prefix? string prefix for fold keys
function M.render_targets(tree, targets, fold_prefix)
    local by_type = {}
    local total = 0
    for name, tgt in pairs(targets) do
        local t = tgt.type
        by_type[t] = by_type[t] or {}
        by_type[t][#by_type[t] + 1] = { name = name, tgt = tgt }
        total = total + 1
    end
    for _, list in pairs(by_type) do
        table.sort(list, function(a, b) return a.name < b.name end)
    end

    local prefix = fold_prefix and (fold_prefix .. ":") or ""

    tree:node("Targets (" .. total .. ")", {
        fold_key = prefix .. "targets",
        hl = "Comment",
    }, function()
        for _, type_key in ipairs(TARGET_TYPE_ORDER) do
            local group = by_type[type_key]
            -- Always show Executables (even when empty), only show others if non-empty
            if group or type_key == "executable" then
                local count = group and #group or 0
                local group_label = TARGET_TYPE_LABELS[type_key] or type_key
                tree:node(group_label .. " (" .. count .. ")", {
                    fold_key = prefix .. "ttype:" .. type_key,
                    hl = "Comment",
                }, function()
                    if not group then return end
                    for _, entry in ipairs(group) do
                        local has_deps = entry.tgt.dependencies and #entry.tgt.dependencies > 0
                        local has_artifact = entry.tgt.artifact ~= nil
                        if has_deps or has_artifact then
                            tree:node(entry.name, {
                                fold_key = prefix .. "target:" .. entry.name,
                                hl = "Comment",
                            }, function()
                                if has_artifact then
                                    tree:leaf("Path: " .. entry.tgt.artifact, "Comment")
                                end
                                if has_deps then
                                    tree:leaf("Links: " .. table.concat(entry.tgt.dependencies, ", "), "Comment")
                                end
                            end)
                        else
                            tree:leaf(entry.name, "Comment")
                        end
                    end
                end)
            end
        end
    end)
end

--- The next intent of the `P` cycle: local → local+shared → shared → local.
--- All three states always available. Data stays in user.json while cycling.
--- @param intent string|nil an item's current intent
--- @return "local"|"shared"|"local+shared"
function M.next_intent(intent)
    if intent == "local" then return "local+shared" end
    if intent == "local+shared" then return "shared" end
    return "local"
end

--- Cycle an item's intent (`P`) through the model command; a refusal is
--- notified.
--- @param row table the `view.Workspace/1` row of a profile, configuration set, project or configuration
--- @param ws? loomworks.Workspace the page's workspace (default: the loaded one)
function M.cycle_intent(row, ws)
    local model = require("loomworks.ui.model_calls")
    model.call(ws, "Workspace/1.set_intent", { item = row, intent = M.next_intent(row.intent) }, function(r)
        local ok, err = model.result(r)
        if not ok then
            vim.notify("loomworks: " .. tostring(err or "the intent was not saved"), vim.log.levels.ERROR)
        end
    end)
end

--- Publish one item now; a refusal is notified.
--- @param row table the item's `view.Workspace/1` row
--- @param ws? loomworks.Workspace the page's workspace (default: the loaded one)
function M.publish_one(row, ws)
    local model = require("loomworks.ui.model_calls")
    model.call(ws, "Workspace/1.publish_one", { item = row }, function(r)
        local ok, err = model.result(r)
        if not ok then
            vim.notify("loomworks: " .. tostring(err or "publish failed: unknown"), vim.log.levels.ERROR)
        end
    end)
end

--- Revert one item to its baseline; a refusal is notified.
--- @param row table the item's `view.Workspace/1` row
--- @param ws? loomworks.Workspace the page's workspace (default: the loaded one)
function M.revert_one(row, ws)
    local model = require("loomworks.ui.model_calls")
    model.call(ws, "Workspace/1.revert_one", { item = row }, function(r)
        local ok, err = model.result(r)
        if not ok then
            vim.notify("loomworks: " .. tostring(err or "revert failed: unknown"), vim.log.levels.ERROR)
        end
    end)
end

--- Get the label for the next intent transition.
--- @param intent string|nil an item's `_intent` (a view row's `intent`)
--- @return string
function M.intent_action_label(intent)
    if intent == "local" then
        return "Share (→ local + shared)"
    elseif intent == "local+shared" then
        return "Unpin local (→ shared)"
    else
        return "Pin local (→ local)"
    end
end


--- Sort items into intent groups and render with separators.
--- Groups: Local + Shared (with pin icon on user-pinned), Local, Shared (dimmed).
--- Empty groups are hidden.
--- @param tree loomworks.Tree
--- @param items table[] view rows to group, by their `intent`
--- @param render_fn fun(tree: loomworks.Tree, item: table, group: string) render a single item
--- @param default? string the group of a row without an intent (default "local")
function M.render_grouped(tree, items, render_fn, default)
    local both = {}
    local local_items = {}
    local shared = {}

    for _, item in ipairs(items) do
        local group = item.intent or default or "local"
        if group == "local+shared" then
            both[#both + 1] = item
        elseif group == "local" then
            local_items[#local_items + 1] = item
        else
            shared[#shared + 1] = item
        end
    end

    if #both > 0 then
        tree:leaf("── Local + Shared ──", "NonText")
        for _, item in ipairs(both) do
            render_fn(tree, item, "local+shared")
        end
    end
    if #local_items > 0 then
        tree:leaf("── Local ──", "NonText")
        for _, item in ipairs(local_items) do
            render_fn(tree, item, "local")
        end
    end
    if #shared > 0 then
        tree:leaf("── Shared ──", "NonText")
        for _, item in ipairs(shared) do
            render_fn(tree, item, "shared")
        end
    end
end

--- A description summary for a picker / dialog entry (spec/ui.md §1.16):
--- "  <summary>" fitted to 40 display columns, rendered inert, as a plain
--- string (no highlight markup). "" when there is no description.
--- @param desc string|nil
--- @param cols? integer default 40
--- @return string
function M.picker_summary(desc, cols)
    local d = require("loomworks.description")
    local sum = d.summary(desc)
    if not sum then return "" end
    return "  " .. d.fit(d.inert_line(sum), cols or 40)
end

--- Render a `Description ▸ <summary>` row in an editor dialog (spec/ui.md
--- §1.16). `<CR>` opens the description editor for `item`; the description
--- is saved by the editor itself (independently of the dialog's accept), and
--- `refresh` re-renders the dialog afterwards. Nothing for a nil item (a set
--- or configuration that does not exist yet) or a generated configuration.
--- @param t loomworks.Tree
--- @param item table|nil
--- @param label string padded label, e.g. "Description"
--- @param refresh fun()|nil
function M.description_row(t, item, label, refresh)
    if not item then return end
    local editor = require("loomworks.ui.description_editor")
    if not editor.editable(item) then return end
    local summary = M.picker_summary(item.description)
    t:item(label .. (summary ~= "" and summary or "  (none)") .. " ▸", {
        hl = item.description and "LoomworksActionable" or "Comment",
        direct = true,
        on_enter = function()
            editor.open(item, { on_saved = function() if refresh then refresh() end end })
        end,
    })
end

--- The chunks of a project's launch rows (spec/ui.md §1.8): `{name}  {summary}
--- {runs}`, the summaries forming a column (at most 36 display columns, blank
--- when absent) before the open-ended command line, which is cut to `width`.
--- @param launches { name: string, config: table }[]
--- @param width integer text width available after the row's indentation
--- @return table<string, { [1]: string, [2]: string }[]> chunks per launch name
function M.launch_row_chunks(launches, width)
    local d = require("loomworks.description")
    local name_w, sum_w = 0, 0
    local sums = {}
    for _, lc in ipairs(launches) do
        name_w = math.max(name_w, d.width(lc.name))
        local s = d.summary(type(lc.config) == "table" and d.normalize(lc.config.description) or nil)
        if s then
            s = d.inert_line(s)
            sums[lc.name] = s
            sum_w = math.max(sum_w, math.min(36, d.width(s)))
        end
    end
    local out = {}
    for _, lc in ipairs(launches) do
        local cfg = type(lc.config) == "table" and lc.config or {}
        local runs = cfg.target and ("target:" .. cfg.target) or (cfg.command or "")
        if type(cfg.args) == "table" and #cfg.args > 0 then
            runs = runs .. " " .. table.concat(cfg.args, " ")
        end
        local chunks = { { lc.name .. string.rep(" ", name_w - d.width(lc.name)), "LoomworksVariant" } }
        local used = name_w
        if sum_w > 0 then
            local s = sums[lc.name] and d.fit(sums[lc.name], sum_w) or ""
            chunks[#chunks + 1] = { "  " .. s .. string.rep(" ", sum_w - d.width(s)), "LoomworksDescription" }
            used = used + 2 + sum_w
        end
        local room = math.max(8, width - used - 2)
        chunks[#chunks + 1] = { "  " .. d.fit(d.inert_line(runs), room), "Comment" }
        out[lc.name] = chunks
    end
    return out
end

--- Add the description affordances to a describable node's opts (spec/ui.md
--- §1.16): the summary on the node line (`description`, render-only), `K`
--- showing the full text (`hover`, only when there is one), and the `e` /
--- "Edit description" action (`on_describe`). Returns `opts`.
--- @param opts table node/item opts
--- @param item table|nil Project|Configuration|ConfigurationSet|Profile
--- @return table opts
function M.with_description(opts, item)
    if not item then return opts end
    M.describe(opts, item.description, item._description_from_module)
    return M.describe_action(opts, item)
end

--- The render half of `with_description`: the summary on the node line and
--- `K` showing the full text (only when there is one).
--- @param opts table node/item opts
--- @param desc string|nil
--- @param from_module boolean|nil a module default (read-only)
--- @return table opts
function M.describe(opts, desc, from_module)
    opts.description = desc
    if desc then
        opts.hover = function()
            local d = require("loomworks.description")
            local out = vim.split(d.inert(desc), "\n", { plain = true })
            if from_module then
                out[#out + 1] = ""
                out[#out + 1] = "(from the project files; edit them to change it)"
            end
            return out
        end
    end
    return opts
end

--- A describable item named by its `view.Workspace/1` row (step 5o C2a): the
--- description editor's item for a row — its kind and label, the row's
--- description, and the row the edit names (`_row`: model_calls sends its
--- id, or in the `in-process` mode the object bound to it). A generated
--- configuration's row is read-only (`_readonly` the reason, core §1.10).
--- @param kind "profile"|"configuration set"|"project"|"configuration"|"launch configuration"
--- @param row table
--- @param label? string the display name (default the row's key or name)
--- @return table
function M.row_item(kind, row, label)
    local item = { _kind = kind, _label = label or row.key or row.name, _row = row, description = row.description }
    if kind == "configuration" and (row.auto_gen or not row.user or row.source_missing) then
        item._readonly = "configuration '" .. tostring(row.key) .. "' is generated from the project files, "
            .. "which also supply its description; declare a configuration that inherits "
            .. "it to give it your own"
    end
    return item
end

--- Whether a routed action (one ui/model_calls names by its row) can act on
--- `row`: in `daemon` mode the row has an id (model_calls sends it, a row
--- without one is refused) — never whether the editor's model has the
--- object yet (a project the daemon just added); in the `in-process` mode
--- the in-process view bound an object to it.
--- @param ctx { mode?: "daemon"|"in-process", ref: fun(row: table): table|nil } the section context
--- @param row table|nil a view row
--- @return boolean
function M.actionable(ctx, row)
    if row == nil then return false end
    if ctx.mode == "daemon" then return row.id ~= nil end
    return ctx.ref(row) ~= nil
end

--- The action half of `with_description`: `e` / "Edit description".
--- @param opts table node/item opts
--- @param item table|nil the described domain object (nil: no action)
--- @return table opts
function M.describe_action(opts, item)
    if not item then return opts end
    opts.on_describe = function()
        require("loomworks.ui.description_editor").open(item)
    end
    return opts
end

--- The read-only saved test-targets line (spec/ui.md "Saved test targets
--- line", core §1.3.4) as `{text, hl}` chunks, or nil when nothing is
--- declared along the chain. Formats a resolved view
--- (`Project:saved_tests_view`): names in list order, cut with `+N` to
--- `width`; the source in parentheses unless the list is the item's own; a
--- missing entry carries a ⚠. A name listed several times appears once per
--- entry; args are not shown.
--- @param view { source: string|nil, invalid: boolean|nil, entries: { label: string, missing: boolean }[] }|nil
--- @param width integer|nil available display width
--- @return {[1]: string, [2]: string}[]|nil
function M.test_targets_chunks(view, width)
    if not view then return nil end
    local src = view.source and ("  (" .. view.source .. ")") or ""
    if view.invalid then
        return { { "Tests: ", "Comment" }, { "⚠ invalid (not an array)", "DiagnosticWarn" },
            src ~= "" and { src, "Comment" } or nil }
    end
    if #view.entries == 0 then return { { "Tests: none (explicit)", "Comment" } } end
    local names = {}
    for _, e in ipairs(view.entries) do
        names[#names + 1] = { (e.missing and "⚠ " or "") .. e.label, e.missing and "DiagnosticWarn" or "Comment" }
    end
    local avail = (width or 100) - vim.fn.strdisplaywidth("Tests: " .. src)
    local shown, used = 0, 0
    for i, n in ipairs(names) do
        local w = vim.fn.strdisplaywidth(n[1]) + (i > 1 and 2 or 0)
        local rest = #names - i
        local tail = rest > 0 and (2 + #("+" .. rest)) or 0
        if i > 1 and used + w + tail > avail then break end
        used = used + w
        shown = i
    end
    local chunks = { { "Tests: ", "Comment" } }
    for i = 1, shown do
        if i > 1 then chunks[#chunks + 1] = { ", ", "Comment" } end
        chunks[#chunks + 1] = names[i]
    end
    if shown < #names then chunks[#chunks + 1] = { ", +" .. (#names - shown), "Comment" } end
    if src ~= "" then chunks[#chunks + 1] = { src, "Comment" } end
    return chunks
end

return M

--- loomworks/ui/launch_editor.lua — Editor for project launch configurations.
---
--- Tree+View dialog for editing launch config properties: name, command,
--- args, working directory, and environment variables.

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")

local M = {}

--- Open the launch config editor.
--- @param opts table
---   title: string
---   name: string — launch config name (editable)
---   command: string
---   args: string[]
---   working_dir: string
---   env: table<string, string>
---   validate?: fun(result): boolean, string|nil
---   deploy: table<string, table>|nil — destination → source descriptor
---   projects: loomworks.Project[]|nil — workspace projects for deploy editor
---   profile: loomworks.Profile|nil — active profile for deploy target resolution
---   workspace: loomworks.Workspace|nil — for deploy destination preview
---   launch_project: loomworks.Project|nil — the project owning this launch config
---   on_accept: fun(result: { name: string, command: string, args: string[], working_dir: string, env: table<string, string>, deploy: table<string, table>|nil })
---   on_cancel: fun()
function M.open(opts)
    local name = opts.name
    local command = opts.command or ""
    local args = vim.deepcopy(opts.args or {})
    local working_dir = opts.working_dir or ""
    local env = vim.deepcopy(opts.env or {})
    local deploy = opts.deploy and vim.deepcopy(opts.deploy) or {}
    local debug_langs = vim.deepcopy(opts.debug or {})
    local name_error = nil

    local function revalidate()
        if not opts.validate then
            name_error = nil
            return
        end
        if name == "" then
            name_error = nil
            return
        end
        local ok, err = opts.validate({
            name = name, command = command,
            args = args, working_dir = working_dir, env = env,
        })
        name_error = not ok and err or nil
    end

    local accepted = false
    local tree, view

    --- Prompt for a string value and refresh.
    local function edit_string(prompt, current, on_done)
        vim.ui.input({
            prompt = prompt,
            default = current,
        }, function(value)
            if value then
                on_done(value)
                if view then view:refresh() end
            end
        end)
    end

    local function render_fn(t)
        t._level = 1

        t:leaf(opts.title or "Launch Configuration", "Title")
        t:blank()

        -- Name
        local name_val = name ~= "" and name or "(empty)"
        local name_hl = name_error and "DiagnosticError"
                or (name ~= "" and "LoomworksActionable" or "Comment")
        t:item("Name       " .. name_val .. " ▸", {
            hl = name_hl,
            direct = true,
            on_enter = function()
                edit_string("Name: ", name, function(v)
                    name = v
                    revalidate()
                end)
            end,
        })
        if name_error then
            t:leaf(name_error, "DiagnosticError")
        end

        -- Command
        local cmd_val = command ~= "" and command or "(empty)"
        t:item("Command    " .. cmd_val .. " ▸", {
            hl = command ~= "" and "LoomworksActionable" or "Comment",
            direct = true,
            on_enter = function()
                edit_string("Command: ", command, function(v) command = v end)
            end,
        })

        -- Args (structured list)
        if #args > 0 then
            t:leaf("Args:", "Comment")
            local n_args = #args
            for ai, arg in ipairs(args) do
                local captured_ai = ai
                t:item("  " .. arg .. " ▸", {
                    hl = "LoomworksActionable",
                    direct = true,
                    on_move_up = captured_ai > 1 and function()
                        args[captured_ai], args[captured_ai - 1] = args[captured_ai - 1], args[captured_ai]
                        if view then view:refresh() end
                    end or nil,
                    on_move_down = captured_ai < n_args and function()
                        args[captured_ai], args[captured_ai + 1] = args[captured_ai + 1], args[captured_ai]
                        if view then view:refresh() end
                    end or nil,
                    on_enter = function()
                        local eq_pos = args[captured_ai]:find("=")
                        if eq_pos then
                            -- Key=value: offer to edit key, value (text), or value (path)
                            local key = args[captured_ai]:sub(1, eq_pos - 1)
                            local val = args[captured_ai]:sub(eq_pos + 1)
                            vim.ui.select({ "Edit value as text", "Edit value as path", "Edit key", "Edit whole arg" }, {
                                prompt = key .. "=",
                            }, function(choice)
                                if not choice then return end
                                if choice == "Edit value as text" then
                                    edit_string(key .. "=", val, function(v)
                                        args[captured_ai] = key .. "=" .. v
                                    end)
                                elseif choice == "Edit value as path" then
                                    require("loomworks.ui.path_editor").open({
                                        title = "Argument Value: " .. key,
                                        path = val,
                                        project = opts.launch_project,
                                        workspace = opts.workspace,
                                        profile = opts.profile,
                                        on_accept = function(path)
                                            args[captured_ai] = key .. "=" .. path
                                            if view then view:refresh() end
                                        end,
                                        on_cancel = function() end,
                                    })
                                elseif choice == "Edit key" then
                                    edit_string("Key: ", key, function(k)
                                        args[captured_ai] = k .. "=" .. val
                                    end)
                                else
                                    edit_string("Arg: ", args[captured_ai], function(v)
                                        args[captured_ai] = v
                                    end)
                                end
                            end)
                        else
                            -- Plain arg: edit as text or path
                            vim.ui.select({ "Edit as text", "Edit as path" }, {
                                prompt = "Edit argument:",
                            }, function(choice)
                                if not choice then return end
                                if choice == "Edit as text" then
                                    edit_string("Arg: ", args[captured_ai], function(v)
                                        args[captured_ai] = v
                                    end)
                                else
                                    require("loomworks.ui.path_editor").open({
                                        title = "Argument Path",
                                        path = args[captured_ai],
                                        project = opts.launch_project,
                                        workspace = opts.workspace,
                                        profile = opts.profile,
                                        on_accept = function(path)
                                            args[captured_ai] = path
                                            if view then view:refresh() end
                                        end,
                                        on_cancel = function() end,
                                    })
                                end
                            end)
                        end
                    end,
                    on_delete = function()
                        table.remove(args, captured_ai)
                        if view then view:refresh() end
                    end,
                })
            end
        else
            t:leaf("Args: (none)", "Comment")
        end

        t:item("  ▸ Add argument", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                edit_string("Argument: ", "", function(v)
                    if v ~= "" then
                        args[#args + 1] = v
                    end
                end)
            end,
        })
        t:item("  ▸ Add key=value argument", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                vim.ui.input({ prompt = "Key (e.g., --config): " }, function(key)
                    if not key or key == "" then return end
                    vim.ui.select({ "Text value", "Path value" }, {
                        prompt = "Value type:",
                    }, function(choice)
                        if not choice then return end
                        if choice == "Text value" then
                            vim.ui.input({ prompt = key .. "=" }, function(val)
                                if val then
                                    args[#args + 1] = key .. "=" .. val
                                    if view then view:refresh() end
                                end
                            end)
                        else
                            require("loomworks.ui.path_editor").open({
                                title = "Value for " .. key,
                                path = "",
                                project = opts.launch_project,
                                workspace = opts.workspace,
                                profile = opts.profile,
                                on_accept = function(path)
                                    args[#args + 1] = key .. "=" .. path
                                    if view then view:refresh() end
                                end,
                                on_cancel = function() end,
                            })
                        end
                    end)
                end)
            end,
        })
        t:item("  ▸ Add path argument", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                require("loomworks.ui.path_editor").open({
                    title = "Path Argument",
                    path = "",
                    project = opts.launch_project,
                    workspace = opts.workspace,
                    profile = opts.profile,
                    on_accept = function(path)
                        args[#args + 1] = path
                        if view then view:refresh() end
                    end,
                    on_cancel = function() end,
                })
            end,
        })

        -- Working directory (opens path editor)
        local wd_val = working_dir ~= "" and working_dir or "(default)"
        t:item("Work dir   " .. wd_val .. " ▸", {
            hl = working_dir ~= "" and "LoomworksActionable" or "Comment",
            direct = true,
            on_enter = function()
                require("loomworks.ui.path_editor").open({
                    title = "Working Directory",
                    path = working_dir,
                    project = opts.launch_project,
                    workspace = opts.workspace,
                    profile = opts.profile,
                    on_accept = function(path)
                        working_dir = path
                        if view then view:refresh() end
                    end,
                    on_cancel = function() end,
                })
            end,
            on_delete = function()
                working_dir = ""
                if view then view:refresh() end
            end,
        })

        t:blank()

        -- Environment variables
        local env_keys = {}
        for k in pairs(env) do env_keys[#env_keys + 1] = k end
        table.sort(env_keys)

        if #env_keys > 0 then
            t:leaf("Environment:", "Comment")
            for _, k in ipairs(env_keys) do
                local ek = k  -- capture
                t:item("  " .. k .. "=" .. env[k] .. " ▸", {
                    hl = "LoomworksActionable",
                    direct = true,
                    on_enter = function()
                        edit_string(ek .. "=", env[ek], function(v)
                            if v == "" then
                                env[ek] = nil
                            else
                                env[ek] = v
                            end
                        end)
                    end,
                    on_delete = function()
                        env[ek] = nil
                        if view then view:refresh() end
                    end,
                })
            end
        else
            t:leaf("Environment: (none)", "Comment")
        end

        t:item("  ▸ Add variable", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                vim.ui.input({ prompt = "Variable name: " }, function(key)
                    if not key or key == "" then return end
                    vim.ui.input({ prompt = key .. "=" }, function(val)
                        if val then
                            env[key] = val
                            if view then view:refresh() end
                        end
                    end)
                end)
            end,
        })

        -- "Add from project variable" — maps a project variable to an env var
        local proj = opts.launch_project
        if proj and proj.variables and next(proj.variables) then
            t:item("  ▸ Add from project variable", {
                hl = "LoomworksActionable",
                direct = true,
                on_enter = function()
                    local var_names = {}
                    for vn in pairs(proj.variables) do
                        var_names[#var_names + 1] = vn
                    end
                    table.sort(var_names)
                    vim.ui.select(var_names, { prompt = "Project variable:" }, function(var_name)
                        if not var_name then return end
                        vim.ui.input({
                            prompt = "Env variable name: ",
                            default = var_name:upper(),
                        }, function(env_key)
                            if not env_key or env_key == "" then return end
                            env[env_key] = "${" .. var_name .. "}"
                            if view then view:refresh() end
                        end)
                    end)
                end,
            })
        end

        t:blank()

        -- Deploy steps (sources can be single or array)
        local deploy_mod = require("loomworks.deploy")
        local deploy_keys = {}
        for k in pairs(deploy) do deploy_keys[#deploy_keys + 1] = k end
        table.sort(deploy_keys)

        local function format_source(src)
            local display = src.project or "?"
            if src.target then display = display .. " : " .. src.target
            elseif src.path then display = display .. " : " .. src.path end
            if src.configuration then display = display .. " (" .. src.configuration .. ")" end
            if src.pre_build then display = display .. " [pre-build]" end
            return display
        end

        if #deploy_keys > 0 then
            t:leaf("Deploy:", "Comment")
            for _, dest in ipairs(deploy_keys) do
                local sources = deploy_mod.normalize_sources(deploy[dest])
                local captured_dest = dest

                for si, src in ipairs(sources) do
                    local captured_si = si
                    local prefix = si == 1
                        and ("  " .. dest .. " <- ")
                        or ("  " .. string.rep(" ", #dest) .. " <- ")
                    t:item(prefix .. format_source(src) .. " ▸", {
                        hl = "LoomworksActionable",
                        direct = true,
                        on_enter = function()
                            require("loomworks.ui.deploy_editor").open({
                                destination = captured_dest,
                                source = vim.deepcopy(src),
                                projects = opts.projects or {},
                                profile = opts.profile,
                                workspace = opts.workspace,
                                launch_project = opts.launch_project,
                                existing_destinations = deploy_keys,
                                current_destination = captured_dest,
                                on_accept = function(new_dest, new_source)
                                    local cur = deploy_mod.normalize_sources(deploy[captured_dest])
                                    cur[captured_si] = new_source
                                    if new_dest ~= captured_dest then
                                        -- Destination changed: remove from old, add to new
                                        table.remove(cur, captured_si)
                                        if #cur == 0 then
                                            deploy[captured_dest] = nil
                                        elseif #cur == 1 then
                                            deploy[captured_dest] = cur[1]
                                        else
                                            deploy[captured_dest] = cur
                                        end
                                        -- Add to new destination
                                        local new_existing = deploy[new_dest]
                                        if new_existing then
                                            local new_arr = deploy_mod.normalize_sources(new_existing)
                                            new_arr[#new_arr + 1] = new_source
                                            deploy[new_dest] = new_arr
                                        else
                                            deploy[new_dest] = new_source
                                        end
                                    else
                                        -- Same destination: update in place
                                        if #cur == 1 then
                                            deploy[captured_dest] = cur[1]
                                        else
                                            deploy[captured_dest] = cur
                                        end
                                    end
                                    if view then view:refresh() end
                                end,
                                on_cancel = function() end,
                            })
                        end,
                        on_delete = function()
                            local cur = deploy_mod.normalize_sources(deploy[captured_dest])
                            table.remove(cur, captured_si)
                            if #cur == 0 then
                                deploy[captured_dest] = nil
                            elseif #cur == 1 then
                                deploy[captured_dest] = cur[1]
                            else
                                deploy[captured_dest] = cur
                            end
                            if view then view:refresh() end
                        end,
                    })
                end
            end
        else
            t:leaf("Deploy: (none)", "Comment")
        end

        t:item("  ▸ Add deploy step", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                require("loomworks.ui.deploy_editor").open({
                    destination = "",
                    source = nil,
                    projects = opts.projects or {},
                    profile = opts.profile,
                    workspace = opts.workspace,
                    launch_project = opts.launch_project,
                    existing_destinations = deploy_keys,
                    on_accept = function(new_dest, new_source)
                        local existing = deploy[new_dest]
                        if existing then
                            -- Append to existing destination
                            local arr = deploy_mod.normalize_sources(existing)
                            arr[#arr + 1] = new_source
                            deploy[new_dest] = arr
                        else
                            deploy[new_dest] = new_source
                        end
                        if view then view:refresh() end
                    end,
                    on_cancel = function() end,
                })
            end,
        })

        -- Debug languages
        t:blank()
        if #debug_langs > 0 then
            t:leaf("Debug:", "Comment")
            for di, lang in ipairs(debug_langs) do
                local captured_di = di
                local debug_mod = require("loomworks.debug")
                local adapter = opts.workspace
                    and debug_mod.resolve_adapter(opts.workspace, lang)
                    or debug_mod.default_adapter(lang) or "?"
                local prefix = di == 1 and " (primary) " or " (attach)  "
                t:item("  " .. lang .. prefix .. "→ " .. adapter, {
                    hl = "LoomworksActionable",
                    direct = true,
                    on_delete = function()
                        table.remove(debug_langs, captured_di)
                        if view then view:refresh() end
                    end,
                    on_move_up = captured_di > 1 and function()
                        debug_langs[captured_di], debug_langs[captured_di - 1] =
                            debug_langs[captured_di - 1], debug_langs[captured_di]
                        if view then view:refresh() end
                    end or nil,
                    on_move_down = captured_di < #debug_langs and function()
                        debug_langs[captured_di], debug_langs[captured_di + 1] =
                            debug_langs[captured_di + 1], debug_langs[captured_di]
                        if view then view:refresh() end
                    end or nil,
                })
            end
        else
            t:leaf("Debug: (default from project language)", "Comment")
        end

        t:item("  ▸ Add debug language", {
            hl = "LoomworksActionable",
            direct = true,
            on_enter = function()
                -- Collect available languages from workspace modules
                local available = {}
                local seen = {}
                -- Add languages from debug.lua known list
                for _, lang in ipairs(require("loomworks.debug").known_languages()) do
                    if not seen[lang] then
                        seen[lang] = true
                        available[#available + 1] = lang
                    end
                end
                -- Add languages from workspace modules
                if opts.workspace and opts.workspace._modules then
                    for _, mod in ipairs(opts.workspace._modules) do
                        for _, lang in ipairs(mod.languages) do
                            if not seen[lang] then
                                seen[lang] = true
                                available[#available + 1] = lang
                            end
                        end
                    end
                end
                -- Filter out already-added languages
                local filtered = {}
                local added = {}
                for _, l in ipairs(debug_langs) do added[l] = true end
                for _, l in ipairs(available) do
                    if not added[l] then
                        filtered[#filtered + 1] = l
                    end
                end
                if #filtered == 0 then
                    vim.notify("loomworks: no more languages to add", vim.log.levels.INFO)
                    return
                end
                vim.ui.select(filtered, {
                    prompt = "Add debug language:",
                }, function(choice)
                    if not choice then return end
                    debug_langs[#debug_langs + 1] = choice
                    if view then view:refresh() end
                end)
            end,
        })

        t:blank()
        t:leaf("[Enter] change  [D] remove  [C-j/C-k] move  [y] accept  [q] cancel", "Comment")
    end

    tree = Tree.new(render_fn)

    local orig_on_key = tree.on_key
    function tree:on_key(action, line)
        if action == "accept" then
            if name == "" then
                name_error = "name cannot be empty"
                return { refresh = true }
            end
            if command == "" then
                vim.notify("loomworks: command cannot be empty", vim.log.levels.ERROR)
                return {}
            end
            if name_error then
                return {}
            end
            accepted = true
            view:close()
            opts.on_accept({
                name = name,
                command = command,
                args = args,
                working_dir = working_dir,
                env = env,
                deploy = deploy,
                debug = #debug_langs > 0 and debug_langs or nil,
            })
            return {}
        end
        return orig_on_key(self, action, line)
    end

    local parent_win = vim.api.nvim_get_current_win()

    local height = 0.7
    local width = 90

    view = View.new({
        widget = tree,
        lock_to_items = true,
        win = {
            width = width,
            height = height,
            zindex = 65,
            backdrop = 65,
            title = " " .. (opts.title or "Launch Configuration") .. " ",
            title_pos = "center",
        },
        keymaps = {
            ["<CR>"]    = "enter",
            ["D"]       = "delete",
            ["<C-j>"]   = "move_down",
            ["<C-k>"]   = "move_up",
            ["y"]       = "accept",
        },
        events = {},
        on_close = function()
            if parent_win and vim.api.nvim_win_is_valid(parent_win) then
                vim.api.nvim_set_current_win(parent_win)
            end
            if not accepted then
                opts.on_cancel()
            end
        end,
    })

    view:open()
end

return M

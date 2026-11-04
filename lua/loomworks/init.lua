--- loomworks/init.lua — Public API facade.
--- Creates a singleton Core instance and delegates all calls to it.

local M = {}

local Core = require("loomworks.core")
local events = require("loomworks.events")

--- The singleton core instance. Created at module load time.
--- @type loomworks.Core
local core = Core.new()

-- The editor's views (spec §19.13): only the daemon's (loomworks.views
-- builds nothing, step 6b-α).
local views = require("loomworks.views")

--- Auto-load mode. Default: "auto".
--- @type string|false
local auto_load_mode = "auto"

--- Task output window config (Snacks.win overrides).
--- @type table
local task_output_win = {}

--- Access the underlying core instance (for advanced use / testing).
--- @return loomworks.Core
function M._core()
    return core
end

--- Emit an event. Used by components that bypass Core (e.g. task_tracker).
--- @param event string
--- @param data any
function M._emit(event, data)
    events.emit(event, data)
end

-- ---------------------------------------------------------------------------
-- Setup & workspace
-- ---------------------------------------------------------------------------

--- Load the workspace at `root` (spec §19.16 "End state"): the editor loads
--- NO workspace of its own (step 6b-α): it records the root (the deferred-LSP
--- gate, §9.7) and observes the workspace daemon of it — everything it shows
--- comes from the daemon's views and replies. Only the editor attaches (the
--- CLI never calls setup).
--- @param root string
local function load(root)
    -- Another root's pending state goes. A successor follows: no
    -- `workspace_closed` (§9.7), so buffers the gate holds for this root
    -- stay held until the daemon's configuration.
    core:shutdown({ successor = true })
    core:set_pending_root(root)
    require("loomworks.daemon.observer").attach(M.workspace_root(), { binary = M._binary_config })
end
M._load = load

--- Set up default keymaps.
--- @param opts? { keys?: boolean|table }
local function setup_keymaps(opts)
    if opts and opts.keys == false then return end

    local map = vim.keymap.set
    map("n", "<leader>ww", function() M.toggle() end, { desc = "Loomworks info" })
    map("n", "<leader>wb", function() M.build_target() end, { desc = "Build default target" })
    map("n", "<leader>wB", function() M.build_profile() end, { desc = "Build active profile" })
    map("n", "<leader>wr", function() M.debug_target() end, { desc = "Debug target" })
    map("n", "<leader>wR", function() M.launch_target() end, { desc = "Launch target" })
    map("n", "<leader>ws", function() M.pick_profile() end, { desc = "Select profile" })
    map("n", "<leader>wO", function()
        require("loomworks.device_log").toggle()
    end, { desc = "Toggle device log output" })
    map("n", "<F5>", function() M.debug_target() end, { desc = "Debug target" })
    map("n", "<S-F5>", function() M.stop_target() end, { desc = "Stop launch" })
    -- Tests — loomtest is optional; skip test keymaps if not installed
    local ok_loomtest, loomtest = pcall(require, "loomtest")
    if ok_loomtest then
        map("n", "<leader>tt", function() loomtest.debug_nearest() end, { desc = "Debug nearest test" })
        map("n", "<leader>tT", function() loomtest.run_nearest() end, { desc = "Run nearest test" })
        map("n", "<leader>tf", function() loomtest.debug_file() end, { desc = "Debug file tests" })
        map("n", "<leader>tF", function() loomtest.run_file() end, { desc = "Run file tests" })
    end
end

--- Check that hard dependencies are available. Refuses setup with a
--- clear message if any is missing. Hard deps: `overseer`, `snacks`.
--- @return boolean ok, string|nil err
local function check_hard_dependencies()
    for _, dep in ipairs({ "overseer", "snacks" }) do
        if not pcall(require, dep) then
            return false, "loomworks requires " .. dep .. ".nvim; please install it and restart"
        end
    end
    return true
end

--- Initialize loomworks.
--- Registers keymaps and fidget integration. Workspace loading is handled
--- separately by auto_load when a file is opened, or by calling load()
--- explicitly.
--- Refuses to set up if required dependencies (overseer, snacks) are missing.
--- @param opts? { root?: string, auto_load?: string|false, task_output_win?: table, keys?: boolean, lsp?: boolean|table, progress_max_width?: integer, log_level?: string, binary?: any }
function M.setup(opts)
    local ok, err = check_hard_dependencies()
    if not ok then
        vim.notify(err, vim.log.levels.ERROR)
        return
    end

    if opts and opts.auto_load ~= nil then
        auto_load_mode = opts.auto_load
    end
    if opts and opts.task_output_win then
        task_output_win = opts.task_output_win
    end
    if opts and opts.binary ~= nil then
        -- The host binary the editor launches the daemon from (spec §19.16).
        local setting, warning = require("loomworks.provision.select").check_setting(opts.binary)
        M._binary_config = setting
        if warning then vim.notify("loomworks: " .. warning, vim.log.levels.WARN) end
    end
    if opts and opts.log_level then
        local log = require("loomworks.log")
        local levels = { error = log.ERROR, warn = log.WARN, info = log.INFO, debug = log.DEBUG }
        local level = levels[opts.log_level] or opts.log_level
        core._deps.log:set_level(level)
    end

    setup_keymaps(opts)

    local fidget_opts = nil
    if opts and opts.progress_max_width ~= nil then
        if type(opts.progress_max_width) == "number" and opts.progress_max_width > 0 then
            fidget_opts = { progress_max_width = opts.progress_max_width }
        else
            vim.notify(
                "loomworks: progress_max_width must be a positive integer; got "
                    .. tostring(opts.progress_max_width),
                vim.log.levels.WARN)
        end
    end
    require("loomworks.fidget").setup(fidget_opts)

    -- Record the workspace root synchronously BEFORE installing servers (spec
    -- §9.7 / FIX A). `setup_servers` calls `vim.lsp.enable`, which resolves
    -- `root_dir` synchronously for already-open buffers; the deferred-start
    -- gate must already know the root then, or it resolves immediately and the
    -- server starts ungated (to be restarted once the workspace loads). The
    -- later `core:setup(opts)` sets the same pending root again (idempotent).
    if opts and opts.root then
        core:set_pending_root(opts.root)
    end

    -- LSP: unless explicitly disabled (`opts.lsp == false`), install server
    -- configs via vim.lsp.config. Defaults in; user may override per-server
    -- via `opts.lsp = { clangd = {...} }` or disable with `lsp = false`.
    if not (opts and opts.lsp == false) then
        local lsp_opts = opts and type(opts.lsp) == "table" and opts.lsp or nil
        require("loomworks.lsp").setup_servers(lsp_opts)
    end

    -- Load workspace if root is specified (auto_load passes root explicitly)
    if opts and opts.root then
        load(opts.root)
    end
end

--- Get the current auto-load mode.
--- @return string|false
function M._auto_load_mode()
    return auto_load_mode
end

--- The setup option `binary` (spec §19.16 "Host binary"), checked.
--- @type loomworks.provision.BinarySetting|nil
M._binary_config = nil

--- The host binary the editor would launch the workspace daemon from, with
--- every source tried (spec §19.16): `:LoomworksDaemon status` and
--- `:checkhealth loomworks`. Resolved afresh; launches nothing.
--- @return loomworks.provision.Selection
function M.host_binary_selection()
    -- (The selection does not depend on the workspace: the editor reads no
    -- lw.pin, a global or managed lw follows it itself.)
    local _, _, sel = require("loomworks.provision.select").resolve(vim.fn.getcwd(),
        { setting = M._binary_config })
    return sel
end

--- The tasks observed in the workspace daemon (spec §19.16), in start order;
--- empty while no observer runs. Never loads the daemon modules.
--- @return loomworks.RemoteTask[]
function M.get_daemon_tasks()
    local mod = package.loaded["loomworks.daemon.observer"]
    local obs = type(mod) == "table" and mod.current() or nil
    return obs and obs:tasks() or {}
end

--- The status page's Runtime line (spec/ui.md §1.1): the observer's state
--- or note; nil while no observer runs. `warn` selects the warning
--- highlight.
--- @return string|nil text, boolean warn
function M.daemon_runtime_line()
    return require("loomworks.daemon.observer").runtime_line()
end

--- `:LoomworksDaemon connect` (spec §19.16): connect to the workspace daemon,
--- launching it when none is live. Returns false + why when it cannot.
--- @return boolean ok, string|nil why
function M.daemon_connect()
    local root = M.workspace_root()
    if not root then return false, "no workspace loaded" end
    local observer = require("loomworks.daemon.observer")
    local obs = observer.current() or observer.attach(root, { binary = M._binary_config })
    if not obs then return false, "no workspace loaded" end
    obs:start(true)
    return true
end

--- The daemon-mode facade (spec §19.16 "Public API"): the getters answer
--- from the daemon's views through it (the editor holds no model).
--- @return table
local function daemon_rows()
    return require("loomworks.daemon.facade")
end

--- Get the active configuration set: the `view.Workspace/1` `config_sets`
--- record whose `active` is true (a copy, with its id; nil while the view is
--- not held).
--- @return loomworks.ViewConfigSet|nil
function M.get_active_configuration_set()
    return daemon_rows().active_configuration_set()
end

--- Get the active workspace: always nil in the editor (it holds no model,
--- spec §19.16 "Public API"); the `lw` binary's loaded one (cli.lua).
--- @return loomworks.Workspace|nil
function M.get_workspace()
    return core:get_workspace()
end

--- Get the last setup error (e.g., cache version mismatch).
--- @return { root: string, message: string }|nil
function M.get_setup_error()
    return core:get_setup_error()
end

--- The configured workspace root, known synchronously even during async init
--- (spec §9.7): the root the editor observes the daemon of.
--- nil when setup was never called for a root.
--- @return string|nil
function M.workspace_root()
    return core:workspace_root()
end

--- The root of the workspace the editor has loaded (auto-load's "already
--- loaded" check): the root it observes the daemon of (it holds no model,
--- step 6b-α); nil when nothing is loaded.
--- @return string|nil
function M.loaded_root()
    local mod = package.loaded["loomworks.daemon.observer"]
    local obs = type(mod) == "table" and mod.current() or nil
    return obs and obs.root or nil
end

--- Tear down what the editor has loaded (`:LoomworksReload`): the workspace
--- daemon's observer (the daemon keeps running, §19.11) and the pending
--- root.
function M.shutdown()
    local mod = package.loaded["loomworks.daemon.observer"]
    if type(mod) == "table" then mod.detach() end
    core:shutdown()
end

--- Get the task output window config (Snacks.win overrides).
--- @return table
function M.get_task_output_win()
    return task_output_win
end

--- Register an event listener.
--- @param event string
--- @param fn function
function M.on(event, fn)
    events.on(event, fn)
end

--- Remove an event listener registered with `M.on`.
--- @param event string
--- @param fn function
function M.off(event, fn)
    events.off(event, fn)
end

--- Emit `lsp_buf_state_changed` (spec §7) for the LSP layer, which reaches the
--- event bus only through this facade.
--- @param payload { bufnr: integer, server: string, state: loomworks.LspBufState }
function M._emit_lsp_buf_state(payload)
    events.emit("lsp_buf_state_changed", payload)
end

-- ---------------------------------------------------------------------------
-- Object factories
-- ---------------------------------------------------------------------------

-- The getters below (spec §19.16 "Public API") return plain copies of the
-- daemon's view rows, with their ids, and nil while the view they read is
-- not held.

--- Get the active profile: the `view.Workspace/1` `profiles` record whose
--- `active` is true.
--- @return loomworks.ViewProfile|nil
function M.get_active_profile()
    return daemon_rows().active_profile()
end

--- Get all profiles: the `view.Workspace/1` `profiles` records, by key (nil
--- while not held).
--- @return table<string, loomworks.ViewProfile>|nil
function M.get_profiles()
    return daemon_rows().profiles()
end

--- Get tool entries for the configuration sets UI: per configuration set
--- name, the `view.Workspace/1` `profiles` records of that set (nil while
--- not held).
--- @return table<string, loomworks.ViewProfile[]>|nil set_name -> entries
function M.get_tool_entries()
    return daemon_rows().tool_entries()
end

--- Get all projects: the `view.Workspace/1` `projects` records, by key (nil
--- while not held).
--- @return table<string, loomworks.ViewProject>|nil
function M.get_projects()
    return daemon_rows().projects()
end

--- Get all configuration sets: the `view.Workspace/1` `config_sets`
--- records, by name (nil while not held).
--- @return table<string, loomworks.ViewConfigSet>|nil
function M.get_config_sets()
    return daemon_rows().config_sets()
end

-- ---------------------------------------------------------------------------
-- Profile management
-- ---------------------------------------------------------------------------

--- Scan for connected devices from all device-capable modules (a
--- `Devices/1.scan` task of the workspace daemon; refused or failed:
--- notified, `callback(nil, err)`).
--- @param callback? fun(devices: loomworks.DeviceRecord[]|nil, err: string|nil)
function M.scan_devices(callback)
    require("loomworks.device_source").scan(nil, callback)
end

--- Get the current list of discovered devices (the daemon's registry,
--- `Devices/1.list`, as last read).
--- @return loomworks.DeviceRecord[]
function M.get_devices()
    return require("loomworks.device_source").list(nil)
end

--- The root whose working copy the deletion of the working copy acts on
--- when no workspace is loaded: the refused load's, else the cwd's.
--- @return string
function M.user_prefs_root()
    local err = M.get_setup_error()
    return (err and err.root) or require("loomworks.workspace").resolve_root()
end

--- Review a working copy that is not signed by this machine and, on
--- confirmation, trust it (re-sign exactly what was shown) — spec §17.4.
--- Shows the program-bearing fields first in a confirmation prompt with
--- Trust / Discard / Cancel choices. `opts.confirm` replaces `vim.fn.confirm`
--- (tests).
--- @param root? string workspace root (default: the refused/pending root, else cwd)
--- @param opts? { confirm?: fun(msg: string, choices: string, default: integer): integer }
--- @return "trusted"|"discarded"|"cancelled"|"valid"|"error" outcome
function M.trust_user_prefs(root, opts)
    opts = opts or {}
    local err = core:get_setup_error()
    root = root or (err and err.root) or core:workspace_root()
        or require("loomworks.workspace").resolve_root()
    local review, rerr = core:review_user_prefs(root)
    if not review then
        vim.notify("loomworks: " .. tostring(rerr), vim.log.levels.ERROR)
        return "error"
    end
    if review.status == "valid" then
        vim.notify("loomworks: .nvim/loomworks.user.json is already trusted (signed by this machine)",
            vim.log.levels.INFO)
        -- Valid again since a load refused it (restored, or re-signed by
        -- `lw trust`): load the workspace now (spec §17.4).
        local norm = core._deps.normalize
        if err and err.trust and err.trust.kind == "user" and err.root
            and norm(err.root) == norm(root) then
            load(root)
        end
        return "valid"
    end
    local prog, other = require("loomworks.program_fields").review(review.data, require("loomworks.modules"))
    local lines = {
        review.path,
        review.status == "unsigned"
            and "is not signed by this machine (written by hand, or by an earlier loomworks)."
            or "was modified outside loomworks, or copied from another machine.",
        "",
        "Program settings — what loomworks may run on this file's word:",
    }
    if #prog == 0 then lines[#lines + 1] = "  (none)" end
    for _, l in ipairs(prog) do lines[#lines + 1] = "  " .. l end
    lines[#lines + 1] = "Other contents:"
    for _, l in ipairs(other) do lines[#lines + 1] = "  " .. l end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Trust this working copy?"
    local confirm = opts.confirm or vim.fn.confirm
    local choice = confirm(table.concat(lines, "\n"), "&Trust\n&Discard\n&Cancel", 3)
    if choice == 1 then
        local ok, serr = core:trust_user_prefs(root, review.content)
        if not ok then
            vim.notify("loomworks: " .. tostring(serr), vim.log.levels.ERROR)
            return "error"
        end
        vim.notify("loomworks: working copy trusted (signed for this machine)", vim.log.levels.INFO)
        return "trusted"
    elseif choice == 2 then
        core:delete_user_prefs(root)
        return "discarded"
    end
    return "cancelled"
end

--- Get detected tools organized by module type: per module type, the
--- distinct `{ module, key?, label }` tool rows the `view.Workspace/1`
--- `profiles` records select (nil while not held); the toolchains a module
--- detects are the `Toolchains/1.list` call.
--- @return table<string, loomworks.ViewProfileTool[]>|nil
function M.get_tools_by_type()
    return daemon_rows().tools_by_type()
end

-- ---------------------------------------------------------------------------
-- LSP options
-- ---------------------------------------------------------------------------

--- Get effective LSP options for a server (defaults applied): a copy of
--- that server's options in the held `LspConfig/1` state (nil while it is
--- not held).
--- @param server string
--- @return table|nil
function M.get_lsp_options(server)
    return daemon_rows().lsp_options(server)
end

--- Set a single LSP option and persist to user.json (spec §19.16 "LSP
--- configuration"): it is written only by the workspace daemon's
--- `LspConfig/1.set_option`: this returns true once the call is
--- sent and `cb` learns the outcome; not carried, refused or failed is an
--- error (notified) and nothing is written.
--- @param server string
--- @param key string
--- @param value any nil removes the key
--- @param cb? fun(ok: boolean, err: string|nil) called with the outcome
--- @return boolean ok false when not saved (notified)
--- @return string|nil err
function M.set_lsp_option(server, key, value, cb)
    return require("loomworks.lsp_source").set_option(server, key, value, cb)
end

--- Get orphaned cached configs (configs with state not referenced by any
--- profile): the `view.Workspace/1` `orphaned.configurations` records
--- `{ id, key, build_dir? }` (nil while not held).
--- @return { id?: string, key: string, build_dir?: string }[]|nil
function M.get_orphaned_configs()
    return daemon_rows().orphaned_configs()
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- Find the project containing a buffer's file: a copy of the buffer's
--- `view.ProjectsIndex/1` record, as `lw.buf_project`.
--- @param bufnr number
--- @return loomworks.ViewProjectRecord|nil
function M.project_for_buf(bufnr)
    return daemon_rows().project_for_buf(bufnr)
end

--- Resolve the compile command loomworks' owned LSP database uses (or would
--- use) for an absolute file (spec §14): refused (`status = "refused"`, spec
--- §19.16 "Public API"): no compilation database or model is read.
--- @param file string absolute source or header path
--- @return loomworks.CompileCommandResult
function M.compile_command_for_file(file)
    return { status = "refused", message = require("loomworks.daemon.facade").COMPILE_COMMAND_REFUSAL }
end

--- The buffer's project as its `loomworks.view.ProjectsIndex/1` record (spec
--- §19.13 "Views"): the record whose `abs_path` is the longest prefix of the
--- buffer's path on a separator boundary, nil when none matches (or the
--- workspace is not loaded, in the daemon too). Unlike `project_for_buf`, a
--- project at `/a/foo` never claims a buffer in `/a/foobar`.
--- @param bufnr? number defaults to the current buffer
--- @return loomworks.ViewProjectRecord|nil
function M.buf_project(bufnr)
    return views.buf_project(bufnr)
end

--- The always-warm header (`loomworks.view.Header/1`): the daemon's while
--- the editor is subscribed to it (loomworks.views.get).
--- @return loomworks.ViewHeader|nil
function M.view_header()
    return views.header()
end

--- Per-buffer LSP status (spec §9.8): whether loomworks started, is holding,
--- or withholds a managed language server for the buffer. Available without an
--- active profile (unlike `buf_status`). "none" for buffers loomworks has no
--- LSP opinion about, and when the LSP layer is not loaded.
--- @param bufnr? integer defaults to the current buffer
--- @return loomworks.LspBufState
function M.lsp_buf_state(bufnr)
    local lsp = package.loaded["loomworks.lsp"]
    if type(lsp) ~= "table" or type(lsp.buf_state) ~= "function" then return "none" end
    return lsp.buf_state(bufnr)
end

--- Get status info for the buffer's project, suitable for statusline/winbar.
--- Read from the two views (spec §19.13 "Two sources, one shape"): nil unless
--- the header is `loaded` and the buffer is in a project.
--- @param bufnr? number defaults to current buffer
--- @return loomworks.BufStatus|nil
function M.buf_status(bufnr)
    local header = views.header()
    if not header or header.state ~= "loaded" then return nil end
    local status = views.status_of(header, views.projects_index(), vim.api.nvim_buf_get_name(bufnr or 0))
    -- The per-buffer LSP state is editor-local in every mode (the LSP layer
    -- always runs in the editor), so it is added here, not in the views.
    if status then status.lsp = M.lsp_buf_state(bufnr) end
    return status
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

--- Create a new workspace (loomworks.json) at the given root: refused,
--- nothing written (spec §19.16 "Model writes": `lw init` creates it).
--- @param root string workspace root directory
--- @param name? string workspace name
--- @return boolean ok, string|nil err
function M.create_workspace(root, name)
    return false, require("loomworks.daemon.facade").CREATE_REFUSAL
end

--- Open the project browser for adding projects.
function M.open_project_browser()
    -- (The root the editor observes the daemon of, step 6b-α.)
    local root = M.loaded_root()
    if not root then
        vim.notify("loomworks: no workspace loaded", vim.log.levels.WARN)
        return
    end
    require("loomworks.ui.project_browser").open(root)
end

--- Open the workspace status page.
--- @param win_overrides? table Snacks.win config overrides
function M.open(win_overrides)
    require("loomworks.ui.status").open(win_overrides)
end

function M.toggle()
    require("loomworks.ui.status").toggle()
end

--- Build the active profile's default target: `Launch/1.build` of the
--- default target of `Launch/1.targets`, the picker first when there is
--- none (loomworks.daemon.facade, spec §19.16 "Public API").
function M.build_target()
    require("loomworks.daemon.facade").build_target()
end

--- Build the full active profile (all targets): `Build/1.build` of the
--- active profile row (loomworks.daemon.facade).
function M.build_profile()
    require("loomworks.daemon.facade").build_profile()
end

--- Show a picker for selecting the active profile: the `profiles` rows, the
--- choice sent as `Profiles/1.set_active` (no "None": loomworks.daemon.facade).
function M.pick_profile()
    require("loomworks.daemon.facade").pick_profile()
end

--- Show an action picker for the active profile's default target: "Build"
--- builds it, "Switch target" opens the target picker; with no default
--- target straight to the picker (loomworks.daemon.facade).
function M.pick_target_action()
    require("loomworks.daemon.facade").pick_target_action()
end

--- Open the target picker; persist the user's selection without starting a
--- build: the active profile's `Launch/1.targets`, the choice stored with
--- `Profiles/1.set_default_target` (loomworks.daemon.facade).
function M.pick_target()
    require("loomworks.daemon.facade").pick_target_only()
end

function M.launch_target()
    require("loomworks.daemon.facade").launch("launch")
end

function M.debug_target()
    local debug_mod = require("loomworks.debug")
    if not debug_mod.available() then
        vim.notify(
            "loomworks: nvim-dap not installed; launching without debugger",
            vim.log.levels.WARN)
        M.launch_target()
        return
    end
    require("loomworks.daemon.facade").launch("debug")
end

--- Stop the active launch or debug session.
function M.stop_target()
    require("loomworks.session_tracker").stop()
end

return M

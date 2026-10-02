--- loomworks/core.lua — Infrastructure layer.
--- Uses a constructor pattern for testability: Core.new(deps) returns an
--- isolated instance with injectable dependencies and clean state.
--- Registries and business logic live on the Workspace instance;
--- Core owns I/O, modules, events, file tracking, and setup.
--- Thin delegation wrappers forward to Workspace so that init.lua callers
--- continue to work via core:method().

--- @class loomworks.Core
--- @field _deps table injected dependencies
--- @field _workspace loomworks.Workspace|nil
--- @field _setup_error { root: string, message: string, trust?: { kind: "user"|"cache", status: string, path: string }, user_untrusted?: string, cache_untrusted?: boolean, user_version_mismatch?: boolean, newer?: boolean }|nil set when setup fails (`trust`: a refused `.nvim` file, spec §17.4; `newer`: a file with a newer schema, spec §2.7)
--- @field _state "uninitialized"|"initializing"|"initialized"
--- @field _pending_root string|nil root passed to setup(), known before async init resolves
local Core = {}
Core.__index = Core

local Workspace = require("loomworks.workspace").Workspace

--- Default dependency table. Tests override individual entries.
local DEFAULT_DEPS = {
    workspace = require("loomworks.workspace"),
    merge     = require("loomworks.merge"),
    events    = require("loomworks.events"),
    user      = require("loomworks.user"),
    cache     = require("loomworks.cache"),
    config    = require("loomworks.config"),
    --- Machine signatures on `.nvim` state (spec §17). Tests inject a stub.
    trust     = require("loomworks.trust"),
    --- How this host tells the user to resolve a refused `.nvim` file
    --- (spec §17.10). The CLI replaces these with its commands.
    trust_actions = {
        trust = ":LoomworksTrust (or T on the status page)",
        discard = "U on the status page",
        nuke = "<C-n> on the status page",
    },
    io        = require("loomworks.io"),
    -- Cross-process locks (spec §19.3): `locks = { op, build }` may be injected;
    -- by default loomworks.op_lock.locks(deps, root) picks the real modules,
    -- or inert ones for a root that does not exist (a test's fake root).
    read_file_async = require("loomworks.io").read_file_async,
    read_files_async = require("loomworks.io").read_files_async,
    detect_tools_async = require("loomworks.merge").detect_tools_async,
    modules   = require("loomworks.modules"),
    FileTracker = require("loomworks.file_tracker"),
    log       = require("loomworks.log").default(),
    notify    = vim.notify,
    now       = function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
    clock     = function() return vim.uv.hrtime() / 1e9 end,
    --- Normalize a file path for comparison. On Windows, also lowercases
    --- because the filesystem is case-insensitive.
    normalize = (function()
        local is_win = vim.fn.has("win32") == 1
        if is_win then
            return function(p)
                return vim.fs.normalize(p):lower()
            end
        end
        return vim.fs.normalize
    end)(),
    schedule  = vim.schedule,
    --- Whether a filesystem path exists. Used to detect a build directory that
    --- was removed out of band, so a cached built/configured unit resets to
    --- unconfigured (spec §3.1 rule 7). A plain `stat` — no module-specific
    --- probing. Injectable so tests can simulate a present/absent directory.
    --- @param path string
    --- @return boolean
    dir_exists = function(path)
        return (vim.uv or vim.loop).fs_stat(path) ~= nil
    end,
    --- Resolve a path to its canonical on-disk form (long name + real case on
    --- Windows, symlinks followed), or nil if it does not exist. Used by the
    --- deletion boundary check to reconcile 8.3 short vs long path forms before
    --- the prefix comparison. Injectable so tests can encode the short<->long
    --- contract without an 8.3 filesystem.
    --- @param path string
    --- @return string|nil
    realpath = function(path)
        return (vim.uv or vim.loop).fs_realpath(path)
    end,
    --- Resolve an overseer task by id. Returns nil if overseer not available.
    --- @param task_id number
    --- @return table|nil task
    get_overseer_task = function(task_id)
        local ok, task_list = pcall(require, "overseer.task_list")
        if not ok then return nil end
        return task_list.get(task_id)
    end,
    --- Get the file path for a buffer.
    --- @param bufnr number
    --- @return string
    buf_name = function(bufnr)
        return vim.api.nvim_buf_get_name(bufnr)
    end,
}

--- Create a new Core instance.
--- @param deps? table override individual dependencies for testing
--- @return loomworks.Core
function Core.new(deps)
    local self = setmetatable({}, Core)
    if deps then
        self._deps = setmetatable(deps, { __index = DEFAULT_DEPS })
    else
        self._deps = DEFAULT_DEPS
    end
    self._workspace = nil
    self._setup_error = nil
    self._state = "uninitialized"
    self._pending_root = nil
    return self
end

-- ===========================================================================
-- Setup & lifecycle (stays on Core)
-- ===========================================================================

--- Force-reload loomworks.json from disk and remerge.
--- Delegates to Workspace.
function Core:reload_config()
    if not self._workspace then return end
    self._workspace:reload_config()
end

--- Get the workspace initialization state.
--- @return "uninitialized"|"initializing"|"initialized"
function Core:state()
    return self._state
end

--- Get the tool detection state.
--- @return "not_scanned"|"scanning"|"scanned"
function Core:tool_state()
    if not self._workspace then return "not_scanned" end
    return self._workspace._tool_state
end

--- Whether the active profile's owned LSP databases are ready — the active
--- profile's configured build directories have had their compilation databases
--- generated (or there was nothing to generate). The deferred-LSP gate (§9.7)
--- releases held server starts once this is true, so a server starts once with
--- the resolved binary and a populated compile-commands directory.
---
--- Terminal cases: with a live workspace, mirror its `_lsp_ready`. With no
--- workspace but a pending root (setup in progress), report NOT ready so
--- under-root buffers are held. With neither (loomworks not managing this cwd),
--- report ready so non-loomworks buffers resolve immediately.
--- @return boolean
function Core:lsp_ready()
    if not self._workspace then
        return self._pending_root == nil
    end
    return self._workspace._lsp_ready == true
end

--- The configured workspace root, known synchronously even during async init
--- (spec §9.7). Falls back to the last root passed to `setup()` before a
--- workspace object exists. nil when setup was never called.
--- @return string|nil
function Core:workspace_root()
    if self._workspace then return self._workspace.root end
    return self._pending_root
end

--- Record the configured workspace root synchronously, BEFORE the async
--- `setup()` runs (spec §9.7 / FIX A). LSP server installation resolves
--- `root_dir` synchronously for already-open buffers the moment
--- `vim.lsp.enable` runs; if that happens before `setup()` set the pending
--- root, the gate would see no root and resolve immediately (an ungated
--- start, later restarted). Callers install servers only after this. Resolves
--- the root the same way `setup()` does and is idempotent — `setup()` sets the
--- same value again.
--- @param root? string
function Core:set_pending_root(root)
    self._pending_root = self._deps.workspace.resolve_root(root)
end

--- Initialize the workspace asynchronously.
--- Reads files in parallel, then processes synchronously via vim.schedule.
--- @param opts? { root?: string }
function Core:setup(opts)
    if self._state == "initializing" then return end

    self._setup_error = nil
    self._state = "initializing"
    self._deps.events.emit("workspace_initializing")

    local ws_mod = self._deps.workspace
    local root = ws_mod.resolve_root(opts and opts.root or nil)
    -- Remember the configured root synchronously, before async init resolves,
    -- so the deferred-LSP gate (spec §9.7) can decide whether a buffer is under
    -- the workspace root while the workspace is still initializing.
    self._pending_root = root
    local paths = ws_mod.paths(root)

    -- A commit journal left by a crashed multi-file operation (spec §19.4) is
    -- completed before the files are read — or the workspace is refused. (A
    -- host whose refusal hook raises — the CLI's `die` — leaves the state as
    -- it found it.)
    local okr, refused = pcall(self._recover_journal, self, root)
    if not okr then
        self._state = "uninitialized"
        error(refused, 0)
    end
    if refused then
        -- (a host that reports refusals itself — the CLI — prints it once)
        if not self._deps.quiet_trust_errors then
            self._deps.notify("loomworks: " .. refused, vim.log.levels.ERROR)
        end
        if self._workspace then
            self._workspace:teardown()
            self._workspace = nil
        end
        self._setup_error = { journal = true, message = refused }
        self._state = "uninitialized"
        self._deps.events.emit("workspace_changed", nil)
        return
    end

    self._deps.read_files_async(
        { paths.config, paths.user, paths.cache },
        function(results)
            self._deps.schedule(function()
                self:_on_files_read(root, paths, results)
            end)
        end
    )
end

--- Complete (or refuse) a commit journal of `root` before loading (spec
--- §19.4). While the journal's writer still holds the workspace operation
--- lock the commit is in progress: wait for it (bounded), then report the
--- workspace busy (the CLI dies; the editor loads what is there and its file
--- tracker reloads when the commit lands). Returns the refusal message, or nil.
--- @param root string
--- @return string|nil refusal
function Core:_recover_journal(root)
    if require("loomworks.op_lock").locks(self._deps, root).fake then return nil end
    local txn = require("loomworks.txn")
    if txn.read_journal(root) == nil then return nil end
    local op_lock = require("loomworks.op_lock")
    if op_lock.held(root) then return nil end -- this process is mid-commit
    local tok, msg
    local deadline = (vim.uv or vim.loop).hrtime() + 2e9
    repeat
        tok, msg = op_lock.acquire(root, "recover")
        if tok or txn.read_journal(root) == nil then break end
        vim.wait(50)
    until (vim.uv or vim.loop).hrtime() > deadline
    if not tok then
        if txn.read_journal(root) == nil then return nil end
        -- A refused journal, or a commit still in progress.
        if msg and msg:find("loomworks.txn.json", 1, true) then return msg end
        if self._deps.on_lock_refused then self._deps.on_lock_refused(msg) end
        self._deps.notify("loomworks: " .. tostring(msg), vim.log.levels.WARN)
        return nil
    end
    if tok.recovered then
        self._deps.notify("loomworks: " .. tok.recovered, vim.log.levels.WARN)
        pcall(self._deps.log.info, self._deps.log, "%s", tok.recovered)
    end
    op_lock.release(tok)
    return nil
end

--- Process read file results and complete initialization.
--- @param root string
--- @param paths table
--- @param results table<string, string|nil>
function Core:_on_files_read(root, paths, results)
    local ws_mod = self._deps.workspace

    local function fail(msg, setup_error)
        -- A host that reports refused-trust errors itself (the CLI prints its
        -- own actionable message) sets `quiet_trust_errors`.
        if not (setup_error and setup_error.trust and self._deps.quiet_trust_errors) then
            self._deps.notify("loomworks: " .. msg, vim.log.levels.ERROR)
        end
        -- A refused file (spec §17.4, or a newer schema, §2.7) unloads a
        -- live workspace too (a file changed under it): nothing may keep
        -- running on — or saving — the old state.
        if setup_error and (setup_error.trust or setup_error.newer) and self._workspace then
            self._workspace:teardown()
            self._workspace = nil
        end
        self._setup_error = setup_error
        self._state = "uninitialized"
        self._deps.events.emit("workspace_changed", nil)
    end

    local config_content = results[paths.config]
    local user_content = results[paths.user]
    local cache_content = results[paths.cache]

    self._deps.log:set_root(root)
    self._deps.log:info("Loading workspace from %s", root)

    -- Need at least one of loomworks.json or user.json
    if not config_content and not user_content then
        self._deps.log:warn("No workspace files found in %s", root)
        fail("no workspace files found in " .. root)
        return
    end

    local data, err = ws_mod.assemble(root, config_content, user_content, cache_content,
        { trust = self._deps.trust, modules = self._deps.modules })
    if not data then
        fail(err)
        return
    end

    -- Machine signatures (spec §17.4): a working copy that is not signed by
    -- this machine, or a cache with a foreign/modified signature, refuses the
    -- load. Nothing in the file was read, and nothing overwrites it.
    local trust_err = self:_trust_error(root, data)
    -- A configuration import replaces a refused working copy unread (spec
    -- §16.39): the host asks for that with `replace_untrusted_user`. The
    -- file's content was never decoded (assemble dropped it); the workspace
    -- loads as if it were absent and remembers why (`_user_unread`). Any other
    -- refusal (an invalid cache) still applies.
    local unread_user = nil
    if trust_err and self._deps.replace_untrusted_user
            and trust_err.trust and trust_err.trust.kind == "user" then
        unread_user = data.user_trust
        data.user_trust = nil
        trust_err = self:_trust_error(root, data)
    end
    if trust_err then
        fail(trust_err.message, trust_err)
        return
    end

    -- A file written with a NEWER schema than this version understands is
    -- valid, only newer: refuse the load, never rewrite it, and point at the
    -- update — not at reset / discard (spec §2.7).
    if data.cache_newer or data.user_newer then
        local sg = require("loomworks.save_guard")
        local msg = data.cache_newer
            and sg.newer_schema_message(".nvim/loomworks.cache.json", data.cache_newer,
                require("loomworks.cache").CURRENT_VERSION)
            or sg.newer_schema_message(".nvim/loomworks.user.json", data.user_newer,
                require("loomworks.user").CURRENT_VERSION)
        fail(msg, { root = root, message = msg, newer = true })
        return
    end

    if data.cache_version_mismatch then
        fail("Cache version mismatch. Press <C-n> to reset.",
            { root = root, message = "Cache version mismatch. Press <C-n> to reset." })
        return
    end

    if data.cache_inconsistent then
        fail("Cache is internally inconsistent. Press <C-n> to reset.",
            { root = root, message = "Cache is internally inconsistent. Press <C-n> to reset." })
        return
    end

    if data.user_version_mismatch then
        fail("user.json version mismatch. Press U to delete user preferences and reload.",
            { root = root, message = "user.json version mismatch. Press U to delete user preferences and reload.",
              user_version_mismatch = true })
        return
    end

    -- Refuse to load when user.json has structurally invalid projects, rather
    -- than dropping them — a later save would persist the drop (data loss).
    -- Preserve the file and tell the user what to fix.
    if data.user_projects_invalid then
        local msg = "user.json is invalid: " .. data.user_projects_invalid ..
            " — fix .nvim/loomworks.user.json and retry"
        fail(msg, { root = root, message = msg })
        return
    end

    local ok, val_err = self:_validate_projects(data.config, data.root)
    if not ok then
        fail(val_err)
        return
    end

    -- Tear down any previous workspace before replacing — releases its
    -- file tracker, cancels in-flight tasks, detaches event subscribers.
    -- Fire-and-forget the returned future; on swap we don't wait.
    if self._workspace then
        self._workspace:teardown()
    end

    self._workspace = Workspace.new(self, data)
    self._workspace._shared_ignored = data.shared_ignored or {}
    self._workspace._user_unread = unread_user

    self._workspace:_cleanup_orphaned_skeletons(data.cache)
    self._workspace:remerge(data.config, data.cache, data.user)
    -- Disk baselines for the stale-save guard (spec §2.7): the exact bytes
    -- this load read.
    self._workspace:_adopt_disk("user", user_content)
    self._workspace:_adopt_disk("cache", cache_content)
    -- Same schema, newer writer: load, but say so once (spec §2.7).
    do
        local sg = require("loomworks.save_guard")
        for _, f in ipairs({
            { paths.user, ".nvim/loomworks.user.json", data.user and data.user._meta },
            { paths.cache, ".nvim/loomworks.cache.json", data.cache and data.cache._meta },
        }) do
            local warning = sg.newer_writer_warning(f[1], f[2], f[3])
            if warning then self._deps.notify("loomworks: " .. warning, vim.log.levels.WARN) end
        end
    end
    self._state = "initialized"
    self._deps.events.emit("workspace_changed", self._workspace)

    -- Migration (spec §17.4): a cache written before signatures existed is
    -- ignored unread — this load holds no build state from it. Loading never
    -- writes: the file is replaced by the first command that writes the cache
    -- (the disk baseline above is its exact bytes, so that save neither merges
    -- nor refuses), and read-only commands / dry runs leave it untouched.
    if data.cache_trust == "unsigned" then
        self._deps.notify("loomworks: ignoring an unsigned build cache "
            .. "(written by an earlier loomworks); build state is recreated on the next build",
            vim.log.levels.WARN)
    end

    self._workspace:_start_tracking(paths)

    self._deps.log:info("Workspace '%s' loaded: %d projects, %d profiles",
        self._workspace.name,
        #self._workspace._projects,
        #self._workspace._profiles)
    for _, p in ipairs(self._workspace._projects) do
        local cfg_count = p._configurations and #p._configurations or 0
        self._deps.log:debug("  Project '%s' [%s]: %d configurations", p.key, p.type or "?", cfg_count)
        if p._configurations then
            for _, cfg in ipairs(p._configurations) do
                local variant = cfg.module_config and cfg.module_config.variant or "?"
                self._deps.log:debug("    Config '%s' variant=%s abstract=%s",
                    cfg.name, variant, tostring(cfg:is_abstract()))
            end
        end
    end
    self._deps.notify("loomworks: workspace '" .. self._workspace.name .. "' loaded (" .. self._workspace.root .. ")", vim.log.levels.INFO)

    self._workspace:_scan_tools_async()
end

-- ===========================================================================
-- Trust (spec §17)
-- ===========================================================================

--- Build the setup error for a refused `.nvim` file, or nil when the loaded
--- files are acceptable. `trust` = `{ kind = "user"|"cache", status, path }`.
--- @param root string
--- @param data table assembled workspace data
--- @return table|nil setup_error
function Core:_trust_error(root, data)
    local a = self._deps.trust_actions or {}
    local us = data.user_trust
    if us == "unsigned" or us == "invalid" then
        local why = (us == "unsigned")
            and "is not signed by this machine (written by hand or by an earlier loomworks)"
            or "was modified outside loomworks or copied from another machine (its signature does not match)"
        local msg = ".nvim/loomworks.user.json " .. why .. " — it is not used until you review and trust it: "
            .. (a.trust or "trust it") .. ", or discard it: " .. (a.discard or "discard it")
        return {
            root = root, message = msg,
            trust = { kind = "user", status = us, path = self._deps.user.filepath(root) },
            user_untrusted = us,
        }
    end
    if data.cache_trust == "invalid" then
        local msg = ".nvim/loomworks.cache.json was not written on this machine (its signature does not match)"
            .. " — it is not used; reset the build cache: " .. (a.nuke or "reset it")
        return {
            root = root, message = msg,
            trust = { kind = "cache", status = "invalid", path = self._deps.cache.filepath(root) },
            cache_untrusted = true,
        }
    end
    return nil
end

--- Read the working copy for review (spec §17.4 "trust"): its verification
--- status, the exact content that trusting would sign, and the decoded data.
--- @param root string
--- @return table|nil review `{ path, status, content, data }`, string|nil err
function Core:review_user_prefs(root)
    local norm_root = self._deps.normalize(root)
    local path = self._deps.user.filepath(norm_root)
    local text = self._deps.io.read_file(path)
    if not text then return nil, "no working copy at " .. path end
    local status, content = self._deps.trust.verify("user", text)
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
        return nil, path .. " is not valid JSON — fix or discard it"
    end
    return { path = path, status = status, content = content, data = decoded }
end

--- Trust the working copy: re-sign exactly the reviewed content, then reload.
--- The caller confirmed with the user after showing `review_user_prefs`.
--- @param root string
--- @param reviewed_content? string content the user reviewed (refused if the file changed since)
--- @return boolean ok, string|nil err
function Core:trust_user_prefs(root, reviewed_content)
    local norm_root = self._deps.normalize(root)
    local path = self._deps.user.filepath(norm_root)
    if not self:_safe_nvim_path(path, norm_root) then
        return false, "refusing to sign a path outside .nvim/: " .. path
    end
    local ok, err = self._deps.trust.sign_file(path, "user", reviewed_content)
    if not ok then return false, err end
    self._setup_error = nil
    self:setup({ root = norm_root })
    return true
end

-- ===========================================================================
-- Validation (stays on Core)
-- ===========================================================================

--- Validate all projects against their modules.
--- @param config loomworks.Config
--- @param root string
--- @return boolean ok, string|nil err
function Core:_validate_projects(config, root)
    local modules_mod = self._deps.modules
    for key, project in pairs(config.projects) do
        local mod = modules_mod.get(project.type)
        if mod and mod.validate then
            local abs_path = root .. "/" .. project.path
            local result = mod.validate(abs_path, project.type_config)
            -- Log warnings but don't block loading — missing directories are
            -- normal when projects come from another branch or were removed
            for _, warning in ipairs(result.warnings or {}) do
                self._deps.notify("loomworks: project '" .. key .. "': " .. warning, vim.log.levels.WARN)
            end
        end
    end
    return true, nil
end

-- ===========================================================================
-- Safety & nuke (stays on Core)
-- ===========================================================================

--- Validate that a path is a child of root/.nvim/ before deletion.
--- Uses absolute normalized paths to prevent directory traversal.
--- @param path string path to validate
--- @param root string workspace root
--- @return boolean safe
function Core:_safe_nvim_path(path, root)
    local normalize = self._deps.normalize
    local norm_path = normalize(path)
    local nvim_prefix = normalize(root .. "/.nvim")
    -- Ensure path starts with root/.nvim/ (trailing slash prevents partial matches)
    return norm_path == nvim_prefix or norm_path:sub(1, #nvim_prefix + 1) == nvim_prefix .. "/"
end

--- Nuke the cache: delete .nvim/build/ and loomworks.cache.json, then reload.
--- Caller must confirm with the user before calling this.
--- @param root string workspace root to nuke
function Core:nuke_cache(root)
    -- The live workspace goes first (spec §19.3): its tasks are stopped (an
    -- editor build would keep writing into the tree, and hold its lock) and
    -- it can no longer save — a callback that ran while the removal pumps the
    -- event loop must not recreate the cache with stale `built` states. The
    -- reload below builds a fresh one, also when the nuke was refused.
    self:_retire_workspace()
    local norm_root = self:_nuke_files(root)
    self:setup({ root = norm_root or self._deps.normalize(root) })
end

--- Stop the live workspace's tasks (waiting, bounded, for them to end) and
--- tear it down so nothing of it writes again.
function Core:_retire_workspace()
    local ws = self._workspace
    if not ws then return end
    self._workspace = nil
    local done = false
    local ok, f = pcall(ws.teardown, ws)
    if ok and type(f) == "table" and f.next then
        f:next(function() done = true end):catch(function() done = true end)
        vim.wait(10000, function() return done end, 20)
    end
end

--- The deletion half of `nuke_cache` (no reload): remove `.nvim/build/`, the
--- build cache (+ backup) and the health cache (+ backup), each checked to be
--- under `root/.nvim/`. Shared by the editor's nuke and `lw nuke` (spec §17.4).
--- Returns the normalized root when it ran (a failed rm is reported, and the
--- reload shows what is left), nil when refused.
--- @param root string
--- @return string|nil norm_root
function Core:_nuke_files(root)
    local st, msg = self:_nuke_begin(root)
    if not st then
        self._deps.notify("loomworks: " .. msg, vim.log.levels.ERROR)
        return nil
    end
    return self:_nuke_run(st)
end

--- Would a nuke of `root` run now? Takes and at once releases what a nuke
--- takes (the safety checks, the operation lock, the build locks), so a host
--- can refuse BEFORE it lists what it would delete or asks to confirm (a
--- refused nuke shows only its refusal). The editor passes
--- `{ skip_own = true }`: its own builds are stopped by `nuke_cache` before
--- the real acquisition. Returns true, or nil + the refusal message (no
--- `loomworks:` prefix).
--- @param root string
--- @param opts? { skip_own?: boolean }
--- @return boolean|nil ok, string|nil message
function Core:nuke_check(root, opts)
    local st, msg = self:_nuke_begin(root, opts)
    if not st then return nil, msg end
    self:_nuke_release(st)
    return true
end

--- Release what `_nuke_begin` took, deleting nothing (a declined or
--- refused nuke). Idempotent.
--- @param st table
function Core:_nuke_release(st)
    if not st or st.released then return end
    st.released = true
    for _, h in ipairs(st.held) do st.locks.build.release(h) end
    st.locks.op.release(st.tok)
end

--- The first half of a nuke: the safety checks, then the locks in lock
--- order (spec §19.3). Nothing is removed. Returns the state `_nuke_run`
--- deletes under (the caller must run or release it), or nil + the refusal
--- message (no `loomworks:` prefix; nothing held).
--- @param root string
--- @param opts? { skip_own?: boolean }
--- @return table|nil state, string|nil message
function Core:_nuke_begin(root, opts)
    -- Safety: root must be absolute (Unix /... or Windows C:/...)
    local norm_root = self._deps.normalize(root)
    if not norm_root:match("^/") and not norm_root:match("^%a:/") then
        return nil, "nuke_cache requires an absolute path, got: " .. root
    end

    -- Safety: loomworks.json or the working copy must exist at root (confirms
    -- this is a real workspace — a user.json-only workspace is one, §2.2).
    local config_path = norm_root .. "/loomworks.json"
    if not self._deps.io.read_file(config_path)
            and not self._deps.io.read_file(self._deps.user.filepath(norm_root)) then
        return nil, "no loomworks.json or .nvim/loomworks.user.json found at " .. norm_root .. ", aborting nuke"
    end

    local build_dir = norm_root .. "/.nvim/build"
    local cache_path = self._deps.cache.filepath(norm_root)
    local health_path = norm_root .. "/.nvim/loomworks.health.json"

    -- Safety: verify all paths are under root/.nvim/
    local paths_to_delete = { build_dir, cache_path, cache_path .. ".bak", health_path, health_path .. ".bak" }
    for _, p in ipairs(paths_to_delete) do
        if not self:_safe_nvim_path(p, norm_root) then
            return nil, "refusing to delete path outside .nvim/: " .. p
        end
    end

    -- Lock order (spec §19.3): the workspace operation lock, then the build
    -- lock of every build directory it removes — so a nuke refuses while a
    -- build runs instead of deleting under it. Nothing is removed on refusal.
    local locks = require("loomworks.op_lock").locks(self._deps, norm_root)
    local tok, lmsg = locks.op.acquire(norm_root, "nuke")
    if not tok then return nil, "cannot nuke: " .. tostring(lmsg) end
    if tok.recovered then self._deps.notify("loomworks: " .. tok.recovered, vim.log.levels.WARN) end
    local held, berr = self:_nuke_build_locks(norm_root, build_dir, locks.build, opts)
    if not held then
        locks.op.release(tok)
        return nil, berr
    end
    return { root = norm_root, build_dir = build_dir, cache_path = cache_path, health_path = health_path,
        locks = locks, tok = tok, held = held }
end

--- The second half of a nuke, under the locks `_nuke_begin` took (released
--- here). Returns the normalized root when it ran, nil when refused.
--- @param st table
--- @return string|nil norm_root
function Core:_nuke_run(st)
    local norm_root, build_dir, locks, held = st.root, st.build_dir, st.locks, st.held
    local cache_path, health_path = st.cache_path, st.health_path
    local cache_bak = cache_path .. ".bak"

    -- 1. The caches first (§15 invariant 1, deletion safety 4): once they are
    --    gone nothing claims a configured or built tree, whatever happens to
    --    the removal below.
    self._deps.io.rm_rf(cache_path)
    self._deps.io.rm_rf(cache_bak)
    self._deps.io.rm_rf(health_path)
    self._deps.io.rm_rf(health_path .. ".bak")

    -- 2. Move the build tree aside in one atomic rename, so a build that
    --    starts as soon as the locks go creates a fresh `.nvim/build` instead
    --    of writing into the tree being removed. Trees left aside by a nuke
    --    that crashed are removed too. If the rename fails (on Windows: a
    --    program has a file in the tree open) nuke REFUSES rather than remove
    --    the tree in place: a build that starts once the locks go would then
    --    write into a tree still being deleted, and a tree with open files
    --    could not be removed completely anyway. Only the caches are gone,
    --    which is harmless: the builds reconfigure.
    local targets = self:_nuke_leftovers(norm_root)
    local aside, rerr = self:_nuke_move_aside(norm_root, build_dir)
    if aside then
        targets[#targets + 1] = aside
    elseif rerr then
        self:_nuke_release(st)
        self._deps.notify("loomworks: cannot nuke: could not move .nvim/build aside (" .. rerr
            .. ") — close programs using files in it (the editor's build, a file explorer, a "
            .. "running program), then nuke again. The build caches were removed; the tree was "
            .. "left as it is.", vim.log.levels.ERROR)
        return nil
    else
        -- No real directory to move (none, or a host's fake root).
        targets[#targets + 1] = build_dir
    end
    -- The lockfiles moved with the tree: nothing of theirs is left to release
    -- in `.nvim/build`; drop the handles.
    for _, h in ipairs(held) do locks.build.release(h) end
    st.held = {}

    -- 3. Remove, keeping this process's event loop running so the operation
    --    lock heartbeats: a large tree must not look like a hung holder.
    for _, t in ipairs(targets) do
        local ok, err = self:_nuke_remove(t)
        if not ok then
            self._deps.notify("loomworks: failed to delete build dir: " .. tostring(err), vim.log.levels.ERROR)
        end
    end
    self:_nuke_release(st)
    return norm_root
end

--- Trees a crashed nuke left aside: directories directly in `<root>/.nvim`
--- named exactly `build.nuke-<hex>`, real directories (lstat: never a link or
--- junction), under `.nvim/` (`_safe_nvim_path`).
--- @param root string normalized root
--- @return string[]
function Core:_nuke_leftovers(root)
    local uv = vim.uv or vim.loop
    local out = {}
    local dir = root .. "/.nvim"
    local req = uv.fs_scandir(dir)
    while req do
        local name = uv.fs_scandir_next(req)
        if not name then break end
        if name:match("^build%.nuke%-%x+$") then
            local p = dir .. "/" .. name
            local st = uv.fs_lstat(p)
            if st and st.type == "directory" and self:_safe_nvim_path(p, root) then out[#out + 1] = p end
        end
    end
    table.sort(out)
    return out
end

--- Rename `build_dir` to `<root>/.nvim/build.nuke-<nonce>`. Returns the new
--- path, or nil (+ the error when the rename failed; nil alone when there is
--- no real directory to move — a missing tree, a link, a fake test root).
--- @param root string normalized root
--- @param build_dir string normalized `<root>/.nvim/build`
--- @return string|nil aside, string|nil err
function Core:_nuke_move_aside(root, build_dir)
    local uv = vim.uv or vim.loop
    local st = uv.fs_lstat(build_dir)
    if not st or st.type ~= "directory" then return nil end
    local aside = root .. "/.nvim/build.nuke-" .. require("loomworks.lock_record").new_nonce()
    if not self:_safe_nvim_path(aside, root) then return nil, "unsafe path" end
    local last
    for i = 1, 5 do
        local ok, err = uv.fs_rename(build_dir, aside)
        if ok then return aside end
        last = err
        if i < 5 then vim.wait(100) end
    end
    return nil, tostring(last)
end

--- Remove one nuke target (asynchronously when the host can, while pumping
--- the event loop). Returns ok, err.
--- @param target string
--- @return boolean ok, string|nil err
function Core:_nuke_remove(target)
    local io_mod = self._deps.io
    -- Nothing real to remove (a missing tree, or a host's fake root): the
    -- plain removal. Otherwise asynchronously, while pumping the loop.
    if not io_mod.rm_rf_async or not (vim.uv or vim.loop).fs_lstat(target) then
        return io_mod.rm_rf(target)
    end
    local done, ok, err = false, false, nil
    io_mod.rm_rf_async(target, function(o, e) done, ok, err = true, o, e end)
    -- Until the removal has really ended: an interrupted wait (Ctrl-C in the
    -- editor) waits again, so the operation lock is never released while the
    -- tree is still being removed. (The CLI's interrupt ends the process; a
    -- half-removed aside tree is removed by the next nuke.)
    while not done do
        vim.wait(24 * 3600 * 1000, function() return done end, 50)
    end
    return ok, err
end

--- The build directories `nuke` removes that may be in use: every directory
--- with a lockfile `<dir>.loomworks-lock` under `build_dir` (scanned to depth
--- 12, never following links), plus the loaded workspace's build directories
--- under it. Read-only. Each entry is `{ key, path, shown }`:
--- the normalized path (order, identity), the path as found (on-disk casing
--- below `.nvim/build`) and its display form `.nvim/build/...`.
--- @param build_dir string normalized `<root>/.nvim/build`
--- @return table[]
function Core:_nuke_lock_dirs(build_dir)
    local uv = vim.uv or vim.loop
    local normalize = self._deps.normalize
    local suffix = ".loomworks-lock"
    local found, seen = {}, {}
    local function add(dir)
        local raw = tostring(dir):gsub("\\", "/")
        local k = normalize(raw)
        if (k:sub(1, #build_dir + 1) == build_dir .. "/") and not seen[k] then
            seen[k] = true
            found[#found + 1] = { key = k, path = raw, shown = ".nvim/build" .. raw:sub(#build_dir + 1) }
        end
    end
    local function scan(dir, depth)
        local req = uv.fs_scandir(dir)
        if not req then return end
        while true do
            local name, typ = uv.fs_scandir_next(req)
            if not name then break end
            local p = dir .. "/" .. name
            if typ == nil then
                local st = uv.fs_lstat(p)
                typ = st and st.type or nil
            end
            if typ == "file" and name:sub(-#suffix) == suffix then
                add(p:sub(1, -#suffix - 1))
            elseif typ == "directory" and depth < 12 then
                scan(p, depth + 1)
            end
        end
    end
    scan(build_dir, 0)
    local ws = self._workspace
    for _, unit in pairs(ws and ws._config_units or {}) do
        if unit.build_dir_value then add(unit.build_dir_value) end
    end
    return found
end

--- Take the build lock of every directory `nuke` removes (canonical order,
--- refusing a lock this process holds unless `opts.skip_own`). Returns the
--- handles, or nil + the refusal message (nothing held).
--- @param root string normalized workspace root
--- @param build_dir string normalized `<root>/.nvim/build`
--- @param build_lock? table
--- @param opts? { skip_own?: boolean }
--- @return table[]|nil handles, string|nil message
function Core:_nuke_build_locks(root, build_dir, build_lock, opts)
    build_lock = build_lock or require("loomworks.op_lock").locks(self._deps, root).build
    local lock_break = require("loomworks.lock_break")
    local _ = root
    local dirs = self:_nuke_lock_dirs(build_dir)
    table.sort(dirs, function(a, b) return a.key < b.key end)
    local held = {}
    -- The editor's check (`opts.skip_own`) passes over this process's own
    -- builds: `nuke_cache` stops them before it takes the locks for real.
    local skip_own = opts and opts.skip_own
    for _, e in ipairs(dirs) do
        local mine = build_lock.held_by_me(e.path)
        if mine and skip_own then goto continue end
        if mine then
            -- A task of this very process still uses it (nuke_cache retires
            -- the workspace first, so this is some other holder here): never
            -- delete under it.
            for _, x in ipairs(held) do build_lock.release(x) end
            return nil, "cannot nuke: " .. e.shown .. " is in use by this process — stop its build first"
        else
            local ctx = { what = e.shown, command = lock_break.command or "lw nuke", unlock = e.shown,
                style = "nuke", prefix = "cannot nuke: " }
            local h, msg = lock_break.acquire(function()
                local hh, _, info = build_lock.acquire(e.path, "nuke", ctx)
                return hh, info
            end, ctx)
            if not h then
                for _, x in ipairs(held) do build_lock.release(x) end
                return nil, msg
            end
            held[#held + 1] = h
        end
        ::continue::
    end
    return held
end

--- Delete user.json and reload the workspace.
--- Called when user.json has a version mismatch and user confirms deletion.
--- @param root string
function Core:delete_user_prefs(root)
    local norm_root = self._deps.normalize(root)
    -- The working copy and its backup go together, under the workspace
    -- operation lock (spec §19.3).
    local op_lock = require("loomworks.op_lock").locks(self._deps, norm_root).op
    local tok, lmsg = op_lock.acquire(norm_root, "trust --discard")
    if not tok then
        self._deps.notify("loomworks: " .. lmsg, vim.log.levels.ERROR)
        return
    end
    local ok_d, derr = pcall(self._delete_user_prefs_locked, self, norm_root)
    op_lock.release(tok)
    if not ok_d then error(derr, 0) end
end

--- `delete_user_prefs` under the operation lock.
--- @param norm_root string
function Core:_delete_user_prefs_locked(norm_root)

    local user_path = self._deps.user.filepath(norm_root)
    if not self:_safe_nvim_path(user_path, norm_root) then
        self._deps.notify("loomworks: refusing to delete path outside .nvim/: " .. user_path, vim.log.levels.ERROR)
        return
    end

    local ok, err = self._deps.io.rm_rf(user_path)
    if not ok then
        self._deps.notify("loomworks: failed to delete user.json: " .. (err or "unknown"), vim.log.levels.ERROR)
        return
    end
    -- The backup of a discarded working copy goes too (spec §17.4 discard).
    self._deps.io.rm_rf(user_path .. ".bak")

    self._deps.notify("loomworks: user preferences deleted, reloading", vim.log.levels.INFO)
    self._setup_error = nil
    self:setup({ root = norm_root })
end

-- ===========================================================================
-- Queries (stays on Core)
-- ===========================================================================

--- Get the active workspace.
--- @return loomworks.Workspace|nil
function Core:get_workspace()
    return self._workspace
end

--- Get the last setup error (e.g., cache version mismatch).
--- @return { root: string, message: string }|nil
function Core:get_setup_error()
    return self._setup_error
end

--- Find the project containing a buffer's file.
--- @param bufnr number
--- @return loomworks.Project|nil
function Core:project_for_buf(bufnr)
    if not self._workspace then return nil end

    local buf_path = self._deps.buf_name(bufnr)
    if buf_path == "" then return nil end
    buf_path = self._deps.normalize(buf_path)

    local best_project, best_len = nil, 0
    for _, project in pairs(self._workspace._projects) do
        local project_path = project.path or project.key
        local project_abs = self._deps.normalize(self._workspace.root .. "/" .. project_path)
        if buf_path:sub(1, #project_abs) == project_abs and #project_abs > best_len then
            best_project = project
            best_len = #project_abs
        end
    end

    return best_project
end

--- Detach the active workspace fully. Called on VimLeave-style shutdown.
function Core:shutdown()
    if self._workspace then
        self._workspace:teardown()
        self._workspace = nil
    end
end

-- ===========================================================================
-- Thin delegation wrappers (forward to Workspace)
-- ===========================================================================
-- These keep the init.lua -> core:method() calling convention working
-- without requiring changes to init.lua or any external callers.

--- @see loomworks.Workspace.remerge
function Core:remerge()
    if not self._workspace then return end
    self._workspace:remerge()
end

--- @see loomworks.Workspace._save_cache
function Core:_save_cache()
    if not self._workspace then return false end
    return self._workspace:_save_cache()
end

--- @see loomworks.Workspace.get_active_configuration_set
function Core:get_active_configuration_set()
    if not self._workspace then return nil end
    return self._workspace:get_active_configuration_set()
end

--- @see loomworks.Workspace.get_active_profile
function Core:get_active_profile()
    if not self._workspace then return nil end
    return self._workspace:get_active_profile()
end

--- @see loomworks.Workspace.get_profiles
function Core:get_profiles()
    if not self._workspace then return {} end
    return self._workspace:get_profiles()
end

--- @see loomworks.Workspace.get_projects
function Core:get_projects()
    if not self._workspace then return {} end
    return self._workspace:get_projects()
end

--- @see loomworks.Workspace.get_config_sets
function Core:get_config_sets()
    if not self._workspace then return {} end
    return self._workspace:get_config_sets()
end

--- @see loomworks.Workspace.get_tool_entries
function Core:get_tool_entries()
    if not self._workspace then return {} end
    return self._workspace:get_tool_entries()
end

--- @see loomworks.Workspace.get_tools_by_type
function Core:get_tools_by_type()
    if not self._workspace then return {} end
    return self._workspace:get_tools_by_type()
end

--- @see loomworks.Workspace.get_orphaned_configs
function Core:get_orphaned_configs()
    if not self._workspace then return {} end
    return self._workspace:get_orphaned_configs()
end

--- @see loomworks.Workspace.create_operation
function Core:create_operation(profile, action, units, target_states)
    if not self._workspace then return nil end
    return self._workspace:create_operation(profile, action, units, target_states)
end

--- @see loomworks.Workspace.get_operations
function Core:get_operations()
    if not self._workspace then return {} end
    return self._workspace:get_operations()
end

--- @see loomworks.Workspace.cancel_conflicting_operations
function Core:cancel_conflicting_operations(units)
    if not self._workspace then return end
    self._workspace:cancel_conflicting_operations(units)
end

--- @see loomworks.Workspace.has_pending_deletions
function Core:has_pending_deletions()
    if not self._workspace then return false end
    return self._workspace:has_pending_deletions()
end

--- @see loomworks.Workspace.after_deletions
function Core:after_deletions(fn)
    if not self._workspace then fn(); return end
    self._workspace:after_deletions(fn)
end

--- @see loomworks.Workspace.has_running_tasks
function Core:has_running_tasks()
    if not self._workspace then return false end
    return self._workspace:has_running_tasks()
end

--- @see loomworks.Workspace.find_running_tasks_for_items
function Core:find_running_tasks_for_items(items)
    if not self._workspace then return {} end
    return self._workspace:find_running_tasks_for_items(items)
end

--- @see loomworks.Workspace.get_active_tasks
function Core:get_active_tasks()
    if not self._workspace then return {} end
    return self._workspace:get_active_tasks()
end

--- @see loomworks.Workspace.get_build_dir_locks_info
function Core:get_build_dir_locks_info()
    if not self._workspace then return {} end
    return self._workspace:get_build_dir_locks_info()
end

--- @see loomworks.Workspace.force_release_build_dir_lock
function Core:force_release_build_dir_lock(dir)
    if not self._workspace then return false end
    return self._workspace:force_release_build_dir_lock(dir)
end

--- @see loomworks.Workspace.cancel_task
function Core:cancel_task(task_id)
    if not self._workspace then return false end
    return self._workspace:cancel_task(task_id)
end

--- @see loomworks.Workspace.cancel_tasks_for_project
function Core:cancel_tasks_for_project(project)
    if not self._workspace then return 0 end
    return self._workspace:cancel_tasks_for_project(project)
end

--- @see loomworks.Workspace.cancel_tasks_for_profile
function Core:cancel_tasks_for_profile(profile)
    if not self._workspace then return 0 end
    return self._workspace:cancel_tasks_for_profile(profile)
end

--- @see loomworks.Workspace.get_lsp_options
function Core:get_lsp_options(server)
    if not self._workspace then return {} end
    return self._workspace:get_lsp_options(server)
end

--- @see loomworks.Workspace.set_lsp_option
function Core:set_lsp_option(server, key, value)
    if not self._workspace then return end
    self._workspace:set_lsp_option(server, key, value)
end

--- @see loomworks.Workspace.stop_tasks_then
function Core:stop_tasks_then(task_ids, on_done)
    if not self._workspace then on_done(); return end
    self._workspace:stop_tasks_then(task_ids, on_done)
end

--- @see loomworks.Workspace.record_task_result
function Core:record_task_result(result)
    if not self._workspace then return end
    self._workspace:record_task_result(result)
end

--- @see loomworks.Workspace._validate_build_dir
function Core:_validate_build_dir(build_dir, safe_prefix)
    if not self._workspace then return false end
    return self._workspace:_validate_build_dir(build_dir, safe_prefix)
end

--- @see loomworks.Workspace._delete_build_dirs_async
function Core:_delete_build_dirs_async(dirs, callback)
    if not self._workspace then callback({}); return end
    self._workspace:_delete_build_dirs_async(dirs, callback)
end

--- @see loomworks.Workspace.delete_cached_configs
function Core:delete_cached_configs(items)
    if not self._workspace then return end
    self._workspace:delete_cached_configs(items)
end

--- @see loomworks.Workspace.reset_cached_configs
function Core:reset_cached_configs(items)
    if not self._workspace then return end
    self._workspace:reset_cached_configs(items)
end

--- @see loomworks.Workspace.mark_cached_configs_cleaned
function Core:mark_cached_configs_cleaned(items)
    if not self._workspace then return end
    self._workspace:mark_cached_configs_cleaned(items)
end

--- @see loomworks.Workspace._mark_cache_unknown
function Core:_mark_cache_unknown(items)
    if not self._workspace then return end
    self._workspace:_mark_cache_unknown(items)
end

--- @see loomworks.Workspace._run_deletion
function Core:_run_deletion(items, work_fn, on_done, reason)
    if not self._workspace then if on_done then on_done() end; return end
    self._workspace:_run_deletion(items, work_fn, on_done, reason)
end

--- @see loomworks.Workspace.execute_deletion
function Core:execute_deletion(plan, opts, on_done)
    if not self._workspace then if on_done then on_done() end; return end
    self._workspace:execute_deletion(plan, opts, on_done)
end

--- @see loomworks.Workspace._materialize_from_data
function Core:_materialize_from_data(config_set, tool_entry)
    if not self._workspace then return end
    self._workspace:_materialize_from_data(config_set, tool_entry)
end

--- @see loomworks.Workspace._scan_tools
function Core:_scan_tools()
    if not self._workspace then return end
    self._workspace:_scan_tools()
end

--- @see loomworks.Workspace._scan_tools_async
function Core:_scan_tools_async()
    if not self._workspace then return end
    self._workspace:_scan_tools_async()
end

--- @see loomworks.Workspace._scan_targets_async
function Core:_scan_targets_async()
    if not self._workspace then return end
    self._workspace:_scan_targets_async()
end

--- @see loomworks.Workspace._add_launch_config_targets
function Core:_add_launch_config_targets()
    if not self._workspace then return end
    self._workspace:_add_launch_config_targets()
end

--- @see loomworks.Workspace.rescan_tools
function Core:rescan_tools()
    if not self._workspace then return end
    self._workspace:rescan_tools()
end

--- @see loomworks.Workspace._cleanup_orphaned_skeletons
function Core:_cleanup_orphaned_skeletons(raw_cache)
    if not self._workspace then return end
    self._workspace:_cleanup_orphaned_skeletons(raw_cache)
end

return Core

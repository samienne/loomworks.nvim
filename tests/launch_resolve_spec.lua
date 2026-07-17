-- Phase 1 of the CLI launch-targets work (spec §16.17): the pure resolvers
-- that both the editor executors and the headless runner share. These spawn
-- no tasks — they only turn a launch target into a {cmd,args,cwd,env} spec.

local Target = require("loomworks.target")
local LaunchTarget = require("loomworks.launch_target")

--- Minimal ConfigUnit stub: only what resolve_run_spec touches.
local function stub_unit(build_dir, project_key)
    return {
        build_dir = function() return build_dir end,
        _project = { key = project_key },
    }
end

describe("Target:resolve_run_spec", function()
    it("returns cmd/cwd/name for an executable with an artifact", function()
        local t = Target.new(stub_unit("/b", "app"), "app",
            { type = "executable", artifact = "src/app/app.exe" })
        local spec, err = t:resolve_run_spec()
        assert.is_nil(err)
        assert.equals("/b/src/app/app.exe", spec.cmd)
        assert.equals("/b", spec.cwd)
        assert.equals("app: run app", spec.name)
    end)

    it("errors for a non-executable target", function()
        local t = Target.new(stub_unit("/b", "app"), "lib",
            { type = "static_library", artifact = "libx.a" })
        local spec, err = t:resolve_run_spec()
        assert.is_nil(spec)
        assert.is_truthy(err:find("not an executable"))
    end)

    it("errors when the executable has no built artifact", function()
        local t = Target.new(stub_unit("/b", "app"), "app", { type = "executable" })
        local spec, err = t:resolve_run_spec()
        assert.is_nil(spec)
        assert.is_truthy(err:find("no built artifact"))
    end)

    it("errors when there is no build directory", function()
        local t = Target.new(stub_unit(nil, "app"), "app",
            { type = "executable", artifact = "app.exe" })
        local spec, err = t:resolve_run_spec()
        assert.is_nil(spec)
        assert.is_truthy(err:find("no build directory"))
    end)

    it("defaults the working dir to the project directory (§8.7)", function()
        local unit = {
            build_dir = function() return "/b" end,
            _project = { key = "app", abs_path = function() return "/ws/app" end },
        }
        local t = Target.new(unit, "app", { type = "executable", artifact = "app.exe" })
        assert.equals("/ws/app", t:resolve_run_spec().cwd)
    end)

    it("honors an explicit working_dir override", function()
        local unit = {
            build_dir = function() return "/b" end,
            _project = { key = "app", abs_path = function() return "/ws/app" end },
        }
        local t = Target.new(unit, "app", { type = "executable", artifact = "app.exe" })
        assert.equals("/custom/run", t:resolve_run_spec({ working_dir = "/custom/run" }).cwd)
    end)
end)

describe("Target run environment (§8.7)", function()
    local function unit_with(targets, opts)
        opts = opts or {}
        return {
            build_dir = function() return opts.build_dir or "/b" end,
            variant = function() return opts.variant end,
            _tool_data = opts.tool_data,
            _project = {
                key = opts.project or "app",
                _module = opts.module and { impl = opts.module } or nil,
            },
            targets = targets,
        }
    end

    -- PATH composition is Windows-only (POSIX resolves .so via rpath); guard
    -- the dir-on-PATH assertions so the suite is correct on every platform.
    local is_win = vim.fn.has("win32") == 1

    local function path_of(env)
        assert.is_table(env)
        local p = env.PATH or env.Path
        assert.is_string(p)
        return p
    end

    it("prepends sibling shared/module-library dirs to PATH (not static libs)", function()
        local unit = unit_with({
            app  = { type = "executable", artifact = "src/app/app.exe" },
            foo  = { type = "shared_library", artifact = "sub/foo.dll" },
            bar  = { type = "module_library", artifact = "plug/bar.dll" },
            slib = { type = "static_library", artifact = "libs/s.a" }, -- ignored
        })
        local spec = Target.new(unit, "app",
            { type = "executable", artifact = "src/app/app.exe" }):resolve_run_spec()
        if not is_win then
            assert.is_nil(spec.env, "POSIX relies on rpath, not PATH")
            return
        end
        local p = path_of(spec.env)
        assert.is_truthy(p:find("/b/sub", 1, true), "shared-lib dir on PATH")
        assert.is_truthy(p:find("/b/plug", 1, true), "module-lib dir on PATH")
        assert.is_nil(p:find("/b/libs", 1, true), "static-lib dir NOT on PATH")
    end)

    it("orders shared-lib dirs deterministically (sorted)", function()
        if not is_win then return end
        local unit = unit_with({
            app = { type = "executable", artifact = "app.exe" },
            z   = { type = "shared_library", artifact = "zzz/z.dll" },
            a   = { type = "shared_library", artifact = "aaa/a.dll" },
        })
        local spec = Target.new(unit, "app",
            { type = "executable", artifact = "app.exe" }):resolve_run_spec()
        local p = path_of(spec.env)
        assert.is_truthy(p:find("/b/aaa", 1, true) < p:find("/b/zzz", 1, true),
            "aaa before zzz on PATH (sorted, not hash order)")
    end)

    it("prepends the module's runtime_path dirs (toolchain runtime)", function()
        if not is_win then return end
        local unit = unit_with(
            { app = { type = "executable", artifact = "app.exe" } },
            { module = { runtime_path = function() return { "/toolchain/bin" } end } })
        local spec = Target.new(unit, "app",
            { type = "executable", artifact = "app.exe" }):resolve_run_spec()
        assert.is_truthy(path_of(spec.env):find("/toolchain/bin", 1, true))
    end)

    it("leaves env nil when there is nothing to add", function()
        local unit = unit_with({ app = { type = "executable", artifact = "app.exe" } })
        local spec = Target.new(unit, "app",
            { type = "executable", artifact = "app.exe" }):resolve_run_spec()
        assert.is_nil(spec.env)
    end)
end)

describe("module runtime_path (§8.4)", function()
    it("meson returns the compiler bin dir from tool_data", function()
        local meson = require("loomworks.modules.meson")
        assert.same({ "/opt/gcc/bin" },
            meson.runtime_path({ tool_data = { compiler_bin_dir = "/opt/gcc/bin" } }))
        assert.is_nil(meson.runtime_path({ tool_data = {} }))
        assert.is_nil(meson.runtime_path({}))
    end)

    it("cmake returns the compiler_path's directory", function()
        local cmake = require("loomworks.modules.cmake")
        assert.same({ "C:/tc/bin" },
            cmake.runtime_path({ tool_data = { compiler_path = "C:/tc/bin/clang++.exe" } }))
        assert.is_nil(cmake.runtime_path({ tool_data = {} }))
    end)
end)

describe("LaunchTarget:resolve_launch_spec", function()
    -- Construct a LaunchTarget instance directly, bypassing descriptor
    -- resolution — the dispatcher only reads _launch_config / _target.
    local function lt(fields)
        return setmetatable(fields, LaunchTarget)
    end

    it("dispatches to an executable build target and forwards extra_args", function()
        local target = {
            is_executable = function() return true end,
            resolve_run_spec = function()
                return { cmd = "/b/app.exe", cwd = "/b", name = "app: run app" }
            end,
        }
        local spec = lt({ _target = target }):resolve_launch_spec({ extra_args = { "a", "b" } })
        assert.equals("/b/app.exe", spec.cmd)
        assert.equals("/b", spec.cwd)
        assert.same({ "a", "b" }, spec.args)
        assert.equals("app: run app", spec.name)
    end)

    it("dispatches to a command config, declared args before extra_args", function()
        local self = lt({ _project = { key = "app" }, _launch_name = "gui", _launch_config = {} })
        -- Stub the expansion seam so no full workspace/expand context is needed.
        self.resolve_command_spec = function()
            return { cmd = "prog", args = { "--flag" }, cwd = "/w", env = { X = "1" } }
        end
        local spec = self:resolve_launch_spec({ extra_args = { "in.txt" } })
        assert.same({ "--flag", "in.txt" }, spec.args)
        assert.equals("app: gui", spec.name)
        assert.same({ X = "1" }, spec.env)
    end)

    it("works with no extra_args (editor path)", function()
        local target = {
            is_executable = function() return true end,
            resolve_run_spec = function()
                return { cmd = "/b/app.exe", cwd = "/b", name = "app: run app" }
            end,
        }
        local spec = lt({ _target = target }):resolve_launch_spec()
        assert.same({}, spec.args)
    end)

    it("errors for a target that is neither command nor executable", function()
        local spec, err = lt({}):resolve_launch_spec()
        assert.is_nil(spec)
        assert.is_truthy(err:find("neither"))
    end)

    it("propagates a target resolution error", function()
        local target = {
            is_executable = function() return true end,
            resolve_run_spec = function()
                return nil, "no build directory for target 'app'"
            end,
        }
        local spec, err = lt({ _target = target }):resolve_launch_spec()
        assert.is_nil(spec)
        assert.is_truthy(err:find("no build directory"))
    end)
end)

describe("LaunchTarget:_resolve_target_ref (target-backed launch, §8.7)", function()
    local function with_targets(targets)
        return setmetatable({ _config_unit = { targets = targets } }, LaunchTarget)
    end
    local app = { display_name = function() return "app" end }
    local lib = { display_name = function() return "lib" end }
    local subject = with_targets({ ["app::@a1b2"] = app, ["lib::@c3d4"] = lib })

    it("resolves by exact key (opaque module id)", function()
        assert.equals(app, subject:_resolve_target_ref("app::@a1b2"))
    end)

    it("resolves by display name (friendly name from --from-target)", function()
        assert.equals(app, subject:_resolve_target_ref("app"))
        assert.equals(lib, subject:_resolve_target_ref("lib"))
    end)

    it("returns nil for an unknown reference", function()
        assert.is_nil(subject:_resolve_target_ref("nope"))
    end)

    it("returns nil when no targets are parsed", function()
        assert.is_nil(with_targets(nil):_resolve_target_ref("app"))
    end)
end)

describe("LaunchTarget:describe (status/listing)", function()
    local function lt(fields) return setmetatable(fields, LaunchTarget) end

    it("describes a module target", function()
        assert.equals("app:app (target)",
            lt({ _project = { key = "app" }, _target_id = "app" }):describe())
    end)

    it("describes a command/target-backed launch config", function()
        assert.equals("app:run (launch config)",
            lt({ _project = { key = "app" }, _launch_name = "run" }):describe())
    end)

    it("falls back to unresolved when nothing is set", function()
        assert.equals("app (unresolved)", lt({ _project = { key = "app" } }):describe())
    end)
end)

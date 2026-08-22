-- `lw run` operand resolution (spec §16.17 "Positional grammar"). A single
-- operand is ALWAYS a target on the resolved profile (never a profile selector);
-- two operands name profile + target; none runs the default. `cli._run_selection`
-- maps parsed operands → (profile, target) with an injectable resolve seam, and
-- the named target is matched AFTER the build via `cli._match_targets`. Separate
-- blocks cover cmd_run's `--` split + flag parsing and the shared matcher.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Run `fn` with io.write / io.stderr / os.exit captured, so a die() path is
--- observable (exit_code set, no process kill) instead of terminating busted.
local function capture(fn)
    local out_buf, err_buf = {}, {}
    local real_write, real_stderr, real_exit = io.write, io.stderr, os.exit
    io.write = function(s) out_buf[#out_buf + 1] = s end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
    local exit_code
    os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
    local ok, ret = pcall(fn)
    io.write, io.stderr, os.exit = real_write, real_stderr, real_exit
    return {
        ok = ok,
        ret = ret,
        exit_code = exit_code,
        stdout = table.concat(out_buf),
        stderr = table.concat(err_buf),
    }
end

local function prof(key) return { key = key } end

--- An injectable `resolve` seam (stands in for resolve_build_target) + a call
--- log. `resolved` is the profile it returns; a nil operand (0-/1-operand form)
--- is recorded via a counter since it can't be appended to a list.
local function resolver(resolved)
    local log = { resolve = {}, n = 0, last = "unset" }
    local seam = function(ws_in, name)
        log.n = log.n + 1
        log.resolve[log.n] = name
        log.last = name
        return resolved or prof("resolved:" .. tostring(name)), ws_in
    end
    return { resolve = seam }, log
end

-- ---------------------------------------------------------------------------
-- _run_selection — operand → (profile, target) mapping
-- ---------------------------------------------------------------------------

describe("cli._run_selection", function()
    it("zero operands → resolve(nil), no target", function()
        local deps, log = resolver(prof("only"))
        local profile, target = cli._run_selection({}, {}, deps)

        assert.equals(1, log.n)
        assert.is_nil(log.last)                     -- resolve(ws, nil)
        assert.is_nil(target)
        assert.equals("only", profile.key)
    end)

    it("one operand → the SAME nil-resolution as bare run, operand is the target", function()
        local active = prof("active")
        local deps, log = resolver(active)
        local profile, target = cli._run_selection({}, { "app" }, deps)

        assert.equals(1, log.n)
        assert.is_nil(log.last)                     -- profile resolved with NO name…
        assert.equals(active, profile)              -- …the active/sole profile
        assert.equals("app", target)               -- …and `app` is a TARGET on it
    end)

    it("one operand equal to a PROFILE key is STILL a target, not a profile selector", function()
        -- Breaking-change guard: `lw run Debug` must not select profile "Debug".
        local active = prof("active")
        local deps, log = resolver(active)
        local profile, target = cli._run_selection({}, { "Debug" }, deps)

        assert.equals(1, log.n)
        assert.is_nil(log.last)                     -- resolve called with nil, NOT "Debug"
        assert.equals(active, profile)              -- the active profile, not "Debug"
        assert.equals("Debug", target)             -- "Debug" is treated as the target name
    end)

    it("two operands → resolve(<profile>), second operand is the target", function()
        local deps, log = resolver(prof("Debug"))
        local profile, target = cli._run_selection({}, { "Debug", "app" }, deps)

        assert.same({ "Debug" }, log.resolve)       -- profile resolved BY NAME
        assert.equals("app", target)
        assert.equals("Debug", profile.key)
    end)

    it("headless + multiple profiles + one operand errors (profile undeterminable)", function()
        -- No resolve seam → the REAL resolve_build_target(ws, nil) runs. Under
        -- `nvim --headless` stdin is not a tty, so it takes the non-interactive
        -- path (§16.3): with several profiles and no name it dies, listing them.
        -- The one operand is a target, so it can NEVER stand in as the profile.
        local ws = { _profiles = { prof("Debug"), prof("Release") } }
        local res = capture(function() return cli._run_selection(ws, { "app" }) end)

        assert.is_false(res.ok)
        assert.equals(1, res.exit_code)
        assert.is_truthy(res.stderr:find("no profile specified", 1, true))
        assert.is_truthy(res.stderr:find("Debug", 1, true))
        assert.is_truthy(res.stderr:find("Release", 1, true))
    end)
end)

-- ---------------------------------------------------------------------------
-- _match_targets — the shared matcher (runs against the POST-BUILD candidates)
-- ---------------------------------------------------------------------------

describe("cli._match_targets (post-build target resolution)", function()
    -- `all` is injected here, modelling the candidate list `launchable_targets`
    -- produces AFTER the build — so build targets (kind "target") are present.
    local BUILT = {
        { project = { key = "app" }, name = "myexe", kind = "target" },
        { project = { key = "app" }, name = "gui", kind = "launch" },
    }

    it("finds a build-target name that only exists once the profile is built", function()
        local matches = cli._match_targets(nil, {}, "myexe", nil, nil, BUILT)
        assert.equals(1, #matches)
        assert.equals("myexe", matches[1].name)
        assert.equals("target", matches[1].kind)
    end)

    it("a profile key used as a one-operand target does NOT match (→ clear error)", function()
        -- `lw run Debug` reaches here as target "Debug"; no such target exists,
        -- so match is empty and cmd_run dies with the launchable-targets list.
        local matches, all = cli._match_targets(nil, {}, "Debug", nil, nil, BUILT)
        assert.equals(0, #matches)
        assert.equals(BUILT, all)                   -- caller lists these in the error
    end)

    it("honors a --project scope and a project:name prefix", function()
        local profile = { project = function() return true end } -- "app" is a known project
        assert.equals(1, #cli._match_targets(nil, profile, "app:myexe", nil, nil, BUILT))
        assert.equals(1, #cli._match_targets(nil, {}, "myexe", "app", nil, BUILT))
        assert.equals(0, #cli._match_targets(nil, {}, "myexe", "other", nil, BUILT))
    end)

    it("honors a --target / --launch kind filter", function()
        assert.equals(1, #cli._match_targets(nil, {}, "myexe", nil, "target", BUILT))
        assert.equals(0, #cli._match_targets(nil, {}, "myexe", nil, "launch", BUILT))
    end)
end)

-- ---------------------------------------------------------------------------
-- cmd_run: `--` split + flag parsing feed the resolver correctly
-- ---------------------------------------------------------------------------

describe("cli.cmd_run — operand/flag parsing", function()
    -- Monkeypatch the resolver to capture what cmd_run hands it, then halt
    -- before the (real) build/launch machinery runs.
    local function parsed(argv)
        local seen
        local real = cli._run_selection
        cli._run_selection = function(_, positionals)
            seen = { positionals = positionals }
            error({ __stop = true }, 0)
        end
        capture(function() return cli.cmd_run({}, argv) end)
        cli._run_selection = real
        return seen
    end

    it("keeps a lone target operand out of the forwarded args (`lw run app -- --flag`)", function()
        local s = parsed({ "run", "app", "--", "--flag" })
        assert.same({ "app" }, s.positionals)       -- one operand → target
    end)

    it("consumes --project / --target flags (not left as positionals)", function()
        local s = parsed({ "run", "--project", "proj", "--target", "app" })
        assert.same({ "app" }, s.positionals)
    end)

    it("passes both operands through for the two-operand form", function()
        local s = parsed({ "run", "Debug", "app" })
        assert.same({ "Debug", "app" }, s.positionals)
    end)
end)

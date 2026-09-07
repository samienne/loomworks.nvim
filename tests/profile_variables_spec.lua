--- Tests for profile-scoped fill of blank project variables (core §1.3.1).
---
--- Covers three layers:
---   * pure resolution/validation — a `default`-less declaration is valid and
---     resolves *blank*; the active profile fills a blank but never shadows a
---     value the config chain / default provides; `blank_variables` reporting.
---   * the build gate — `Profile:assert_buildable` refuses while a blank is
---     unfilled and passes once filled.
---   * `lw profile set/unset` on disk — persistence to user.json (only),
---     reload, undeclared/unknown-profile rejection, active-profile default,
---     and exclusion from loomworks.json on publish.

local variables = require("loomworks.variables")

-- A fake profile exposing just `variable_value`, as `variables.resolve` uses it.
local function fake_profile(vals)
    return {
        variable_value = function(_, project_key, name)
            local by_project = vals and vals[project_key]
            return by_project and by_project[name] or nil
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Declaration validation — default is optional
-- ---------------------------------------------------------------------------
describe("validate_declarations with optional default", function()
    it("accepts a declaration with a type and no default (blank)", function()
        local ok, err = variables.validate_declarations({
            sdk_root = { type = "path" },
        })
        assert.is_true(ok)
        assert.is_nil(err)
    end)

    it("still requires a valid type", function()
        local ok = variables.validate_declarations({ x = { default = "v" } })
        assert.is_falsy(ok)
    end)

    it("still rejects a non-string default when present", function()
        local ok = variables.validate_declarations({
            x = { type = "string", default = 7 },
        })
        assert.is_falsy(ok)
    end)
end)

-- ---------------------------------------------------------------------------
-- Resolution — profile fill, blanks-only
-- ---------------------------------------------------------------------------
describe("profile-fill variable resolution", function()
    local function project(decls) return { key = "App", variables = decls } end

    it("resolves BLANK (value nil) when no default and no profile", function()
        local r = variables.resolve(project({ sdk_root = { type = "path" } }), nil, nil, nil)
        assert.is_nil(r.sdk_root.value)
        assert.is_false(r.sdk_root.from_profile)
    end)

    it("the active profile fills a blank variable", function()
        local prof = fake_profile({ App = { sdk_root = "/opt/sdk/3.2" } })
        local r = variables.resolve(project({ sdk_root = { type = "path" } }), nil, nil, prof)
        assert.equals("/opt/sdk/3.2", r.sdk_root.value)
        assert.is_true(r.sdk_root.from_profile)
    end)

    it("the profile value does NOT override a project default", function()
        local prof = fake_profile({ App = { sdk_root = "/from/profile" } })
        local r = variables.resolve(
            project({ sdk_root = { type = "path", default = "/from/default" } }),
            nil, nil, prof)
        assert.equals("/from/default", r.sdk_root.value)
        assert.is_false(r.sdk_root.from_profile)
    end)

    it("the profile value does NOT override a config-chain value", function()
        local proj = project({ sdk_root = { type = "path" } }) -- blank default
        local cfg = { name = "Debug", variables = { sdk_root = "/from/config" }, _inherits = {} }
        local prof = fake_profile({ App = { sdk_root = "/from/profile" } })
        local r = variables.resolve(proj, cfg, nil, prof)
        assert.equals("/from/config", r.sdk_root.value)
        assert.is_false(r.sdk_root.from_profile)
        assert.equals(cfg, r.sdk_root.source_config)
    end)

    it("blank_variables lists only the still-blank names", function()
        local proj = project({
            sdk_root = { type = "path" },          -- blank
            port = { type = "string", default = "9229" }, -- has default
        })
        assert.same({ "sdk_root" }, variables.blank_variables(proj, nil, nil, nil))
        -- Filled by the profile → no longer blank.
        local prof = fake_profile({ App = { sdk_root = "/x" } })
        assert.same({}, variables.blank_variables(proj, nil, nil, prof))
    end)
end)

-- ---------------------------------------------------------------------------
-- Build gate — Profile:assert_buildable
-- ---------------------------------------------------------------------------
describe("blank-variable build gate", function()
    local Profile = require("loomworks.profile").Profile

    --- Minimal Profile-shaped object exposing just what assert_buildable /
    --- blank_variables need: one project with variable declarations, a
    --- (possibly nil) configuration, and the profile's own fill values.
    --- `is_valid` is stubbed true so only the blank gate is under test.
    local function gate_profile(decls, profile_vals, cfg)
        local project = { key = "App", variables = decls }
        local pp = { _project = project, configuration = function() return cfg end }
        local self = setmetatable({
            key = "Dev",
            _profile_variables = profile_vals,
        }, { __index = Profile })
        function self:projects() return { pp } end
        function self:is_valid() return true, {} end
        return self
    end

    it("refuses a build while a declared blank is unfilled", function()
        local p = gate_profile({ sdk_root = { type = "path" } }, nil, nil)
        local ok, err = p:assert_buildable()
        assert.is_false(ok)
        assert.is_truthy(err:find("sdk_root", 1, true))
        assert.is_truthy(err:find("is blank", 1, true))
        assert.is_truthy(err:find("Dev", 1, true))
        assert.is_truthy(err:find("App", 1, true))
    end)

    it("passes once the profile fills the blank", function()
        local p = gate_profile({ sdk_root = { type = "path" } },
            { App = { sdk_root = "/opt/sdk" } }, nil)
        local ok, err = p:assert_buildable()
        assert.is_true(ok)
        assert.is_nil(err)
    end)

    it("a variable with a default is not a gate", function()
        local p = gate_profile({ sdk_root = { type = "path", default = "/d" } }, nil, nil)
        assert.is_true((p:assert_buildable()))
    end)

    it("blank_variables reports the (project, name) pair", function()
        local p = gate_profile({ sdk_root = { type = "path" } }, nil, nil)
        local blanks = p:blank_variables()
        assert.equals(1, #blanks)
        assert.equals("App", blanks[1].project_key)
        assert.equals("sdk_root", blanks[1].name)
    end)
end)

-- ---------------------------------------------------------------------------
-- lw profile set / unset — on disk
-- ---------------------------------------------------------------------------
_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local function capture(fn)
    local out_buf, err_buf = {}, {}
    local rw, rs, rex = io.write, io.stderr, os.exit
    io.write = function(s) out_buf[#out_buf + 1] = s end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
    local exit_code
    os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
    pcall(fn)
    io.write, io.stderr, os.exit = rw, rs, rex
    return {
        exit_code = exit_code,
        stdout = table.concat(out_buf),
        stderr = table.concat(err_buf),
    }
end

describe("lw profile set/unset (on-disk)", function()
    --- Create a temp workspace with a typescript App declaring a blank
    --- `sdk_root`, a Debug config, a `Dev` set mapping App=Debug, and an
    --- active `Dev` profile (typescript needs no toolchain). Returns the root.
    local function make_ws()
        local root = vim.fn.tempname():gsub("\\", "/")
        vim.fn.mkdir(root, "p")
        vim.fn.mkdir(root .. "/App", "p")
        local lw = {
            projects = {
                App = {
                    typescript = vim.empty_dict(),
                    variables = { sdk_root = { type = "path" } },
                },
            },
        }
        local f = assert(io.open(root .. "/loomworks.json", "w"))
        f:write(vim.json.encode(lw)); f:close()
        capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
        capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" }) end)
        capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
        return root
    end

    local function read_json(path)
        local f = io.open(path, "r")
        if not f then return nil end
        local c = f:read("*a"); f:close()
        return vim.json.decode(c)
    end
    local function read_user(root) return read_json(root .. "/.nvim/loomworks.user.json") end

    it("set persists into user.json profile_variables and survives reload", function()
        local root = make_ws()
        local r = capture(function()
            cli.cmd_profile("set", root, { "profile", "set", "Dev", "App", "sdk_root", "/opt/sdk/3.2" })
        end)
        assert.is_nil(r.exit_code) -- no die()

        local user = read_user(root)
        assert.equals("/opt/sdk/3.2", user.profile_variables.Dev.App.sdk_root)

        -- A fresh command reloads from disk; the query resolves the fill value.
        local g = capture(function()
            cli.cmd_profile_query(root, { "profile", "query", "Dev", "App", "variables.sdk_root" })
        end)
        assert.equals("/opt/sdk/3.2", vim.trim(g.stdout))
    end)

    it("defaults to the active profile when none is named", function()
        local root = make_ws()
        capture(function()
            cli.cmd_profile("set", root, { "profile", "set", "App", "sdk_root", "/opt/active" })
        end)
        local user = read_user(root)
        assert.equals("/opt/active", user.profile_variables.Dev.App.sdk_root)
    end)

    it("unset clears the value and prunes the empty map", function()
        local root = make_ws()
        capture(function()
            cli.cmd_profile("set", root, { "profile", "set", "Dev", "App", "sdk_root", "/x" })
        end)
        capture(function()
            cli.cmd_profile("unset", root, { "profile", "unset", "Dev", "App", "sdk_root" })
        end)
        local user = read_user(root)
        assert.is_nil(user.profile_variables)
    end)

    it("rejects setting an UNDECLARED variable", function()
        local root = make_ws()
        local r = capture(function()
            cli.cmd_profile("set", root, { "profile", "set", "Dev", "App", "nope", "x" })
        end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("declares no variable 'nope'", 1, true))
        assert.is_nil(read_user(root).profile_variables)
    end)

    it("errors on an unknown profile", function()
        local root = make_ws()
        local r = capture(function()
            cli.cmd_profile("set", root, { "profile", "set", "Nope", "App", "sdk_root", "/x" })
        end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:lower():find("profile", 1, true))
    end)

    it("an unfilled blank is a build-blocking diagnostic that fails --check, cleared by filling", function()
        local root = make_ws()
        -- Active profile Dev has a blank sdk_root → status --check fails and the
        -- diagnostic names the variable. cmd_status RETURNS the exit code.
        local before_code
        local before = capture(function() before_code = cli.cmd_status(root, { check = true }) end)
        assert.is_truthy((before_code or 0) ~= 0)
        assert.is_truthy(before.stdout:find("sdk_root", 1, true))
        assert.is_truthy(before.stdout:lower():find("blank", 1, true))

        -- Fill it → the diagnostic clears and --check passes.
        capture(function()
            cli.cmd_profile("set", root, { "profile", "set", "Dev", "App", "sdk_root", "/opt/sdk" })
        end)
        local after_code
        local after = capture(function() after_code = cli.cmd_status(root, { check = true }) end)
        assert.equals(0, (after_code or 0))
        assert.is_falsy(after.stdout:lower():find("sdk_root", 1, true))
    end)

    it("fill values are NOT written to loomworks.json on publish", function()
        local root = make_ws()
        capture(function()
            cli.cmd_profile("set", root, { "profile", "set", "Dev", "App", "sdk_root", "/secret/local/path" })
        end)
        capture(function() cli.cmd_profile_publish(root, "Dev") end)

        local shared = read_json(root .. "/loomworks.json")
        assert.is_nil(shared.profile_variables)
        -- The published profile entry carries no fill values either.
        if shared.profiles and shared.profiles.Dev then
            assert.is_nil(shared.profiles.Dev.variables)
            assert.is_nil(shared.profiles.Dev.profile_variables)
        end
        -- Not leaked anywhere in the file.
        local raw = assert(io.open(root .. "/loomworks.json", "r"))
        local text = raw:read("*a"); raw:close()
        assert.is_falsy(text:find("/secret/local/path", 1, true))
    end)
end)

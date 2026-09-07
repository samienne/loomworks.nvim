-- CLI consistency fixes: one shared NAMED-profile matcher across build/run/
-- clean/select/show/remove/target (#1/#2), verb aliases (#3), launch management
-- accepting the run/target addressing (#4), and positional `<project> <config>`
-- mappings for `configuration-set create` (#5).
--
-- Two layers: pure seams (match_profile_arg, resolve_build_target,
-- resolve_profile_for_show, consume_launch_address) exercised with hand-built
-- shapes, and an on-disk round-trip through the real CLI commands for the
-- aliases and the cset positional form.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

-- Run `fn` with io.write / io.stderr / os.exit captured, so a die() path is
-- observable (exit_code set, no process kill) instead of terminating busted.
local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, ret = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  return {
    ok = ok, ret = ret, exit_code = exit_code,
    stdout = table.concat(out_buf), stderr = table.concat(err_buf),
  }
end

local function ws_with(keys, active, sets)
  local profiles = {}
  for _, k in ipairs(keys) do profiles[#profiles + 1] = { key = k } end
  return { _profiles = profiles, _active_profile_key = active, _config_sets = sets or {} }
end

-- ---------------------------------------------------------------------------
-- #1/#2 — the single shared NAMED matcher
-- ---------------------------------------------------------------------------
describe("match_profile_arg (shared named matcher)", function()
  -- Keys chosen so a bare "2" is BOTH a valid list index AND a boundary
  -- substring of a DIFFERENT key: sorted-by-key order is one-1, three-3, two-2,
  -- so index 2 = "three-3" while the substring "2" would hit "two-2".
  local ws = ws_with({ "one-1", "two-2", "three-3" })

  it("a bare number resolves the stable list index, NOT a substring", function()
    local p = cli._match_profile_arg(ws, "2")
    assert.equals("three-3", p.key) -- index 2 (sorted), not "two-2"
  end)

  it("no_number opt-out falls through to name matching (a boundary substring)", function()
    local p = cli._match_profile_arg(ws, "2", { no_number = true })
    assert.equals("two-2", p.key) -- "2" now a unique boundary substring
  end)

  it("an exact key wins", function()
    assert.equals("two-2", cli._match_profile_arg(ws, "two-2").key)
  end)

  it("a unique boundary substring resolves", function()
    local w = ws_with({ "Debug:ninja-clang-18", "Release:ninja-gcc-13" })
    assert.equals("Debug:ninja-clang-18", cli._match_profile_arg(w, "Debug").key)
    assert.equals("Debug:ninja-clang-18", cli._match_profile_arg(w, "clang-18").key)
  end)

  it("a boundary-NON-match does not match (clang-1 vs only clang-18)", function()
    local w = ws_with({ "Debug:ninja-clang-18" })
    assert.is_nil(cli._match_profile_arg(w, "clang-1"))
  end)

  it("returns nil (not a die) on a total miss", function()
    assert.is_nil(cli._match_profile_arg(ws_with({ "a", "b" }), "zzz"))
  end)

  it("dies on an ambiguous substring", function()
    local w = ws_with({ "Debug:gcc", "Debug:clang" })
    local r = capture(function() cli._match_profile_arg(w, "Debug") end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("matches multiple profiles", 1, true))
  end)
end)

describe("resolve_build_target (build/clean/run) named resolution — #1 bug", function()
  -- The bug: build used plain string.find + no number index, so `lw build 2`
  -- was a substring, and `clang-1` plain-matched `clang-18`. It now shares the
  -- boundary/number matcher with resolve_profile.
  it("a bare number is the list index, not a substring", function()
    -- one-1, three-3, two-2 sorted; index 2 = three-3 (substring "2" → two-2).
    local ws = ws_with({ "one-1", "two-2", "three-3" })
    local p = cli._resolve_build_target(ws, "2")
    assert.equals("three-3", p.key)
  end)

  it("a boundary-non-match (clang-1 vs clang-18) does NOT resolve — it dies", function()
    local ws = ws_with({ "Debug:ninja-clang-18" }) -- no config sets → no onboarding
    local r = capture(function() cli._resolve_build_target(ws, "clang-1") end)
    assert.equals(1, r.exit_code)                       -- did not silently match clang-18
    assert.is_falsy(r.ret and type(r.ret) == "table" and r.ret.key)
  end)

  it("a unique boundary substring still resolves", function()
    local ws = ws_with({ "Debug:ninja-clang-18", "Release:ninja-gcc-13" })
    assert.equals("Release:ninja-gcc-13", cli._resolve_build_target(ws, "gcc").key)
  end)
end)

describe("resolve_profile_for_show — #2 substring", function()
  local ws = ws_with({ "Debug:ninja-clang-18", "Release:ninja-clang-18" }, "Debug:ninja-clang-18")

  it("resolves a unique substring (previously exact-key only)", function()
    assert.equals("Release:ninja-clang-18", cli._resolve_profile_for_show(ws, "Release").key)
  end)

  it("resolves a bare number to the list index", function()
    assert.equals("Debug:ninja-clang-18", cli._resolve_profile_for_show(ws, "1").key)
  end)

  it("with no name defaults to the active profile (even non-interactive)", function()
    assert.equals("Debug:ninja-clang-18", cli._resolve_profile_for_show(ws).key)
  end)
end)

-- ---------------------------------------------------------------------------
-- #4 — launch address parsing (project:name / --project / --launch)
-- ---------------------------------------------------------------------------
describe("consume_launch_address", function()
  local ws = { _projects = { { key = "App" }, { key = "Lib" } } }

  local function addr(tokens)
    -- tokens are args[3..]; prepend two placeholders for args[1..2].
    local t = { "launch", "sub" }
    for _, v in ipairs(tokens) do t[#t + 1] = v end
    return cli._consume_launch_address(ws, t, 3)
  end

  it("legacy two-positional <project> <name>", function()
    local p, n, i = addr({ "App", "serve" })
    assert.equals("App", p); assert.equals("serve", n); assert.equals(5, i)
  end)

  it("single project:name operand (known project prefix)", function()
    local p, n = addr({ "App:serve" })
    assert.equals("App", p); assert.equals("serve", n)
  end)

  it("single bare name keeps its ':' when the prefix is not a project", function()
    local p, n = addr({ "weird:name" })
    assert.is_nil(p); assert.equals("weird:name", n)
  end)

  it("--project / --launch flags", function()
    local p, n = addr({ "--project", "Lib", "--launch", "run" })
    assert.equals("Lib", p); assert.equals("run", n)
  end)

  it("--project flag + single positional name", function()
    local p, n = addr({ "--project", "Lib", "run" })
    assert.equals("Lib", p); assert.equals("run", n)
  end)

  it("stops at the first edit flag, leaving it for the caller", function()
    -- `launch set App:serve --command deno`
    local p, n, i = addr({ "App:serve", "--command", "deno" })
    assert.equals("App", p); assert.equals("serve", n)
    -- next_index points at the edit flag (--command is args[4] here → i=4).
    assert.equals(4, i)
  end)

  it("leaves trailing bare args after a satisfied two-positional address", function()
    local p, n, i = addr({ "App", "serve", "extra" })
    assert.equals("App", p); assert.equals("serve", n); assert.equals(5, i)
  end)
end)

-- ---------------------------------------------------------------------------
-- On-disk round-trip: #3 aliases + #5 cset positional create
-- ---------------------------------------------------------------------------
describe("aliases + cset positional create (on-disk)", function()
  local uv = vim.uv or vim.loop

  --- Temp workspace with two typescript projects and one config each.
  --- `configuration create` (alias of add) is used for the second, exercising #3.
  local function make_ws()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    local lw = {
      projects = {
        App = { typescript = vim.empty_dict() },
        Lib = { typescript = vim.empty_dict() },
      },
    }
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode(lw)); f:close()
    vim.fn.mkdir(root .. "/App", "p")
    vim.fn.mkdir(root .. "/Lib", "p")
    capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
    -- #3: `configuration create` is an alias of `configuration add`.
    local r = capture(function()
      cli.cmd_configuration("create", root, "Lib", "Release", "variant:default")
    end)
    assert.is_nil(r.exit_code, "configuration create alias should not die: " .. r.stderr)
    return root
  end

  local function read_user(root)
    local f = io.open(root .. "/.nvim/loomworks.user.json", "r")
    if not f then return nil end
    local c = f:read("*a"); f:close()
    return vim.json.decode(c)
  end

  it("#5 configuration-set create accepts positional <project> <config> pairs", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_cset("create", root, { "configuration-set", "create", "dev", "App", "Debug", "Lib", "Release" })
    end)
    assert.is_nil(r.exit_code, "positional cset create should not die: " .. r.stderr)
    local user = read_user(root)
    local set = user.configuration_sets.dev
    assert.equals("Debug", set.App or (set.mappings and set.mappings.App))
  end)

  it("#5 the project=config form still works", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_cset("create", root, { "configuration-set", "create", "dev", "App=Debug" })
    end)
    assert.is_nil(r.exit_code, "= form should still work: " .. r.stderr)
    local user = read_user(root)
    assert.is_truthy(user.configuration_sets.dev)
  end)

  it("#3 configuration-set `add` is an alias of `create`", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_cset("add", root, { "configuration-set", "add", "dev2", "App=Debug" })
    end)
    assert.is_nil(r.exit_code, "cset add alias should not die: " .. r.stderr)
    assert.is_truthy(read_user(root).configuration_sets.dev2)
  end)

  it("#3 launch `create` is an alias of `add`", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_launch("create", root, { "launch", "create", "App", "serve", "node", "server.js" })
    end)
    assert.is_nil(r.exit_code, "launch create alias should not die: " .. r.stderr)
    assert.is_truthy(read_user(root).projects.App.launch.serve)
  end)

  it("#4 launch show/set/remove accept project:name and --project/--launch", function()
    local root = make_ws()
    capture(function()
      cli.cmd_launch("add", root, { "launch", "add", "App", "serve", "node", "server.js" })
    end)

    -- show via project:name
    local s = capture(function()
      cli.cmd_launch("show", root, { "launch", "show", "App:serve" })
    end)
    assert.is_nil(s.exit_code)
    assert.is_truthy(s.stdout:find("serve", 1, true))

    -- show via flags
    local s2 = capture(function()
      cli.cmd_launch("show", root, { "launch", "show", "--project", "App", "--launch", "serve" })
    end)
    assert.is_nil(s2.exit_code)
    assert.is_truthy(s2.stdout:find("serve", 1, true))

    -- set via project:name + edit flag
    local up = capture(function()
      cli.cmd_launch("set", root, { "launch", "set", "App:serve", "--command", "deno" })
    end)
    assert.is_nil(up.exit_code, "launch set via project:name should not die: " .. up.stderr)
    assert.equals("deno", read_user(root).projects.App.launch.serve.command)

    -- remove via project:name
    local rm = capture(function()
      cli.cmd_launch("remove", root, { "launch", "remove", "App:serve" })
    end)
    assert.is_nil(rm.exit_code, "launch remove via project:name should not die: " .. rm.stderr)
    local lc = read_user(root).projects.App.launch
    assert.is_nil(lc and lc.serve)
  end)

  it("#3 the legacy two-positional launch show still works", function()
    local root = make_ws()
    capture(function()
      cli.cmd_launch("add", root, { "launch", "add", "App", "serve", "node" })
    end)
    local s = capture(function()
      cli.cmd_launch("show", root, { "launch", "show", "App", "serve" })
    end)
    assert.is_nil(s.exit_code, "two-positional show should still work: " .. s.stderr)
    assert.is_truthy(s.stdout:find("serve", 1, true))
  end)
end)

-- ---------------------------------------------------------------------------
-- #3 — alias routing for commands whose full run needs heavier setup
-- ---------------------------------------------------------------------------
describe("alias routing (does not hit the unknown-subcommand path)", function()
  it("profile `add` routes to create (not 'unknown profile subcommand')", function()
    local r = capture(function() cli.cmd_profile("add", nil, { "profile", "add" }) end)
    assert.is_falsy(r.stderr:find("unknown profile subcommand", 1, true))
  end)

  it("sdk `create` routes to add (not 'unknown sdk subcommand')", function()
    local r = capture(function() cli.cmd_sdk("create", nil, { "sdk", "create" }) end)
    assert.is_falsy(r.stderr:find("unknown sdk subcommand", 1, true))
  end)

  it("project `create` routes to add (not 'unknown project subcommand')", function()
    local r = capture(function() cli.cmd_project("create", nil, nil, nil, nil, { "project", "create" }) end)
    assert.is_falsy(r.stderr:find("unknown project subcommand", 1, true))
  end)

  it("target `unset` routes to clear (same no-profile error as clear, not a listing miss)", function()
    local ws_root = nil
    local unset = capture(function() cli.cmd_target(ws_root, { "target", "unset" }) end)
    -- clear path: resolve_profile(nil) → "no profile specified"; NOT the
    -- listing path's "no profile matching 'unset'".
    assert.is_falsy(unset.stderr:find("matching 'unset'", 1, true))
  end)
end)

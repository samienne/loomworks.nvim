-- `lw export` / `lw import` (spec §16.39): export prints the configuration in
-- the published-snapshot format without writing anything — the whole
-- workspace by default, exactly what a publish writes with --published —
-- and import replaces the working copy from such a file, keeping the
-- machine-local state an export cannot carry, assigning intent by presence in
-- loomworks.json, behind a review + confirmation, with a backup.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local user = require("loomworks.user")
local io_mod = require("loomworks.io")
local trust = require("loomworks.trust")
local uv = vim.uv or vim.loop

local raw_out -- captures M._raw_stdout (the export's JSON)

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex, rraw = io.write, io.stderr, os.exit, cli._raw_stdout
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  cli._raw_stdout = function(s) raw_out[#raw_out + 1] = s end
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, ret = pcall(fn)
  io.write, io.stderr, os.exit, cli._raw_stdout = rw, rs, rex, rraw
  if not ok and not (type(ret) == "table" and ret.__exit) then error(ret, 0) end
  return { exit_code = exit_code or 0, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function run(root, ...)
  local saved_arg, saved_root = _G.arg, vim.env.LW_ROOT
  _G.arg = { ... }
  vim.env.LW_ROOT = root
  raw_out = {}
  local r = capture(function() cli.main() end)
  r.json = table.concat(raw_out)
  _G.arg, vim.env.LW_ROOT = saved_arg, saved_root
  cli._set_create_intent(nil)
  return r
end

local function ok_run(root, ...)
  local r = run(root, ...)
  assert(r.exit_code == 0, table.concat({ ... }, " ") .. " -> " .. r.exit_code .. "\n" .. r.stdout .. r.stderr)
  return r
end

local function read(path) return io_mod.read_file(path) end
local function write(path, text)
  local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

local function tmp_root()
  local root = vim.fn.tempname():gsub("\\", "/")
  for _, d in ipairs({ "app", "web", "old" }) do
    vim.fn.mkdir(root .. "/" .. d, "p")
    write(root .. "/" .. d .. "/tsconfig.json", "{}")
  end
  return root
end

--- Source workspace: app (+ Debug config, launch) and dev set published;
--- web, its webdev set and the dev profile local.
local function make_source()
  local root = tmp_root()
  for _, argv in ipairs({
    { "init" },
    { "project", "add", "app" },
    { "project", "add", "web", "--local" },
    { "config", "add", "app", "Debug", "variant:default" },
    { "configset", "create", "dev", "app=Debug" },
    { "configset", "create", "webdev", "web=variant:default", "--local" },
    { "profile", "create", "dev" },
    { "launch", "add", "app", "serve", "node", "server.js" },
    { "publish" },
  }) do
    ok_run(root, unpack(argv))
  end
  return root
end

local function user_data(root)
  local status, body = trust.verify("user", read(user.filepath(root)))
  assert.equals("valid", status)
  return vim.json.decode(body)
end

describe("lw export", function()
  it("prints the whole configuration as a loomworks.json on stdout only", function()
    local root = make_source()
    local before_cfg, before_user = read(root .. "/loomworks.json"), read(user.filepath(root))
    local r = ok_run(root, "export")
    local data = vim.json.decode(r.json)
    assert.is_not_nil(data.projects.app)
    assert.is_not_nil(data.projects.web) -- local items too
    assert.is_not_nil(data.configuration_sets.webdev)
    assert.is_not_nil(data.profiles.dev) -- the local profile
    assert.is_not_nil(data.projects.app.launch.serve)
    assert.equals("", r.stdout) -- the summary goes to stderr
    assert.truthy(r.stderr:find("exported 2 projects", 1, true))
    assert.truthy(r.stderr:find("1 program setting", 1, true))
    -- Read-only.
    assert.equals(before_cfg, read(root .. "/loomworks.json"))
    assert.equals(before_user, read(user.filepath(root)))
  end)

  it("--published is byte-identical to what lw publish writes", function()
    local root = make_source()
    local r = ok_run(root, "export", "--published")
    assert.equals(read(root .. "/loomworks.json"), r.json)
    assert.truthy(r.stderr:find("nothing was written", 1, true))
    local data = vim.json.decode(r.json)
    assert.is_nil(data.projects.web)
    assert.is_nil(data.profiles)
  end)

  it("the full export equals a publish once every item is shared", function()
    local root = make_source()
    ok_run(root, "project", "publish", "web")
    ok_run(root, "configset", "publish", "webdev")
    ok_run(root, "profile", "publish", "dev")
    local r = ok_run(root, "export")
    assert.equals(read(root .. "/loomworks.json"), r.json)
  end)

  it("--no-profiles leaves profiles out", function()
    local root = make_source()
    local data = vim.json.decode(ok_run(root, "export", "--no-profiles").json)
    assert.is_nil(data.profiles)
    assert.is_not_nil(data.configuration_sets.dev)
  end)

  it("includes shared-only items with their ignored program settings, and unknown-type projects verbatim", function()
    local root = tmp_root()
    write(root .. "/loomworks.json", vim.json.encode({
      projects = {
        app = { typescript = {}, launch = { serve = { command = "node", args = { "x.js" } } } },
        odd = { path = "old", frobnicate = { knob = 7, configurations = { Fast = { level = 3 } } } },
      },
    }))
    local data = vim.json.decode(ok_run(root, "export").json)
    -- The launch is ignored from loomworks.json (§17.6) but written back.
    assert.same({ command = "node", args = { "x.js" } }, data.projects.app.launch.serve)
    -- (Its own `configurations` are not kept by the shared serializer today:
    -- a publish drops them too — BACKLOG "Unknown-type configurations".)
    assert.equals(7, data.projects.odd.frobnicate.knob)
    assert.equals("old", data.projects.odd.path)
  end)

  it("writes DEL and C1 characters as \\u escapes (same decoded value)", function()
    local transfer = require("loomworks.config_transfer")
    local raw = { projects = { app = { typescript = { note = "a\194\133b\127c" } } } }
    local text = transfer.export_text(raw)
    assert.is_nil(text:find("\194\133", 1, true))
    assert.is_nil(text:find("\127", 1, true))
    assert.truthy(text:find("\\u0085", 1, true))
    assert.truthy(text:find("\\u007f", 1, true))
    assert.same(raw, vim.json.decode(text))
    -- Everything else is exactly the publish encoding.
    local plain = { projects = { app = { typescript = { note = "plain — ü" } } } }
    assert.equals(io_mod.encode_json(plain), transfer.export_text(plain))
  end)

  it("-o writes a file; refuses loomworks.json and .nvim/", function()
    local root = make_source()
    local dest = vim.fn.tempname():gsub("\\", "/") .. ".json"
    local r = ok_run(root, "export", "-o", dest)
    assert.truthy(r.stdout:find(dest, 1, true))
    local text = read(dest)
    assert.equals(text, ok_run(root, "export").json)
    assert.is_nil(uv.fs_stat(dest .. ".bak"))
    ok_run(root, "export", "-o", dest) -- overwrites, still no .bak
    assert.is_nil(uv.fs_stat(dest .. ".bak"))

    local before = read(root .. "/loomworks.json")
    r = run(root, "export", "-o", root .. "/loomworks.json")
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("lw publish", 1, true))
    assert.equals(before, read(root .. "/loomworks.json"))
    r = run(root, "export", "--output", root .. "/.nvim/x.json")
    assert.equals(1, r.exit_code)
    assert.is_nil(uv.fs_stat(root .. "/.nvim/x.json"))
    r = run(root, "export", "-o", root .. "/missing/x.json")
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("does not exist", 1, true))
  end)
end)

describe("lw import", function()
  --- Target checkout: the source's committed loomworks.json, plus its own
  --- working copy with a local `old` project, an active profile on it, and
  --- machine-local settings an export cannot carry.
  local function make_target(src)
    local root = tmp_root()
    write(root .. "/loomworks.json", read(src .. "/loomworks.json"))
    assert(user.save(root, {
      _meta = { version = 2 },
      active_profile = "olddev",
      projects = { old = { typescript = {} } },
      configuration_sets = { olddev = { old = "variant:default" } },
      profiles = { olddev = { configuration_set = "olddev" } },
      lsp = { clangd = { clang_tidy = false } },
      debug = { adapters = { ["c++"] = "cppdbg" } },
      intent = { projects = { old = "local" }, configuration_sets = { olddev = "local" } },
    }))
    return root
  end

  local function export_of(src, ...)
    local path = vim.fn.tempname():gsub("\\", "/") .. ".json"
    write(path, ok_run(src, "export", ...).json)
    return path
  end

  it("replaces the working configuration, keeps machine-local state, backs up", function()
    local src = make_source()
    local file = export_of(src)
    local root = make_target(src)
    local previous = read(user.filepath(root))
    local r = ok_run(root, "import", file, "--yes")
    assert.truthy(r.stdout:find("Program settings", 1, true))
    assert.truthy(r.stdout:find("(new)", 1, true))
    assert.truthy(r.stdout:find("Active profile olddev is not in the import", 1, true))

    local data = user_data(root)
    assert.is_nil(data.projects.old)
    assert.is_not_nil(data.projects.app)
    assert.is_not_nil(data.projects.web)
    assert.is_nil(data.configuration_sets.olddev)
    assert.is_not_nil(data.profiles.dev)
    assert.is_nil(data.active_profile)
    assert.same({ clangd = { clang_tidy = false } }, data.lsp)
    assert.same({ adapters = { ["c++"] = "cppdbg" } }, data.debug)

    -- The backup is the previous working copy, byte for byte.
    local backup = r.stdout:match("previous working copy: (%S+%.bak)")
    assert.is_not_nil(backup)
    assert.equals(previous, read(root .. "/" .. backup))

    -- Nothing published changes: the published export equals loomworks.json.
    assert.equals(read(root .. "/loomworks.json"), ok_run(root, "export", "--published").json)
    -- And the round trip reproduces the source's full export.
    assert.equals(read(file), ok_run(root, "export").json)
  end)

  it("keeps the active profile when the import still has it", function()
    local src = make_source()
    ok_run(src, "profile", "select", "dev")
    local root = make_target(src)
    ok_run(root, "import", export_of(src), "-y")
    ok_run(root, "profile", "select", "dev")
    ok_run(root, "import", export_of(src), "-y")
    assert.equals("dev", user_data(root).active_profile)
  end)

  it("--shared makes imported items (not profiles) published; --local unpublishes", function()
    local src = make_source()
    local file = export_of(src)
    local root = make_target(src)
    ok_run(root, "--shared", "import", file, "-y")
    local pub = vim.json.decode(ok_run(root, "export", "--published").json)
    assert.is_not_nil(pub.projects.web)
    assert.is_not_nil(pub.configuration_sets.webdev)
    assert.is_nil(pub.profiles)

    local r = ok_run(root, "--local", "import", file, "-y", "--dry-run")
    assert.truthy(r.stdout:find("would remove", 1, true))
    ok_run(root, "--local", "import", file, "-y")
    pub = vim.json.decode(ok_run(root, "export", "--published").json)
    assert.same({}, pub.projects)
  end)

  it("published items the import leaves out stay as shared, still published", function()
    local src = make_source()
    local file = vim.fn.tempname():gsub("\\", "/") .. ".json"
    write(file, vim.json.encode({ projects = { web = { typescript = {} } } }))
    local root = make_target(src)
    local r = ok_run(root, "import", file, "-y")
    assert.truthy(r.stdout:find("project app", 1, true))
    local data = user_data(root)
    assert.is_nil(data.projects.app)
    assert.equals(read(root .. "/loomworks.json"), ok_run(root, "export", "--published").json)
  end)

  it("--dry-run and a refused confirmation write nothing", function()
    local src = make_source()
    local file = export_of(src)
    local root = make_target(src)
    local before = read(user.filepath(root))
    local r = ok_run(root, "import", file, "--dry-run")
    assert.truthy(r.stdout:find("dry run", 1, true))
    r = run(root, "--no-input", "import", file)
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("--yes", 1, true))
    cli._test_interactive = true
    local rs = io.stdin
    local text = read(file)
    io.stdin = { read = function() return text end }
    r = run(root, "import", "-")
    io.stdin = rs
    cli._test_interactive = nil
    assert.equals(1, r.exit_code) -- stdin input needs --yes
    assert.equals(before, read(user.filepath(root)))
    for name in vim.fs.dir(root .. "/.nvim") do
      assert.is_nil(name:match("%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%.bak$"), "backup written: " .. name)
    end
  end)

  it("rejects invalid input, a working copy, and an untrusted working copy — changing nothing", function()
    local src = make_source()
    local root = make_target(src)
    local before = read(user.filepath(root))
    local bad = vim.fn.tempname():gsub("\\", "/") .. ".json"

    write(bad, "{ not json")
    local r = run(root, "import", bad, "-y")
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("not valid JSON", 1, true))

    write(bad, vim.json.encode({ projects = { x = { a = {}, b = {} } } }))
    r = run(root, "import", bad, "-y")
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("nothing was changed", 1, true))

    r = run(root, "import", user.filepath(src), "-y")
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("is a working copy", 1, true))
    assert.equals(before, read(user.filepath(root)))

    -- An untrusted working copy is never read, so it cannot be replaced.
    write(user.filepath(root), '{ "_meta": { "version": 2 } }')
    r = run(root, "import", export_of(src), "-y")
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("lw trust", 1, true))
    assert.equals('{ "_meta": { "version": 2 } }', read(user.filepath(root)))
  end)

  it("creates the working copy when there is none", function()
    local src = make_source()
    local root = tmp_root()
    write(root .. "/loomworks.json", read(src .. "/loomworks.json"))
    local r = ok_run(root, "import", export_of(src), "-y")
    assert.truthy(r.stdout:find("there was no working copy", 1, true))
    assert.is_not_nil(user_data(root).projects.web)
  end)
end)

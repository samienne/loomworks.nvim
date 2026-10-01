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
    assert.same({ knob = 7, configurations = { Fast = { level = 3 } } }, data.projects.odd.frobnicate)
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
    -- The report names the resolved path (long form on Windows, where the
    -- temp dir may be an 8.3 short path), so match the file name.
    assert.truthy(r.stdout:find(dest:match("[^/]+$"), 1, true))
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

  it("says there was no active profile before, and does not imply the import lost one", function()
    local src = make_source()
    local file = export_of(src)
    local root = make_target(src)
    ok_run(root, "profile", "select", "--none")
    local dry = ok_run(root, "import", file, "--dry-run")
    assert.truthy(dry.stdout:find("active profile: none (unchanged)", 1, true), dry.stdout)
    local r = ok_run(root, "import", file, "-y")
    assert.truthy(r.stdout:find("active profile: none (unchanged)", 1, true), r.stdout)
    assert.truthy(r.stdout:find("no profile is active (none was before) — "
      .. "`lw profile select <profile>` to choose one (`lw profile list`)", 1, true), r.stdout)
    assert.falsy(r.stdout:find("no active profile —", 1, true), r.stdout)
    assert.is_nil(user_data(root).active_profile)
  end)

  it("keeps the plain select hint when the import cleared the active profile", function()
    local src = make_source()
    local root = make_target(src)
    local r = ok_run(root, "import", export_of(src), "-y")
    assert.truthy(r.stdout:find("no active profile — `lw profile select <profile>`", 1, true), r.stdout)
    assert.falsy(r.stdout:find("none (unchanged)", 1, true), r.stdout)
    assert.falsy(r.stdout:find("none was before", 1, true), r.stdout)
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

  it("rejects invalid input and a working copy — changing nothing", function()
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
  end)

  it("is refused when the working copy changed on disk after it was read (§2.7)", function()
    local src = make_source()
    local file = export_of(src)
    local root = make_target(src)
    local ws = cli._load_workspace(root, false)
    local deps = ws._core._deps
    local saved_hook, refused = deps.on_save_refused, nil
    deps.on_save_refused = function(msg) refused = msg end -- the CLI would die here
    local plan = assert(ws:prepare_import(read(file)))
    -- Another lw / the editor saves while the review is on screen.
    assert(user.save(root, { _meta = { version = 2 }, projects = { old = { typescript = {} } },
      configuration_sets = { mine = { old = "variant:default" } } }))
    local theirs = read(user.filepath(root))
    local ok, err, backup = ws:commit_import(plan)
    deps.on_save_refused = saved_hook
    ws:_stop_tracking()
    assert.is_nil(ok)
    assert.truthy(tostring(err):find("changed on disk", 1, true))
    assert.truthy(refused and refused:find("changed on disk", 1, true))
    assert.is_nil(backup)
    -- Nothing written: the other writer's file stands, no backup was taken.
    assert.equals(theirs, read(user.filepath(root)))
    for name in vim.fs.dir(root .. "/.nvim") do
      assert.is_nil(name:match("%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%.bak$"), "backup written: " .. name)
    end
    -- Reloaded: the model holds the other writer's working copy, not the import.
    local sets = {}
    for _, cs in pairs(ws._config_sets) do sets[cs.name] = true end
    assert.is_true(sets.mine == true)
    assert.is_nil(sets.webdev)
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

describe("lw import round trip on one workspace", function()
  --- A workspace with NO loomworks.json (never published): the project and
  --- the set carry intent local+shared, `dev` is active, and both profiles
  --- hold a device selection and a fill value.
  local function make_local(with_shared)
    local root = tmp_root()
    if with_shared then
      write(root .. "/loomworks.json", vim.json.encode({
        projects = { app = { typescript = {} } },
        configuration_sets = { dev = { app = "variant:default" } },
      }))
    end
    assert(user.save(root, {
      _meta = { version = 2 },
      active_profile = "dev",
      projects = { app = { typescript = {} }, web = { typescript = {} } },
      configuration_sets = { dev = { app = "variant:default" }, webdev = { web = "variant:default" } },
      profiles = { dev = { configuration_set = "dev" }, webdev = { configuration_set = "webdev" } },
      device = { dev = "SERIAL-DEV", webdev = "SERIAL-WEB" },
      profile_variables = { dev = { app = { v = "x" } }, webdev = { web = { v = "y" } } },
      lsp = { clangd = { clang_tidy = false } },
      intent = not with_shared
        and { projects = { app = "local+shared" }, configuration_sets = { dev = "local+shared" } } or nil,
    }))
    if with_shared then -- web is local, its set too: same intents, by presence
      assert.is_nil(user_data(root).intent)
    end
    return root
  end

  local function export_to_file(root, ...)
    local path = vim.fn.tempname():gsub("\\", "/") .. ".json"
    write(path, ok_run(root, "export", ...).json)
    return path
  end

  for _, with_shared in ipairs({ false, true }) do
    local label = with_shared and "with a loomworks.json" or "without a loomworks.json"
    it("keeps intent, the active profile, devices and fills (" .. label .. ")", function()
      local root = make_local(with_shared)
      local before = user_data(root)
      local published = ok_run(root, "export", "--published").json
      local file = export_to_file(root)
      local dry = ok_run(root, "import", file, "--dry-run")
      assert.is_nil(dry.stdout:find("would remove", 1, true), dry.stdout)
      assert.is_nil(dry.stdout:find("intent:", 1, true), dry.stdout)
      assert.truthy(dry.stdout:find("active profile: dev (kept)", 1, true), dry.stdout)
      ok_run(root, "import", file, "--yes")
      local after = user_data(root)
      assert.equals("dev", after.active_profile)
      assert.same(before.intent, after.intent)
      -- What a publish would write is unchanged too (with a loomworks.json the
      -- intents equal the presence defaults, so the map is empty both times).
      assert.equals(published, ok_run(root, "export", "--published").json)
      assert.same(before.device, after.device)
      assert.same(before.profile_variables, after.profile_variables)
      assert.same(before.lsp, after.lsp)
      -- Lossless: a second export is the same file.
      assert.equals(read(file), ok_run(root, "export").json)
    end)
  end

  it("--local lists each intent change; no publish warning without loomworks.json", function()
    local root = make_local(false)
    local file = export_to_file(root)
    local r = ok_run(root, "--local", "import", file, "--dry-run")
    assert.truthy(r.stdout:find("intent: project app local+shared -> local", 1, true), r.stdout)
    assert.truthy(r.stdout:find("intent: configuration set dev local+shared -> local", 1, true), r.stdout)
    assert.is_nil(r.stdout:find("would remove", 1, true), r.stdout)
  end)

  it("--local warns, naming them, when loomworks.json items would be removed", function()
    local root = make_local(true)
    local file = export_to_file(root)
    local r = ok_run(root, "--local", "import", file, "--dry-run")
    assert.truthy(r.stdout:find("the next `lw publish` would remove 2 items from loomworks.json", 1, true), r.stdout)
    assert.truthy(r.stdout:find("configuration set dev", 1, true), r.stdout)
  end)

  it("names the device selections and fills dropped with a removed profile", function()
    local root = make_local(false)
    local file = vim.fn.tempname():gsub("\\", "/") .. ".json"
    local data = vim.json.decode(ok_run(root, "export").json)
    data.profiles.webdev = nil
    write(file, vim.json.encode(data))
    local r = ok_run(root, "import", file, "--dry-run")
    assert.truthy(r.stdout:find("active profile: dev (kept)", 1, true), r.stdout)
    assert.truthy(r.stdout:find("device selection of webdev (SERIAL-WEB)", 1, true), r.stdout)
    assert.truthy(r.stdout:find("fill values of webdev", 1, true), r.stdout)
  end)
end)

describe("lw import over a working copy not signed by this machine", function()
  local UNSIGNED = '{ "_meta": { "version": 2 }, "active_profile": "dev",'
    .. ' "lsp": { "clangd": { "clang_tidy": false } } }'

  it("--dry-run works and says the file is replaced unread", function()
    local src = make_source()
    local file = vim.fn.tempname():gsub("\\", "/") .. ".json"
    write(file, ok_run(src, "export").json)
    local root = tmp_root()
    write(root .. "/loomworks.json", read(src .. "/loomworks.json"))
    vim.fn.mkdir(root .. "/.nvim", "p")
    write(user.filepath(root), UNSIGNED)
    local r = ok_run(root, "import", file, "--dry-run")
    assert.truthy(r.stdout:find("not signed by this machine", 1, true), r.stdout)
    assert.truthy(r.stdout:find("replaced unread", 1, true), r.stdout)
    assert.truthy(r.stdout:find("dry run", 1, true))
    assert.equals(UNSIGNED, read(user.filepath(root)))
  end)

  it("a confirmed import replaces it unread, keeps a backup, carries nothing over", function()
    local src = make_source()
    ok_run(src, "profile", "select", "dev")
    local file = vim.fn.tempname():gsub("\\", "/") .. ".json"
    write(file, ok_run(src, "export").json)
    local root = tmp_root()
    write(root .. "/loomworks.json", read(src .. "/loomworks.json"))
    vim.fn.mkdir(root .. "/.nvim", "p")
    write(user.filepath(root), UNSIGNED)
    local r = run(root, "--no-input", "import", file)
    assert.equals(1, r.exit_code) -- still needs --yes
    assert.equals(UNSIGNED, read(user.filepath(root)))
    r = ok_run(root, "import", file, "--yes")
    local backup = r.stdout:match("previous working copy: (%S+%.bak)")
    assert.is_not_nil(backup, r.stdout)
    assert.equals(UNSIGNED, read(root .. "/" .. backup))
    local data = user_data(root) -- signed by this machine now
    assert.is_not_nil(data.projects.web)
    assert.is_nil(data.lsp)
    assert.is_nil(data.active_profile)
    -- Unread: nothing is known about its active profile, so no "none (unchanged)".
    assert.falsy(r.stdout:find("none (unchanged)", 1, true), r.stdout)
    assert.falsy(r.stdout:find("none was before", 1, true), r.stdout)
    assert.truthy(r.stdout:find("no active profile — `lw profile select <profile>`", 1, true), r.stdout)
    ok_run(root, "status")
  end)

  it("is refused when the unread file changed on disk before the write (§2.7)", function()
    local src = make_source()
    local file = vim.fn.tempname():gsub("\\", "/") .. ".json"
    write(file, ok_run(src, "export").json)
    local root = tmp_root()
    write(root .. "/loomworks.json", read(src .. "/loomworks.json"))
    vim.fn.mkdir(root .. "/.nvim", "p")
    write(user.filepath(root), UNSIGNED)
    local ws = cli._load_workspace(root, false, { replace_untrusted_user = true })
    assert.equals("unsigned", ws._user_unread)
    -- Nothing but the import may overwrite the unread file.
    assert.is_false((ws:_save_user()))
    assert.equals(UNSIGNED, read(user.filepath(root)))
    local deps = ws._core._deps
    local saved_hook, refused = deps.on_save_refused, nil
    deps.on_save_refused = function(msg) refused = msg end
    local plan = assert(ws:prepare_import(read(file)))
    -- Another lw writes (and signs) the working copy meanwhile.
    assert(user.save(root, { _meta = { version = 2 }, projects = { old = { typescript = {} } } }))
    local theirs = read(user.filepath(root))
    local ok, err, backup = ws:commit_import(plan)
    deps.on_save_refused = saved_hook
    deps.replace_untrusted_user = nil
    if ws._stop_tracking then ws:_stop_tracking() end
    assert.is_nil(ok)
    assert.truthy(tostring(err):find("changed on disk", 1, true))
    assert.truthy(refused and refused:find("changed on disk", 1, true))
    assert.is_nil(backup)
    assert.equals(theirs, read(user.filepath(root)))
  end)

  it("an invalid cache still refuses", function()
    local src = make_source()
    local file = vim.fn.tempname():gsub("\\", "/") .. ".json"
    write(file, ok_run(src, "export").json)
    local root = tmp_root()
    write(root .. "/loomworks.json", read(src .. "/loomworks.json"))
    vim.fn.mkdir(root .. "/.nvim", "p")
    write(user.filepath(root), UNSIGNED)
    -- Signed with another machine's key: invalid here.
    local key = trust.key_path()
    trust._set_key_path(vim.fn.tempname() .. "/other/trust.key")
    local foreign = assert(trust.sign("cache", trust.encode({ _meta = { version = 8 }, build_dirs = vim.empty_dict() })))
    trust._set_key_path(key)
    write(root .. "/.nvim/loomworks.cache.json", foreign)
    local r = run(root, "import", file, "--dry-run")
    assert.equals(1, r.exit_code)
    assert.truthy(r.stderr:find("loomworks.cache.json", 1, true), r.stderr)
    assert.equals(UNSIGNED, read(user.filepath(root)))
  end)
end)

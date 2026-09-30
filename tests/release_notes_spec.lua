-- Release notes (spec §16.37): the CHANGELOG.md grammar and the real file,
-- selection and rendering, the self-update "what's new" block, the sandboxed
-- (host) load, the last-seen record and the upgrade notice, and the
-- `lw release-notes` command.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local rn = require("loomworks.release_notes")
local notice = require("loomworks.release_notice")

local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"):gsub("\\", "/")

local function read(p)
  local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s
end

local function temp_dir()
  local d = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(d, "p")
  return d
end

local SAMPLE = table.concat({
  "# Changelog",
  "",
  "Intro text that is not an entry.",
  "<!--",
  "## 9.9.9 - 2000-01-01",
  "-->",
  "",
  "## Unreleased",
  "",
  "### Added",
  "- A new thing",
  "  that wraps. (#9)",
  "",
  "## 1.2.0 - 2026-02-01",
  "",
  "Second release summary",
  "on two lines.",
  "",
  "### Breaking",
  "- Removed the old flag. (#8)",
  "",
  "### Upgrade notes",
  "- Re-run setup. (#8)",
  "",
  "### Fixed",
  "- A bug. (#7)",
  "",
  "## 1.1.0 - 2026-01-15",
  "",
  "First minor.",
  "",
  "### Added",
  "- Feature A. (#5)",
  "",
  "## 1.0.0 - 2026-01-01",
  "",
  "The first release.",
  "",
  "### Added",
  "- Everything. (#1)",
  "",
}, "\n")

describe("release notes: the real CHANGELOG.md", function()
  local text = read(ROOT .. "/CHANGELOG.md")

  it("is valid under the §16.37 grammar", function()
    assert.same({}, rn.validate(text))
  end)

  it("has a 0.1.40 entry with a summary and upgrade notes", function()
    local e = rn.find(rn.parse(text), "0.1.40")
    assert.is_table(e)
    assert.equals("2026-09-30", e.date)
    assert.is_string(e.summary)
    local names = {}
    for _, s in ipairs(e.sections) do names[#names + 1] = s.name end
    assert.same({ "Upgrade notes", "Added", "Fixed" }, names)
  end)

  it("starts with an Unreleased entry", function()
    assert.is_true(rn.parse(text).entries[1].unreleased)
  end)
end)

describe("release notes: parse and validate", function()
  it("skips the preamble and comments, joins continuation lines", function()
    local doc = rn.parse(SAMPLE)
    assert.same({}, doc.errors)
    assert.equals(4, #doc.entries)
    assert.is_true(doc.entries[1].unreleased)
    assert.equals("A new thing that wraps. (#9)", doc.entries[1].sections[1].items[1])
    assert.equals("Second release summary on two lines.", doc.entries[2].summary)
    assert.equals("1.2.0", doc.entries[2].version)
    assert.same({}, rn.validate(SAMPLE))
  end)

  local function errs_of(t) return table.concat(rn.validate(t), "\n") end

  it("reports malformed headings, unknown sections and stray items", function()
    local e = errs_of("## 1.0 - 2026-01-01\n## 1.0.0 - 2026-01-01\n\nS.\n\n### Misc\n- x\n")
    assert.matches("malformed entry heading", e)
    assert.matches("unknown section 'Misc'", e)
    assert.matches("item outside a section", errs_of("## 1.0.0 - 2026-01-01\n\nS.\n\n- x\n"))
  end)

  it("enforces order, uniqueness, summaries, items and full-release versions", function()
    assert.matches("out of order",
      errs_of("## 1.0.0 - 2026-01-01\n\nS.\n\n### Fixed\n- a\n\n### Added\n- b\n"))
    assert.matches("appears twice",
      errs_of("## 1.0.0 - 2026-01-01\n\nS.\n\n### Fixed\n- a\n\n### Fixed\n- b\n"))
    assert.matches("no summary", errs_of("## 1.0.0 - 2026-01-01\n\n### Fixed\n- a\n"))
    assert.matches("no items", errs_of("## 1.0.0 - 2026-01-01\n\nS.\n"))
    assert.matches("pre%-releases have no entry",
      errs_of("## 1.0.0-beta.1 - 2026-01-01\n\nS.\n\n### Fixed\n- a\n"))
    assert.matches("not older than",
      errs_of("## 1.0.0 - 2026-01-01\n\nS.\n\n### Fixed\n- a\n\n## 1.1.0 - 2026-01-02\n\nS.\n\n### Fixed\n- b\n"))
    assert.matches("must be the first entry",
      errs_of("## 1.0.0 - 2026-01-01\n\nS.\n\n### Fixed\n- a\n\n## Unreleased\n"))
  end)

  it("rejects non-ASCII and control characters", function()
    assert.matches("non%-ASCII", errs_of("## 1.0.0 - 2026-01-01\n\nS \226\128\148 dash.\n\n### Fixed\n- a\n"))
    assert.matches("non%-ASCII", errs_of("## 1.0.0 - 2026-01-01\n\nS.\n\n### Fixed\n- a \27[31m\n"))
  end)

  it("orders versions like the host (a prerelease below its release)", function()
    assert.equals(-1, rn.compare("0.1.41-beta.1", "0.1.41"))
    assert.equals(1, rn.compare("0.1.10", "0.1.9"))
    assert.equals(-1, rn.compare("0.1.41-beta.2", "0.1.41-beta.10"))
    assert.equals(0, rn.compare("1.0.0", "1.0.0"))
    assert.equals("0.1.40", rn.normalize("v0.1.40"))
    assert.is_nil(rn.normalize("0.1"))
    assert.is_nil(rn.normalize("../x"))
  end)
end)

describe("release notes: selection", function()
  local doc = rn.parse(SAMPLE)
  local function versions(res)
    local v = {}
    for _, e in ipairs(res.entries) do v[#v + 1] = e.version or "unreleased" end
    return v
  end

  it("default: the three newest visible entries, counting the rest", function()
    local res = rn.select(doc, "1.2.0", { kind = "default" })
    assert.same({ "1.2.0", "1.1.0", "1.0.0" }, versions(res))
    assert.equals(0, res.more)
    res = rn.select(doc, "1.2.0", { kind = "count", n = 1 })
    assert.same({ "1.2.0" }, versions(res))
    assert.equals(2, res.more)
  end)

  it("a release never sees newer entries or the Unreleased one", function()
    assert.same({ "1.1.0", "1.0.0" }, versions(rn.select(doc, "1.1.0", { kind = "all" })))
  end)

  it("a prerelease sees Unreleased under its own version", function()
    local res = rn.select(doc, "1.3.0-beta.1", { kind = "count", n = 2 })
    assert.same({ "1.3.0-beta.1", "1.2.0" }, versions(res))
    assert.is_true(res.entries[1].unreleased)
  end)

  it("a development source sees everything, Unreleased first", function()
    assert.same({ "unreleased", "1.2.0", "1.1.0", "1.0.0" }, versions(rn.select(doc, nil, { kind = "all" })))
  end)

  it("--since and <version>", function()
    assert.same({ "1.2.0", "1.1.0" }, versions(rn.select(doc, "1.2.0", { kind = "since", version = "1.0.0" })))
    assert.same({}, versions(rn.select(doc, "1.2.0", { kind = "since", version = "1.2.0" })))
    assert.same({ "1.1.0" }, versions(rn.select(doc, "1.2.0", { kind = "version", version = "1.1.0" })))
    local res, err = rn.select(doc, "1.2.0", { kind = "version", version = "7.0.0" })
    assert.is_nil(res)
    assert.matches("no release notes for 7.0.0", err)
  end)
end)

describe("release notes: rendering", function()
  local doc = rn.parse(SAMPLE)

  it("without a width every item is one full line", function()
    local lines = rn.render(rn.select(doc, "1.2.0", { kind = "count", n = 1 }))
    assert.equals("loomworks 1.2.0 - 2026-02-01  (running)", lines[1])
    assert.equals("  Second release summary on two lines.", lines[2])
    assert.is_true(vim.tbl_contains(lines, "  - Removed the old flag. (#8)"))
    assert.equals("2 older releases: lw release-notes --all", lines[#lines])
  end)

  it("wraps to the width with a hanging indent", function()
    local res = { running = "1.0.0", more = 0, entries = { {
      version = "1.0.0", date = "2026-01-01", summary = string.rep("word ", 30),
      sections = { { name = "Added", items = { string.rep("item ", 30) } } } } } }
    for _, l in ipairs(rn.render(res, { width = 40 })) do
      assert.is_true(#l <= 40, l)
    end
    local lines = rn.render(res, { width = 40 })
    assert.is_true(vim.tbl_contains(lines, "    item item item item item item item"))
  end)

  it("says when nothing is newer", function()
    local lines = rn.render(rn.select(doc, "1.2.0", { kind = "since", version = "1.2.0" }))
    assert.same({ "Nothing newer than 1.2.0 (running 1.2.0)." }, lines)
  end)

  it("--json document", function()
    local j = rn.to_json(rn.select(doc, "1.3.0-beta.1", { kind = "count", n = 2 }), vim.NIL)
    assert.equals(1, j.schema)
    assert.equals("1.3.0-beta.1", j.running)
    assert.equals(2, j.more)
    assert.is_true(j.entries[1].unreleased)
    assert.equals(vim.NIL, j.entries[1].date)
    assert.equals("Breaking", j.entries[2].sections[1].name)
    local decoded = vim.json.decode(vim.json.encode(j))
    assert.equals("1.2.0", decoded.entries[2].version)
  end)
end)

describe("release notes: what's new (self-update)", function()
  it("lists each newer release's summary and its action items", function()
    local lines = rn.whats_new(SAMPLE, "1.0.0", "1.2.0", {})
    assert.equals("What's new since 1.0.0:", lines[1])
    assert.equals("  1.2.0  Second release summary on two lines.", lines[2])
    assert.equals("         ! Breaking: Removed the old flag. (#8)", lines[3])
    assert.equals("         ! Re-run setup. (#8)", lines[4])
    assert.equals("  1.1.0  First minor.", lines[5])
    assert.equals(5, #lines)
  end)

  it("is empty when nothing is newer, and caps the releases listed", function()
    assert.same({}, rn.whats_new(SAMPLE, "1.2.0", "1.2.0", {}))
    local lines = rn.whats_new(SAMPLE, "0.9.0", "1.2.0", { max = 1 })
    assert.equals("  ... and 2 earlier releases", lines[#lines])
  end)

  it("runs in the host's sandbox: no require, io, os or vim", function()
    local src = read(ROOT .. "/lua/loomworks/release_notes.lua")
    local chunk = assert(loadstring(src, "=release_notes"))
    setfenv(chunk, {
      string = string, table = table, math = math, ipairs = ipairs, pairs = pairs, next = next,
      type = type, select = select, tostring = tostring, tonumber = tonumber, error = error,
      pcall = pcall, setmetatable = setmetatable, getmetatable = getmetatable, rawget = rawget,
    })
    local mod = chunk()
    local lines = mod.whats_new(read(ROOT .. "/CHANGELOG.md"), "0.1.39", "0.1.40", { width = 79 })
    assert.equals("What's new since 0.1.39:", lines[1])
    for _, l in ipairs(lines) do
      assert.is_true(#l <= 79, l)
      assert.is_nil(l:find("[\128-\255]"), "ASCII: " .. l)
    end
  end)
end)

describe("release notice (last-seen and the one-line notice)", function()
  local data
  before_each(function() data = temp_dir() end)
  after_each(function() vim.fn.delete(data, "rf") end)

  local function install(v) vim.fn.mkdir(data .. "/lua-" .. v, "p"); return data .. "/lua-" .. v end
  local function none() return nil end

  it("derives the running version and data dir from the bundle's location", function()
    assert.equals("0.1.40", notice.running_version("/d/loomworks/lua-0.1.40"))
    assert.is_nil(notice.running_version("/src/loomworks.nvim/lua"))
    assert.equals("/d/loomworks", notice.release_data_dir("/d/loomworks/lua-0.1.40", none))
    assert.is_nil(notice.release_data_dir("/d/loomworks/pinned/abc123/lua-0.1.40", none))
    assert.is_nil(notice.release_data_dir("/d/loomworks/lua-0.1.40",
      function(n) return n == "LOOMWORKS_PINNED" and "0.1.40" or nil end))
  end)

  it("only ever raises the last-seen version", function()
    assert.is_true(notice.write_seen(data, "0.1.40"))
    assert.equals("0.1.40", notice.read_seen(data))
    assert.is_false(notice.write_seen(data, "0.1.39"))
    assert.equals("0.1.40", notice.read_seen(data))
    assert.is_true(notice.write_seen(data, "0.1.41-beta.1"))
    assert.equals("0.1.41-beta.1", notice.read_seen(data))
  end)

  it("decides: notice when newer and interactive, record on a first install", function()
    assert.same({ action = "notice", from = "0.1.39", to = "0.1.40" },
      notice.decide({ running = "0.1.40", seen = "0.1.39", interactive = true }))
    assert.is_nil(notice.decide({ running = "0.1.40", seen = "0.1.39", interactive = false }))
    assert.is_nil(notice.decide({ running = "0.1.40", seen = "0.1.40", interactive = true }))
    assert.is_nil(notice.decide({ running = "0.1.39", seen = "0.1.40", interactive = true }))
    assert.same({ action = "notice", from = "0.1.38", to = "0.1.40" },
      notice.decide({ running = "0.1.40", previous = "0.1.38", interactive = true }))
    assert.same({ action = "record", to = "0.1.40" }, notice.decide({ running = "0.1.40", interactive = false }))
  end)

  it("maybe_notice: once, after an update, from the previous installed bundle", function()
    install("0.1.38")
    local root = install("0.1.40")
    local o = { interactive = true, luaroot = root, getenv = none }
    assert.equals("lw: updated 0.1.38 -> 0.1.40 - see what's new: lw release-notes --since 0.1.38",
      notice.maybe_notice(o))
    assert.equals("0.1.40", notice.read_seen(data))
    assert.is_nil(notice.maybe_notice(o))
  end)

  it("maybe_notice: a non-interactive run shows and records nothing", function()
    notice.write_seen(data, "0.1.39")
    local root = install("0.1.40")
    assert.is_nil(notice.maybe_notice({ interactive = false, luaroot = root, getenv = none }))
    assert.equals("0.1.39", notice.read_seen(data))
  end)

  it("maybe_notice: a first installation records silently", function()
    local root = install("0.1.40")
    assert.is_nil(notice.maybe_notice({ interactive = true, luaroot = root, getenv = none }))
    assert.equals("0.1.40", notice.read_seen(data))
  end)

  it("is silenced by the setting or the environment (which wins)", function()
    notice.write_seen(data, "0.1.39")
    local root = install("0.1.40")
    assert.is_nil(notice.maybe_notice({ interactive = true, luaroot = root, getenv = none,
      cfg = { ["release-notes"] = "off" } }))
    assert.is_nil(notice.maybe_notice({ interactive = true, luaroot = root,
      getenv = function(n) return n == "LOOMWORKS_RELEASE_NOTES" and "0" or nil end }))
    assert.equals("0.1.39", notice.read_seen(data))
    assert.is_false(notice.silenced(function() return "on" end, { ["release-notes"] = "off" }))
  end)

  it("finds CHANGELOG.md in a bundle layout and in the source tree", function()
    local text = notice.read_text(ROOT .. "/lua/loomworks")
    assert.is_string(text)
    assert.matches("## 0.1.40 %- 2026%-09%-30", text)
    local b = temp_dir()
    vim.fn.mkdir(b .. "/loomworks", "p")
    local f = assert(io.open(b .. "/loomworks/CHANGELOG.md", "wb")); f:write(SAMPLE); f:close()
    assert.equals(SAMPLE, (notice.read_text(b .. "/loomworks")))
    vim.fn.delete(b, "rf")
  end)
end)

describe("`lw release-notes`", function()
  local cli = require("loomworks.cli")

  local function capture(fn)
    local out_buf, err_buf = {}, {}
    local rw, rs, rex = io.write, io.stderr, os.exit
    io.write = function(...) for _, s in ipairs({ ... }) do out_buf[#out_buf + 1] = s end end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
    local exit_code
    os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
    local ok, e = pcall(fn)
    io.write, io.stderr, os.exit = rw, rs, rex
    if not ok and not (type(e) == "table" and e.__exit) then error(e, 0) end
    return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
  end

  local saved_root
  before_each(function()
    cli._test_release_notes_text = SAMPLE
    cli._test_stdout_tty = false
    saved_root = _G.__loomworks_luaroot
    _G.__loomworks_luaroot = "/nowhere/lua-1.2.0"
  end)
  after_each(function()
    cli._test_release_notes_text = nil
    cli._test_stdout_tty = nil
    _G.__loomworks_luaroot = saved_root
  end)

  local function run(argv)
    local saved = _G.arg
    _G.arg = argv
    local r = capture(function() cli.main() end)
    _G.arg = saved
    return r
  end

  it("prints the newest notes, full lines when piped", function()
    local r = run({ "release-notes", "-n", "1" })
    assert.equals(0, r.exit_code)
    assert.matches("^loomworks 1%.2%.0 %- 2026%-02%-01  %(running%)\n", r.stdout)
    assert.matches("\n  Second release summary on two lines%.\n", r.stdout)
    assert.matches("2 older releases: lw release%-notes %-%-all\n$", r.stdout)
  end)

  it("--since, <version>, --json", function()
    local r = run({ "release-notes", "--since", "1.0.0" })
    assert.matches("loomworks 1%.1%.0", r.stdout)
    assert.is_nil(r.stdout:find("loomworks 1.0.0", 1, true))
    r = run({ "release-notes", "v1.1.0" })
    assert.matches("^loomworks 1%.1%.0 %- 2026%-01%-15\n", r.stdout)
    r = run({ "release-notes", "--json", "--all" })
    local j = vim.json.decode(r.stdout)
    assert.equals("1.2.0", j.running)
    assert.equals(3, #j.entries)
  end)

  it("usage errors exit 2; an unknown version exits 1", function()
    assert.equals(2, run({ "release-notes", "--all", "-n", "2" }).exit_code)
    assert.equals(2, run({ "release-notes", "-n", "0" }).exit_code)
    assert.equals(2, run({ "release-notes", "not-a-version" }).exit_code)
    assert.equals(2, run({ "release-notes", "--bogus" }).exit_code)
    local r = run({ "release-notes", "7.0.0" })
    assert.equals(1, r.exit_code)
    assert.matches("no release notes for 7%.0%.0", r.stderr)
  end)

  it("says when the build carries no notes", function()
    cli._test_release_notes_text = nil
    local rt = notice.read_text
    notice.read_text = function() return nil end
    local code
    local r = capture(function() code = cli.cmd_release_notes({ "release-notes" }) end)
    notice.read_text = rt
    assert.equals(1, code)
    assert.matches("not available in this build", r.stderr)
  end)

  it("has a help topic, and completion offers options and versions", function()
    assert.is_true(cli.has_help_topic("release-notes"))
    local c = capture(function() cli.cmd_complete("2", { "lw", "release-notes", "" }) end).stdout
    assert.matches("%-%-since", c)
    local c2 = capture(function() cli.cmd_complete("3", { "lw", "release-notes", "--since", "" }) end).stdout
    assert.matches("0%.1%.40", c2)
  end)
end)

describe("upgrade notice before a command", function()
  local cli = require("loomworks.cli")
  local data, saved_root

  before_each(function()
    data = temp_dir()
    vim.fn.mkdir(data .. "/lua-0.1.39", "p")
    vim.fn.mkdir(data .. "/lua-0.1.40", "p")
    saved_root = _G.__loomworks_luaroot
    _G.__loomworks_luaroot = data .. "/lua-0.1.40"
  end)
  after_each(function()
    _G.__loomworks_luaroot = saved_root
    cli._test_notice_interactive = nil
    vim.fn.delete(data, "rf")
  end)

  local function stderr_of(fn)
    local buf, rs = {}, io.stderr
    io.stderr = { write = function(_, s) buf[#buf + 1] = s end }
    local ok, e = pcall(fn)
    io.stderr = rs
    assert(ok, e)
    return table.concat(buf)
  end

  it("prints one line on an interactive terminal, once", function()
    cli._test_notice_interactive = true
    local e = stderr_of(function() cli._release_notice({ "status" }, false) end)
    assert.equals("lw: updated 0.1.39 -> 0.1.40 - see what's new: lw release-notes --since 0.1.39\n", e)
    assert.equals("", stderr_of(function() cli._release_notice({ "status" }, false) end))
  end)

  it("stays silent for --json output and non-interactive runs", function()
    cli._test_notice_interactive = true
    assert.equals("", stderr_of(function() cli._release_notice({ "health", "--json" }, false) end))
    cli._test_notice_interactive = false
    assert.equals("", stderr_of(function() cli._release_notice({ "status" }, true) end))
    assert.is_nil(notice.read_seen(data))
  end)
end)

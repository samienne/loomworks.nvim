-- `lw status` name-column widths — profile / config-set / project name columns
-- must use the available terminal width instead of a hardcoded cap, so full
-- names show on a wide terminal and only truncate (with an ellipsis) when the
-- terminal is genuinely narrow. Exercises the pure seams:
--   * `_term_width`   — tty measurement (injected) → $COLUMNS → default 100
--   * `_fit_column`   — content-sized, terminal-capped column width
--   * `_status_profile_rows` — the exact rows `cmd_status` emits for Profiles
-- stdout is captured/piped in the runner, so the tty path is only reachable via
-- the injectable `guess`/`new_tty` seams.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

describe("term_width", function()
  local saved_columns
  before_each(function() saved_columns = vim.env.COLUMNS end)
  after_each(function() vim.env.COLUMNS = saved_columns end)

  it("returns the $COLUMNS value when set and stdout is not a tty", function()
    vim.env.COLUMNS = "123"
    -- Force the non-tty branch so the measurement can't depend on the real fd.
    assert.equals(123, cli._term_width({ guess = function() return "pipe" end }))
  end)

  it("falls back to the default (100) when $COLUMNS is unset and not a tty", function()
    vim.env.COLUMNS = nil
    assert.equals(100, cli._term_width({ guess = function() return "file" end }))
  end)

  it("measures a real stdout tty via libuv get_winsize", function()
    vim.env.COLUMNS = "40" -- must be ignored: the tty width wins
    local closed = false
    local w = cli._term_width({
      guess = function() return "tty" end,
      new_tty = function()
        return {
          get_winsize = function() return 137, 42 end, -- width, height
          close = function() closed = true end,
        }
      end,
    })
    assert.equals(137, w)
    assert.is_true(closed)
  end)

  it("falls back to $COLUMNS when the tty reports a non-positive width", function()
    vim.env.COLUMNS = "88"
    local w = cli._term_width({
      guess = function() return "tty" end,
      new_tty = function()
        return { get_winsize = function() return 0, 0 end, close = function() end }
      end,
    })
    assert.equals(88, w)
  end)
end)

describe("fit_column", function()
  -- fit_column(longest, tw, reserved, min): never wider than the content, never
  -- wider than (tw - reserved), never narrower than min.
  it("uses the full content width when it fits in the terminal", function()
    assert.equals(50, cli._fit_column(50, 100, 33, 8))
  end)

  it("caps to the terminal budget when the content overflows", function()
    -- budget = max(8, 40 - 33) = 8
    assert.equals(8, cli._fit_column(50, 40, 33, 8))
  end)

  it("never pads past the min for short content (no over-padding)", function()
    assert.equals(8, cli._fit_column(5, 100, 33, 8))
  end)
end)

describe("status_profile_rows (name column sizing)", function()
  local pal = cli._status_palette(false)
  local function grouped() return { by_key = {}, by_project = {} } end

  it("REGRESSION: shows a long profile name in full on a wide terminal", function()
    local long = string.rep("a", 50)
    local plist = { { key = long, _configuration_set_name = "dev" } }
    -- Default-width terminal (100). Before the fix the name column was a
    -- hardcoded 38, which truncated this 50-char name; now it uses the width.
    local rows, name_w = cli._status_profile_rows(pal, plist, long, grouped(), 100)
    assert.equals(1, #rows)
    assert.is_truthy(rows[1]:find(long, 1, true))   -- full name present …
    assert.is_nil(rows[1]:find("…", 1, true))       -- … and never truncated
    assert.is_true(name_w >= 50)
    -- No set column: the set is the name's prefix (spec §16.18).
    assert.is_nil(rows[1]:find("set=", 1, true))
  end)

  it("truncates a long name with an ellipsis on a narrow terminal", function()
    local long = string.rep("a", 50)
    local plist = { { key = long, _configuration_set_name = "dev" } }
    local rows = cli._status_profile_rows(pal, plist, long, grouped(), 40)
    assert.is_truthy(rows[1]:find("…", 1, true))    -- ellipsis present
    assert.is_nil(rows[1]:find(long, 1, true))      -- full name NOT present
  end)

  it("does not over-pad short names to a fixed width", function()
    local plist = {
      { key = "a", _configuration_set_name = "dev" },
      { key = "b", _configuration_set_name = "dev" },
    }
    local _, name_w = cli._status_profile_rows(pal, plist, "a", grouped(), 100)
    -- Names are 1 char; the column collapses to the small minimum, nowhere near 38.
    assert.is_true(name_w <= 8)
  end)

  it("measures raw text, not painted output (ANSI escapes never widen a name)", function()
    local long = string.rep("a", 50)
    local plist = { { key = long, _configuration_set_name = "dev" } }
    local colored = cli._status_palette(true)
    local rows = cli._status_profile_rows(colored, plist, long, grouped(), 100)
    -- Painted (has escapes) but the raw name is still present un-truncated.
    assert.is_truthy(require("loomworks.term").render(rows[1]):find("\27%["))
    assert.is_truthy(rows[1]:find(long, 1, true))
    assert.is_nil(rows[1]:find("…", 1, true))
  end)
end)

-- One layout rule for rows with an open-ended tail (spec §16.35): identity and
-- fixed columns, then the summary column, then the open-ended list, which takes
-- the truncation.
describe("summary column before an open-ended tail", function()
  local saved_tty
  before_each(function() saved_tty = cli._test_stdout_tty end)
  after_each(function() cli._test_stdout_tty = saved_tty end)

  it("sizes the column to the longest summary, capped at 36; 0 without descriptions", function()
    cli._test_stdout_tty = false
    assert.equals(0, cli._summary_column({ nil, nil }, 100, 10))
    assert.equals(5, cli._summary_column({ "Short\n\nbody", nil }, 100, 10))
    assert.equals(36, cli._summary_column({ string.rep("x", 80) }, 100, 10))
  end)

  it("on a terminal, gives up the column (-1) when fewer than 16 columns would remain", function()
    cli._test_stdout_tty = true
    assert.equals(-1, cli._summary_column({ "Summary text" }, 40, 18))
    assert.equals(12, cli._summary_column({ "Summary text" }, 80, 18))
  end)

  it("keeps the tail aligned and cuts the tail, not the summary", function()
    local a = cli._row_with_summary("  Dev", "Set summary", 11, { "App→Debug", "Lib→Release" }, 13)
    local b = cli._row_with_summary("  Bar", nil, 11, "App→Release", 12)
    local function col(l, s) return vim.fn.strdisplaywidth(l:sub(1, l:find(s, 1, true) - 1)) end
    assert.equals(col(a, "App→"), col(b, "App→"))
    assert.is_truthy(a:find("Set summary  App→Debug …+1", 1, true), a)
    assert.equals("  Dev App→Debug", cli._row_with_summary("  Dev", "Set summary", 0, "App→Debug", nil))
  end)
end)

-- The open-ended list takes the truncation at whole-entry boundaries (spec
-- §16.35): never an entry cut mid-way while at least one whole entry fits.
describe("fit_list (open-ended tail at whole entries)", function()
  local names = { "OhosRelease", "variant:Debug", "variant:Release" }

  it("prints the list in full when it fits, or without a width", function()
    assert.equals("OhosRelease, variant:Debug, variant:Release", cli._fit_list(names, 0, 60))
    assert.equals("OhosRelease, variant:Debug, variant:Release +2", cli._fit_list(names, 2, nil))
    assert.equals("OhosRelease, variant:Debug, variant:Release +2", cli._fit_list(names, 2, 46))
  end)

  it("keeps whole names and counts every hidden one after …+", function()
    -- The field report: 38 columns used to show "…, variant:R…".
    assert.equals("OhosRelease, variant:Debug …+1", cli._fit_list(names, 0, 38))
    assert.equals("OhosRelease, variant:Debug …+3", cli._fit_list(names, 2, 38))
    assert.equals("OhosRelease …+2", cli._fit_list(names, 0, 16))
    assert.equals("OhosRelease …+4", cli._fit_list(names, 2, 25))
  end)

  it("falls back to a display-column cut only when no whole name fits", function()
    local r = cli._fit_list({ "AVeryLongConfigurationName", "Debug" }, 0, 16)
    assert.equals(16, vim.fn.strdisplaywidth(r))
    assert.is_truthy(r:find("…$"))
    assert.equals("AVeryLongConfi…", cli._fit_list({ "AVeryLongConfigurationName" }, 0, 15))
  end)

  it("measures display columns, not bytes", function()
    assert.equals("App→Debug …+1", cli._fit_list({ "App→Debug", "Lib→Release" }, 0, 13))
  end)
end)

describe("status project and set rows at several widths", function()
  local saved_tty
  before_each(function() saved_tty = cli._test_stdout_tty end)
  after_each(function() cli._test_stdout_tty = saved_tty end)

  -- Mirrors cmd_status's project-row math: 2 + name + 1 + type(6) + 1 +
  -- summary column + gaps + 4 marker columns.
  local function project_row(tw)
    cli._test_stdout_tty = true
    local desc = "LumeScene plugin: scene API, import pipeline and ECS glue"
    local name_w = 9
    local sum_w = cli._summary_column({ desc }, tw, 2 + name_w + 1 + 6)
    local cfg_w = math.max(50, tw - 2 - name_w - 1 - 6 - 1 - 4)
    if sum_w > 0 then cfg_w = math.max(16, tw - 2 - name_w - 1 - 6 - 1 - sum_w - 3 - 4) end
    local head = { "OhosRelease", "variant:Debug", "variant:Release", more = 0 }
    return cli._row_with_summary("  LumeScene cmake ", desc, sum_w, head, cfg_w)
  end

  for _, tw in ipairs({ 60, 80, 100, 140 }) do
    it("never cuts a configuration name mid-way at " .. tw .. " columns", function()
      local row = project_row(tw)
      local first = vim.split(row, "\n", { plain = true })[1]
      local tail = first:sub(first:find("OhosRelease", 1, true))
      -- Every entry shown is a whole name.
      local list = tail:gsub(" …%+%d+$", "")
      for entry in (list .. ", "):gmatch("(.-), ") do
        assert.is_truthy(({ OhosRelease = 1, ["variant:Debug"] = 1, ["variant:Release"] = 1 })[entry],
          "cut entry '" .. entry .. "' in: " .. first)
      end
    end)
  end

  it("shows all names on a wide terminal and whole names + count at 100", function()
    assert.is_truthy(project_row(140):find("OhosRelease, variant:Debug, variant:Release", 1, true))
    assert.is_truthy(project_row(100):find("OhosRelease, variant:Debug …+1", 1, true))
  end)
end)

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
    -- The set value still renders after the name.
    assert.is_truthy(rows[1]:find("set=dev", 1, true))
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
    assert.is_truthy(rows[1]:find("\27%["))
    assert.is_truthy(rows[1]:find(long, 1, true))
    assert.is_nil(rows[1]:find("…", 1, true))
  end)
end)

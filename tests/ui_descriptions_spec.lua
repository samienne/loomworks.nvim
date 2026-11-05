-- Editor side of descriptions (spec/plugin.md UI §1.16): the summary on a node line
-- (fitted to the window, inert, LoomworksDescription), the expanded
-- description leaves (8-line cap + "more" leaf), `K` hover, the `e` /
-- "Edit description" action and picker summaries.

local Tree = require("loomworks.ui.tree")
local helpers = require("loomworks.ui.helpers")
local editor = require("loomworks.ui.description_editor")

--- Render a tree whose render_fn is `fn`, at window width `width`.
local function render(width, fn)
  local t = Tree.new(fn)
  t.width = width
  local lines, hls = t:render()
  return t, lines, hls
end

local function desc_hls(hls)
  local out = {}
  for _, h in ipairs(hls) do
    if h.hl_group == "LoomworksDescription" then out[#out + 1] = h end
  end
  return out
end

describe("status tree: descriptions", function()
  it("appends the summary to a node line, highlighted and fitted to the window", function()
    local _, lines, hls = render(60, function(t)
      t:node("Dev", { fold_key = "set:Dev", description = "What CI ships\n\nbody" }, function() end)
    end)
    assert.equals("▶ Dev  What CI ships", lines[1])
    local dh = desc_hls(hls)
    assert.equals(1, #dh)
    assert.equals(#"▶ Dev  ", dh[1].col_start)
    assert.equals(#lines[1], dh[1].col_end)
  end)

  it("truncates with … to the remaining width, and omits it below 12 columns", function()
    local long = string.rep("abcdefghij", 10)
    local _, lines = render(40, function(t)
      t:item("Name", { description = long })
    end)
    assert.is_truthy(lines[1]:find("…", 1, true))
    assert.is_true(vim.fn.strdisplaywidth(lines[1]) <= 40)
    local _, narrow = render(20, function(t)
      t:item("A fairly long row", { description = long })
    end)
    assert.equals("A fairly long row", narrow[1])
  end)

  it("caps the summary at 60 columns on a wide window", function()
    local long = string.rep("x", 100)
    local _, lines = render(200, function(t) t:item("N", { description = long }) end)
    local sum = lines[1]:sub(#"N  " + 1)
    assert.equals(60, vim.fn.strdisplaywidth(sum))
  end)

  it("renders untrusted text inert: no newline, control characters visible", function()
    local _, lines = render(100, function(t)
      t:item("N", { description = "a\27[31mb\7" })
      t:node("M", { fold_key = "m", description = "x\ny" }, function() end)
    end)
    assert.equals("N  a^[[31mb^G", lines[1])
    for _, l in ipairs(lines) do assert.is_nil(l:find("\n", 1, true)) end
  end)

  it("expanded description: one leaf per line, 8-line cap, a K hint, hover shows all", function()
    local body = {}
    for i = 1, 12 do body[#body + 1] = "line " .. i end
    local desc = "Summary\n\n" .. table.concat(body, "\n")
    local t, lines = render(80, function(tr)
      tr:description(desc)
      tr:leaf("Path: x", "Comment")
    end)
    assert.equals("Summary", lines[1])
    assert.equals("", lines[2])
    assert.equals("line 6", lines[8])
    assert.is_truthy(lines[9]:find("6 more lines", 1, true))
    assert.equals("Path: x", lines[10])
    local r = t:on_key("hover", 3)
    assert.same(vim.split(desc, "\n", { plain = true }), r.hover)
    local r2 = t:on_key("hover", 9)
    assert.equals("line 12", r2.hover[#r2.hover])
  end)

  it("a module default is labelled on its first leaf", function()
    local _, lines = render(80, function(t) t:description("From preset", true) end)
    assert.is_truthy(lines[1]:find("(from project files)", 1, true))
  end)

  it("with_description wires summary, hover and the describe action", function()
    local opened
    local item = { description = "Sum\n\nBody" }
    local saved = editor.open
    editor.open = function(it) opened = it end
    local t = render(80, function(tr)
      tr:node("P", helpers.with_description({ fold_key = "p" }, item), function() end)
    end)
    local r = t:on_key("hover", 1)
    t:on_key("describe", 1)
    editor.open = saved
    assert.same({ "Sum", "", "Body" }, r.hover)
    assert.equals(item, opened)
  end)

  it("picker summaries are fitted plain strings", function()
    assert.equals("", helpers.picker_summary(nil))
    assert.equals("  Short", helpers.picker_summary("Short\n\nbody"))
    local s = helpers.picker_summary(string.rep("y", 80))
    assert.equals(40, vim.fn.strdisplaywidth(s:sub(3)))
  end)
end)

-- Saving from an editor dialog hands on ONLY the fields the dialog edits (the
-- launch editor, the configuration-set editor's rename): what it does not
-- show (a launch's device block, a set's description and intent) is never
-- part of the result, so the daemon's save keeps it (spec/ui.md; the save
-- itself is `Projects/1.launch_save` / `ConfigSets/1.update`, the daemon's).
-- Each spec drives the real dialog widget — View is stubbed so no window
-- opens — edits one shown field through its row and accepts.

local View = require("loomworks.ui.view")

--- Open `dialog_mod` with `opts` against a stubbed View; returns the tree.
local function open_dialog(dialog_mod, opts)
  local tree
  local orig = View.new
  View.new = function(vopts)
    tree = vopts.widget
    return { open = function() end, close = function() end, refresh = function() end }
  end
  local ok, err = pcall(require(dialog_mod).open, opts)
  View.new = orig
  assert(ok, err)
  return tree
end

--- Press <CR> on the first rendered row matching `pattern`, answering the
--- prompt it opens with `answer`.
local function enter_row(tree, pattern, answer)
  local lines = tree:render()
  local row
  for i, l in ipairs(lines) do
    if l:find(pattern) then row = i; break end
  end
  assert(row, "no row matching " .. pattern .. " in:\n" .. table.concat(lines, "\n"))
  local orig = vim.ui.input
  vim.ui.input = function(_, cb) cb(answer) end
  local ok, err = pcall(tree.on_key, tree, "enter", row)
  vim.ui.input = orig
  assert(ok, err)
end

describe("launch editor dialog save", function()
  it("hands on only the fields it shows, with the edit; nothing else", function()
    local result
    local tree = open_dialog("loomworks.ui.launch_editor", {
      title = "Edit", name = "run", command = "app", args = { "-v" },
      working_dir = "/w", env = { FOO = "bar" }, deploy = nil, debug = { "c++" }, variables = {},
      on_accept = function(r) result = r end,
      on_cancel = function() end,
    })
    enter_row(tree, "^%s*Command ", "app2")
    tree:on_key("accept", 1)
    assert.is_table(result)
    -- (An empty deploy is absent on the wire: ui/model_calls.)
    assert.same({ name = "run", command = "app2", args = { "-v" }, working_dir = "/w",
      env = { FOO = "bar" }, deploy = {}, debug = { "c++" } }, result)
  end)
end)

describe("configuration set editor dialog save", function()
  it("a rename hands on the new name and the same mappings only", function()
    local app = { id = "p:1", key = "App" }
    local dev = { id = "c:1", key = "Dev" }
    local result
    local tree = open_dialog("loomworks.ui.config_set_editor", {
      title = "Edit", name = "Dev", projects = { app },
      mappings = { [app] = dev }, available_configs = { [app] = { dev } },
      on_accept = function(r) result = r end,
      on_cancel = function() end,
    })
    enter_row(tree, "^%s*Name ", "Ship")
    tree:on_key("accept", 1)
    assert.is_table(result)
    assert.equals("Ship", result.name)
    assert.same({ [app] = dev }, result.mappings)
    local keys = vim.tbl_keys(result)
    table.sort(keys)
    assert.same({ "mappings", "name" }, keys)
  end)
end)

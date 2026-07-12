--- Standalone (luvi) entry point.
---
--- Installs the `vim` shim, forwards the app arguments luvi passes after `--`,
--- and runs the shared CLI. The Neovim host runs `cli.lua` directly instead
--- (real `vim` present); both converge on the same command logic.
-- luvi's `require` uses standard package.path, not a bundle-aware loader, so
-- point it at the real loomworks lua tree. LW_LUA is set by the launcher
-- (absolute path to `<loomworks>/lua`).
local lua_dir = os.getenv("LW_LUA")
if lua_dir then
  lua_dir = lua_dir:gsub("\\", "/"):gsub("/+$", "")
  package.path = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;" .. package.path
end

if not _G.vim then
  _G.vim = require("loomworks.shim")
end

-- luvi passes app args (everything after `--`) as varargs to the main chunk.
_G.arg = { ... }

require("loomworks.cli")

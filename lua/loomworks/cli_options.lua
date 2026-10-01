--- loomworks/cli_options.lua — the options each `lw` command knows, so an
--- unknown one is a usage error instead of being silently ignored (spec §16.7,
--- "Unknown options").
---
--- The tables mirror the command parsers in cli.lua; keep them in step when a
--- parser gains an option (tests/cli_unknown_options_spec.lua pins the rules).
--- The global options (`--no-input`, `--non-interactive`, `--shared`,
--- `--local`, `--dev[=…]`, `--no-pin`) are stripped by the dispatcher before
--- this check, and `--help` / `-h` are answered before it.
---
--- A spec is:
---   flags      options that take no value;
---   valued     options that consume the next token as their value;
---   eq         prefixes accepted as `--opt=value` (e.g. "--print=");
---   free_after the number of positional operands after which the rest of the
---              argv is not checked (a value that may start with '-', or a
---              program's own arguments);
---   frees      valued options after which (and their value) the rest is free
---              (`launch add --from-target <t> <program args…>`);
---   permissive true: this command/sub-command is not checked (its grammar
---              passes unknown tokens through by design).
--- Checking always stops at `--`: what follows belongs to a program or a
--- native tool.

local M = {}

local function set(list)
  local s = {}
  for _, v in ipairs(list or {}) do s[v] = true end
  return s
end

local function spec(t)
  return {
    flags = set(t.flags),
    valued = set(t.valued),
    eq = t.eq or {},
    free_after = t.free_after,
    frees = set(t.frees),
    permissive = t.permissive,
  }
end

local NONE = spec({})
local PERMISSIVE = spec({ permissive = true })

-- Device options (DEV.parse_device_opt, spec §16.34) on run / test, plus
-- `--break-locks[=now]` (spec §19.5), accepted by every command that takes a
-- build-directory or device lock and stripped by the dispatcher after this
-- check (loomworks.lock_break).
local DEVICE_FLAGS = { "--fresh", "--no-wait", "--break-locks" }
local BREAK = { "--break-locks" }
local BREAK_EQ = { "--break-locks=" }
local DEVICE_VALUED = { "--device", "--timeout", "--query-timeout", "--transfer-timeout", "--log" }

local function concat(...)
  local r = {}
  for _, l in ipairs({ ... }) do for _, v in ipairs(l) do r[#r + 1] = v end end
  return r
end

-- Sub-commands that take the workspace operation lock (spec §19.3).
local OPLOCK = spec({ flags = BREAK, eq = BREAK_EQ })

-- `-m <para>` on item-creating verbs (M._extract_create_paras, §16.35).
local CREATE = spec({ valued = { "-m", "--message" }, eq = { "-m=", "--message=" } })
local CREATE_PROFILE = spec({ flags = { "--activate", "-a" }, valued = { "-m", "--message" },
  eq = { "-m=", "--message=" } })
-- `describe` text sources (M._describe_parse). A lone `-` is an operand (stdin).
local DESCRIBE = spec({ flags = { "-e", "--edit", "--clear", "--json" },
  valued = { "-m", "--message", "-F", "--file" }, eq = { "-m=", "--message=" } })
-- The `--project` / `--launch` launch address (consume_launch_address).
local LAUNCH_ADDR = spec({ valued = { "--project", "--launch" } })

--- Commands with sub-commands: `subs` by canonical name, `aliases` mapping an
--- alias to it, `default` for a missing sub-command (or a first token that is
--- an option), and `operand_default` for a first token that is not a known
--- sub-command but an operand (`lw target <profile>`).
M.COMMANDS = {
  run = spec({
    flags = concat({ "--target", "--launch", "--print", "--dry-run", "--no-build" }, DEVICE_FLAGS),
    valued = concat({ "--project", "--cwd", "--working-dir", "--prefix" }, DEVICE_VALUED),
    eq = { "--print=", "--dry-run=", "--break-locks=" },
  }),
  build = spec({ flags = { "--force", "--reconfigure", "--verbose", "-v", "--break-locks" },
    valued = { "--target" }, eq = { "--target=", "--break-locks=" } }),
  test = spec({ flags = DEVICE_FLAGS, valued = concat({ "--junit", "--target" }, DEVICE_VALUED),
    eq = BREAK_EQ }),
  clean = spec({ flags = BREAK, eq = BREAK_EQ }),
  reset = spec({ flags = { "--all", "-y", "--yes", "--break-locks" }, eq = BREAK_EQ }),
  unlock = spec({ flags = { "--all", "--force", "--workspace", "--journal" }, valued = { "--device" } }),
  profiles = NONE,
  publish = spec({ flags = BREAK, eq = BREAK_EQ }),
  -- `lw export` / `lw import` (§16.39). A lone `-` is an operand (stdout/stdin).
  export = spec({ flags = { "--published", "--no-profiles" }, valued = { "-o", "--output" },
    eq = { "--output=" } }),
  import = spec({ flags = { "-y", "--yes", "-n", "--dry-run", "--take-name", "--break-locks" }, eq = BREAK_EQ }),
  status = spec({ flags = { "--check", "--cache-stats" } }),
  -- `--force` / `--refresh` predate health re-checking everything; kept as no-ops.
  -- Positional words are health areas (§16.36).
  health = spec({ flags = { "--json", "--verbose", "-v", "--all", "--force", "--refresh" } }),
  init = spec({ valued = { "--name" } }),
  tools = spec({ flags = { "--cached" } }),
  trust = spec({ flags = { "-y", "--yes", "--discard", "--break-locks" }, eq = BREAK_EQ }),
  nuke = spec({ flags = { "-y", "--yes", "--break-locks" }, eq = BREAK_EQ }),
  migrate = spec({ flags = { "--check", "-y", "--yes", "--break-locks" }, eq = BREAK_EQ }),
  pull = spec({ flags = { "--dry-run", "-n", "--break-locks" }, eq = BREAK_EQ }),
  ["release-notes"] = spec({ flags = { "--all", "--json" }, valued = { "--since", "-n" },
    eq = { "--since=", "-n=" } }),
  -- Topic / shell names only; their own parsers report anything else.
  help = PERMISSIVE,
  completion = PERMISSIVE,
  settings = {
    subs = { list = NONE, get = NONE, set = spec({ free_after = 1 }), unset = NONE },
    default = NONE,
  },
  module = {
    subs = { list = NONE, install = spec({ flags = { "--force" } }), update = spec({ flags = { "--all" } }),
      remove = NONE },
    aliases = { ls = "list", add = "install", upgrade = "update", rm = "remove" },
    default = NONE,
  },
  worktree = {
    subs = { list = NONE, add = spec({ flags = { "--no-pull", "--pull" } }) },
    default = NONE,
  },
  sdk = {
    subs = { types = NONE, detect = NONE, list = NONE,
      add = spec({ flags = { "--force" }, valued = { "--family", "--version" } }), remove = NONE },
    aliases = { create = "add", rm = "remove" },
    default = NONE,
  },
  device = {
    subs = {
      list = spec({ flags = { "--json" }, valued = { "--query-timeout" } }),
      select = spec({ flags = { "--clear" } }),
      clean = spec({ flags = { "--no-wait", "--break-locks" }, valued = { "--device", "--query-timeout" },
        eq = BREAK_EQ }),
    },
    aliases = { ls = "list" },
    default = NONE,
  },
  workspace = { subs = { rename = NONE }, aliases = { mv = "rename" }, default = NONE },
  profile = {
    subs = {
      list = NONE, show = NONE, select = spec({ flags = { "--none" } }),
      create = CREATE_PROFILE, remove = OPLOCK, publish = OPLOCK, query = NONE,
      -- `[<profile>] <project> <variable> <value>`: the value may start with '-'.
      set = spec({ free_after = 2 }), unset = NONE, describe = DESCRIBE,
    },
    aliases = { add = "create", rm = "remove" },
    default = NONE,
  },
  project = {
    subs = {
      list = NONE, show = NONE, add = CREATE, remove = NONE, rename = OPLOCK, unset = NONE,
      publish = OPLOCK, describe = DESCRIBE,
      -- `<project> <variable> [<default>] [--type T]`: the default may start with '-'.
      set = spec({ valued = { "--type" }, eq = { "--type=" }, free_after = 2 }),
    },
    aliases = { create = "add", rm = "remove", mv = "rename" },
    default = NONE,
  },
  config = {
    subs = {
      list = NONE, show = NONE, get = NONE, add = CREATE, unset = NONE, rename = OPLOCK,
      remove = NONE, publish = OPLOCK, describe = DESCRIBE,
      -- `<project> <config> <param> <value>`: the value may start with '-' (-O2).
      set = spec({ free_after = 3 }),
    },
    aliases = { create = "add", mv = "rename", rm = "remove" },
    default = NONE,
  },
  configset = {
    subs = {
      list = NONE, show = NONE, create = CREATE, map = NONE, unmap = NONE, rename = OPLOCK,
      remove = NONE, publish = OPLOCK, describe = DESCRIBE,
    },
    aliases = { add = "create", mv = "rename", rm = "remove" },
    default = NONE,
  },
  launch = {
    subs = {
      list = NONE,
      -- `<project> <name> <command> [args…]` / `--from-target <t> [args…]`:
      -- everything after the command (or the target) is the program's.
      add = spec({ valued = { "--working-dir", "--cwd", "--env", "--from-target", "--description" },
        eq = { "--description=" }, frees = { "--from-target" }, free_after = 3 }),
      -- Every token `set` does not know becomes a program argument (its
      -- documented grammar), so there is nothing to refuse.
      set = PERMISSIVE,
      show = spec({ flags = { "--json" }, valued = { "--project", "--launch" } }),
      remove = LAUNCH_ADDR,
      rename = NONE,
      -- `<project> <name>` or `--project`/`--launch`, then the describe sources.
      describe = spec({ flags = { "-e", "--edit", "--clear", "--json" },
        valued = { "-m", "--message", "-F", "--file", "--project", "--launch" },
        eq = { "-m=", "--message=" } }),
    },
    aliases = { create = "add", edit = "set", rm = "remove", mv = "rename" },
    default = NONE,
  },
  target = {
    subs = {
      list = NONE,
      set = spec({ flags = { "--target", "--launch" }, valued = { "--project", "--cwd", "--working-dir" } }),
      clear = NONE,
    },
    aliases = { unset = "clear" },
    default = NONE,
    operand_default = NONE,
  },
}

--- Command aliases → canonical command names.
M.ALIASES = {
  configuration = "config", cfg = "config",
  ["configuration-set"] = "configset", cs = "configset",
  ws = "workspace", devices = "device", mod = "module",
}

--- Commands answered by the host (or, in the nvim-hosted fallback, by a short
--- "standalone binary only" note) rather than by a COMMANDS entry. `update` is
--- the removed command that still names its replacements (§16.24).
M.HOST_COMMANDS = {
  version = true, ["-v"] = true, ["--version"] = true, ["self-update"] = true,
  install = true, bootstrap = true, update = true,
}

--- Is `name` a command lw knows (spec §16.7 "Unknown commands")? Covers the
--- COMMANDS table, its aliases, the host commands and the help spellings.
--- `profiles` is in COMMANDS; `status` too.
--- @param name string
--- @return boolean
function M.is_command(name)
  if type(name) ~= "string" then return false end
  if name == "-h" or name == "--help" then return true end
  if M.HOST_COMMANDS[name] then return true end
  return M.COMMANDS[M.ALIASES[name] or name] ~= nil
end

--- Find the first unknown option in `argv` (argv[1] is the command, global
--- options already stripped). Returns nil when every option is known (or the
--- command is not checked), else the option and the command label for the
--- message (`run`, `launch add`).
--- @param argv string[]
--- @return string|nil option, string|nil label
function M.find_unknown(argv)
  local command = argv[1]
  if type(command) ~= "string" then return nil end
  local cmd = M.ALIASES[command] or command
  local entry = M.COMMANDS[cmd]
  if not entry then return nil end
  local s, start, label = entry, 2, cmd
  if entry.subs then
    local sub = argv[2]
    if sub == nil or sub:sub(1, 1) == "-" then
      s = entry.default
    else
      local name = (entry.aliases and entry.aliases[sub]) or sub
      if entry.subs[name] then
        s, start, label = entry.subs[name], 3, cmd .. " " .. name
      elseif entry.operand_default then
        s = entry.operand_default
      else
        return nil -- the handler reports the unknown sub-command
      end
    end
  end
  if not s or s.permissive then return nil end
  local npos, i = 0, start
  while argv[i] ~= nil do
    local v = argv[i]
    if v == "--" then return nil end
    if s.free_after and npos >= s.free_after then return nil end
    if #v > 1 and v:sub(1, 1) == "-" then
      if s.valued[v] then
        if s.frees[v] then return nil end
        i = i + 2
      elseif s.flags[v] then
        i = i + 1
      else
        local ok = false
        for _, p in ipairs(s.eq) do
          if v:sub(1, #p) == p then ok = true; break end
        end
        if not ok then return v, label end
        i = i + 1
      end
    else
      npos = npos + 1
      i = i + 1
    end
  end
  return nil
end

return M

--- loomworks/cli_options.lua — the options each `lw` command knows, so an
--- unknown one is a usage error instead of being silently ignored (spec §16.7,
--- "Unknown options").
---
--- The tables mirror the command parsers in cli.lua; keep them in step when a
--- parser gains an option (tests/cli_unknown_options_spec.lua pins the rules).
--- The global options (`M.GLOBAL`: `--no-input`, `--non-interactive`,
--- `--shared`, `--local`, `--dev[=…]`, `--no-pin`) are stripped
--- by the dispatcher (`split_globals`) before this check — only where they are
--- lw's own (`own_end`), never from a program's arguments — and `--help` /
--- `-h` are answered before it.
---
--- A spec is:
---   flags      options that take no value;
---   valued     options that take a value: the next token, or joined as
---              `--opt=value` (split at the first `=`, `normalize`). The value
---              is required: the last token, `--` or a token starting with
---              `--` is not one (spec §16.7 "Option values");
---   eq         prefixes accepted as `--opt=value` on an option that is not
---              valued (a flag with an optional value, e.g. "--print=");
---   one        extra groups of options that hold one value between them
---              (`--working-dir` / `--clear-working-dir`, `--command` /
---              `--from-target`). A valued option not in `REPEATABLE` holds
---              one value, and `ALIASES_ONE` pairs alias spellings: giving
---              that value twice is a usage error;
---   free_after the number of positional operands after which the rest of the
---              argv is not checked (a value that may start with '-', or a
---              program's own arguments);
---   binds      valued options after which `free_after` no longer applies:
---              lw's own options then run to the first `--`, which ends
---              them (`launch add --from-target <t>` has no command token);
---   permissive true: this command/sub-command is not checked (its grammar
---              passes unknown tokens through by design);
---   verbatim   true: what `free_after` leaves unchecked is a
---              program's argument list, so not even a global option is
---              recognised there (`launch add`'s program arguments). Without
---              it the unchecked rest is a value operand: global options are
---              still lw's own up to `--` (`lw config set A D opt -O2 --no-input`).
--- Checking always stops at `--`: what follows belongs to a program or a
--- native tool (and on a set-value command or `launch set` it is the escape
--- for a value / argument that spells a global option).

local M = {}

local function set(list)
  local s = {}
  for _, v in ipairs(list or {}) do s[v] = true end
  return s
end

--- Valued options that may be given more than once (spec §16.7 "Option
--- values"): every other valued option holds one value.
M.REPEATABLE = set({ "--env", "--unset-env", "--description", "-m", "--message", "--prefix", "--target",
  "--log" })

--- Spellings of one option: given together they set the same value twice.
local ALIASES_ONE = { { "--working-dir", "--cwd" }, { "-F", "--file" }, { "-o", "--output" } }

local function spec(t)
  -- slot[opt] = the group an option's value belongs to (its first member).
  local slot = {}
  for _, g in ipairs(ALIASES_ONE) do
    for _, o in ipairs(g) do slot[o] = g[1] end
  end
  for _, g in ipairs(t.one or {}) do
    -- An extra group may extend an alias pair (`--working-dir`, `--cwd`, `--clear-working-dir`).
    local key = slot[g[1]] or g[1]
    for _, o in ipairs(g) do slot[o] = key end
  end
  return {
    flags = set(t.flags),
    valued = set(t.valued),
    slot = slot,
    eq = t.eq or {},
    free_after = t.free_after,
    binds = set(t.binds),
    empty_ok = set(t.empty_ok),
    permissive = t.permissive,
    verbatim = t.verbatim,
  }
end

local NONE = spec({})
local PERMISSIVE = spec({ permissive = true })

-- Device options (DEV.parse_device_opt, spec §16.34) on run / test.
local DEVICE_FLAGS = { "--fresh", "--no-wait" }
local DEVICE_VALUED = { "--device", "--timeout", "--query-timeout", "--transfer-timeout", "--log" }

local function concat(...)
  local r = {}
  for _, l in ipairs({ ... }) do for _, v in ipairs(l) do r[#r + 1] = v end end
  return r
end

-- `-m <para>` on item-creating verbs (M._extract_create_paras, §16.35).
local CREATE = spec({ valued = { "-m", "--message" }, eq = { "-m=", "--message=" } })
local CREATE_PROFILE = spec({ flags = { "--activate", "-a" }, valued = { "-m", "--message" },
  eq = { "-m=", "--message=" } })
-- `describe` text sources (M._describe_parse). A lone `-` is an operand (stdin).
-- `-m ""` clears the description, like `--clear` (§16.35).
local DESCRIBE = spec({ flags = { "-e", "--edit", "--clear", "--json" },
  valued = { "-m", "--message", "-F", "--file" }, eq = { "-m=", "--message=" },
  empty_ok = { "-m", "--message" } })
-- The `--project` / `--launch` launch address (consume_launch_address).
local LAUNCH_ADDR = spec({ valued = { "--project", "--launch" } })

--- Commands with sub-commands: `subs` by canonical name, `aliases` mapping an
--- alias to it, `default` for a missing sub-command (or a first token that is
--- an option), and `operand_default` for a first token that is not a known
--- sub-command but an operand (`lw target <profile>`).
M.COMMANDS = {
  run = spec({
    flags = concat({ "--target", "--launch", "--print", "--dry-run", "--no-build", "--verbose", "-v" },
      DEVICE_FLAGS),
    valued = concat({ "--project", "--cwd", "--working-dir", "--prefix" }, DEVICE_VALUED),
    eq = { "--print=", "--dry-run=" },
  }),
  build = spec({ flags = { "--force", "--reconfigure", "--verbose", "-v" }, valued = { "--target" },
    eq = { "--target=" } }),
  test = spec({ flags = concat({ "--saved", "--discovered", "--list", "--json", "--no-build", "--verbose",
      "-v" }, DEVICE_FLAGS),
    valued = concat({ "--junit", "--target", "--cwd", "--working-dir" }, DEVICE_VALUED) }),
  clean = spec({ flags = { "--verbose", "-v" } }),
  reset = spec({ flags = { "--all", "-y", "--yes" } }),
  unlock = spec({ flags = { "--all" }, valued = { "--device" } }),
  profiles = NONE,
  publish = NONE,
  -- `lw export` / `lw import` (§16.39). A lone `-` is an operand (stdout/stdin).
  export = spec({ flags = { "--published", "--no-profiles" }, valued = { "-o", "--output" },
    eq = { "--output=" } }),
  import = spec({ flags = { "-y", "--yes", "-n", "--dry-run", "--take-name" } }),
  status = spec({ flags = { "--check", "--cache-stats" } }),
  -- `--force` / `--refresh` predate health re-checking everything; kept as no-ops.
  -- Positional words are health areas (§16.36).
  health = spec({ flags = { "--json", "--verbose", "-v", "--all", "--force", "--refresh" } }),
  init = spec({ valued = { "--name" } }),
  tools = spec({ flags = { "--cached" } }),
  trust = spec({ flags = { "-y", "--yes", "--discard" } }),
  nuke = spec({ flags = { "-y", "--yes" } }),
  migrate = spec({ flags = { "--check", "-y", "--yes" } }),
  pull = spec({ flags = { "--dry-run", "-n" } }),
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
      clean = spec({ flags = { "--no-wait" }, valued = { "--device", "--query-timeout" } }),
    },
    aliases = { ls = "list" },
    default = NONE,
  },
  workspace = { subs = { rename = NONE }, aliases = { mv = "rename" }, default = NONE },
  profile = {
    subs = {
      list = NONE, show = NONE, select = spec({ flags = { "--none" } }),
      create = CREATE_PROFILE, remove = NONE, publish = NONE, query = NONE,
      -- `[<profile>] <project> <variable> <value>`: the value may start with '-'.
      set = spec({ free_after = 2 }), unset = NONE, describe = DESCRIBE,
    },
    aliases = { add = "create", rm = "remove" },
    default = NONE,
  },
  project = {
    subs = {
      list = NONE, show = NONE, add = CREATE, remove = NONE, rename = NONE, unset = NONE,
      publish = NONE, describe = DESCRIBE,
      -- `<project> <variable> [<default>] [--type T]`: the default may start with '-'.
      set = spec({ valued = { "--type" }, eq = { "--type=" }, free_after = 2 }),
    },
    aliases = { create = "add", rm = "remove", mv = "rename" },
    default = NONE,
  },
  config = {
    subs = {
      list = NONE, show = NONE, get = NONE, add = CREATE, unset = NONE, rename = NONE,
      remove = NONE, publish = NONE, describe = DESCRIBE,
      -- `<project> <config> <param> <value>`: the value may start with '-' (-O2).
      set = spec({ free_after = 3 }),
    },
    aliases = { create = "add", mv = "rename", rm = "remove" },
    default = NONE,
  },
  configset = {
    subs = {
      list = NONE, show = NONE, create = CREATE, map = NONE, unmap = NONE, rename = NONE,
      remove = NONE, publish = NONE, describe = DESCRIBE,
    },
    aliases = { add = "create", mv = "rename", rm = "remove" },
    default = NONE,
  },
  launch = {
    subs = {
      list = NONE,
      -- `<project> <name> <command> [args…]`: everything after the command is
      -- the program's. `--from-target <t>` has no command token: lw's options
      -- run to the first `--` and only what follows it is the program's.
      add = spec({ valued = { "--working-dir", "--cwd", "--env", "--from-target", "--description" },
        eq = { "--description=" }, binds = { "--from-target" }, free_after = 3, verbatim = true,
        empty_ok = { "--working-dir", "--cwd" } }),
      -- Bare tokens are the new arguments; an unknown option before `--` is
      -- refused (an argument starting with `-` goes after `--`). A global
      -- option is lw's own up to `--` (`lw launch set App demo -- --dev`).
      set = spec({ flags = { "--clear-working-dir", "--clear-args" },
        valued = { "--project", "--launch", "--working-dir", "--cwd", "--env", "--unset-env",
          "--command", "--from-target", "--description" },
        one = { { "--working-dir", "--cwd", "--clear-working-dir" }, { "--command", "--from-target" } },
        empty_ok = { "--working-dir", "--cwd", "--description" } }),
      show = spec({ flags = { "--json" }, valued = { "--project", "--launch" } }),
      remove = LAUNCH_ADDR,
      rename = NONE,
      -- `<project> <name>` or `--project`/`--launch`, then the describe sources.
      describe = spec({ flags = { "-e", "--edit", "--clear", "--json" },
        valued = { "-m", "--message", "-F", "--file", "--project", "--launch" },
        eq = { "-m=", "--message=" }, empty_ok = { "-m", "--message" } }),
    },
    aliases = { create = "add", edit = "set", rm = "remove", mv = "rename" },
    default = NONE,
  },
  -- `lw test-target` (spec §16.9): args after `--` (add) are the entries' own.
  ["test-target"] = {
    subs = {
      list = NONE,
      add = spec({ flags = { "--project-wide", "--unchecked" }, valued = { "--config", "--working-dir", "--cwd" } }),
      remove = spec({ flags = { "--project-wide" }, valued = { "--config", "--index" } }),
      clear = spec({ flags = { "--project-wide", "--empty" }, valued = { "--config" } }),
    },
    aliases = { rm = "remove" },
    default = NONE,
    operand_default = NONE,
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

--- The global options (spec §16.7): known to every command, recognised
--- before the command and among its own arguments, never after `--` nor in a
--- program's arguments (see `own_end`). None takes a separate value: the
--- valued ones are spelled `--dev=<path>` and `--color=<when>` (a bare
--- `--color` is not one).
M.GLOBAL = set({ "--no-input", "--non-interactive", "--shared", "--local",
  "--dev", "--no-pin", "--no-color" })

--- Is `v` a global option (including `--dev=<path>` and `--color=<when>`)?
--- @param v any
--- @return boolean
function M.is_global(v)
  return type(v) == "string" and (M.GLOBAL[v] == true or v:sub(1, 6) == "--dev="
    or v:sub(1, 8) == "--color=")
end

--- A `--opt=value` token for a valued option of `s`: the option, else nil.
local function split_eq(s, v)
  local o = v:match("^(%-%-?[^=]+)=")
  if o and s.valued[o] then return o end
  return nil
end

--- Is `v` not a value for a valued option (spec §16.7 "Option values")?
local function not_a_value(v)
  return v == nil or v:sub(1, 2) == "--"
end

--- Walk `argv` (argv[1] is the command) with its command's spec; global
--- options count as known flags. Returns the first unknown option and the
--- command label (or nil), the index where lw's own arguments end (see
--- `own_end`), the first option-value problem before them (a usage message
--- or nil: a missing or empty value, a single-valued option given twice) and the
--- indices of the `--opt=value` tokens to split (`normalize`).
--- @param argv string[]
--- @return string|nil option, string|nil label, integer own_end, string|nil problem, table splits
local function walk(argv)
  local n = #argv + 1
  local splits = {}
  local function to_dashdash(from)
    for k = from, #argv do if argv[k] == "--" then return k end end
    return n
  end
  local command = argv[1]
  if command == "--" then return nil, nil, 1, nil, splits end
  if type(command) ~= "string" then return nil, nil, n, nil, splits end
  local cmd = M.ALIASES[command] or command
  local entry = M.COMMANDS[cmd]
  if not entry then return nil, nil, to_dashdash(2), nil, splits end
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
        return nil, nil, to_dashdash(2), nil, splits -- the handler reports the unknown sub-command
      end
    end
  end
  if not s then return nil, nil, to_dashdash(start), nil, splits end
  if s.permissive then return nil, nil, to_dashdash(start), nil, splits end
  local problem
  local held = {} -- slot -> the option that set it
  local function hold(o)
    if problem or (s.valued[o] and M.REPEATABLE[o]) then return end
    if not s.valued[o] and not s.slot[o] then return end -- a plain flag
    local key = s.slot[o] or o
    local prev = held[key]
    if prev == o then
      problem = "option '" .. o .. "' given twice for `lw " .. label .. "` — it holds one value"
    elseif prev then
      problem = "options '" .. prev .. "' and '" .. o .. "' cannot be combined for `lw " .. label
        .. "` — give one"
    end
    held[key] = prev or o
  end
  -- An empty value is a usage error except where "" clears (a launch edit's
  -- `--working-dir ""` / `--description ""`, spec §16.7 "Option values").
  local function check_empty(o, val)
    if val == "" and not s.empty_ok[o] then
      problem = problem or ("option '" .. o .. "' for `lw " .. label .. "` needs a non-empty value")
    end
  end
  local npos, i, free_after = 0, start, s.free_after
  while argv[i] ~= nil do
    local v = argv[i]
    if v == "--" then return nil, nil, i, problem, splits end
    if free_after and npos >= free_after then
      return nil, nil, s.verbatim and i or to_dashdash(i), problem, splits
    end
    if #v > 1 and v:sub(1, 1) == "-" then
      local eo = split_eq(s, v)
      if M.is_global(v) then
        i = i + 1
      elseif eo then
        -- `--opt=value`: the value may be anything, `--…` included.
        hold(eo)
        check_empty(eo, v:sub(#eo + 2))
        if s.binds[eo] then free_after = nil end
        splits[i] = true
        i = i + 1
      elseif s.valued[v] then
        hold(v)
        if s.binds[v] then free_after = nil end
        if not_a_value(argv[i + 1]) then
          problem = problem or ("option '" .. v .. "' for `lw " .. label .. "` needs a value"
            .. " (a value starting with `--` is given as " .. v .. "=<value>)")
          i = i + 1
        else
          check_empty(v, argv[i + 1])
          i = i + 2
        end
      elseif s.flags[v] then
        hold(v)
        i = i + 1
      else
        local ok = false
        for _, p in ipairs(s.eq) do
          if v:sub(1, #p) == p then ok = true; break end
        end
        if not ok then return v, label, to_dashdash(i), problem, splits end
        i = i + 1
      end
    else
      npos = npos + 1
      i = i + 1
    end
  end
  return nil, nil, n, problem, splits
end

--- Where lw's own arguments end in `argv` (argv[1] is the command, leading
--- global options already removed): the index of the first token that
--- belongs to a program or a native tool — the first `--`, or the program
--- arguments after `launch add`'s command — or #argv + 1. Global
--- options are recognised only before it (spec §16.7); on `launch set` and the
--- set-value commands that is up to `--`, which escapes an argument or value
--- spelling a global option.
--- @param argv string[]
--- @return integer
function M.own_end(argv)
  local _, _, e = walk(argv)
  return e
end

--- Split the raw command line into the global options and the rest: global
--- options before the command and among the command's own arguments
--- (`own_end`) are taken out; everything after — a program's arguments, the
--- tail after `--` — is left untouched (spec §16.7).
--- Also returns the first option-value problem among the command's own
--- arguments (spec §16.7 "Option values"), found before the global options
--- are taken out, so `--working-dir --no-input` is a missing value rather
--- than a directory named after the token that follows.
--- @param raw string[]
--- @return string[] rest, string[] globals (in order), string|nil problem
function M.split_globals(raw)
  local globals, k = {}, 1
  while raw[k] ~= nil and M.is_global(raw[k]) do
    globals[#globals + 1] = raw[k]; k = k + 1
  end
  local tail = {}
  for j = k, #raw do tail[#tail + 1] = raw[j] end
  local _, _, stop, problem = walk(tail)
  local rest = {}
  for j, v in ipairs(tail) do
    if j > 1 and j < stop and M.is_global(v) then
      globals[#globals + 1] = v
    else
      rest[#rest + 1] = v
    end
  end
  return rest, globals, problem
end

--- `argv` (globals already taken out) with every `--opt=value` token of a
--- valued option among lw's own arguments split into `--opt`, `value` (at the
--- first `=`), so a handler only sees the separate form (spec §16.7 "Option
--- values"). Nothing at or after `own_end` is touched.
--- @param argv string[]
--- @return string[]
function M.normalize(argv)
  local _, _, _, _, splits = walk(argv)
  if next(splits) == nil then return argv end
  local out = {}
  for i, v in ipairs(argv) do
    if splits[i] then
      local o, val = v:match("^(%-%-?[^=]+)=(.*)$")
      out[#out + 1] = o; out[#out + 1] = val
    else
      out[#out + 1] = v
    end
  end
  return out
end

--- `list` without its first `--` at or after index `from` (default 1): on a
--- set-value command the `--` only escapes a value that spells a global
--- option (`lw config set App Debug opt -- --dev`), it is not itself a value.
--- @param list string[]
--- @param from integer|nil
--- @return string[]
function M.drop_escape(list, from)
  local out, dropped = {}, false
  for j, v in ipairs(list) do
    if not dropped and v == "--" and j >= (from or 1) then
      dropped = true
    else
      out[#out + 1] = v
    end
  end
  return out
end

--- Find the first unknown option in `argv` (argv[1] is the command, global
--- options already stripped). Returns nil when every option is known (or the
--- command is not checked), else the option and the command label for the
--- message (`run`, `launch add`).
--- @param argv string[]
--- @return string|nil option, string|nil label
function M.find_unknown(argv)
  local bad, label = walk(argv)
  return bad, label
end

return M

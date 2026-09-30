--- loomworks/release_notes.lua — the release notes reader and renderer
--- (spec §16.37).
---
--- PURE: text in, tables / lines out. No `require`, no I/O, no `vim`, no
--- globals beyond the Lua builtins below — a host loads this file from a newly
--- installed bundle into a sandbox (boot/whats_new.lua) to render self-update's
--- "what's new" lines (§16.32), so it must stay free of every dependency.
--- Finding the file, the running version and the last-seen record live in
--- loomworks/release_notice.lua.
---
--- Grammar (CHANGELOG.md): preamble and `<!-- ... -->` comments are skipped;
--- `## Unreleased` or `## <version> - <YYYY-MM-DD>` starts an entry; a summary
--- paragraph; `### <section>` headings from SECTIONS; `- ` items whose
--- continuation lines are indented by two spaces.

local M = {}

--- The sections an entry may have, in their required order.
M.SECTIONS = { "Breaking", "Upgrade notes", "Added", "Changed", "Fixed", "Security", "Removed" }
--- The sections the short forms (what's new) surface.
M.ACTION_SECTIONS = { ["Breaking"] = true, ["Upgrade notes"] = true }
--- Entries shown by the default selection.
M.DEFAULT_COUNT = 3
--- Releases listed by the what's-new block before "and N earlier".
M.WHATS_NEW_MAX = 5
--- Action items listed per release in the what's-new block.
M.WHATS_NEW_ITEMS = 3
--- Widest wrapped line.
M.MAX_WIDTH = 100

local SECTION_RANK = {}
for i, s in ipairs(M.SECTIONS) do SECTION_RANK[s] = i end

-- ---------------------------------------------------------------------------
-- Versions (a local copy of the host's semver ordering: no boot dependency)
-- ---------------------------------------------------------------------------

--- Strip a leading `v`; nil unless the rest is a valid version
--- (`<n>.<n>.<n>` with an optional `-<pre-release>`).
--- @param v any
--- @return string|nil
function M.normalize(v)
  if type(v) ~= "string" then return nil end
  v = v:gsub("^[vV]", "")
  if v:match("^%d+%.%d+%.%d+$") or v:match("^%d+%.%d+%.%d+%-[%w][%w%.%-]*$") then return v end
  return nil
end

--- @param v string|nil
--- @return boolean
function M.is_pre_release(v)
  return type(v) == "string" and v:find("-", 1, true) ~= nil
end

--- The full release a version belongs to (`0.1.41-beta.2` -> `0.1.41`).
function M.base(v)
  return (v:gsub("%-.*$", ""))
end

local function split(v)
  local core, pre = v:match("^([^%-]+)%-?(.*)$")
  local nums = {}
  for n in (core or v):gmatch("%d+") do nums[#nums + 1] = tonumber(n) end
  local ids = {}
  if pre and pre ~= "" then
    for id in pre:gmatch("[^%.]+") do ids[#ids + 1] = id end
  end
  return nums, ids
end

local function cmp_ident(x, y)
  local nx, ny = tonumber(x), tonumber(y)
  if nx and ny then return nx < ny and -1 or (nx > ny and 1 or 0) end
  if nx then return -1 end
  if ny then return 1 end
  return x < y and -1 or (x > y and 1 or 0)
end

--- Semver ordering: -1, 0 or 1. A pre-release orders below its release.
--- @param a string
--- @param b string
--- @return integer
function M.compare(a, b)
  local an, ap = split(a)
  local bn, bp = split(b)
  for i = 1, math.max(#an, #bn) do
    local x, y = an[i] or 0, bn[i] or 0
    if x ~= y then return x < y and -1 or 1 end
  end
  if #ap == 0 and #bp == 0 then return 0 end
  if #ap == 0 then return 1 end
  if #bp == 0 then return -1 end
  for i = 1, math.max(#ap, #bp) do
    local x, y = ap[i], bp[i]
    if x == nil then return -1 end
    if y == nil then return 1 end
    local r = cmp_ident(x, y)
    if r ~= 0 then return r end
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Parsing
-- ---------------------------------------------------------------------------

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

--- Parse CHANGELOG text. Tolerant: whatever it cannot place is reported in
--- `errors` ({ line, msg }) and skipped.
--- @param text string
--- @return { entries: table[], errors: table[] }
function M.parse(text)
  local doc = { entries = {}, errors = {} }
  local function err(ln, msg) doc.errors[#doc.errors + 1] = { line = ln, msg = msg } end
  local entry, section, item, summary_open, summary
  local in_comment = false

  local function close_entry()
    if not entry then return end
    if summary then entry.summary = trim(table.concat(summary, " ")) end
    if entry.summary == "" then entry.summary = nil end
    summary = nil
  end

  local ln = 0
  for raw in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
    ln = ln + 1
    local line = raw:gsub("\r$", "")
    -- HTML comments (one or more lines) are not content.
    if in_comment then
      if line:find("-->", 1, true) then in_comment = false end
      line = nil
    elseif line:match("^%s*<!%-%-") then
      if not line:find("-->", 1, true) then in_comment = true end
      line = nil
    end
    if line == nil then
      -- skipped
    elseif line:match("^## ") then
      close_entry()
      local h = trim(line:sub(4))
      section, item = nil, nil
      if h == "Unreleased" then
        entry = { unreleased = true, sections = {}, line = ln }
      else
        local v, d = h:match("^(%S+) %- (%d%d%d%d%-%d%d%-%d%d)$")
        if v and M.normalize(v) == v then
          entry = { version = v, date = d, unreleased = false, sections = {}, line = ln }
        else
          err(ln, "malformed entry heading '" .. line .. "' (want '## <x.y.z> - <YYYY-MM-DD>' or '## Unreleased')")
          entry = nil
        end
      end
      if entry then doc.entries[#doc.entries + 1] = entry end
      summary_open, summary = entry ~= nil, nil
    elseif not entry then
      -- preamble (or the body of a malformed entry)
    elseif line:match("^### ") then
      local name = trim(line:sub(5))
      summary_open, item = false, nil
      if not SECTION_RANK[name] then
        err(ln, "unknown section '" .. name .. "' (use one of: " .. table.concat(M.SECTIONS, ", ") .. ")")
        section = nil
      else
        section = { name = name, items = {}, line = ln }
        entry.sections[#entry.sections + 1] = section
      end
    elseif line:match("^#") then
      err(ln, "unexpected heading '" .. line .. "' (entries are '## ', sections '### ')")
    elseif line:match("^%s*$") then
      item = item -- a blank line ends a paragraph; items continue after it
      if summary_open and summary then summary_open = false end
    elseif line:match("^%- ") then
      if section then
        item = { trim(line:sub(3)) }
        section.items[#section.items + 1] = item
      else
        err(ln, "item outside a section: '" .. line .. "'")
      end
    elseif line:match("^  %S") and item then
      item[#item + 1] = trim(line)
    elseif summary_open and not section then
      summary = summary or {}
      summary[#summary + 1] = trim(line)
    else
      err(ln, "unexpected text '" .. line .. "' (items start with '- ', continuations are indented two spaces)")
    end
  end
  close_entry()
  -- Items become strings (their lines joined by single spaces).
  for _, e in ipairs(doc.entries) do
    for _, s in ipairs(e.sections) do
      for i, it in ipairs(s.items) do s.items[i] = table.concat(it, " ") end
    end
  end
  return doc
end

--- Whether an entry has anything to show.
local function has_content(e)
  if e.summary then return true end
  for _, s in ipairs(e.sections) do if #s.items > 0 then return true end end
  return false
end
M.has_content = has_content

--- The strict grammar checks the test suite and the release gate apply on top
--- of what `parse` reports: ASCII text, section order and uniqueness, released
--- entries with a summary and items, descending unique full-release versions.
--- @param text string
--- @return string[] errors ("line N: message"), empty when valid
function M.validate(text)
  local out = {}
  local doc = M.parse(text)
  for _, e in ipairs(doc.errors) do out[#out + 1] = "line " .. e.line .. ": " .. e.msg end
  local ln = 0
  for raw in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
    ln = ln + 1
    local l = raw:gsub("\r$", "")
    if l:find("[%z\1-\8\11-\31\127-\255]") then
      out[#out + 1] = "line " .. ln .. ": non-ASCII or control character (release notes are ASCII only)"
    end
  end
  local prev
  local seen = {}
  for i, e in ipairs(doc.entries) do
    local where = "line " .. e.line .. ": "
    if e.unreleased then
      if i ~= 1 then out[#out + 1] = where .. "'## Unreleased' must be the first entry" end
    else
      if M.is_pre_release(e.version) then
        out[#out + 1] = where .. e.version .. ": pre-releases have no entry of their own (their changes stay under Unreleased)"
      end
      if seen[e.version] then out[#out + 1] = where .. "version " .. e.version .. " appears twice" end
      seen[e.version] = true
      if prev and M.compare(e.version, prev) >= 0 then
        out[#out + 1] = where .. e.version .. " is not older than " .. prev .. " (newest first)"
      end
      prev = e.version
      if not e.summary then out[#out + 1] = where .. e.version .. " has no summary paragraph" end
      local n = 0
      for _, s in ipairs(e.sections) do n = n + #s.items end
      if n == 0 then out[#out + 1] = where .. e.version .. " has no items" end
    end
    local last = 0
    local names = {}
    for _, s in ipairs(e.sections) do
      local r = SECTION_RANK[s.name]
      if names[s.name] then
        out[#out + 1] = "line " .. s.line .. ": section '" .. s.name .. "' appears twice in one entry"
      elseif r < last then
        out[#out + 1] = "line " .. s.line .. ": section '" .. s.name .. "' out of order (order: "
          .. table.concat(M.SECTIONS, ", ") .. ")"
      end
      names[s.name] = true
      last = math.max(last, r)
      if #s.items == 0 then out[#out + 1] = "line " .. s.line .. ": section '" .. s.name .. "' is empty" end
    end
  end
  return out
end

--- Find the released entry for `version` (exact).
function M.find(doc, version)
  for _, e in ipairs(doc.entries) do
    if not e.unreleased and M.compare(e.version, version) == 0 then return e end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Selection
-- ---------------------------------------------------------------------------

--- The entries visible to a run of `running` (nil = a development source),
--- newest first. An Unreleased entry is copied with `version = running` when
--- the running version is a pre-release (§16.37 "Visible entries").
--- @param doc table parse() result
--- @param running string|nil
--- @return table[]
function M.visible(doc, running)
  local out = {}
  local unrel = doc.entries[1] and doc.entries[1].unreleased and has_content(doc.entries[1])
    and doc.entries[1] or nil
  local cutoff
  if running then
    cutoff = M.is_pre_release(running) and M.base(running) or running
    if unrel and M.is_pre_release(running) then
      out[#out + 1] = { unreleased = true, version = running, summary = unrel.summary,
        sections = unrel.sections }
    end
  elseif unrel then
    out[#out + 1] = { unreleased = true, summary = unrel.summary, sections = unrel.sections }
  end
  for _, e in ipairs(doc.entries) do
    if not e.unreleased and (not cutoff or M.compare(e.version, cutoff) <= 0) then
      out[#out + 1] = e
    end
  end
  return out
end

--- An entry's version for ordering: an Unreleased copy without a version is
--- newer than everything.
local function newer_than(e, v)
  if e.version == nil then return true end
  return M.compare(e.version, v) > 0
end

--- Select entries (§16.37 "Command"). `sel`:
---   { kind = "default" } | { kind = "count", n = N } | { kind = "all" }
---   | { kind = "version", version = V } | { kind = "since", version = V }
--- Returns { running, entries, more, since? } or nil, message.
--- @param doc table
--- @param running string|nil
--- @param sel table
--- @return table|nil result
--- @return string|nil err
function M.select(doc, running, sel)
  local vis = M.visible(doc, running)
  local res = { running = running, entries = {}, more = 0 }
  local kind = sel and sel.kind or "default"
  if kind == "default" or kind == "count" then
    local n = kind == "count" and sel.n or M.DEFAULT_COUNT
    for i = 1, math.min(n, #vis) do res.entries[i] = vis[i] end
    res.more = math.max(0, #vis - n)
  elseif kind == "all" then
    res.entries = vis
  elseif kind == "since" then
    res.since = sel.version
    for _, e in ipairs(vis) do
      if newer_than(e, sel.version) then res.entries[#res.entries + 1] = e end
    end
  elseif kind == "version" then
    for _, e in ipairs(vis) do
      if e.version and M.compare(e.version, sel.version) == 0 then
        res.entries = { e }
        return res
      end
    end
    local e = M.find(doc, sel.version)
    if e then res.entries = { e }; return res end
    return nil, "no release notes for " .. sel.version .. " - `lw release-notes --all` lists every release"
  else
    return nil, "unknown selection"
  end
  return res
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Word-wrap `text` to `width` columns: the first line starts with `first`,
--- the rest with `rest`. No width: one line. A word longer than the line is
--- kept whole.
--- @param text string
--- @param width integer|nil
--- @param first string
--- @param rest string
--- @return string[]
function M.wrap(text, width, first, rest)
  if not width then return { first .. text } end
  local lines, cur, prefix = {}, nil, first
  for word in text:gmatch("%S+") do
    if cur == nil then
      cur = prefix .. word
    elseif #cur + 1 + #word <= width then
      cur = cur .. " " .. word
    else
      lines[#lines + 1] = cur
      prefix = rest
      cur = prefix .. word
    end
  end
  lines[#lines + 1] = cur or first
  return lines
end

local function id(s) return s end

--- The title of an entry.
local function title(e, running)
  if e.unreleased then
    if e.version then return "loomworks " .. e.version .. " - prerelease (changes not yet released)" end
    return "loomworks - unreleased changes (development source)"
  end
  local t = "loomworks " .. e.version .. " - " .. e.date
  if running and M.compare(e.version, running) == 0 then t = t .. "  (running)" end
  return t
end

--- Render a select() result as lines.
--- opts: width (nil: no wrapping), paint { title, dim } (identity by default),
--- command (the command name shown in hints; default `lw release-notes`).
--- @param res table
--- @param opts table|nil
--- @return string[]
function M.render(res, opts)
  opts = opts or {}
  local width = opts.width and math.min(opts.width, M.MAX_WIDTH) or nil
  local paint = opts.paint or {}
  local ptitle, pdim = paint.title or id, paint.dim or id
  local cmd = opts.command or "lw release-notes"
  local out = {}
  local function add(l) out[#out + 1] = l end
  if #res.entries == 0 then
    if res.since then
      add("Nothing newer than " .. res.since .. (res.running and (" (running " .. res.running .. ")") or "") .. ".")
    else
      add("No release notes.")
    end
    return out
  end
  for i, e in ipairs(res.entries) do
    if i > 1 then add("") end
    add(ptitle(title(e, res.running)))
    if e.summary then
      for _, l in ipairs(M.wrap(e.summary, width, "  ", "  ")) do add(l) end
    end
    for _, s in ipairs(e.sections) do
      add("")
      add("  " .. ptitle(s.name))
      for _, it in ipairs(s.items) do
        for _, l in ipairs(M.wrap(it, width, "  - ", "    ")) do add(l) end
      end
    end
  end
  if res.more and res.more > 0 then
    add("")
    add(pdim((res.more == 1 and "1 older release" or (res.more .. " older releases")) .. ": " .. cmd .. " --all"))
  end
  return out
end

--- The `--json` document (§16.37). `null` is the JSON null sentinel of the
--- caller's encoder (vim.NIL).
function M.to_json(res, null)
  local entries = {}
  for _, e in ipairs(res.entries) do
    local sections = {}
    for _, s in ipairs(e.sections) do
      local items = {}
      for i, it in ipairs(s.items) do items[i] = it end
      sections[#sections + 1] = { name = s.name, items = items }
    end
    entries[#entries + 1] = {
      version = e.version or null,
      date = e.date or null,
      unreleased = e.unreleased and true or false,
      summary = e.summary or null,
      sections = sections,
    }
  end
  return { schema = 1, running = res.running or null, entries = entries, more = res.more or 0 }
end

--- Self-update's "what's new" block (§16.32): per release after `from` up to
--- `to` (newest first), the version, its summary and its Breaking / Upgrade
--- notes items; at most `opts.max` releases. Empty when nothing is newer.
--- opts: width (nil: no wrapping), max, items.
--- @param text string CHANGELOG.md
--- @param from string the version that was running
--- @param to string the version just installed
--- @param opts table|nil
--- @return string[]
function M.whats_new(text, from, to, opts)
  opts = opts or {}
  local width = opts.width and math.min(opts.width, M.MAX_WIDTH) or nil
  local max = opts.max or M.WHATS_NEW_MAX
  local per = opts.items or M.WHATS_NEW_ITEMS
  local doc = M.parse(text)
  local picked = {}
  for _, e in ipairs(M.visible(doc, to)) do
    if e.version and M.compare(e.version, from) > 0 then picked[#picked + 1] = e end
  end
  if #picked == 0 then return {} end
  local shown = math.min(#picked, max)
  local col = 0
  for i = 1, shown do col = math.max(col, #picked[i].version) end
  local pad = string.rep(" ", col + 4)
  local out = { "What's new since " .. from .. ":" }
  for i = 1, shown do
    local e = picked[i]
    local head = "  " .. e.version .. string.rep(" ", col - #e.version + 2)
    local sum = e.summary or "Changes not yet summarized; see the full notes."
    for _, l in ipairs(M.wrap(sum, width, head, pad)) do out[#out + 1] = l end
    local n, extra = 0, 0
    for _, s in ipairs(e.sections) do
      if M.ACTION_SECTIONS[s.name] then
        for _, it in ipairs(s.items) do
          if n < per then
            n = n + 1
            local label = s.name == "Breaking" and "Breaking: " or ""
            for _, l in ipairs(M.wrap(label .. it, width, pad .. "! ", pad .. "  ")) do
              out[#out + 1] = l
            end
          else
            extra = extra + 1
          end
        end
      end
    end
    if extra > 0 then out[#out + 1] = pad .. "! (+" .. extra .. " more)" end
  end
  if #picked > shown then
    local rest = #picked - shown
    out[#out + 1] = "  ... and " .. rest .. " earlier release" .. (rest == 1 and "" or "s")
  end
  return out
end

return M

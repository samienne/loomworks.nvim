-- The repo launcher / pin checks (spec §16.24 "Checks: one source of truth",
-- §16.31 provider #4) — ONE implementation, consumed by the `lw bootstrap`
-- status page (boot.bootstrap, luvi host, no system Lua) and by the health
-- provider (loomworks.launcher_health, system Lua, either host).
--
-- Pure over an injected env — no vim shim, no direct spawn — so each host
-- passes its own git runner and hash function, and tests pass fakes:
--
--   env.git(cwd, args) -> code, stdout   (code nil / non-zero: no answer)
--   env.sha256(bytes)  -> hex
--   env.read(path)     -> bytes|nil       (default: io.open)
--   env.exists(path)   -> boolean         (default: io.open)
--   env.stale(root, version) -> n, bytes  (stale cached binaries; default none)
--   env.invoked        how lw was run, so remedies are spelled in that form:
--                      "lw.sh" | "lw.cmd" (the launcher named itself),
--                      "launcher" (pinned context, launcher unknown), "global"
--
-- ASCII only: the status page prints before system Lua (§16.7).

local launcher = require("boot.launcher")
local pin = require("boot.pin")

local M = {}

M.is_windows = package.config:sub(1, 1) == "\\"

local function default_read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end

local function default_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local function join_list(list) return table.concat(list, ", ") end

local function lower_if_win(p) return M.is_windows and p:lower() or p end

--- Is `path` equal to or strictly under `dir` (separator-bounded)?
local function under(path, dir)
  path, dir = lower_if_win(path), lower_if_win(dir)
  return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

--- Resolve `rel` against `base` (forward slashes, `..` collapsed).
local function join(base, rel)
  rel = rel:gsub("\\", "/")
  if rel:match("^%a:/") or rel:sub(1, 1) == "/" then return rel end
  local parts = {}
  for seg in (base .. "/" .. rel):gmatch("[^/]+") do
    if seg == ".." then parts[#parts] = nil
    elseif seg ~= "." then parts[#parts + 1] = seg end
  end
  local lead = base:sub(1, 1) == "/" and "/" or ""
  return lead .. table.concat(parts, "/")
end
M._join = join

--- The work-tree top level containing `root`, or nil (not a repository / no git).
function M.toplevel(root, git)
  local code, out = git(root, { "rev-parse", "--show-toplevel" })
  if code ~= 0 or type(out) ~= "string" then return nil end
  local top = out:match("^([^\r\n]+)")
  return top and (top:gsub("\\", "/"):gsub("/+$", "")) or nil
end

--- Is the launcher cache ignored by a COMMITTED rule of the repository: the
--- matching line is in the committed (HEAD) content of a tracked `.gitignore`
--- inside the work tree? The user's global excludes and `.git/info/exclude` do
--- not count (teammates and CI do not have them), nor does an untracked,
--- staged-only or locally modified `.gitignore` line. The one rule both pin
--- management (writing) and the checks (reporting) apply.
--- @param git fun(cwd: string, args: string[]): integer|nil, string|nil
--- @return boolean|nil covered (nil: git could not answer), string|nil source
---   when not covered but matched by an uncommitted rule: that file, relative
---   to the work-tree top
function M.cache_ignored_by_repo(root, top, git)
  if not top then return nil end
  local code, out = git(root, { "-c", "core.excludesFile=", "check-ignore", "-v", "--no-index",
    "--", launcher.CACHE_DIR .. "/lw.marker" })
  if code == nil or (code ~= 0 and code ~= 1) then return nil end
  if code ~= 0 then return false end
  local m = launcher.parse_check_ignore(out)
  if not m or m.pattern:sub(1, 1) == "!" then return false end
  -- git reports the source relative to the work-tree top (or absolute).
  local src = join(top, m.source)
  local base = src:match("([^/]+)$")
  if not (base == ".gitignore" and under(src, top) and not under(src, top .. "/.git")) then
    return false
  end
  -- Committed content: the matching line must be in HEAD's copy of the file.
  local rel = src == top and "" or src:sub(#top + 2)
  local c2, committed = git(root, { "show", "HEAD:" .. rel })
  if c2 == 0 and type(committed) == "string" then
    for line in (committed .. "\n"):gmatch("([^\n]*)\n") do
      if (line:gsub("\r$", ""):gsub("^%s+", ""):gsub("%s+$", "")) == m.pattern then return true end
    end
  end
  return false, rel
end

--- The command prefix of an invoked form (spec §16.24 "Invoked form").
M.PREFIX = { ["lw.sh"] = "./lw.sh", ["lw.cmd"] = ".\\lw.cmd", launcher = "./lw.sh", global = "lw" }

--- A command spelled in the invoked form.
--- @param invoked "lw.sh"|"lw.cmd"|"launcher"|"global"|nil
function M.cmd(invoked, rest)
  return (M.PREFIX[invoked or "global"] or "lw") .. " " .. rest
end

--- The one-line "run it" advice; for a launcher that did not name itself, the
--- Windows launcher form is added.
function M.run(invoked, rest)
  if invoked == "launcher" then
    return "run `./lw.sh " .. rest .. "` (`.\\lw.cmd " .. rest .. "` from cmd/PowerShell)"
  end
  return "run `" .. M.cmd(invoked, rest) .. "`"
end

--- How the running lw was invoked, for code running after main.lua (system
--- Lua): main.lua's verdict when there is one, else the environment.
--- @return "lw.sh"|"lw.cmd"|"launcher"|"global"
function M.invoked()
  local g = rawget(_G, "__loomworks_invoked")
  if g then return g end
  local l = os.getenv("LOOMWORKS_LAUNCHER")
  if l == "lw.sh" or l == "lw.cmd" then return l end
  if (os.getenv("LOOMWORKS_PINNED") or "") ~= "" then return "launcher" end
  return "global"
end

--- `git add <files> && git commit`.
function M.commit_cmd(files)
  return "git add " .. table.concat(files, " ") .. " && git commit"
end

--- Parse `git status --porcelain=v1` output into { [path] = state }, `state`
--- one of "untracked", "staged, new", "modified", "deleted". Pure.
function M.parse_porcelain(out)
  local res = {}
  for line in (tostring(out or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local x, y, path = line:match("^(.)(.) (.+)$")
    if x then
      path = path:gsub('^"(.*)"$', "%1")
      local st
      if x == "?" then st = "untracked"
      elseif x == "A" then st = "staged, new"
      elseif x == "D" or y == "D" then st = "deleted"
      else st = "modified" end
      res[path] = st
    end
  end
  return res
end

--- Inspect a pin root. Returns the full picture the status page renders and
--- the findings health lists.
--- @param root string the pin root (the directory holding lw.pin)
--- @param env table see the header
--- @return table result { root, mode, version?, pin?, pin_error?, missing_hashes, launchers, git?, stale?, findings[] }
function M.run_checks(root, env)
  env = env or {}
  local read = env.read or default_read
  local exists = env.exists or default_exists
  local git = env.git or function() return nil end
  local invoked = env.invoked or "global"
  local findings = {}
  local function nag(id, title, remedy, detail, extra)
    local f = { id = id, kind = "suggestion", title = title, remedy = remedy, detail = detail }
    for k, v in pairs(extra or {}) do f[k] = v end
    findings[#findings + 1] = f
    return f
  end
  local function info(id, title, detail)
    findings[#findings + 1] = { id = id, kind = "info", title = title, detail = detail }
  end

  local res = { root = root, launchers = {}, missing_hashes = {}, findings = findings }

  -- ---- mode ---------------------------------------------------------------
  local has = {}
  for _, f in ipairs(launcher.FILES) do has[f] = exists(root .. "/" .. f) end
  if not has["lw.pin"] then
    res.mode = "none"
    return res
  end
  res.mode = (has["lw.sh"] or has["lw.cmd"]) and "launchers" or "pin-only"
  local pin_only = res.mode == "pin-only"
  local repair_args = pin_only and "bootstrap install --pin-only" or "bootstrap install"
  local function repair() return M.run(invoked, repair_args) .. ", which keeps the pin" end
  res.repair = M.cmd(invoked, repair_args)
  local R = { command = res.repair }   -- findings fixed by the repair

  -- ---- the pin --------------------------------------------------------------
  local p, perr = pin.parse(read(root .. "/lw.pin") or "")
  res.pin, res.pin_error = p, (not p) and tostring(perr) or nil
  res.version = p and p.version or nil
  if not p then
    nag("pin-unreadable", "lw.pin cannot be read (" .. tostring(perr) .. ")",
      M.run(invoked, "bootstrap install --version <x.y.z>") .. " to rewrite it - lw help launcher")
  else
    local want = {}
    for _, a in pairs(pin.HOST_ASSETS) do want[#want + 1] = a end
    table.sort(want)
    want[#want + 1] = pin.bundle_asset(p.version)
    for _, a in ipairs(want) do
      if not p.hashes[a] then res.missing_hashes[#res.missing_hashes + 1] = a end
    end
    if #res.missing_hashes > 0 then
      nag("pin-hashes", "lw.pin has no hash for " .. join_list(res.missing_hashes) ..
        " - those platforms cannot run the launcher", repair(), nil, R)
    end
  end

  -- ---- the launchers ----------------------------------------------------------
  for _, kind in ipairs({ "sh", "cmd" }) do
    local name = launcher.KINDS[kind]
    local entry = { present = has[name], generation = "absent" }
    res.launchers[name] = entry
    if not pin_only then
      local bytes = has[name] and read(root .. "/" .. name) or nil
      if not bytes then
        entry.present = false
        nag("launcher-missing", name .. " is missing", repair(), nil, R)
      else
        local c = launcher.classify(kind, bytes, env.sha256)
        entry.generation, entry.releases = c.status, c.releases
        if c.status == "known" then
          local texts = {}
          for _, d in ipairs(c.defects or {}) do texts[#texts + 1] = d.text end
          if c.breaks then
            local broken = {}
            for _, d in ipairs(c.defects) do
              if d.severity == "breaks" then broken[#broken + 1] = d.text end
            end
            nag("launcher-defect", name .. " is the launcher written by lw " .. c.releases .. ": " ..
              join_list(broken), repair(), table.concat(texts, "; "), R)
          else
            info("launcher-older", name .. " is the launcher written by lw " .. c.releases ..
              ", older than this lw's: " .. join_list(texts) .. "; refresh it with " ..
              (repair():gsub("^run ", "")))
          end
        elseif c.status == "unknown" then
          local force = M.cmd(invoked, (pin_only and "bootstrap install --force" or "bootstrap install --force"))
          nag("launcher-unknown", name .. " differs from every launcher lw wrote (local edits?)",
            "if the edits are not intended, `" .. force .. "` restores the generated launcher",
            nil, { command = force, why = "restore the generated " .. name .. " (drops the local edits)" })
        end
      end
    end
  end

  -- ---- git ----------------------------------------------------------------------
  local top = M.toplevel(root, git)
  if top then
    local g = { top = top }
    res.git = g
    local files = pin_only and { "lw.pin" } or launcher.FILES
    local function args(pre)
      local a = {}
      for _, x in ipairs(pre) do a[#a + 1] = x end
      a[#a + 1] = "--"
      for _, f in ipairs(files) do a[#a + 1] = f end
      return a
    end
    -- tracked + modes
    local c1, stage = git(root, args({ "ls-files", "--stage" }))
    local modes = c1 == 0 and launcher.parse_ls_stage(stage) or nil
    g.modes = modes
    -- not committed yet: untracked, staged-only, modified or deleted vs HEAD,
    -- over the pin, the launchers and the metadata files install writes
    local watch = pin_only and { "lw.pin", ".gitattributes" }
      or { "lw.sh", "lw.cmd", "lw.pin", ".gitignore", ".gitattributes" }
    local sargs = { "status", "--porcelain=v1", "--untracked-files=all", "--" }
    for _, f in ipairs(watch) do sargs[#sargs + 1] = f end
    local cs, sout = git(root, sargs)
    if cs == 0 then
      local st = M.parse_porcelain(sout)
      local prefix = ""
      if lower_if_win(root) ~= lower_if_win(top) and under(root, top) then prefix = root:sub(#top + 2) .. "/" end
      local list, names = {}, {}
      for _, f in ipairs(watch) do
        local state = st[prefix .. f] or st[f]
        if state then
          list[#list + 1] = f .. " (" .. state .. ")"
          names[#names + 1] = f
        end
      end
      g.uncommitted = names
      if #names > 0 then
        nag("uncommitted", "not committed yet: " .. join_list(list),
          "commit them: `" .. M.commit_cmd(names) .. "` - contributors and CI only get what is committed",
          nil, { command = M.commit_cmd(names), commit_files = names,
            why = "commit them - contributors and CI only get what is committed" })
      end
    end
    if modes then
      if not pin_only and modes["lw.sh"] and modes["lw.sh"] ~= "100755" then
        nag("exec-bit", "lw.sh is not executable in git (mode " .. modes["lw.sh"] ..
          ") - CI on Linux/macOS cannot run it",
          repair() .. ", or `git update-index --chmod=+x lw.sh`; then commit", nil, R)
      end
    end
    -- attributes (the user's global attributes file does not count)
    local c2, attr = git(root, args({ "-c", "core.attributesFile=", "check-attr", "text", "eol" }))
    if c2 == 0 then
      local a = launcher.parse_check_attr(attr)
      local bad = {}
      for _, f in ipairs(files) do
        if not launcher.attrs_ok(f, a[f]) then bad[#bad + 1] = f end
      end
      g.attrs_bad = bad
      if #bad > 0 then
        nag("attributes", "no line-ending rule for " .. join_list(bad) .. " in .gitattributes", repair(),
          pin_only and "lw.pin needs `text eol=lf`"
          or "lw.sh and lw.pin need `text eol=lf`, lw.cmd `text eol=crlf`", R)
      end
      -- the rules that ARE effective must come from committed content: the
      -- attributes as HEAD's tree gives them (git >= 2.40; older: skipped)
      local good = {}
      for _, f in ipairs(files) do
        if launcher.attrs_ok(f, a[f]) then good[#good + 1] = f end
      end
      if #good > 0 then
        local uncommitted
        local ch = git(root, { "rev-parse", "--verify", "-q", "HEAD" })
        if ch ~= 0 then
          uncommitted = good                        -- no commit yet
        else
          local hargs = { "-c", "core.attributesFile=", "check-attr", "--source", "HEAD", "text", "eol", "--" }
          for _, f in ipairs(good) do hargs[#hargs + 1] = f end
          local ch2, hout = git(root, hargs)
          if ch2 == 0 then
            local ha = launcher.parse_check_attr(hout)
            uncommitted = {}
            for _, f in ipairs(good) do
              if not launcher.attrs_ok(f, ha[f]) then uncommitted[#uncommitted + 1] = f end
            end
          end
        end
        g.attrs_uncommitted = uncommitted
        if uncommitted and #uncommitted > 0 then
          nag("attributes-uncommitted", "line-ending rules for " .. join_list(uncommitted) ..
            " are not committed yet (.gitattributes)",
            "commit them: `" .. M.commit_cmd({ ".gitattributes" }) .. "`",
            "others check the files out with whatever line endings their git config gives",
            { command = M.commit_cmd({ ".gitattributes" }), commit_files = { ".gitattributes" },
              why = "commit the line-ending rules" })
        end
      end
    end
    -- committed + checked-out line endings
    local c3, eol = git(root, args({ "ls-files", "--eol" }))
    if c3 == 0 then
      local e = launcher.parse_ls_eol(eol)
      local committed, checkout = {}, {}
      for _, f in ipairs(files) do
        local r = e[f]
        if r then
          if r.index ~= "lf" and r.index ~= "" and r.index ~= "none" then
            committed[#committed + 1] = f .. " (" .. r.index .. ")"
          end
          local want = launcher.EOL[f]
          if r.worktree ~= "" and r.worktree ~= "none" and r.worktree ~= want then
            checkout[#checkout + 1] = f .. " (" .. r.worktree .. ", needs " .. want .. ")"
          end
        end
      end
      g.eol_committed_bad, g.eol_checkout_bad = committed, checkout
      if #committed > 0 then
        nag("eol-committed", "committed with CR LF line endings: " .. join_list(committed),
          "once the attributes are in place: `git add --renormalize " .. table.concat(files, " ") ..
          "`, then commit", nil,
          { command = "git add --renormalize " .. table.concat(files, " ") .. " && git commit",
            why = "store the files with LF (once the attributes are in place)" })
      end
      if #checkout > 0 then
        nag("eol-checkout", "wrong line endings in this checkout: " .. join_list(checkout) ..
          (pin_only and " - the pin will be misread" or " - the launcher will fail"), repair(), nil, R)
      end
    end
    -- ignore rule: a committed .gitignore of the repo, not a personal one
    if not pin_only then
      local by_repo, src = M.cache_ignored_by_repo(root, top, git)
      if by_repo == true then
        g.ignore = "repo"
      elseif by_repo == false and src then
        g.ignore, g.ignore_source = "uncommitted", src
        nag("ignore", ".nvim/cache/ is ignored only by an uncommitted rule in " .. src ..
          " - others will see downloaded binaries as untracked until it is committed",
          "commit it: `" .. M.commit_cmd({ src }) .. "`", nil,
          { command = M.commit_cmd({ src }), commit_files = { src }, why = "commit the ignore rule" })
      elseif by_repo == false then
        local probe = launcher.CACHE_DIR .. "/lw.marker"
        local c5 = git(root, { "check-ignore", "-q", "--no-index", "--", probe })
        g.ignore = c5 == 0 and "personal" or "none"
        nag("ignore", c5 == 0
          and ".nvim/cache/ is ignored only by an uncommitted or personal rule (your global gitignore or .git/info/exclude) - others will see downloaded binaries as untracked"
          or ".nvim/cache/ is not ignored - downloaded binaries show as untracked",
          repair(), nil, R)
      end
    end
  end

  -- ---- stale cached binaries ------------------------------------------------------
  if res.version and env.stale then
    local n, bytes = env.stale(root, res.version)
    if n and n > 0 then
      res.stale = { n = n, bytes = bytes }
      info("stale-cache", string.format("%d old pinned binar%s in .nvim/cache (%.1f MB) - removed by the next %s",
        n, n == 1 and "y" or "ies", (bytes or 0) / 1048576, M.cmd(invoked, "bootstrap install")))
    end
  end

  if #findings == 0 then
    res.healthy = true
    if pin_only then
      info("ok", "lw " .. tostring(res.version) .. " pinned (pin only, no launchers); lw.pin line endings ok")
    else
      info("ok", "lw " .. tostring(res.version) .. " pinned; lw.sh / lw.cmd current, modes and line endings ok")
    end
  end
  -- actionable first, then informational (stable within each kind)
  local sorted = {}
  for _, f in ipairs(findings) do if f.kind == "suggestion" then sorted[#sorted + 1] = f end end
  for _, f in ipairs(findings) do if f.kind ~= "suggestion" then sorted[#sorted + 1] = f end end
  res.findings = sorted
  return res
end

return M

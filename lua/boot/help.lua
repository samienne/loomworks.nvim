-- Host-level help: what `lw help` / `-h` / `--help` / `lw <cmd> --help` print
-- when no loomworks system Lua is available (a release host before its first
-- `lw self-update`). The full help lives in the bundle's CLI; without it the
-- host still documents its own commands — otherwise a user could not even
-- learn what `install` / `self-update` do. With a bundle (or a fused/dev
-- build), the CLI's help dispatcher answers instead and this is unused.
--
-- Pure: builds text, prints nothing. Keep the per-command text short and in
-- agreement with the CLI's `lw help <command>` topics.

local M = {}

M.HINT = "Full help needs the loomworks bundle: run `lw self-update`."

M.TOPICS = {
  version = [[lw version

Print this lw binary's release version (with its capability version), the
system-Lua source and bundle in use (`none installed` until the first
`lw self-update`), and the update channel.]],

  ["self-update"] = [[lw self-update [--force] [--channel <stable|unstable>] [--no-host]

Download the current release, verify its signature and hashes against the key
built into lw, and activate its bundle; then replace this lw binary with the
same release's (verified before the swap), when that release is newer.

  --force              reinstall the bundle even if that version is present
  --channel <name>     `stable` (default) or `unstable`, for this run only
  --no-host            update only the bundle; leave the lw binary as it is

Releases come from LOOMWORKS_RELEASE_URL, else the `release-url` setting, else
the built-in default (a local directory works as an offline mirror).]],

  install = [[lw install [-y] [--no-modify-path] [--no-bundle] [--dry-run]

Install this lw binary for the current user, make sure its location is on
PATH, and fetch the first release bundle. No admin required.

  location   Windows: %LOCALAPPDATA%\Microsoft\WindowsApps\lw.exe (on PATH)
             Unix:    ~/.local/bin/lw

  -y, --yes          replace an existing lw and apply PATH changes without
                     prompting (needed with --no-input / in CI)
  --no-modify-path   install the binary but never touch PATH / shell rc
  --no-bundle        skip fetching the release bundle (do `lw self-update` later)
  --dry-run          print what would happen, change nothing

If a different lw is already installed there, install says what it is and asks
before replacing it; without a terminal it refuses unless -y is given.]],

  bootstrap = [[lw bootstrap [--version <x.y.z>]

Write a repo-local launcher + version pin (lw.sh, lw.cmd, lw.pin) at the repo
root, so contributors and CI run a fixed, verified lw without a global install.
The pin records hashes from the release's signed SHA256SUMS.

  --version <x.y.z>   pin this release instead of the running host's version]],

  update = [[lw update [--version <x.y.z>]

Repoint an existing lw.pin (written by `lw bootstrap`) at a release — the
newest one, or the one --version names — re-reading its signed hashes.

  --version <x.y.z>   pin this release instead of the newest]],
}

local USAGE = [[lw — loomworks standalone runner

No loomworks release bundle is installed, so only the lw binary's own commands
are available:

  version        this lw's version, source, bundle, and update channel
  self-update [--force] [--channel <stable|unstable>] [--no-host]
                 download + verify the current release (bundle + lw binary)
  install [-y] [--no-modify-path] [--no-bundle] [--dry-run]
                 install this lw for the current user + fetch the bundle
  bootstrap [--version <x.y.z>]
                 write a repo-local launcher + version pin (lw.sh/.cmd/.pin)
  update [--version <x.y.z>]
                 repoint lw.pin at a release

`lw <command> --help` shows details for one of these.]]

--- The general host usage, plus the bundle hint. `cmd` (optional) is a
--- non-host command the user asked about — say it needs the bundle.
--- @param cmd string|nil
--- @return string
function M.usage(cmd)
  local lead = cmd and ("`lw " .. cmd .. "` is provided by the loomworks bundle, " ..
    "which is not installed.\n\n") or ""
  return lead .. USAGE .. "\n\n" .. M.HINT
end

--- Help for `topic`: its host help when it is a host command, else the usage.
--- @param topic string|nil
--- @return string
function M.text(topic)
  if topic and M.TOPICS[topic] then return M.TOPICS[topic] .. "\n\n" .. M.HINT end
  return M.usage(topic)
end

--- The help an argument list asks for, or nil when it asks for none. Help is
--- `lw help [<command>]`, or `--help` / `-h` anywhere before a `--` (whose
--- tail belongs to a build tool or program); leading global flags are skipped.
--- @param args string[] the arguments after the host's own flags
--- @return string|nil text
function M.for_args(args)
  local words, flag = {}, false
  for _, v in ipairs(args) do
    if v == "--" then break end
    if v == "--help" or v == "-h" then
      flag = true
    elseif type(v) == "string" and v:sub(1, 1) ~= "-" then
      words[#words + 1] = v
    end
  end
  if words[1] == "help" then return M.text(words[2]) end
  if flag then return M.text(words[1]) end
  return nil
end

return M

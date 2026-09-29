-- Host-level help: the help of the HOST's own commands (version, self-update,
-- install, bootstrap and the deprecated update) — the single source of that text (spec §16.7):
-- the bundle's CLI reuses these topics for `lw help <host command>`, so the
-- answer is the same with or without a bundle. Also what `lw help` / `-h` /
-- `--help` / `lw <cmd> --help` print when no loomworks system Lua is available
-- (a release host before its first `lw self-update`): the host documents its
-- own commands in full and, for any other command, says full help needs the
-- bundle — naming the repo launcher in a pinned repository.
--
-- Pure: builds text, prints nothing. ASCII only (it prints before system Lua
-- can set the console encoding, §16.7).

local M = {}

M.HINT = "Full help needs the loomworks bundle: run `lw self-update`."

-- In a repository with a version pin, the launcher runs the pinned release
-- (and provisions its bundle), so that is where full help is.
M.PINNED_HINT = "This repository pins lw: run it through the launcher for full help:\n" ..
  "  ./lw.sh help <command>     (Linux, macOS, Git Bash)\n" ..
  "  .\\lw.cmd help <command>    (cmd, PowerShell)"

M.TOPICS = {
  version = [[lw version

Print the host's release version (with its capability version in
parentheses; `dev build` for a host built from a source tree, `unknown
release` for a release host without an embedded version), the active
bundle, the update channel, and which system-Lua source is active - one of:
  dev      a checked-out tree (--dev / default-source=dev / LOOMWORKS_LUA)
  release  a verified release bundle (lua-<ver>/ under the data dir)
  fused    the copy bundled into the lw binary (a full-fused/dev build)
  none     nothing installed yet - the bundle reads `none installed (run
           `lw self-update`)`; a downloaded release binary starts this way
Run through a repo launcher (./lw.sh, .\lw.cmd) it also names the lw.pin it
runs under.

A host command, handled by the lw binary itself.]],

  install = [[lw install [-y] [--no-modify-path] [--no-bundle] [--dry-run]

Install the running lw binary for the current user and make it usable.
It copies itself to a per-user location, ensures that location
is on PATH, and fetches the first release bundle. No admin required.

  location   Windows: %LOCALAPPDATA%\Microsoft\WindowsApps\lw.exe (on PATH)
             Unix:    ~/.local/bin/lw

  -y, --yes          replace an existing lw and apply PATH changes without
                     prompting (needed with --no-input / in CI)
  --no-modify-path   install the binary but never touch PATH / shell rc
  --no-bundle        skip fetching the release bundle (do `lw self-update` later)
  --dry-run          print what would happen, change nothing

If a different lw is already installed at that location, install says what it
is (a development build or its release, size, date) and asks before replacing
it; without a terminal (--no-input, LW_NO_INPUT, CI) it refuses unless -y is
given. An identical binary is reported as already installed.

Typical bootstrap (download, verify by hash, then let the verified binary
install itself) - from the release page for your platform, e.g.:

  curl -fsSL <url>/lw-linux-x86_64 -o /tmp/lw \
    && echo "<sha256>  /tmp/lw" | sha256sum -c \
    && chmod +x /tmp/lw && /tmp/lw install

For a repository, `lw bootstrap install` (a committed, pinned launcher)
needs no install at all - see `lw help bootstrap`.

A host command (handled by lw itself).]],

  ["self-update"] = [[lw self-update [--force] [--channel <stable|unstable>] [--no-host]

Download the current release, verify its signature and hashes, and activate
it. Fetches manifest.json + manifest.json.sig, checks the
signature against the key built into lw, downloads the bundle, verifies its
SHA-256 against the (trusted) manifest, then extracts it into a new
lua-<version>/ under the data dir - never overwriting a running copy. Integrity
rests on the signature, not the transport, so it is safe behind a proxy;
set LOOMWORKS_INSECURE_TLS=1 for TLS-intercepting proxies.

Then it replaces the lw binary itself with the same release's host,
when that release is newer than the running host's (it never
downgrades the binary, e.g. after a channel switch to stable): the release's
SHA256SUMS signature is checked against the built-in key and the downloaded
binary against its hash BEFORE the installed binary is touched (never relaxed,
even behind a proxy); the swap is atomic and any failure leaves the old binary
in place. If the binary's location is not writable (a system or
package-managed install) it warns with the manual steps and still succeeds.
A pinned (lw.pin) or development host never replaces itself.

If the release needs a newer lw binary than this one, the binary is updated
first and self-update exits non-zero asking you to re-run it for the bundle.

  --force              reinstall the bundle even if that version is already
                       present (does NOT force a reinstall of the lw binary -
                       that is replaced only by a newer release)
  --channel <name>     `stable` (default) or `unstable` for this run only
  --no-host            update only the bundle; leave the lw binary as it is

Update channel: `stable` follows the newest full release;
`unstable` includes pre-releases, for testing ahead of a stable cut. Both are
verified identically - `unstable` never means less checking. Precedence:
--channel > LOOMWORKS_CHANNEL > the `channel` setting > stable. Persist a
default with `lw settings set channel unstable`.

Source of releases: LOOMWORKS_RELEASE_URL, else the `release-url` settings key,
else the built-in default. A local directory works as an offline mirror and is
used as-is (it supersedes the channel - no release-API query).
Not applicable to a development source. A host command (handled by lw itself).]],

  bootstrap = [==[lw bootstrap [--json] [--check]
lw bootstrap install [--version <x.y.z> | --latest [--channel <name>]] [--pin-only] [--force]
lw bootstrap upgrade [--channel <name>] [--pin-only] [--force]

Pin this repository to a fixed, verified lw release, with committed launchers
(lw.sh, lw.cmd) so contributors and CI need no install at all - or just the pin
(lw.pin), which a globally installed lw honours.

  (no sub-command)  show the pin, the launchers and the repository metadata,
                    then what you can do. Writes nothing. Works outside a git
                    repository and outside a loomworks workspace.
     --json           one JSON document instead of the page
     --check          exit 1 when there is no pin or any finding needs action
                      (a CI guard); without it the page always exits 0
  install           make the repository correct, from any start: no pin, pin
                    only, stale or edited launchers, missing rules. Idempotent -
                    a second run changes nothing.
     --version <x.y.z>  pin this release
     --latest           pin the newest release on your update channel (never
                        moves the pin backwards; --channel stable|unstable for
                        this run)
     --pin-only         write only lw.pin (and its .gitattributes rule): no
                        launcher scripts; launchers already there are left alone
     --force            replace an lw.sh / lw.cmd that is not a launcher lw wrote
                        (by default such a file - e.g. with local edits - is kept)
  upgrade           the same as `install --latest`: move the pin to the newest
                    release

Which version install pins: --version / --latest when given; otherwise the
pinned version (so plain `install` in a pinned repository only repairs - it
never moves the pin); in a repository with no pin, this lw's own release (a
development build has none: pass --version or --latest). The hashes come from
the release's SIGNED SHA256SUMS (the signature is checked against the key built
into lw before any hash is trusted), and the release is checked to be
fetchable before anything is written.

What install writes: lw.pin (the version and the SHA-256 of every lw binary and
of the release bundle), lw.sh and lw.cmd, and the repository metadata:
  .gitignore      .nvim/cache/ ignored - appended unless a committed rule of the
                  repo already covers it (your personal gitignore does not
                  count: teammates and CI do not have it)
  .gitattributes  lw.sh and lw.pin `text eol=lf`, lw.cmd `text eol=crlf`,
                  appended when missing
  exec bit        in a git repo that does not track file modes (Windows), lw.sh
                  is staged as executable (mode 100755) - the only file lw
                  stages; commit the rest yourself
It reports only what it changed (`lw.pin already at X - no changes` when
nothing did) and removes old pinned lw binaries from .nvim/cache/.

Which launcher: `./lw.sh <cmd>` in a POSIX shell - Linux, macOS, and Git Bash /
MSYS2 on Windows; `.\lw.cmd <cmd>` in cmd.exe or PowerShell (the `.\` matters: a
bare `lw.cmd` can run another lw.cmd found on PATH). The launcher downloads the
pinned lw binary into .nvim/cache/ (quietly, retrying a failed download up to
3 times), verifies its sha256 against the pin, and runs it - that lw then
provisions (downloads + verifies) the pinned bundle into your per-user data
dir, never into the repository. So a clean checkout goes from `./lw.sh build`
to building, reproducibly. `./lw.sh version` names the pin it runs.

Pin only (--pin-only): no scripts are committed; a globally installed lw runs
the pinned release (fetching + verifying it) for build, run, test, configure
and clean, so everyone - CI included - needs lw installed (`lw help install`).
`lw bootstrap` and `lw health` then treat the missing launchers as intended.
A later plain `lw bootstrap install` adds the launchers, keeping the pin. The
editor plugin is not governed by the pin.

Upgrading through the launcher: `./lw.sh bootstrap upgrade` needs no global lw -
it runs as the currently pinned release. That release writes ITS launchers, so
after moving to a newer release run `./lw.sh bootstrap install` once more to
take the new release's launchers (upgrade says so). A global lw can run
`lw bootstrap upgrade` directly too.

Proxies: the launcher honors HTTPS_PROXY/HTTP_PROXY. `--insecure` (or
LOOMWORKS_INSECURE=1) relaxes TLS for an intercepting proxy - safe only because
the sha256 check is independent and always enforced. `--verify` additionally
runs `gh attestation verify` when gh is present (skipped with a note otherwise).
Air-gapped: point LOOMWORKS_RELEASE_URL at a local mirror directory.

Bypass the pin with `--no-pin`, or LOOMWORKS_LW=<path> to run a specific binary
(the dev / test-at-head override). `lw health` checks the launcher files too
(`lw help launcher`). Before lw 0.1.37 plain `lw bootstrap` wrote the files; it
now only reports - use `lw bootstrap install`. A host command (handled by lw
itself); never redirected by an existing pin.]==],

  update = [==[lw update [--version <x.y.z>] [--force]      (deprecated)

`lw update` is deprecated and will be removed in a later release. It still
works, printing a one-line notice, and does exactly what these do:

  lw update                    ->  lw bootstrap install --latest   (= lw bootstrap upgrade)
  lw update --version <x.y.z>  ->  lw bootstrap install --version <x.y.z>
  --force                      ->  the same --force

Like before it needs a repository that already has an lw.pin. `--latest` now
follows your update channel (`lw help self-update`); on the default stable
channel nothing changes. See `lw help bootstrap`.]==],
}

local USAGE = [[lw - loomworks standalone runner

No loomworks release bundle is installed, so only the lw binary's own commands
are available:

  version        this lw's version, source, bundle, and update channel
  self-update [--force] [--channel <stable|unstable>] [--no-host]
                 download + verify the current release (bundle + lw binary)
  install [-y] [--no-modify-path] [--no-bundle] [--dry-run]
                 install this lw for the current user + fetch the bundle
  bootstrap [--json] [--check]
                 this repo's lw pin + launchers: status and what to do
  bootstrap install [--version <x.y.z> | --latest] [--pin-only] [--force]
                 pin this repo to an lw release (lw.pin, lw.sh, lw.cmd)
  bootstrap upgrade
                 move the pin to the newest release

`lw <command> --help` shows details for one of these.]]

--- The note on where full help is: the repo launcher in a pinned repository,
--- else the bundle acquisition.
--- @param ctx? { pinned?: boolean }
--- @return string
function M.hint(ctx)
  return (ctx and ctx.pinned) and M.PINNED_HINT or M.HINT
end

--- The general host usage, plus the full-help note. `cmd` (optional) is a
--- non-host command the user asked about — say it needs the bundle.
--- @param cmd string|nil
--- @param ctx? { pinned?: boolean }
--- @return string
function M.usage(cmd, ctx)
  local lead = cmd and ("`lw " .. cmd .. "` is provided by the loomworks bundle, " ..
    "which is not installed.\n\n") or ""
  return lead .. USAGE .. "\n\n" .. M.hint(ctx)
end

--- Help for `topic`: a host command's complete help (no bundle note — it IS
--- the full help), else the usage with the full-help note.
--- @param topic string|nil
--- @param ctx? { pinned?: boolean }
--- @return string
function M.text(topic, ctx, sub)
  if topic and M.TOPICS[topic] then return M.subcommand(topic, sub) or M.TOPICS[topic] end
  return M.usage(topic, ctx)
end

--- Only `sub`'s part of a host command's help (spec §16.7): its entry — a line
--- `  <sub> ...` indented two, with its continuation lines indented three or
--- more — plus a pointer to the whole. nil when the help does not document it.
--- The same shape the CLI's sub-command help uses.
--- @param topic string
--- @param sub string|nil
--- @return string|nil
function M.subcommand(topic, sub)
  local text = M.TOPICS[topic]
  if not text or type(sub) ~= "string" or not sub:match("^%a[%w_-]*$") then return nil end
  local lines = {}
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
  local entry
  for i, l in ipairs(lines) do
    if l:match("^  %S") and l:sub(3, 2 + #sub) == sub
        and (#l == 2 + #sub or l:sub(3 + #sub, 3 + #sub):match("%s")) then
      entry = { "lw " .. topic .. " " .. (l:sub(3):gsub("%s+$", "")) }
      for j = i + 1, #lines do
        local c = lines[j]
        if c:match("^%s*$") or not c:match("^   ") then break end
        entry[#entry + 1] = c
      end
      break
    end
  end
  if not entry then return nil end
  entry[#entry + 1] = ""
  entry[#entry + 1] = "`lw help " .. topic .. "` for the whole command."
  return table.concat(entry, "\n")
end

--- The help an argument list asks for, or nil when it asks for none. Help is
--- `lw help [<command>]`, or `--help` / `-h` anywhere before a `--` (whose
--- tail belongs to a build tool or program); leading global flags are skipped.
--- @param args string[] the arguments after the host's own flags
--- @param ctx? { pinned?: boolean } whether a version pin was found
--- @return string|nil text
function M.for_args(args, ctx)
  local words, flag = {}, false
  for _, v in ipairs(args) do
    if v == "--" then break end
    if v == "--help" or v == "-h" then
      flag = true
    elseif type(v) == "string" and v:sub(1, 1) ~= "-" then
      words[#words + 1] = v
    end
  end
  if words[1] == "help" then return M.text(words[2], ctx, words[3]) end
  if flag then return M.text(words[1], ctx, words[2]) end
  return nil
end

return M

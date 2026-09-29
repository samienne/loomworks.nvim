-- Host-level help: the help of the HOST's own commands (version, self-update,
-- install, bootstrap, update) — the single source of that text (spec §16.7):
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

For a repository, `lw bootstrap` (a committed, pinned launcher) needs no
install at all - see `lw help bootstrap`.

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

  bootstrap = [[lw bootstrap [--version <x.y.z>] [--force]

Install a repo-local launcher + version pin so contributors and CI run a fixed,
verified lw without a prior global install. Writes three committed files at the
repo root - lw.sh, lw.cmd and lw.pin - and makes sure the repository carries
them correctly:
  .gitignore      .nvim/cache/ ignored - appended unless a committed rule of the
                  repo already covers it (your personal gitignore does not
                  count: teammates and CI do not have it)
  .gitattributes  lw.sh and lw.pin `text eol=lf`, lw.cmd `text eol=crlf`,
                  appended when missing
  exec bit        in a git repo that does not track file modes (Windows), lw.sh
                  is staged as executable (mode 100755) - the only file
                  bootstrap stages; commit the rest yourself

The pin records the release version and the SHA-256 of every host binary and of
the release bundle, taken from that release's SIGNED SHA256SUMS (its signature
is verified against the key built into lw before any hash is trusted). Defaults
to this host's release version; pass --version to pin a different release (a
development build has no release version, so it needs --version).

  --version <x.y.z>   pin this release instead of the running host's version
  --force             replace an lw.sh / lw.cmd that is not a launcher lw wrote
                      (by default such a file - e.g. with local edits - is kept)

Which launcher: `./lw.sh <cmd>` in a POSIX shell - Linux, macOS, and Git Bash /
MSYS2 on Windows; `.\lw.cmd <cmd>` in cmd.exe or PowerShell (the `.\` matters: a
bare `lw.cmd` can run another lw.cmd found on PATH). The launcher downloads the
pinned host binary into .nvim/cache/ (quietly, retrying a failed download up to
3 times), verifies its sha256 against the pin, and runs it - the host then
provisions (downloads + verifies) the pinned bundle into your per-user data dir,
never into the repository. So a clean checkout goes from `./lw.sh build` to
building, reproducibly. `./lw.sh version` names the pin it runs.

Proxies: the launcher honors HTTPS_PROXY/HTTP_PROXY. `--insecure` (or
LOOMWORKS_INSECURE=1) relaxes TLS for an intercepting proxy - safe only because
the sha256 check is independent and always enforced. `--verify` additionally
runs `gh attestation verify` when gh is present (skipped with a note otherwise).
Air-gapped: point LOOMWORKS_RELEASE_URL at a local mirror directory.

A globally-installed `lw` also honors the pin: for build/run/test/clean it runs
the pinned release (fetching + verifying it), unless the pin matches itself.
Bypass with `--no-pin`, or LOOMWORKS_LW=<path> to run a specific binary (the
dev / test-at-head override). `lw health` checks the launcher files (`lw help
launcher`). A host command (handled by lw itself).]],

  update = [[lw update [--version <x.y.z>] [--force]

Repoint lw.pin at a target release (default: the latest), rewriting its version
and per-artifact SHA-256 hashes from that release's signed SHA256SUMS. It also
refreshes lw.sh / lw.cmd when they differ from this lw's launchers and applies
the same .gitignore / .gitattributes / exec-bit steps and --force rule as
`lw bootstrap`. Validates the target release is fetchable before touching the
pin, so a bad version fails cleanly. Prints only what changed - `lw.pin already
at X - no changes`, or `lw.pin: A -> B` plus each file it rewrote - and removes
old pinned binaries from .nvim/cache/. Run it in a repo set up with
`lw bootstrap`.

  --version <x.y.z>   pin this release instead of the latest; the CURRENT pin's
                      version repairs the launcher files without moving the pin
  --force             replace an lw.sh / lw.cmd that is not a launcher lw wrote

Through the launcher - `./lw.sh update` (or `.\lw.cmd update`) - no global lw is
needed: it runs as the currently pinned release. That release writes ITS
launchers, so after moving to a newer release run `./lw.sh update` once more to
take the new release's launchers (update says so). A global lw - a release or a
build from source - can run `lw update` directly too. A host command (handled by
lw itself); like bootstrap it is never redirected by an existing pin.]],
}

local USAGE = [[lw - loomworks standalone runner

No loomworks release bundle is installed, so only the lw binary's own commands
are available:

  version        this lw's version, source, bundle, and update channel
  self-update [--force] [--channel <stable|unstable>] [--no-host]
                 download + verify the current release (bundle + lw binary)
  install [-y] [--no-modify-path] [--no-bundle] [--dry-run]
                 install this lw for the current user + fetch the bundle
  bootstrap [--version <x.y.z>] [--force]
                 write a repo-local launcher + version pin (lw.sh/.cmd/.pin)
  update [--version <x.y.z>] [--force]
                 repoint lw.pin at a release

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
function M.text(topic, ctx)
  if topic and M.TOPICS[topic] then return M.TOPICS[topic] end
  return M.usage(topic, ctx)
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
  if words[1] == "help" then return M.text(words[2], ctx) end
  if flag then return M.text(words[1], ctx) end
  return nil
end

return M

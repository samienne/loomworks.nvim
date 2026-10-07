#!/usr/bin/env bash
# Pin the plugin to a release built by the release workflow's build stage
# (spec 19.16 "Plugin pin"; the procedure is in ARCHITECTURE.md "Cutting a release or beta").
#
#   pin.sh <version> [--published] [--no-interface-check]
#
# Downloads the DRAFT release v<version>'s SHA256SUMS, SHA256SUMS.sig and
# lw-<version>-descriptor.json (gh CLI; drafts need an authenticated gh),
# verifies the signature with keys/loomworks-release.pub.pem, checks the
# descriptor offers the interfaces the plugin needs and writes
# lua/loomworks/provision/pinned.lua (scripts/release/pin.lua). The checkout
# must be at the draft's build commit: the pin commit goes directly on top of
# it, and the tag-push run publishes the draft only when that commit changes
# nothing but pinned.lua.
#
#   --published           pin an already published release (no build-commit
#                         check); for seeding the pin, never for a release.
#   --no-interface-check  skip the descriptor check (a release published
#                         before descriptors existed); never for a release.
set -euo pipefail

version="${1:?usage: pin.sh <version> [--published] [--no-interface-check]}"
shift
published=0
extra=()
for a in "$@"; do
  case "$a" in
    --published) published=1 ;;
    --no-interface-check) extra+=(--no-interface-check) ;;
    *) echo "pin.sh: unknown option $a" >&2; exit 2 ;;
  esac
done

repo="$(cd "$(dirname "$0")/../.." && pwd)"
slug="${REPO_SLUG:-samienne/loomworks.nvim}"
tag="v$version"

printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
  || { echo "pin.sh: version '$version' is not <n>.<n>.<n>[-pre]" >&2; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
desc="lw-$version-descriptor.json"
if [ "$published" = 0 ]; then
  # Exactly one draft with tag_name $tag, found by listing the releases
  # (scripts/release/draft.sh; zero or several fail). Its id drives the download.
  info="$(bash "$repo/scripts/release/draft.sh" find "$slug" "$tag")" || exit 1
  id="$(printf '%s' "$info" | cut -f1)"
  build="$(printf '%s' "$info" | cut -f2)"
  head="$(git -C "$repo" rev-parse HEAD)"
  [ "$head" = "$build" ] || {
    echo "pin.sh: HEAD is $head but the draft $tag was built from $build; check out $build first" >&2; exit 1; }
  [ -z "$(git -C "$repo" status --porcelain)" ] || { echo "pin.sh: the working tree is not clean" >&2; exit 1; }
  bash "$repo/scripts/release/draft.sh" download "$slug" "$id" "$T" SHA256SUMS SHA256SUMS.sig
  bash "$repo/scripts/release/draft.sh" download "$slug" "$id" "$T" "$desc" 2>/dev/null \
    || echo "pin.sh: $tag publishes no $desc" >&2
else
  gh release download "$tag" -R "$slug" -D "$T" -p SHA256SUMS -p SHA256SUMS.sig \
    || { echo "pin.sh: no published release $tag on $slug" >&2; exit 1; }
  gh release download "$tag" -R "$slug" -D "$T" -p "$desc" 2>/dev/null \
    || echo "pin.sh: $tag publishes no $desc" >&2
fi

nvim -l "$repo/scripts/release/pin.lua" write "$version" "$T" ${extra[@]+"${extra[@]}"}

if [ "$published" = 0 ]; then
  cat <<EOF

Next (see ARCHITECTURE.md "Cutting a release or beta"):
  git commit -m "Pin lw $version" -- lua/loomworks/provision/pinned.lua
  git tag -a $tag -m "$tag"
  git push github $tag              # ONLY the tag first
The tag push publishes the draft once the pin verifies (release.yml, stage publish).
Only after that run succeeded: push the branch to github, branch and tag to
gitcode, and (beta) fast-forward unstable on both. A failed gate: delete the
tag (git push github :refs/tags/$tag; git tag -d $tag), fix, re-tag.
EOF
fi

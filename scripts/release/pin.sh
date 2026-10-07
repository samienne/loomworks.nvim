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

info="$(gh release view "$tag" -R "$slug" --json isDraft,targetCommitish -q '[.isDraft, .targetCommitish] | @tsv')" \
  || { echo "pin.sh: no release $tag on $slug (dispatch the release workflow with stage=build first)" >&2; exit 1; }
draft="$(printf '%s' "$info" | cut -f1)"
build="$(printf '%s' "$info" | cut -f2)"
if [ "$published" = 0 ]; then
  [ "$draft" = "true" ] || { echo "pin.sh: $tag is already published; pin a draft (or --published to seed)" >&2; exit 1; }
  head="$(git -C "$repo" rev-parse HEAD)"
  [ "$head" = "$build" ] || {
    echo "pin.sh: HEAD is $head but the draft $tag was built from $build; check out $build first" >&2; exit 1; }
  [ -z "$(git -C "$repo" status --porcelain)" ] || { echo "pin.sh: the working tree is not clean" >&2; exit 1; }
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
gh release download "$tag" -R "$slug" -D "$T" -p SHA256SUMS -p SHA256SUMS.sig
gh release download "$tag" -R "$slug" -D "$T" -p "lw-$version-descriptor.json" 2>/dev/null \
  || echo "pin.sh: $tag publishes no lw-$version-descriptor.json" >&2

nvim -l "$repo/scripts/release/pin.lua" write "$version" "$T" ${extra[@]+"${extra[@]}"}

if [ "$published" = 0 ]; then
  cat <<EOF

Next (see ARCHITECTURE.md "Cutting a release or beta"):
  git commit -m "Pin lw $version" -- lua/loomworks/provision/pinned.lua
  git tag -a $tag -m "$tag"
  git push github HEAD:<branch> $tag && git push gitcode HEAD:<branch> $tag
The tag push publishes the draft once the pin verifies (release.yml, stage publish).
EOF
fi

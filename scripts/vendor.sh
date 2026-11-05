#!/usr/bin/env bash
# scripts/vendor.sh — the code this plugin shares with loomworks (the `lw`
# CLI and workspace daemon, samienne/loomworks), vendored byte-identical.
#
#   scripts/vendor.sh <loomworks checkout> <tag>
#       Copy every vendored file from <tag> of the checkout (the committed
#       blob, `git show <tag>:<path>`: never the checkout's working tree, so
#       its line-ending settings do not matter), remove files under a vendored
#       directory that <tag> no longer has, and write VENDOR.MANIFEST: the
#       tag, its commit and the sha256 of every file.
#
#   scripts/vendor.sh --check
#       Verify the vendored files against VENDOR.MANIFEST: every listed file
#       is present with its sha256, and a vendored directory holds no file
#       the manifest does not list. Exit 1 on any mismatch.
#
# Never edit a vendored file here: change it in loomworks, tag, re-vendor.
# The files are `-text` in .gitattributes, so a checkout keeps their bytes.
set -euo pipefail
export LC_ALL=C

# What is vendored, relative to both repositories' roots. An entry ending in
# `/` is a directory: every file under it at the tag.
VENDORED=(
    # The wire protocol: its documents, schemas and transcripts.
    spec/protocol/
    # Protocol helpers: the envelope and output bytes (runtime); schema,
    # documents, schema_check and the conformance engine (tests).
    lua/loomworks/proto/bytes.lua
    lua/loomworks/proto/envelope.lua
    lua/loomworks/proto/schema.lua
    lua/loomworks/proto/documents.lua
    lua/loomworks/proto/schema_check.lua
    lua/loomworks/proto/conformance.lua
    # State shapes both sides build or read.
    lua/loomworks/lsp_config.lua
    lua/loomworks/sha256.lua
    lua/loomworks/test_state.lua
    lua/loomworks/device_log_records.lua
    lua/loomworks/root_finder.lua
    lua/loomworks/description.lua
)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/VENDOR.MANIFEST"

die() { echo "vendor.sh: $*" >&2; exit 1; }

# sha256 of the given files (paths relative to the root), `<sum>  <path>`
# lines (a binary-mode `<sum> *<path>`, as Git Bash prints, normalized).
sha256_lines() {
    local tool=(sha256sum)
    command -v sha256sum >/dev/null 2>&1 || tool=(shasum -a 256)
    (cd "$ROOT" && "${tool[@]}" -- "$@") | sed -E 's/^([0-9a-f]{64}) [ *]/\1  /'
}

# Every file of the local tree under the vendored directories.
local_dir_files() {
    local e
    for e in "${VENDORED[@]}"; do
        [[ "$e" == */ ]] || continue
        [ -d "$ROOT/$e" ] || continue
        (cd "$ROOT" && find "${e%/}" -type f) | sort
    done
}

check() {
    [ -f "$MANIFEST" ] || die "no VENDOR.MANIFEST"
    local bad=0 listed path
    listed="$(grep -E '^[0-9a-f]{64}  ' "$MANIFEST" | cut -c67- | sort)"
    [ -n "$listed" ] || die "VENDOR.MANIFEST lists no files"
    local present=()
    while IFS= read -r path; do
        if [ -f "$ROOT/$path" ]; then present+=("$path"); else echo "missing: $path" >&2; bad=1; fi
    done <<< "$listed"
    if [ "${#present[@]}" -gt 0 ]; then
        local differs
        # A manifest line that the files' current sums do not reproduce.
        differs="$(comm -23 <(grep -E '^[0-9a-f]{64}  ' "$MANIFEST" | sort) \
            <(sha256_lines "${present[@]}" | sort) | cut -c67-)"
        if [ -n "$differs" ]; then printf 'differs: %s\n' $differs >&2; bad=1; fi
    fi
    local extra
    extra="$(comm -13 <(printf '%s\n' "$listed") <(local_dir_files))"
    if [ -n "$extra" ]; then
        printf 'not in VENDOR.MANIFEST: %s\n' $extra >&2; bad=1
    fi
    if [ "$bad" -ne 0 ]; then
        die "vendored files do not match VENDOR.MANIFEST (re-run scripts/vendor.sh <loomworks> <tag>)"
    fi
    echo "vendored files match VENDOR.MANIFEST ($(printf '%s\n' "$listed" | wc -l | tr -d ' ') files, $(sed -n 's/^tag //p' "$MANIFEST"))"
}

vendor() {
    local src="$1" tag="$2"
    git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || die "$src is not a git checkout"
    local commit
    commit="$(git -C "$src" rev-parse --verify --quiet "$tag^{commit}")" || die "no tag $tag in $src"

    local files=() e f
    for e in "${VENDORED[@]}"; do
        if [[ "$e" == */ ]]; then
            local before=${#files[@]}
            while IFS= read -r f; do files+=("$f"); done \
                < <(git -C "$src" ls-tree -r --name-only "$commit" -- "$e")
            [ "${#files[@]}" -gt "$before" ] || die "$tag has no $e"
        else
            git -C "$src" cat-file -e "$commit:$e" 2>/dev/null || die "$tag has no $e"
            files+=("$e")
        fi
    done

    # Files the tag no longer has under a vendored directory.
    local f_old
    while IFS= read -r f_old; do
        [ -n "$f_old" ] || continue
        local keep=0
        for f in "${files[@]}"; do [ "$f" = "$f_old" ] && { keep=1; break; }; done
        [ "$keep" -eq 1 ] || rm -- "$ROOT/$f_old"
    done < <(local_dir_files)

    for f in "${files[@]}"; do
        mkdir -p "$(dirname "$ROOT/$f")"
        git -C "$src" show "$commit:$f" > "$ROOT/$f"
    done

    {
        echo "# Files vendored from loomworks (samienne/loomworks), byte-identical."
        echo "# Written by scripts/vendor.sh; verify with scripts/vendor.sh --check."
        echo "# Do not edit: change the file in loomworks, tag, and re-vendor."
        echo "source samienne/loomworks"
        echo "tag $tag"
        echo "commit $commit"
        # shellcheck disable=SC2046  # vendored paths hold no spaces
        sha256_lines $(printf '%s\n' "${files[@]}" | sort)
    } > "$MANIFEST"
    echo "vendored ${#files[@]} files from $tag ($commit)"
}

case "${1:-}" in
    --check) [ $# -eq 1 ] || die "usage: vendor.sh --check"; check ;;
    ""|-h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; [ -n "${1:-}" ] ;;
    *) [ $# -eq 2 ] || die "usage: vendor.sh <loomworks checkout> <tag> | --check"; vendor "$1" "$2" ;;
esac

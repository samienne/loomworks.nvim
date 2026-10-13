#!/usr/bin/env bash
# The draft release of a tag, found by listing releases (never by the tag:
# the tag does not exist yet while the draft is staged, and `gh release view
# <tag>` can match a published release or another draft).
# Used by .github/workflows/release.yml and scripts/release/pin.sh.
#
#   draft.sh find     <owner/repo> <tag>   print "<release id>\t<target_commitish>"
#                                          of the ONLY draft with tag_name <tag>;
#                                          zero or several drafts: exit 1
#   draft.sh count    <owner/repo> <tag>   print how many releases (draft or
#                                          published) carry tag_name <tag>
#   draft.sh download <owner/repo> <id> <dir> <asset>...
#                                          download the named assets of release
#                                          <id> into <dir>; a missing one: exit 1
#   draft.sh publish  <owner/repo> <id>    un-draft release <id>
#
# Needs an authenticated gh (drafts are visible only to writers).
set -euo pipefail

die() { echo "draft.sh: $*" >&2; exit 1; }

cmd="${1:-}"
repo="${2:-}"
printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || die "bad repository '$repo'"

check_tag() {
  printf '%s' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
    || die "tag '$1' is not v<n>.<n>.<n>[-pre]"
}
check_id() { printf '%s' "$1" | grep -Eq '^[0-9]+$' || die "release id '$1' is not a number"; }

case "$cmd" in
  find)
    check_tag "${3:-}"
    out="$(DRAFT_TAG="$3" gh api "repos/$repo/releases" --paginate \
      --jq '.[] | select(.draft == true and .tag_name == env.DRAFT_TAG) | [.id, .target_commitish] | @tsv')" \
      || die "cannot list the releases of $repo"
    n="$(printf '%s' "$out" | grep -c . || true)"
    [ "$n" = 1 ] || {
      if [ "$n" = 0 ]; then die "no draft release $3 on $repo (dispatch release.yml with stage=build on the build commit)"; fi
      die "$n draft releases $3 on $repo; delete the stale ones (gh api -X DELETE repos/$repo/releases/<id>) so exactly one remains"
    }
    id="$(printf '%s' "$out" | cut -f1)"
    check_id "$id"
    printf '%s\n' "$out"
    ;;
  count)
    check_tag "${3:-}"
    out="$(DRAFT_TAG="$3" gh api "repos/$repo/releases" --paginate \
      --jq '.[] | select(.tag_name == env.DRAFT_TAG) | .id')" \
      || die "cannot list the releases of $repo"
    printf '%s' "$out" | grep -c . || true
    ;;
  download)
    id="${3:-}"; dir="${4:-}"
    check_id "$id"
    [ -n "$dir" ] || die "no download directory"
    shift 4
    mkdir -p "$dir"
    assets="$(gh api "repos/$repo/releases/$id/assets" --paginate --jq '.[] | [.id, .name] | @tsv')" \
      || die "cannot list the assets of release $id"
    for name in "$@"; do
      aid="$(printf '%s\n' "$assets" | awk -F '\t' -v n="$name" '$2 == n { print $1 }')"
      [ -n "$aid" ] || die "release $id has no asset $name"
      check_id "$aid"
      gh api -H "Accept: application/octet-stream" "repos/$repo/releases/assets/$aid" > "$dir/$name" \
        || die "cannot download $name"
    done
    ;;
  publish)
    id="${3:-}"
    check_id "$id"
    gh api -X PATCH "repos/$repo/releases/$id" -F draft=false --jq '"published \(.tag_name) (release \(.id))"'
    ;;
  *)
    die "usage: draft.sh find|count|download|publish <owner/repo> ..."
    ;;
esac

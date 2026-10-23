#!/usr/bin/env bash
# Recreate, in DIR, the exact commit the prepare job chose: fetch the upstream
# tag commit, then the patched commit from the prepare job's git bundle.
# Every later job builds from this, so all five images come from one commit.
#
# Usage: materialize.sh DIR [--full]   (--full fetches complete history, which
#        a push needs; the default is a depth-1 fetch, which builds need)
# Env:   UPSTREAM_REPO UPSTREAM_COMMIT COMMIT TREE BUNDLE
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${UPSTREAM_REPO:?}" "${UPSTREAM_COMMIT:?}" "${COMMIT:?}" "${TREE:?}" "${BUNDLE:?}"
dir=${1:?usage: materialize.sh DIR [--full]}
depth=(--depth=1)
[[ ${2:-} == --full ]] && depth=()

rm -rf "$dir"
git init -q "$dir"
cd "$dir"
git fetch -q --no-tags "${depth[@]}" "https://github.com/${UPSTREAM_REPO}.git" "$UPSTREAM_COMMIT"
git bundle verify -q "$BUNDLE"
git fetch -q --no-tags "$BUNDLE" "refs/heads/homelab-sync:refs/heads/homelab-sync"
git checkout -q homelab-sync

head=$(git rev-parse HEAD)
tree=$(git rev-parse 'HEAD^{tree}')
[[ $head == "$COMMIT" ]] || fail "Source mismatch" "Bundle commit ${head} != planned commit ${COMMIT}."
[[ $tree == "$TREE" ]] || fail "Source mismatch" "Bundle tree ${tree} != planned tree ${TREE}."
[[ $(git rev-parse 'HEAD^1') == "$UPSTREAM_COMMIT" ]] || fail "Source mismatch" "${head} is not on top of ${UPSTREAM_COMMIT}."
log "Materialized ${head} (tree ${tree}) in ${dir}"

#!/usr/bin/env bash
# Create the annotated homelab-vX.Y.Z-rN tag at the planned commit and push it
# to the fork. Runs before any image is pushed, so a rejected push (for example
# the GITHUB_TOKEN "workflows" permission refusal) stops the run with nothing
# published. Never force-pushes: an existing tag makes the push fail.
#
# Usage: push-tag.sh DIR   (DIR from materialize.sh --full)
# Env:   FORK_REPO GIT_TAG COMMIT TREE UPSTREAM_TAG UPSTREAM_COMMIT PATCH_REF
#        PATCH_COMMIT REBASE RUN_URL PUSH_TOKEN TOKEN_NAME
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${FORK_REPO:?}" "${GIT_TAG:?}" "${COMMIT:?}" "${PUSH_TOKEN:?}" "${TOKEN_NAME:?}"
cd "${1:?usage: push-tag.sh DIR}"

git config user.name 'github-actions[bot]'
git config user.email '41898273+github-actions[bot]@users.noreply.github.com'
git remote add origin "https://github.com/${FORK_REPO}.git"

git tag -a "$GIT_TAG" "$COMMIT" -F - <<EOF
${GIT_TAG}

upstream-repository: ${UPSTREAM_REPO:-}
upstream-tag: ${UPSTREAM_TAG:-}
upstream-commit: ${UPSTREAM_COMMIT:-}
patch-ref: ${PATCH_REF:-}
patch-commit: ${PATCH_COMMIT:-}
rebase: ${REBASE:-}
tree: ${TREE:-}
run: ${RUN_URL:-}
EOF

auth=$(printf 'x-access-token:%s' "$PUSH_TOKEN" | base64 -w0)
echo "::add-mask::${auth}"
set +e
out=$(git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${auth}" \
	push origin "refs/tags/${GIT_TAG}" 2>&1)
status=$?
set -e
printf '%s\n' "$out"

if [[ $status -ne 0 ]]; then
	if grep -qiE 'workflows?.*permission|refusing to allow' <<<"$out"; then
		fail "Tag push rejected: missing workflows permission" \
			"Pushing \`${GIT_TAG}\` with ${TOKEN_NAME} was refused. The tag makes upstream commits that change \`.github/workflows/*\` reachable in this fork for the first time, and GitHub only allows that with the \`workflows\` permission, which GITHUB_TOKEN never has." \
			"" '```' "$out" '```' "" \
			"Nothing was published (no image is pushed before the tag). Fix one of these, then re-run:" \
			"- Bring the fork's \`main\` up to date with upstream from an account that may write workflows (\`gh repo sync ${FORK_REPO} --branch main\`), so the upstream commits are already reachable; or" \
			"- store a fine-grained token for ${FORK_REPO} with Contents: read and write and Workflows: read and write as the repository secret \`HOMELAB_SYNC_TOKEN\`; this job uses it for the push when it is set."
	fi
	fail "Tag push rejected" "Pushing \`${GIT_TAG}\` with ${TOKEN_NAME} failed. Nothing was published." '```' "$out" '```'
fi

remote=$(git ls-remote origin "refs/tags/${GIT_TAG}^{}" | awk '{print $1}')
[[ $remote == "$COMMIT" ]] || fail "Tag verification failed" "\`${GIT_TAG}\` on ${FORK_REPO} peels to '${remote}', expected ${COMMIT}."
summary "## :label: Pushed \`${GIT_TAG}\`" "" "\`${GIT_TAG}\` -> \`${COMMIT}\` (pushed with ${TOKEN_NAME})" ""

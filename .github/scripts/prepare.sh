#!/usr/bin/env bash
# Resolve the upstream target, validate and rebase the patch, and decide the
# revision. Read-only against every remote; it pushes nothing.
#
# Env (inputs):  UPSTREAM_REPO FORK_REPO IMAGE_PREFIX INPUT_UPSTREAM_TAG
#                INPUT_PATCH_REF INPUT_DRY_RUN GHCR_USER GHCR_TOKEN RUN_URL
# Outputs:       see the output calls at the end.
# Artifact:      $BUNDLE = git bundle of the commit to build (prerequisite:
#                the upstream tag commit).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${UPSTREAM_REPO:?}" "${FORK_REPO:?}" "${IMAGE_PREFIX:?}" "${BUNDLE:?}"
PATCH_REF=${INPUT_PATCH_REF:-feat/outbound-allowed-cidrs}
UPSTREAM_TAG=${INPUT_UPSTREAM_TAG:-}
DRY_RUN=${INPUT_DRY_RUN:-false}
WORKDIR=${WORKDIR:-src}
BOT_NAME='github-actions[bot]'
BOT_EMAIL='41898273+github-actions[bot]@users.noreply.github.com'

[[ $DRY_RUN == true || $DRY_RUN == false ]] || fail "Invalid dry_run" "dry_run must be true or false, got \`${DRY_RUN}\`."
if [[ ! $PATCH_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ || $PATCH_REF == *..* || $PATCH_REF == *.lock ]]; then
	fail "Invalid patch_ref" "\`${PATCH_REF}\` is not a plain branch or tag name."
fi
if [[ -n $UPSTREAM_TAG && ! $UPSTREAM_TAG =~ ^cluster-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	fail "Invalid upstream_tag" "\`${UPSTREAM_TAG}\` is not of the form \`cluster-vX.Y.Z\`."
fi

git version
git_version=$(git version | awk '{print $3}')
if [[ $(printf '%s\n' 2.40.0 "$git_version" | sort -V | head -1) != 2.40.0 ]]; then
	fail "git too old" "git ${git_version} lacks \`merge-tree --write-tree --merge-base\` (needs >= 2.40)."
fi

rm -rf "$WORKDIR"
git init -q "$WORKDIR"
cd "$WORKDIR"
# *_URL overrides exist only for local testing against scratch repositories.
git remote add upstream "${UPSTREAM_URL:-https://github.com/${UPSTREAM_REPO}.git}"
git remote add origin "${FORK_URL:-https://github.com/${FORK_REPO}.git}"

# --- 1. Target upstream tag ---------------------------------------------------
upstream_tags=$(git ls-remote --tags upstream 'refs/tags/cluster-v*')
release_tags=$(awk '{print $2}' <<<"$upstream_tags" | sed 's#^refs/tags/##' |
	grep -E '^cluster-v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V || true)
[[ -n $release_tags ]] || fail "No upstream release tags" "\`git ls-remote --tags\` found no \`cluster-vX.Y.Z\` tag on ${UPSTREAM_REPO}."
if [[ -z $UPSTREAM_TAG ]]; then
	UPSTREAM_TAG=$(tail -1 <<<"$release_tags")
	log "Highest upstream release tag: ${UPSTREAM_TAG}"
elif ! grep -qxF "$UPSTREAM_TAG" <<<"$release_tags"; then
	fail "Upstream tag not found" "\`${UPSTREAM_TAG}\` does not exist on ${UPSTREAM_REPO}."
fi
VERSION=${UPSTREAM_TAG#cluster-v}
# Commits that upstream release tags point at (peeled for annotated tags).
upstream_tag_commits=$(awk '{print $1}' <<<"$upstream_tags" | sort -u)

git fetch -q --no-tags upstream \
	"+refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}" \
	"+refs/heads/main:refs/remotes/upstream/main"
T=$(git rev-parse --verify "refs/tags/${UPSTREAM_TAG}^{commit}")
log "Target ${UPSTREAM_TAG} = ${T}"

# --- 2. Patch: exactly one commit on top of upstream ----------------------------
if git ls-remote --exit-code -q origin "refs/heads/${PATCH_REF}" >/dev/null; then
	git fetch -q --no-tags origin "+refs/heads/${PATCH_REF}:refs/patch/tip"
elif git ls-remote --exit-code -q origin "refs/tags/${PATCH_REF}" >/dev/null; then
	git fetch -q --no-tags origin "+refs/tags/${PATCH_REF}:refs/patch/tip"
else
	fail "Patch ref not found" "Neither branch nor tag \`${PATCH_REF}\` exists on ${FORK_REPO}."
fi
P=$(git rev-parse --verify 'refs/patch/tip^{commit}')
log "Patch ${PATCH_REF} = ${P}"

patch_shape_help=(
	"The patch ref must be an upstream \`cluster-vX.Y.Z\` tag (or an upstream \`main\` commit) plus EXACTLY ONE commit."
	""
	"Commits on \`${PATCH_REF}\` that upstream does not have:"
	'```'
	"$(git log --oneline --no-decorate upstream/main..refs/patch/tip | head -20)"
	'```'
	"Squash the patch into one commit on top of an upstream tag, force-push it, and re-run."
)
read -ra parents <<<"$(git rev-list --parents -n1 "$P")"
[[ ${#parents[@]} -eq 2 ]] || fail "Patch tip is not a single-parent commit" "${patch_shape_help[@]}"
B=${parents[1]}
if git merge-base --is-ancestor "$P" upstream/main || grep -qxF "$P" <<<"$upstream_tag_commits"; then
	fail "Patch ref carries no patch" "\`${PATCH_REF}\` (${P}) is itself an upstream commit."
fi
if ! git merge-base --is-ancestor "$B" upstream/main && ! grep -qxF "$B" <<<"$upstream_tag_commits"; then
	fail "Patch is not one commit on top of upstream" "${patch_shape_help[@]}"
fi
if [[ $(git rev-parse "${P}^{tree}") == $(git rev-parse "${B}^{tree}") ]]; then
	fail "Patch commit is empty" "${P} changes nothing relative to its parent ${B}."
fi

# --- 3. Rebase the patch onto the target ----------------------------------------
if [[ $B == "$T" ]]; then
	NEW=$P
	REBASE=noop
	log "Patch is already based on ${UPSTREAM_TAG}; keeping ${P}."
else
	set +e
	merge_out=$(git merge-tree --write-tree --name-only --merge-base="$B" "$T" "$P" 2>&1)
	merge_status=$?
	set -e
	if [[ $merge_status -eq 1 ]]; then
		conflicts=$(sed '1d' <<<"$merge_out")
		fail "Patch does not apply to ${UPSTREAM_TAG}" \
			"Rebasing \`${PATCH_REF}\` (${P}, based on ${B}) onto \`${UPSTREAM_TAG}\` (${T}) conflicts in:" \
			'```' "$conflicts" '```' \
			"Nothing was published. Rebase the patch branch by hand and re-run:" \
			'```sh' \
			"git fetch upstream --tags" \
			"git switch ${PATCH_REF}" \
			"git rebase --onto ${UPSTREAM_TAG} HEAD~1   # resolve, then: make verify" \
			"git push --force-with-lease origin ${PATCH_REF}" \
			"gh workflow run upstream-sync.yaml -R ${FORK_REPO}" \
			'```'
	elif [[ $merge_status -ne 0 ]]; then
		fail "git merge-tree failed" '```' "$merge_out" '```'
	fi
	tree=$(head -1 <<<"$merge_out")
	if [[ $tree == $(git rev-parse "${T}^{tree}") ]]; then
		fail "Patch is empty on ${UPSTREAM_TAG}" \
			"Rebasing \`${PATCH_REF}\` onto \`${UPSTREAM_TAG}\` leaves no changes: upstream already contains it." \
			"Nothing was published. Retire the fork images (switch back to upstream images) or update the patch."
	fi
	# Deterministic commit: same patch + same target => same SHA on every run.
	p_date=$(git log -1 --format=%ct "$P")
	t_date=$(git log -1 --format=%ct "$T")
	c_date=$((p_date > t_date ? p_date : t_date))
	NEW=$(
		GIT_AUTHOR_NAME=$(git log -1 --format=%an "$P") \
			GIT_AUTHOR_EMAIL=$(git log -1 --format=%ae "$P") \
			GIT_AUTHOR_DATE=$(git log -1 --format=%ad --date=raw "$P") \
			GIT_COMMITTER_NAME=$BOT_NAME GIT_COMMITTER_EMAIL=$BOT_EMAIL \
			GIT_COMMITTER_DATE="${c_date} +0000" \
			git commit-tree "$tree" -p "$T" -F <(git cat-file commit "$P" | sed '1,/^$/d')
	)
	REBASE=rebased
	log "Rebased ${P} onto ${UPSTREAM_TAG}: ${NEW}"
fi
TREE=$(git rev-parse "${NEW}^{tree}")

# --- 4. Revision ------------------------------------------------------------------
image_state() { # name tag -> present|absent|denied|error:*
	ghcr_status "${IMAGE_PREFIX#ghcr.io/}-$1" "$2" "${GHCR_USER:-}" "${GHCR_TOKEN:-}"
}
version_re=${VERSION//./\\.}
revisions=$(git ls-remote --tags --refs origin "refs/tags/homelab-v${VERSION}-r*" | awk '{print $2}' |
	sed -n "s#^refs/tags/homelab-v${version_re}-r\([1-9][0-9]*\)\$#\1#p" | sort -n)
last=$(tail -1 <<<"$revisions")
MISSING=()
if [[ -z $last ]]; then
	REVISION=1
	MODE=publish
	COMMIT=$NEW
	log "No homelab-v${VERSION}-r* tag yet."
else
	last_tag="homelab-v${VERSION}-r${last}"
	git fetch -q --no-tags origin "+refs/tags/${last_tag}:refs/tags/${last_tag}"
	last_commit=$(git rev-parse --verify "refs/tags/${last_tag}^{commit}")
	last_tree=$(git rev-parse "${last_commit}^{tree}")
	if [[ $(git rev-parse "${last_commit}^1" 2>/dev/null || true) != "$T" ]]; then
		fail "Existing tag does not sit on ${UPSTREAM_TAG}" \
			"\`${last_tag}\` (${last_commit}) is not one commit on top of \`${UPSTREAM_TAG}\` (${T})." \
			"Upstream may have moved the tag. Investigate before publishing anything for v${VERSION}."
	fi
	if [[ $last_tree == "$TREE" ]]; then
		REVISION=$last
		COMMIT=$last_commit
		for name in "${IMAGE_NAMES[@]}"; do
			state=$(image_state "$name" "v${VERSION}-r${REVISION}")
			log "  omnara-${name}:v${VERSION}-r${REVISION}: ${state}"
			case $state in
			present) ;;
			absent | denied) MISSING+=("$name") ;;
			*) fail "Cannot read ghcr.io" "Checking omnara-${name}:v${VERSION}-r${REVISION} returned ${state}." ;;
			esac
		done
		if [[ ${#MISSING[@]} -eq 0 ]]; then MODE=noop; else MODE=resume; fi
	else
		REVISION=$((last + 1))
		MODE=publish
		COMMIT=$NEW
		log "Patch tree changed since ${last_tag} (${last_tree} -> ${TREE})."
	fi
fi
GIT_TAG="homelab-v${VERSION}-r${REVISION}"
IMAGE_TAG="v${VERSION}-r${REVISION}"

if [[ $MODE == publish ]]; then
	# A new revision must not have any image yet: images only follow the git tag.
	for name in "${IMAGE_NAMES[@]}"; do
		state=$(image_state "$name" "$IMAGE_TAG")
		case $state in
		absent | denied) ;;
		present) fail "Image exists without a git tag" \
			"${IMAGE_PREFIX}-${name}:${IMAGE_TAG} already exists but \`${GIT_TAG}\` does not." \
			"Refusing to overwrite it. Find out who pushed it; delete that package version only if it is junk." ;;
		*) fail "Cannot read ghcr.io" "Checking ${IMAGE_PREFIX}-${name}:${IMAGE_TAG} returned ${state}." ;;
		esac
	done
	MISSING=("${IMAGE_NAMES[@]}")
fi

# --- 5. Hand-off --------------------------------------------------------------------
git update-ref refs/heads/homelab-sync "$COMMIT"
git bundle create "$BUNDLE" refs/heads/homelab-sync "^${T}"

need_build=false
push_tag=false
if [[ $DRY_RUN == true || $MODE != noop ]]; then need_build=true; fi
if [[ $DRY_RUN == false && $MODE == publish ]]; then push_tag=true; fi

output mode "$MODE"
output dry_run "$DRY_RUN"
output need_build "$need_build"
output push_tag "$push_tag"
output upstream_tag "$UPSTREAM_TAG"
output upstream_commit "$T"
output version "$VERSION"
output revision "$REVISION"
output git_tag "$GIT_TAG"
output image_tag "$IMAGE_TAG"
output commit "$COMMIT"
output tree "$TREE"
output patch_ref "$PATCH_REF"
output patch_commit "$P"
output rebase "$REBASE"

case $MODE in
publish) verdict="Publish new revision \`${GIT_TAG}\`" ;;
resume) verdict="Resume \`${GIT_TAG}\`: missing images ${MISSING[*]}" ;;
noop) verdict="Up to date: \`${GIT_TAG}\` and all five images exist" ;;
esac
[[ $DRY_RUN == true ]] && verdict="DRY RUN (nothing is pushed). Would: ${verdict}"
summary "## Upstream sync plan" "" "**${verdict}**" "" \
	"| | |" "|---|---|" \
	"| Upstream tag | \`${UPSTREAM_TAG}\` (\`${T}\`) |" \
	"| Patch ref | \`${PATCH_REF}\` (\`${P}\`) |" \
	"| Rebase | ${REBASE} |" \
	"| Commit to build | \`${COMMIT}\` |" \
	"| Tree | \`${TREE}\` |" \
	"| Git tag | \`${GIT_TAG}\` |" \
	"| Image tag | \`${IMAGE_TAG}\` |" \
	"| Images to build | ${MISSING[*]:-none} |" \
	"| Run | ${RUN_URL:-local} |" ""
log "Plan: ${verdict}"

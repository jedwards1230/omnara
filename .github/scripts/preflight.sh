#!/usr/bin/env bash
# Last check before one image is built and pushed. Enforces, per image:
# - the git tag exists on the fork and peels to the planned commit (the tag
#   always exists before any image tag is published);
# - an existing image tag is never overwritten: in resume mode it is skipped,
#   in publish mode it is an error.
# Prints skip=true|false to $GITHUB_OUTPUT.
#
# Env: NAME IMAGE IMAGE_TAG GIT_TAG COMMIT MODE DRY_RUN FORK_REPO GHCR_USER GHCR_TOKEN
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${NAME:?}" "${IMAGE:?}" "${IMAGE_TAG:?}" "${GIT_TAG:?}" "${COMMIT:?}" "${MODE:?}" "${DRY_RUN:?}" "${FORK_REPO:?}"

state=$(ghcr_status "${IMAGE#ghcr.io/}" "$IMAGE_TAG" "${GHCR_USER:-}" "${GHCR_TOKEN:-}")
log "${IMAGE}:${IMAGE_TAG}: ${state}"
case $state in present | absent | denied) ;; *) fail "Cannot read ghcr.io" "Checking ${IMAGE}:${IMAGE_TAG} returned ${state}." ;; esac

if [[ $DRY_RUN == true ]]; then
	log "Dry run: building ${NAME} without pushing (registry state: ${state})."
	output skip false
	exit 0
fi

remote=$(git ls-remote "https://github.com/${FORK_REPO}.git" "refs/tags/${GIT_TAG}^{}" | awk '{print $1}')
[[ $remote == "$COMMIT" ]] || fail "Git tag missing" \
	"\`${GIT_TAG}\` on ${FORK_REPO} peels to '${remote:-nothing}', expected ${COMMIT}. Images are only published for an existing tag."

if [[ $state == present ]]; then
	if [[ $MODE == resume ]]; then
		log "${IMAGE}:${IMAGE_TAG} already exists: keeping it (resume)."
		output skip true
		exit 0
	fi
	fail "Image tag already exists" "${IMAGE}:${IMAGE_TAG} exists although this run minted ${GIT_TAG}. Refusing to overwrite it."
fi
output skip false

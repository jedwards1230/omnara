#!/usr/bin/env bash
# Verify, WITHOUT credentials, that every image of the revision can be pulled
# the way the consuming cluster pulls it: the tag resolves to a multi-arch index
# with linux/amd64 and linux/arm64, the index records the expected commit, the
# tag is listable anonymously, and (for images built in this run) the registry
# digest is the digest that was built. Writes the pinned references to the job
# summary.
#
# Env: IMAGE_PREFIX IMAGE_TAG COMMIT OWNER [DIGEST_DIR]
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${IMAGE_PREFIX:?}" "${IMAGE_TAG:?}" "${COMMIT:?}" "${OWNER:?}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failures=()
private=()
pinned=()
for name in "${IMAGE_NAMES[@]}"; do
	repo="${IMAGE_PREFIX#ghcr.io/}-${name}"
	ref="${IMAGE_PREFIX}-${name}:${IMAGE_TAG}"
	token=$(curl -sS --retry 3 "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" |
		jq -r '.token // empty' 2>/dev/null || true)
	if [[ -z $token ]]; then
		failures+=("${ref}: anonymous pull is denied (package private or missing)")
		private+=("$name")
		continue
	fi
	code=$(curl -sS --retry 3 -D "$tmp/$name.headers" -o "$tmp/$name.json" -w '%{http_code}' \
		-H "Authorization: Bearer ${token}" -H "Accept: ${GHCR_ACCEPT}" \
		"https://ghcr.io/v2/${repo}/manifests/${IMAGE_TAG}")
	if [[ $code != 200 ]]; then
		failures+=("${ref}: anonymous manifest request returned HTTP ${code}")
		continue
	fi
	media=$(jq -r '.mediaType // empty' "$tmp/$name.json")
	case $media in
	application/vnd.oci.image.index.v1+json | application/vnd.docker.distribution.manifest.list.v2+json) ;;
	*)
		failures+=("${ref}: not a multi-arch index (mediaType '${media}')")
		continue
		;;
	esac
	digest="sha256:$(sha256sum "$tmp/$name.json" | cut -d' ' -f1)"
	header=$(tr -d '\r' <"$tmp/$name.headers" | awk 'tolower($1) == "docker-content-digest:" {print $2}')
	[[ -z $header || $header == "$digest" ]] || failures+=("${ref}: header digest ${header} != body digest ${digest}")
	platforms=$(jq -r '[.manifests[] | select(.platform.os != "unknown") | "\(.platform.os)/\(.platform.architecture)"] | unique | join(",")' "$tmp/$name.json")
	for want in linux/amd64 linux/arm64; do
		[[ ",${platforms}," == *",${want},"* ]] || failures+=("${ref}: index lacks ${want} (has ${platforms:-none})")
	done
	revision=$(jq -r '.annotations["org.opencontainers.image.revision"] // empty' "$tmp/$name.json")
	[[ $revision == "$COMMIT" ]] || failures+=("${ref}: index revision is '${revision}', expected ${COMMIT}")
	if [[ -n ${DIGEST_DIR:-} && -f ${DIGEST_DIR}/${name} ]]; then
		built=$(tr -d '[:space:]' <"${DIGEST_DIR}/${name}")
		[[ $built == "$digest" ]] || failures+=("${ref}: registry digest ${digest} != digest built in this run ${built}")
	fi
	if ! curl -sS --retry 3 -H "Authorization: Bearer ${token}" "https://ghcr.io/v2/${repo}/tags/list?n=10000" |
		jq -e --arg t "$IMAGE_TAG" '.tags | index($t) != null' >/dev/null; then
		failures+=("${ref}: tag is not listed anonymously")
	fi
	pinned+=("${ref}@${digest}")
	log "OK ${ref}@${digest} (${platforms})"
done

if [[ ${#pinned[@]} -gt 0 ]]; then
	summary "## :package: Images (index digests)" "" '```' "${pinned[@]}" '```' ""
fi
if [[ ${#failures[@]} -gt 0 ]]; then
	help=()
	if [[ ${#private[@]} -gt 0 ]]; then
		help+=("" "Packages created by this workflow should inherit the public visibility of the repository; these did not:")
		for name in "${private[@]}"; do
			help+=("- https://github.com/users/${OWNER}/packages/container/omnara-${name}/settings: Danger Zone, Change visibility, Public")
		done
		help+=("" "Visibility cannot be changed with GITHUB_TOKEN or the REST API. After fixing it, re-run this workflow: the revision is already complete, so it only re-verifies.")
	fi
	fail "Anonymous pull verification failed" "${failures[@]/#/- }" "${help[@]}"
fi
summary "All five images are anonymously pullable for linux/amd64 and linux/arm64 and record commit \`${COMMIT}\`." ""

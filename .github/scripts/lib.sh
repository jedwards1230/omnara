# shellcheck shell=bash
# Shared helpers for the upstream-sync workflow. Source, do not execute.

: "${GITHUB_STEP_SUMMARY:=/dev/null}"
: "${GITHUB_OUTPUT:=/dev/null}"

# The five images, in the same order as upstream's cluster-release matrix.
# shellcheck disable=SC2034 # used by the scripts that source this file
IMAGE_NAMES=(web api worker maintenance migrations)

GHCR_ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

log() { printf '%s\n' "$*" >&2; }

# Escape a string for a workflow command (annotations).
escape_data() {
	local s=$1
	s=${s//'%'/'%25'}
	s=${s//$'\r'/'%0D'}
	s=${s//$'\n'/'%0A'}
	printf '%s' "$s"
}

summary() { printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"; }

output() { printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; }

# fail TITLE LINE...: error annotation + job summary section, then exit 1.
# Nothing in this workflow fails silently: every refusal goes through here.
fail() {
	local title=$1
	shift
	local body
	body=$(printf '%s\n' "$@")
	printf '::error title=%s::%s\n' "$(escape_data "$title")" "$(escape_data "$body")"
	summary "## :x: ${title}" "" "$@" ""
	exit 1
}

# ghcr_status REPOSITORY TAG [USER TOKEN]
# Prints present | absent | denied | error:<http code> for ghcr.io/REPOSITORY:TAG.
# Without USER/TOKEN the check is anonymous (what the cluster and the image
# tracker do). GHCR refuses an anonymous token for a package that is private
# OR does not exist yet, so "denied" covers both.
ghcr_status() {
	local repo=$1 tag=$2 user=${3:-} token=${4:-} bearer code
	local url="https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io"
	if [[ -n $token ]]; then
		bearer=$(curl -sS --retry 3 -u "${user}:${token}" "$url" | jq -r '.token // empty' 2>/dev/null || true)
	else
		bearer=$(curl -sS --retry 3 "$url" | jq -r '.token // empty' 2>/dev/null || true)
	fi
	if [[ -z $bearer ]]; then
		echo denied
		return 0
	fi
	code=$(curl -sS --retry 3 -o /dev/null -w '%{http_code}' -I \
		-H "Authorization: Bearer ${bearer}" -H "Accept: ${GHCR_ACCEPT}" \
		"https://ghcr.io/v2/${repo}/manifests/${tag}")
	case $code in
	200) echo present ;;
	404) echo absent ;;
	401 | 403) echo denied ;;
	*) echo "error:${code}" ;;
	esac
}

#!/usr/bin/env bash
# A `docker` for the release scripts, recording instead of acting.
#
# hack/test/lib.sh links this into a directory it puts first on PATH, so the
# scripts under test run unmodified. Only the invocations they make are
# handled; anything else is an error, so that a script growing a new docker
# call cannot pass by accident. What it does:
#
#   buildx imagetools create --dry-run REF...   the index the given references
#                                               would merge into, built from
#                                               the fixture registry the way
#                                               buildx builds it — an image
#                                               manifest contributes one
#                                               platform entry, an index
#                                               contributes every entry it
#                                               holds, attestations included
#                                               (that is what the #27 spike
#                                               measured with provenance on)
#   buildx imagetools create -t TAG REF...      the same index, written to the
#                                               fixture registry under TAG, and
#                                               one line appended to
#                                               $FAKE_DOCKER/log — the record a
#                                               test reads to prove the tag
#                                               did or did not move
#   buildx imagetools inspect REF --format F    {{ json .Manifest }} → the
#                                               manifest under REF;
#                                               {{ .Manifest.Digest }} → a
#                                               digest of that file
#   inspect --format F IMAGE                    F applied to
#                                               $FAKE_DOCKER/images/IMAGE.json,
#                                               for the two formats the
#                                               scripts use

set -euo pipefail

[ -n "${FAKE_REGISTRY:-}" ] || { echo 'fake-docker: FAKE_REGISTRY is not set' >&2; exit 2; }
[ -n "${FAKE_DOCKER:-}" ] || { echo 'fake-docker: FAKE_DOCKER is not set' >&2; exit 2; }

unhandled() { echo "fake-docker: unhandled invocation: docker $*" >&2; exit 2; }

# ghcr.io/juherr/steve@sha256:x → the manifest file under the fixture registry.
manifest_file() {
  local ref="$1" name repo
  name="${ref%%@*}"; repo="${name#ghcr.io/}"
  echo "${FAKE_REGISTRY}/v2/${repo}/manifests/${ref#*@}"
}

# The index buildx would merge the references into.
merged_index() {
  local ref file config
  for ref in "$@"; do
    file=$(manifest_file "${ref}")
    [ -f "${file}" ] || { echo "fake-docker: ${ref}: not found" >&2; exit 1; }
    if jq -e '.manifests' "${file}" >/dev/null 2>&1; then
      jq -c '.manifests[]' "${file}"
    else
      config="$(dirname "$(dirname "${file}")")/blobs/$(jq -r '.config.digest' "${file}")"
      jq -c --arg digest "${ref#*@}" --argjson size "$(wc -c <"${file}" | tr -d ' ')" \
        '{mediaType: "application/vnd.oci.image.manifest.v1+json", digest: $digest, size: $size,
          platform: {architecture: .architecture, os: .os}}' "${config}"
    fi
  done | jq -s '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", manifests: .}'
}

case "$1 $2 $3" in
  'buildx imagetools create')
    shift 3
    if [ "${1:-}" = "--dry-run" ]; then
      shift; merged_index "$@"
    elif [ "${1:-}" = "-t" ]; then
      tag="$2"; shift 2
      echo "create -t ${tag} $*" >> "${FAKE_DOCKER}/log"
      merged_index "$@" > "$(manifest_file "${tag%%:*}@${tag##*:}")"
    else
      unhandled buildx imagetools create "$@"
    fi ;;
  'buildx imagetools inspect')
    shift 3
    ref="$1"; format="${3:-}"
    [ "${2:-}" = "--format" ] || unhandled buildx imagetools inspect "$@"
    file=$(manifest_file "${ref%%:*}@${ref##*:}")
    [ -f "${file}" ] || { echo "fake-docker: ${ref}: not found" >&2; exit 1; }
    case "${format}" in
      '{{ json .Manifest }}') cat "${file}" ;;
      '{{ .Manifest.Digest }}') echo "sha256:$(shasum -a 256 "${file}" | cut -d' ' -f1)" ;;
      *) unhandled buildx imagetools inspect "$@" ;;
    esac ;;
  'inspect --format '*)
    format="$3"; image="$4"
    file="${FAKE_DOCKER}/images/${image//[\/:]/_}.json"
    [ -f "${file}" ] || { echo "Error response from daemon: No such object: ${image}" >&2; exit 1; }
    case "${format}" in
      '{{ json .RootFS.Layers }}') jq -c '.RootFS.Layers' "${file}" ;;
      '{{ .Architecture }}') jq -r '.Architecture' "${file}" ;;
      *) unhandled inspect --format "${format}" "${image}" ;;
    esac ;;
  *) unhandled "$@" ;;
esac

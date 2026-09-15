#!/usr/bin/env bash
# A `curl` for the registry readers, serving hack/test/registry/ instead of GHCR.
#
# hack/test/registry-readers.sh links this into a directory it puts first on
# PATH, so the scripts under test run unmodified — no test hook, no "fake
# registry" knob in production code. The URL's path is the file to serve, the
# query string is dropped, and a missing file is what `curl -f` makes of a 404:
# a diagnostic on stderr and exit 22.
#
# One piece of GHCR behaviour is emulated on purpose, because the readers used
# to break on it: asked for a tag that holds an image index without an index
# type in `Accept`, GHCR answers 404 rather than the index (measured on
# aquasecurity/trivy:latest, 2026-09-15). Without that, a reader that still
# requests a single manifest type would pass these tests and fail on the
# registry.

set -euo pipefail

[ -n "${FAKE_REGISTRY:-}" ] || { echo 'fake-curl: FAKE_REGISTRY is not set' >&2; exit 2; }

url='' accept=''
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in Accept:*) accept="${2#Accept: }" ;; esac; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
[ -n "${url}" ] || { echo 'fake-curl: no URL given' >&2; exit 2; }

path="${url#https://ghcr.io/}"
file="${FAKE_REGISTRY}/${path%%\?*}"

not_found() { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }

[ -f "${file}" ] || not_found

case "$(jq -r '.mediaType // empty' "${file}" 2>/dev/null)" in
  application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json)
    case "${accept}" in
      *application/vnd.oci.image.index.v1+json*|*application/vnd.docker.distribution.manifest.list.v2+json*) ;;
      *) not_found ;;
    esac ;;
esac

cat "${file}"

#!/usr/bin/env bash
# Offline tests for hack/mirror-tag.sh, which copies a published tag from
# GHCR to Docker Hub and reads it back.
#
# crane does not run here: a `docker` shim put first on PATH records every
# `docker run` it is handed and answers the four crane commands the script
# uses from the fixture registry — `ghcr.io/juherr/steve` is the
# hack/test/registry/ tree the other suites read, `docker.io/juherr/steve` a
# sibling directory that starts empty. `copy` writes the source manifest
# under the mirror's tag byte for byte, which is what crane does (measured:
# same index digest on both sides, annotation included); `digest` is the
# sha256 of the file, as a registry computes it. Two knobs stand in for the
# registry-side surprises the script must not mistake for a mirror: a copy
# that lands as something else, and a Hub that cannot be read back.
#
# Usage:  ./hack/test/mirror-tag.sh
#         HACK_DIR=/path/to/older/hack ./hack/test/mirror-tag.sh   # red/green
# Exit:   0 all passed · 1 otherwise

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=hack/test/lib.sh
. "${here}/lib.sh"
mirror="${HACK_DIR}/mirror-tag.sh"

setup_fixtures

# setup_fixtures linked the recording docker there; this suite brings its own.
rm -f "${work}/bin/docker"
cat >"${work}/bin/docker" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_CRANE_LOG}"
[ "$1" = run ] || { echo "fake-docker: unhandled invocation: docker $*" >&2; exit 2; }
shift
config=''
while [ $# -gt 0 ]; do
  case "$1" in
    --rm|-i) shift ;;
    -v) config="${2%%:*}"; shift 2 ;;
    -e) shift 2 ;;
    *) break ;;
  esac
done
shift   # the image
# ghcr.io/juherr/steve:tag or @digest → the fixture file; docker.io/… → its sibling.
file() {
  local ref="$1" registry rest repo id
  registry="${ref%%/*}"; rest="${ref#*/}"
  case "${rest}" in *@*) repo="${rest%%@*}"; id="${rest#*@}" ;; *) repo="${rest%%:*}"; id="${rest##*:}" ;; esac
  local dir
  case "${registry}" in
    ghcr.io) dir="${FAKE_REGISTRY}/v2/${repo}/manifests" ;;
    *) dir="${FAKE_REGISTRY}/v2/${registry}/${repo}/manifests" ;;
  esac
  echo "${dir}/${id}"
}
# A registry is content-addressed: what a tag resolved to stays readable by
# its digest after the tag moved. Answering a tag's digest files the content
# under it, which is what the by-digest reads below find.
digest_of() {
  local f="$1" d
  d="sha256:$(shasum -a 256 "${f}" | cut -d' ' -f1)"
  [ -f "$(dirname "${f}")/${d}" ] || cp "${f}" "$(dirname "${f}")/${d}"
  echo "${d}"
}
down() { case "$1" in docker.io/*) [ -n "${FAKE_MIRROR_DOWN:-}" ] ;; *) false ;; esac; }
unknown() { echo "Error: GET https://${1}: MANIFEST_UNKNOWN: manifest unknown" >&2; exit 1; }
case "$1" in
  auth)
    [ "$2" = login ] || { echo "fake-docker: unhandled crane $*" >&2; exit 2; }
    cat >/dev/null
    [ -n "${config}" ] && printf '{"auths":{}}' >"${config}/config.json"
    echo "logged in via /config/config.json" ;;
  digest)
    down "$2" && { echo "Error: GET https://$2: dial tcp: connection refused" >&2; exit 1; }
    f=$(file "$2"); [ -f "${f}" ] || unknown "$2"
    digest_of "${f}"
    # The tag moves right after it was resolved: what the script does next
    # must go by the digest it holds, not by the tag.
    if [ -n "${FAKE_TAG_MOVES_TO:-}" ]; then case "$2" in ghcr.io/*:*) cp "${FAKE_TAG_MOVES_TO}" "${f}" ;; esac; fi ;;
  manifest)
    down "$2" && { echo "Error: GET https://$2: dial tcp: connection refused" >&2; exit 1; }
    f=$(file "$2"); [ -f "${f}" ] || unknown "$2"
    cat "${f}" ;;
  copy)
    src=$(file "$2"); dst=$(file "$3")
    [ -f "${src}" ] || unknown "$2"
    [ -f "${config}/config.json" ] || { echo "Error: HEAD https://$3: unexpected status code 401 Unauthorized" >&2; exit 1; }
    mkdir -p "$(dirname "${dst}")"
    if [ -n "${FAKE_COPY_LANDS_AS:-}" ]; then cp "${FAKE_COPY_LANDS_AS}" "${dst}"; else cp "${src}" "${dst}"; fi
    echo "$3: digest: $(digest_of "${dst}") size: 1" ;;
  *) echo "fake-docker: unhandled crane $*" >&2; exit 2 ;;
esac
SHIM
chmod +x "${work}/bin/docker"
export FAKE_CRANE_LOG="${work}/docker.log"
export TMPDIR="${work}/tmp"
mkdir -p "${TMPDIR}"
hub="${FAKE_REGISTRY}/v2/docker.io/juherr/steve/manifests"
ghcr_digest() { echo "sha256:$(shasum -a 256 "${FAKE_REGISTRY}/v2/juherr/steve/manifests/$1" | cut -d' ' -f1)"; }

creds=(env DOCKERHUB_USERNAME=mirror DOCKERHUB_TOKEN=s3cret)
# The log, the mirror, and the source tag a test may have moved.
reset() {
  rm -f "${FAKE_CRANE_LOG}"; rm -rf "${hub}"
  cp "${here}/registry/v2/juherr/steve/manifests/steve-1.1.0" "${FAKE_REGISTRY}/v2/juherr/steve/manifests/steve-1.1.0"
}
copies() { if [ -f "${FAKE_CRANE_LOG}" ]; then grep -c ' copy ' "${FAKE_CRANE_LOG}" || true; else echo 0; fi; }
expect_copied()    { [ "$(copies)" -eq 1 ] || { fail "expected exactly one copy, got $(copies)"; return 1; }; }
expect_untouched() { [ "$(copies)" -eq 0 ] || { fail "a copy was made: $(grep ' copy ' "${FAKE_CRANE_LOG}")"; return 1; }; }
# Every crane invocation went through the image the workflow pins — the
# exact reference, tag and digest, read from the workflow rather than
# matched by shape — with the config mounted, and the login took the token
# on stdin, never as an argument.
pin=$(sed -n 's/^  CRANE_IMAGE: "\(.*\)"$/\1/p' "${HACK_DIR}/../.github/workflows/build-image.yml")
[[ "${pin}" =~ ^gcr\.io/go-containerregistry/crane:v[0-9.]+@sha256:[0-9a-f]{64}$ ]] \
  || { echo "FAIL the workflow pins CRANE_IMAGE as '${pin}', not as tag@digest"; exit 1; }
expect_invocations() {
  local line
  while IFS= read -r line; do
    [[ "${line}" == "run --rm -i -v "*":/config -e DOCKER_CONFIG=/config ${pin} "* ]] \
      || { fail "an invocation is not through the pinned crane with the config mounted: ${line}"; return 1; }
    [[ "${line}" != *"s3cret"* ]] || { fail "the token is on a command line: ${line}"; return 1; }
  done <"${FAKE_CRANE_LOG}"
  grep -q ' auth login docker.io -u mirror --password-stdin$' "${FAKE_CRANE_LOG}" \
    || { fail "no login to docker.io with --password-stdin: $(cat "${FAKE_CRANE_LOG}")"; return 1; }
}
expect_no_leftover() { [ -z "$(ls -A "${TMPDIR}")" ] || { fail "a config directory was left behind: $(ls -A "${TMPDIR}")"; return 1; }; }

# --- the good tag ----------------------------------------------------------

reset
run 'a two-platform index tag is copied once and reads back with the same digest' \
  "${creds[@]}" "${mirror}" steve-1.1.0
expect_status 0 && expect_copied && expect_out "Mirrored: docker.io/juherr/steve:steve-1.1.0@$(ghcr_digest steve-1.1.0)" \
  && expect_invocations && expect_no_leftover && pass

run 'the copy is made from the resolved digest, not from the tag' \
  grep -E ' copy ghcr.io/juherr/steve@sha256:[0-9a-f]{64} docker.io/juherr/steve:steve-1.1.0$' "${FAKE_CRANE_LOG}"
expect_status 0 && pass

run 'the mirrored tag is the GHCR index byte for byte' \
  cmp "${FAKE_REGISTRY}/v2/juherr/steve/manifests/steve-1.1.0" "${hub}/steve-1.1.0"
expect_status 0 && pass

# crane itself re-pushes nothing on an identical target ("existing manifest",
# measured); the script's contract is only that a second run is green and
# reports the same digest.
run 'a second run on an already-mirrored tag is green and reports the same digest' \
  "${creds[@]}" "${mirror}" steve-1.1.0
expect_status 0 && expect_out "@$(ghcr_digest steve-1.1.0)" && pass

reset
run 'the expected digest handed over by the publish job is accepted when it matches' \
  "${creds[@]}" "${mirror}" steve-1.1.0 "$(ghcr_digest steve-1.1.0)"
expect_status 0 && expect_copied && pass

# The tag moves to a single-manifest image the instant after it was
# resolved: the digest already in hand is what is validated and copied, so
# the mirror holds the index that was checked — and not the manifest the
# tag now names, which would have been refused had it been read.
reset
run 'a tag that moves after being resolved does not change what is mirrored' \
  env FAKE_TAG_MOVES_TO="${FAKE_REGISTRY}/v2/juherr/steve/manifests/steve-1.0.0" "${creds[@]}" "${mirror}" steve-1.1.0
expect_status 0 && expect_copied \
  && { cmp -s "${hub}/steve-1.1.0" "${FAKE_REGISTRY}/v2/juherr/steve/manifests/steve-1.0.0" \
       && { fail "the mirror holds what the tag moved to"; false; } || true; } \
  && { grep -q '"mediaType": "application/vnd.oci.image.index.v1+json"' "${hub}/steve-1.1.0" \
       || { fail "the mirror is not the index that was resolved"; false; }; } && pass

# --- refusals, before the copy -------------------------------------------

reset
run 'a tag that moved since the publish job made it is refused' \
  "${creds[@]}" "${mirror}" steve-1.1.0 sha256:0000000000000000000000000000000000000000000000000000000000000000
expect_status 1 && expect_err 'resolves to' && expect_err 'expected sha256:0000' && expect_untouched && expect_no_leftover && pass

reset
run 'a single-manifest tag is refused' \
  "${creds[@]}" "${mirror}" steve-1.0.0
expect_status 1 && expect_err 'not an image index' && expect_untouched && pass

reset
run 'an index with an attestation entry is refused' \
  "${creds[@]}" "${mirror}" steve-1.0.1
expect_status 1 && expect_err 'exactly linux/amd64 and linux/arm64' && expect_untouched && pass

reset
run 'an unpublished tag is refused' \
  "${creds[@]}" "${mirror}" steve-1.9.9
expect_status 1 && expect_err 'could not read ghcr.io/juherr/steve:steve-1.9.9' && expect_untouched && pass

# --- failures after the copy: said in so many words ------------------------

reset
run 'a copy that lands as something else fails, naming the tag on Docker Hub' \
  env FAKE_COPY_LANDS_AS="${FAKE_REGISTRY}/v2/juherr/steve/manifests/steve-1.0.0" "${creds[@]}" "${mirror}" steve-1.1.0
expect_status 1 && expect_err 'docker.io/juherr/steve:steve-1.1.0 reads back as' && expect_err 'check it by hand' && expect_copied && pass

reset
run 'a mirror that cannot be read back is not a mirror' \
  env FAKE_MIRROR_DOWN=1 "${creds[@]}" "${mirror}" steve-1.1.0
expect_status 1 && expect_err 'cannot be read back' && expect_err 'check it by hand' && pass

# --- usage ------------------------------------------------------------------

reset
run 'no credentials is a usage error' \
  env -u DOCKERHUB_USERNAME -u DOCKERHUB_TOKEN "${mirror}" steve-1.1.0
expect_status 2 && expect_err 'DOCKERHUB_USERNAME' && expect_untouched && pass

run 'a tag that is not steve-X.Y.Z is a usage error' \
  "${creds[@]}" "${mirror}" latest
expect_status 2 && expect_err 'Usage' && pass

# The workflow always passes two arguments; an empty second one is a
# broken hand-over from the publish job, not a hand run without one.
run 'an empty expected digest is a usage error, not a run without one' \
  "${creds[@]}" "${mirror}" steve-1.1.0 ''
expect_status 2 && expect_err 'Usage' && expect_untouched && pass

run 'a malformed expected digest is a usage error' \
  "${creds[@]}" "${mirror}" steve-1.1.0 pub-index
expect_status 2 && expect_err 'Usage' && pass

exit "${failed}"

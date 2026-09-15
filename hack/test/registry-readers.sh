#!/usr/bin/env bash
# Offline regression tests for the registry readers: hack/image-config.sh and
# the two scripts that read through it.
#
# The helper is on the release-gating path, and the shapes it must handle —
# an image index with attestations interleaved, an index without linux/amd64,
# an index of attestations only — do not exist under juherr/steve until #19
# ships. So they live here as fixtures (hack/test/registry/, one file per URL
# path), served by hack/test/fake-curl.sh from the PATH. Nothing here reaches
# the network, and the scripts under test are the real ones, unmodified.
#
# The callers run in a throwaway git repository whose HEAD is what the fixture
# image claims as its revision, so their full path is exercised — through an
# index, to the label, to the tree comparison — without a multi-arch tag on
# GHCR. That is the deterministic form of #28's "point both scripts at a
# multi-arch image", which neither script can do literally: preflight looks
# for the Dockerfile's tag, drift for the newest steve-X.Y.Z, and a foreign
# image has neither.
#
# Usage:  ./hack/test/registry-readers.sh
#         HACK_DIR=/path/to/older/hack ./hack/test/registry-readers.sh   # red/green
# Exit:   0 all passed · 1 otherwise

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
HACK_DIR="${HACK_DIR:-$(dirname "${here}")}"
helper="${HACK_DIR}/image-config.sh"
preflight="${HACK_DIR}/release-preflight.sh"
drift="${HACK_DIR}/release-drift.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/steve-ocpp-csms-image-registry-readers.XXXXXX")
trap 'rm -rf "${work}"' EXIT

# --- fixtures ---------------------------------------------------------------

mkdir -p "${work}/bin"
ln -s "${here}/fake-curl.sh" "${work}/bin/curl"
export PATH="${work}/bin:${PATH}"
export FAKE_REGISTRY="${work}/registry"
cp -R "${here}/registry" "${FAKE_REGISTRY}"

# A repository whose HEAD is the commit the fixture image was "built from".
repo="${work}/repo"
git init -q -b main "${repo}"
git -C "${repo}" -c user.name=test -c user.email=test@example.invalid \
  commit -q --allow-empty -m 'the commit the fixture image records'
git -C "${repo}" branch -q release
git -C "${repo}" remote add origin "${repo}"
revision=$(git -C "${repo}" rev-parse HEAD)
for blob in "${FAKE_REGISTRY}"/v2/juherr/steve/blobs/*; do
  sed -i.bak "s/@REVISION@/${revision}/" "${blob}" && rm "${blob}.bak"
done
printf 'ARG STEVE_REF=steve-1.0.1\n' > "${repo}/Dockerfile"

# --- harness ----------------------------------------------------------------

failed=0
out='' err='' status=0

# run <name> <command...>: captures stdout, stderr and the exit status. Every
# command runs from the throwaway repository, where the callers read the
# Dockerfile and git, and without the GitHub Actions variables — under them
# drift would write to the real step summary and format its warning as an
# annotation.
run() {
  name="$1"; shift
  set +e
  out=$(cd "${repo}" && env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY "$@" 2>"${work}/stderr"); status=$?
  set -e
  err=$(cat "${work}/stderr")
}

pass() { printf 'ok   %s\n' "${name}"; }
fail() { printf 'FAIL %s: %s\n  stdout: %s\n  stderr: %s\n' "${name}" "$1" "${out}" "${err}"; failed=1; }

expect_status() { [ "${status}" -eq "$1" ] || { fail "exit ${status}, expected $1"; return 1; }; }
expect_out()    { [[ "${out}" == *"$1"* ]] || { fail "stdout lacks '$1'"; return 1; }; }
expect_err()    { [[ "${err}" == *"$1"* ]] || { fail "stderr lacks '$1'"; return 1; }; }

# The helper's failure contract: exit 1, and its own one-line reason on stderr
# (curl's diagnostic may precede it — that is the part that says 404 vs 403).
expect_helper_failure() {
  expect_status 1 && expect_err "$1" \
    && { [ "$(grep -c '^image-config: ' <<<"${err}")" -eq 1 ] || fail "expected exactly one 'image-config:' line on stderr"; }
}
expect_config() { expect_status 0 && expect_out "\"architecture\": \"$1\""; }

# --- helper: shapes ---------------------------------------------------------

run 'single manifest: config is returned' \
  "${helper}" steve-1.0.0
expect_config amd64 && pass

run 'index: linux/amd64 is followed even when not first, attestations skipped' \
  "${helper}" steve-1.0.1
expect_config amd64 && pass

run 'index without amd64: first platform entry, not the attestation before it' \
  "${helper}" steve-1.0.2
expect_config arm64 && pass

run 'the label survives the walk' \
  "${helper}" steve-1.0.1
expect_status 0 && expect_out "\"org.opencontainers.image.revision\": \"${revision}\"" && pass

# IMAGE_ARCH: the build workflow asks for the runner's own architecture before
# running the upgrade scenario against the previous release. An index answers
# with that platform's config; an architecture the index lacks falls back like
# the amd64 default does; a single manifest is returned whatever is asked — the
# caller reads `.architecture` and decides.
run 'index: IMAGE_ARCH=arm64 follows the arm64 entry' \
  env IMAGE_ARCH=arm64 "${helper}" steve-1.0.1
expect_config arm64 && pass

run 'index: an IMAGE_ARCH it lacks falls back to the first platform entry' \
  env IMAGE_ARCH=s390x "${helper}" steve-1.0.1
expect_config arm64 && pass

run 'single manifest: IMAGE_ARCH is not a filter' \
  env IMAGE_ARCH=arm64 "${helper}" steve-1.0.0
expect_config amd64 && pass

# --- helper: failure contract ------------------------------------------------

run 'index of attestations only fails' \
  "${helper}" steve-1.0.3
expect_helper_failure 'no image manifest, only attestations' && pass

run 'manifest without a config digest fails' \
  "${helper}" steve-1.0.4
expect_helper_failure 'carries no config digest' && pass

run 'a non-JSON manifest fails through the helper, not through jq' \
  "${helper}" steve-1.0.5
expect_helper_failure 'is not JSON' && pass

run 'an unknown tag fails' \
  "${helper}" steve-9.9.9
expect_helper_failure 'could not read the manifest' && pass

run 'no argument fails' \
  "${helper}"
expect_helper_failure 'usage' && pass

# --- callers ----------------------------------------------------------------

run 'preflight reads through an index; identical packaging means nothing to ship' \
  "${preflight}"
expect_status 1 && expect_err "built from ${revision}" && pass

run 'drift reads through an index and finds release in sync' \
  "${drift}"
expect_status 0 && expect_out "In sync: steve-1.0.1 was built from ${revision}" && pass

printf 'ARG STEVE_REF=steve-1.0.3\n' > "${repo}/Dockerfile"

run 'preflight fails closed when the helper cannot resolve the tag' \
  env REGISTRY_REPO=juherr/broken "${preflight}"
expect_status 2 && expect_err 'CANNOT TELL' && expect_err 'image-config:' && pass

run 'drift warns and exits 0 when the helper cannot resolve the tag' \
  env REGISTRY_REPO=juherr/broken "${drift}"
expect_status 0 && expect_err 'WARNING: Could not read the image config of steve-1.0.3' && pass

printf 'ARG STEVE_REF=steve-1.0.1\n' > "${repo}/Dockerfile"

exit "${failed}"

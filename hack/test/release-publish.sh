#!/usr/bin/env bash
# Offline regression tests for the release-only path: hack/publish-index.sh,
# which makes the tag, and hack/check-pushed-digest.sh, which the build jobs
# run before handing a digest over.
#
# Neither runs on a pull request — both sit behind the `release` guard — so
# this is their only recurring coverage. They run here unmodified against
# the fixture registry (hack/test/registry/, served by fake-curl.sh) and a
# `docker` that records instead of acting (fake-docker.sh): the index it
# would merge is computed from the fixtures the way buildx merges, and every
# `imagetools create -t` it is asked for lands in a log. That log is what
# proves the invariant this file exists for — a candidate that fails a check
# never reaches the tag.
#
# Usage:  ./hack/test/release-publish.sh
#         HACK_DIR=/path/to/older/hack ./hack/test/release-publish.sh   # red/green
# Exit:   0 all passed · 1 otherwise

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=hack/test/lib.sh
. "${here}/lib.sh"
publish="${HACK_DIR}/publish-index.sh"

setup_fixtures

# The record fake-docker keeps of every `imagetools create -t`.
created() { if [ -f "${FAKE_DOCKER}/log" ]; then grep -c '^create -t ' "${FAKE_DOCKER}/log" || true; else echo 0; fi; }
reset_log() { rm -f "${FAKE_DOCKER}/log"; }
expect_published() {
  [ "$(created)" -eq 1 ] || { fail "expected exactly one create -t, got $(created)"; return 1; }
  expect_out 'Digest to pin:' && expect_out "ghcr.io/juherr/steve:$1@sha256:"
}
# A refusal is only worth something if it comes before the tag moves.
expect_untouched() {
  [ "$(created)" -eq 0 ] || { fail "the tag was created or moved: $(cat "${FAKE_DOCKER}/log")"; return 1; }
}

# --- publish-index.sh: the good candidate ---------------------------------

reset_log
run 'a valid pair is published as an index of the two platforms' \
  env EXPECTED_REVISION="${revision}" "${publish}" steve-1.0.1 sha256:pub-amd64 sha256:pub-arm64
expect_status 0 && expect_published steve-1.0.1 && pass

run 'the published tag reads back as exactly linux/amd64 and linux/arm64' \
  jq -c '[.manifests[].platform | "\(.os)/\(.architecture)"]' "${FAKE_REGISTRY}/v2/juherr/steve/manifests/steve-1.0.1"
expect_status 0 && expect_out '["linux/amd64","linux/arm64"]' && pass

# --- publish-index.sh: refusals -------------------------------------------

reset_log
run 'a digest built from another commit is refused' \
  env EXPECTED_REVISION="${revision}" "${publish}" steve-1.0.1 sha256:pub-amd64 sha256:pub-otherrev-arm64
expect_status 1 && expect_err "carries revision '0000000000000000000000000000000000000000'" && expect_untouched && pass

reset_log
run 'a digest of the wrong architecture is refused' \
  env EXPECTED_REVISION="${revision}" "${publish}" steve-1.0.1 sha256:pub-amd64 sha256:pub-amd64
expect_status 1 && expect_err 'is not a linux/arm64 image' && expect_untouched && pass

reset_log
run 'a digest that is an index with an attestation is refused' \
  env EXPECTED_REVISION="${revision}" "${publish}" steve-1.0.1 sha256:pub-amd64 sha256:pub-attested-arm64
expect_status 1 && expect_err 'not hold exactly linux/amd64 and linux/arm64' && expect_untouched && pass

reset_log
run 'a digest with an empty label is refused' \
  env EXPECTED_REVISION="${revision}" "${publish}" steve-1.0.1 sha256:pub-nocreated-amd64 sha256:pub-arm64
expect_status 1 && expect_err 'org.opencontainers.image.created' && expect_untouched && pass

# The contract is the nine org.opencontainers.image.* labels the Dockerfile
# sets, by name — not "whatever labels are there are non-empty".
reset_log
run 'a digest missing a required label is refused' \
  env EXPECTED_REVISION="${revision}" "${publish}" steve-1.0.1 sha256:pub-nodoc-amd64 sha256:pub-arm64
expect_status 1 && expect_err 'org.opencontainers.image.documentation' && expect_untouched && pass

reset_log
run 'an unknown digest is refused' \
  env EXPECTED_REVISION="${revision}" "${publish}" steve-1.0.1 sha256:pub-amd64 sha256:nowhere
expect_status 1 && expect_err 'sha256:nowhere' && expect_untouched && pass

run 'no EXPECTED_REVISION is a usage error' \
  env -u EXPECTED_REVISION "${publish}" steve-1.0.1 sha256:pub-amd64 sha256:pub-arm64
expect_status 2 && expect_err 'Usage' && pass

run 'a malformed digest is a usage error' \
  env EXPECTED_REVISION="${revision}" "${publish}" steve-1.0.1 pub-amd64 sha256:pub-arm64
expect_status 2 && expect_err 'Usage' && pass

exit "${failed}"

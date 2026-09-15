#!/usr/bin/env bash
# Publish `steve-X.Y.Z` as an image index of the two platform digests the
# build jobs pushed, and print the digest consumers pin — the index's.
#
# The build jobs push each architecture by digest, untagged; the tag is made
# here, once, from both. This is the one step that moves what every consumer
# resolves, so what it publishes is checked against the registry rather than
# against what was meant: exactly `linux/amd64` and `linux/arm64`, no
# attestation entry (an index of one platform, or one with `unknown/unknown`
# entries, is the shape a build without `--provenance=false` leaves behind —
# measured on #27), every `org.opencontainers.image.*` label non-empty on
# each platform manifest, and both built from EXPECTED_REVISION — the commit
# the workflow runs.
#
# It lives in a file rather than inline in the workflow so that it can be run
# against a fixture registry and a recording `docker` (hack/test/), where the
# invariants above are red/green tests instead of comments.
#
# Usage:  EXPECTED_REVISION=<sha> ./hack/publish-index.sh <tag> <amd64-digest> <arm64-digest>
# Env:    IMAGE               ghcr.io/<repo>, default ghcr.io/juherr/steve
#         EXPECTED_REVISION   the commit both digests must carry as revision
# Exit:   0 published · 1 refused · 2 usage

set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/juherr/steve}"

usage() { echo "Usage: EXPECTED_REVISION=<sha> $0 <tag> <amd64-digest> <arm64-digest>" >&2; exit 2; }
[ $# -eq 3 ] || usage
tag=$1; amd64=$2; arm64=$3
[ -n "${EXPECTED_REVISION:-}" ] || usage
for d in "${amd64}" "${arm64}"; do
  printf '%s' "${d}" | grep -Eq '^sha256:[^[:space:]]+$' || usage
done

# The helper reads GHCR, so IMAGE must be there — which is where the workflow
# points it; a local registry is not a case this script serves.
case "${IMAGE}" in ghcr.io/*) ;; *) echo "IMAGE must be under ghcr.io/, got '${IMAGE}'" >&2; exit 2 ;; esac
export REGISTRY_REPO="${IMAGE#ghcr.io/}"

die() { printf 'publish-index: %s\n' "$1" >&2; exit 1; }
summary() { cat >>"${GITHUB_STEP_SUMMARY:-/dev/null}"; }

docker buildx imagetools create -t "${IMAGE}:${tag}" "${IMAGE}@${amd64}" "${IMAGE}@${arm64}"

published=$(docker buildx imagetools inspect "${IMAGE}:${tag}" --format '{{ json .Manifest }}') \
  || die "could not read back ${IMAGE}:${tag}"
jq -e '[.manifests[].platform | "\(.os)/\(.architecture)"] | sort == ["linux/amd64", "linux/arm64"]' \
  <<<"${published}" >/dev/null \
  || die "${IMAGE}:${tag} does not hold exactly linux/amd64 and linux/arm64: $(jq -c '[.manifests[].platform]' <<<"${published}")"

for arch in amd64 arm64; do
  digest_var="${arch}"; digest="${!digest_var}"
  config=$(IMAGE_ARCH="${arch}" "$(dirname "$0")/image-config.sh" "${digest}") \
    || die "could not read the image config of ${digest}"
  jq -e '.config.Labels | to_entries | all(.value != "")' <<<"${config}" >/dev/null \
    || die "an empty label on linux/${arch} (${digest})"
  revision=$(jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' <<<"${config}")
  [ "${revision}" = "${EXPECTED_REVISION}" ] \
    || die "linux/${arch} (${digest}) carries revision '${revision}', expected ${EXPECTED_REVISION}"
done

index=$(docker buildx imagetools inspect "${IMAGE}:${tag}" --format '{{ .Manifest.Digest }}')
echo "Pushed: ${IMAGE}:${tag} (linux/amd64, linux/arm64)"
echo "Digest to pin:"
echo "${IMAGE}:${tag}@${index}"
summary <<EOF2
### Published \`${IMAGE}:${tag}\`

Index (the digest to pin): \`${index}\`

- linux/amd64: \`${amd64}\`
- linux/arm64: \`${arm64}\`
EOF2

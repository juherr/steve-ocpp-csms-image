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
# measured on #27), the nine `org.opencontainers.image.*` labels present and
# non-empty on each platform manifest, and both built from EXPECTED_REVISION
# — the commit the workflow runs.
#
# The index itself carries one annotation, `org.opencontainers.image.description`,
# copied from the platform manifests' label: GHCR reads a multi-arch package's
# description from the index, not from the manifests, and without it the
# package page says "No description provided" (measured on the first
# multi-arch steve-3.14.1). The Dockerfile's LABEL stays the one source; the
# index repeats it, and the two platforms have to agree on it.
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

# The labels the Dockerfile's runtime stage sets, by name: each must be on
# every platform manifest and non-empty. Named rather than "whatever is
# there is non-empty", so that a LABEL line lost from the Dockerfile refuses
# the release instead of shipping a tag GHCR can no longer attach to this
# repository (source) or that names no version.
labels=(
  org.opencontainers.image.source
  org.opencontainers.image.url
  org.opencontainers.image.documentation
  org.opencontainers.image.version
  org.opencontainers.image.created
  org.opencontainers.image.revision
  org.opencontainers.image.licenses
  org.opencontainers.image.title
  org.opencontainers.image.description
)
summary() { cat >>"${GITHUB_STEP_SUMMARY:-/dev/null}"; }

# Everything is checked on the candidate, before the tag exists: the two
# digests as the registry holds them, then the index they would merge into —
# `--dry-run` prints it and pushes nothing. A refusal below therefore leaves
# `${IMAGE}:${tag}` exactly where it was, which for a re-release is the
# previous image and for a first release is nowhere.
for arch in amd64 arm64; do
  digest_var="${arch}"; digest="${!digest_var}"
  config=$(IMAGE_ARCH="${arch}" "$(dirname "$0")/image-config.sh" "${digest}") \
    || die "could not read the image config of ${digest}"
  jq -e --arg arch "${arch}" '.os == "linux" and .architecture == $arch' <<<"${config}" >/dev/null \
    || die "${digest} is not a linux/${arch} image: $(jq -c '{os, architecture}' <<<"${config}")"
  for label in "${labels[@]}"; do
    [ -n "$(jq -r --arg l "${label}" '.config.Labels[$l] // empty' <<<"${config}")" ] \
      || die "linux/${arch} (${digest}) lacks the label ${label}, or it is empty"
  done
  revision=$(jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' <<<"${config}")
  [ "${revision}" = "${EXPECTED_REVISION}" ] \
    || die "linux/${arch} (${digest}) carries revision '${revision}', expected ${EXPECTED_REVISION}"
  label_description=$(jq -r '.config.Labels["org.opencontainers.image.description"]' <<<"${config}")
  if [ -z "${description:-}" ]; then
    description="${label_description}"
  elif [ "${label_description}" != "${description}" ]; then
    die "linux/${arch} (${digest}) differs on org.opencontainers.image.description: '${label_description}' vs '${description}'"
  fi
done
annotation="index:org.opencontainers.image.description=${description}"

candidate=$(docker buildx imagetools create --dry-run --annotation "${annotation}" "${IMAGE}@${amd64}" "${IMAGE}@${arm64}") \
  || die "could not compute the index of ${amd64} and ${arm64}"
jq -e --arg d "${description}" '.annotations["org.opencontainers.image.description"] == $d' <<<"${candidate}" >/dev/null \
  || die "the index would not carry the description as its annotation: $(jq -c '.annotations' <<<"${candidate}")"
jq -e '[.manifests[].platform | "\(.os)/\(.architecture)"] | sort == ["linux/amd64", "linux/arm64"]' \
  <<<"${candidate}" >/dev/null \
  || die "the index would not hold exactly linux/amd64 and linux/arm64: $(jq -c '[.manifests[].platform]' <<<"${candidate}")"
jq -e --arg amd64 "${amd64}" --arg arm64 "${arm64}" \
  '[.manifests[].digest] | sort == ([$amd64, $arm64] | sort)' <<<"${candidate}" >/dev/null \
  || die "the index would not point at the two digests given: $(jq -c '[.manifests[].digest]' <<<"${candidate}")"

docker buildx imagetools create -t "${IMAGE}:${tag}" --annotation "${annotation}" "${IMAGE}@${amd64}" "${IMAGE}@${arm64}"

# Read back: the tag must now resolve to the candidate that was checked. A
# mismatch here is a registry-side surprise and exits 1 with the tag already
# moved, which is why it is said in so many words.
published=$(docker buildx imagetools inspect "${IMAGE}:${tag}" --format '{{ json .Manifest }}') \
  || die "could not read back ${IMAGE}:${tag} — the tag has been created, check it by hand"
if [ "$(jq -cS '{manifests, annotations}' <<<"${published}")" != "$(jq -cS '{manifests, annotations}' <<<"${candidate}")" ]; then
  die "${IMAGE}:${tag} was created but does not read back as the candidate that was checked: $(jq -c '{manifests, annotations}' <<<"${published}")"
fi

index=$(docker buildx imagetools inspect "${IMAGE}:${tag}" --format '{{ .Manifest.Digest }}')
echo "Pushed: ${IMAGE}:${tag} (linux/amd64, linux/arm64)"
echo "Digest to pin:"
echo "${IMAGE}:${tag}@${index}"
# Handed to the mirror job as a step output: it copies this digest, not
# whatever the tag resolves to when it runs.
[ -z "${GITHUB_OUTPUT:-}" ] || echo "index_digest=${index}" >> "${GITHUB_OUTPUT}"
summary <<EOF2
### Published \`${IMAGE}:${tag}\`

Index (the digest to pin): \`${index}\`

- linux/amd64: \`${amd64}\`
- linux/arm64: \`${arm64}\`
EOF2

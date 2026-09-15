#!/usr/bin/env bash
# Print the image config of a published tag — the JSON that carries the
# org.opencontainers.image.* labels.
#
# Three readers need it: hack/release-preflight.sh, hack/release-drift.sh and
# the recipe in CLAUDE.md. All three used to take `.config.digest` straight off
# the tag's manifest, which holds only while the tag *is* an image manifest.
# Once a tag resolves to an image index (multi-arch, #19), that read breaks —
# and not gently: asked for a single manifest on an index tag, GHCR answers
# 404 rather than the index (measured on aquasecurity/trivy:latest, 2026-09-15).
# The preflight would then refuse every release, and drift would go silent.
#
# So this walks both shapes. On an index it takes the linux/amd64 entry, or
# failing that the first platform entry: the `revision` label is the same on
# every platform of one build, so one platform answers the question the
# callers ask. The entries it skips are buildx attestations — `unknown/unknown`
# platform, annotated `vnd.docker.reference.type: attestation-manifest` — which
# carry no image config at all.
#
# Every failure exits 1 with one `image-config:` line on stderr saying why;
# when the registry is the cause, curl's own diagnostic comes first, kept on
# purpose because it is the part that says 404 rather than 403. What a failure
# means is the caller's decision, which is how the preflight keeps failing
# closed while drift keeps reporting only.
#
# Usage:  ./hack/image-config.sh <tag-or-digest>
#         REGISTRY_REPO=aquasecurity/trivy ./hack/image-config.sh latest

set -euo pipefail

REGISTRY_REPO="${REGISTRY_REPO:-juherr/steve}"

die() { printf 'image-config: %s\n' "$1" >&2; exit 1; }

ref="${1:-}"
[ -n "${ref}" ] || die "usage: $0 <tag-or-digest>"

# Listing every shape the registry may hold under the tag is what lets a
# single-manifest tag and an index tag be read by the same request.
accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

token=$(curl -fsS \
  "https://ghcr.io/token?scope=repository:${REGISTRY_REPO}:pull&service=ghcr.io" \
  | jq -r '.token // empty') \
  || die "no pull token from GHCR for ${REGISTRY_REPO}"
[ -n "${token}" ] || die "GHCR returned an empty pull token for ${REGISTRY_REPO}"

manifest=$(curl -fsS -H "Authorization: Bearer ${token}" -H "Accept: ${accept}" \
  "https://ghcr.io/v2/${REGISTRY_REPO}/manifests/${ref}") \
  || die "could not read the manifest of ${ref}"

# An index has `.manifests`; an image manifest has `.config`.
platform=$(jq -r '
  if .manifests then
    [.manifests[] | select(.annotations["vnd.docker.reference.type"] != "attestation-manifest")]
    | (map(select(.platform.os == "linux" and .platform.architecture == "amd64")) + .)
    | first.digest // empty
  else empty end' <<<"${manifest}") \
  || die "the manifest of ${ref} is not JSON"

if [ -n "${platform}" ]; then
  manifest=$(curl -fsS -H "Authorization: Bearer ${token}" -H "Accept: ${accept}" \
    "https://ghcr.io/v2/${REGISTRY_REPO}/manifests/${platform}") \
    || die "could not read the platform manifest ${platform} of ${ref}"
elif jq -e '.manifests' <<<"${manifest}" >/dev/null; then
  die "the index of ${ref} has no image manifest, only attestations"
fi

config=$(jq -r '.config.digest // empty' <<<"${manifest}") \
  || die "the platform manifest ${platform} of ${ref} is not JSON"
[ -n "${config}" ] || die "the manifest of ${ref} carries no config digest"

curl -fsSL -H "Authorization: Bearer ${token}" \
  "https://ghcr.io/v2/${REGISTRY_REPO}/blobs/${config}" \
  || die "could not read the image config ${config} of ${ref}"

#!/usr/bin/env bash
# Would releasing HEAD publish anything, or just move a digest?
#
# `steve-X.Y.Z` is one tag per upstream release, and consumers pin by digest
# with the tag alongside as documentation. Republishing that tag when nothing
# about the packaging changed swaps the digest under everyone for no reason —
# the exact failure that took the release off `main` in the first place. Git
# cannot see it: `release..main` can be full of documentation commits while the
# image that would come out is byte-for-byte the current one.
#
# So: read the tag HEAD would ship, ask GHCR whether it is already published,
# and if it is, compare the packaging of the commit it was built from with
# HEAD's. Identical means there is nothing to ship.
#
# A *differing* packaging under an already-published tag is fine and expected —
# a Temurin bump republishes the same tag with a new digest by design (see the
# README under Tags). This checks for a no-op, not for a re-publish.
#
# Unlike hack/release-drift.sh, which reports and never gates, this one gates
# and therefore fails closed: if GHCR cannot be reached we do not know whether
# the tag exists, and "release anyway" is the wrong default for the branch that
# ships to every consumer.
#
# Usage:  ./hack/release-preflight.sh
# Exit:   0 proceed · 1 nothing to ship · 2 cannot tell

set -euo pipefail

REGISTRY_REPO="${REGISTRY_REPO:-juherr/steve}"

# The files whose content reaches the image — the same set hack/release-drift.sh
# compares, for the same reason: workflows are orchestration and do not belong
# in a question about what the image contains.
paths=(Dockerfile .dockerignore entrypoint.sh flyway-callbacks)

die() { printf 'CANNOT TELL: %s\n' "$1" >&2; exit 2; }

steve_ref=$(sed -n 's/^ARG STEVE_REF=//p' Dockerfile | head -1)
if ! printf '%s' "${steve_ref}" | grep -Eq '^steve-[0-9]+\.[0-9]+\.[0-9]+$'; then
  die "invalid ARG STEVE_REF in Dockerfile: '${steve_ref}' (expected steve-X.Y.Z)"
fi

token=$(curl -fsS \
  "https://ghcr.io/token?scope=repository:${REGISTRY_REPO}:pull&service=ghcr.io" \
  | jq -r '.token // empty') \
  || die "no pull token from GHCR for ${REGISTRY_REPO}"
[ -n "${token}" ] || die "GHCR returned an empty pull token for ${REGISTRY_REPO}"

published_tags=$(curl -fsS -H "Authorization: Bearer ${token}" \
  "https://ghcr.io/v2/${REGISTRY_REPO}/tags/list?n=1000" | jq -r '(.tags // [])[]') \
  || die "could not list the tags of ${REGISTRY_REPO}"

if ! printf '%s\n' "${published_tags}" | grep -qx "${steve_ref}"; then
  echo "OK: ${steve_ref} is not published yet — this release creates it."
  exit 0
fi

# Already published. Whether shipping again is meaningful depends on the commit
# it was built from, which the image records and nothing else does.
config=$(curl -fsS -H "Authorization: Bearer ${token}" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  "https://ghcr.io/v2/${REGISTRY_REPO}/manifests/${steve_ref}" \
  | jq -r '.config.digest // empty') \
  || die "could not read the manifest of ${steve_ref}"
[ -n "${config}" ] || die "the manifest of ${steve_ref} carries no config digest"

revision=$(curl -fsSL -H "Authorization: Bearer ${token}" \
  "https://ghcr.io/v2/${REGISTRY_REPO}/blobs/${config}" \
  | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty') \
  || die "could not read the image config of ${steve_ref}"

if [ -z "${revision}" ] || ! git cat-file -e "${revision}^{commit}" 2>/dev/null; then
  # Built elsewhere, or from history this clone does not have. No basis for
  # comparison, and guessing in either direction is worse than saying so.
  die "${steve_ref} carries revision '${revision}', which is not a commit here"
fi

if git diff --quiet "${revision}" HEAD -- "${paths[@]}"; then
  cat >&2 <<EOF
NOTHING TO SHIP: ${steve_ref} is already published, built from ${revision},
whose packaging is identical to HEAD's. Releasing would republish the same image
under a new digest and move the tag for every consumer pinning it.

Bump ARG STEVE_REF in the Dockerfile, or — to deliberately rebuild this tag,
after a failed publish — run the "Build SteVe image" workflow on the release
branch.
EOF
  exit 1
fi

echo "OK: ${steve_ref} is published from ${revision}, whose packaging differs from HEAD's."
git diff --stat "${revision}" HEAD -- "${paths[@]}"

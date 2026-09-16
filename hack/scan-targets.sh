#!/usr/bin/env bash
# Print the images scan-published.yml has to scan: one {tag, arch} per
# platform each of the newest release tags on GHCR actually carries, as the
# JSON `include` list of the scan matrix.
#
# Given an image index, `trivy image` scans the platform matching the runner —
# linux/amd64 — and never looks at the other, so the workflow scans each
# platform as its own matrix job, with `--platform`. The candidates are the
# two platforms the build produces, amd64 and arm64, and nothing else is
# looked for; but rather than assuming a tag carries both, the registry is
# probed for each, because Trivy given `--platform linux/arm64` on a single
# amd64 manifest — every tag published before the image went multi-arch —
# does not fail: it ignores the option and scans the amd64 image (measured,
# 0.74.0). Assuming both would file those findings under an `-arm64`
# category. The probe is the same test the build workflow makes before its
# upgrade scenario: ask hack/image-config.sh for that architecture and keep
# the pair only when the answer is the one asked for — on a single manifest,
# and on an index lacking that platform, the helper answers with what the tag
# does carry. A third architecture added to the build has to be added to the
# candidates below as well, or it ships unscanned.
#
# Only the three most recent releases, and only steve-X.Y.Z tags: an immutable
# old tag's CVE list only ever grows and the answer for whoever pinned it is
# always "move up", which the newest scan already says; scanning it for ever
# would leave one stale `trivy-<retired tag>-<arch>` category in the Security
# tab per release and platform. Sorted on the numeric components — lexically
# steve-3.9.0 sorts after steve-3.13.0.
#
# A tag the helper cannot read fails the whole listing, with nothing on stdout:
# that is a broken publication, not a scan to skip quietly. Every failure exits
# 1 with one `scan-targets:` line on stderr, after the helper's own reason.
# The matrix is the workflow's, not this script's, so it lives here for the
# reason release-drift.sh does: so that verifying it means running it — under
# hack/test/registry-readers.sh, against the fixture shapes, offline.
#
# Usage:  ./hack/scan-targets.sh
#         REGISTRY_REPO=juherr/steve ./hack/scan-targets.sh

set -euo pipefail

REGISTRY_REPO="${REGISTRY_REPO:-juherr/steve}"
helper="$(dirname "$0")/image-config.sh"

die() { printf 'scan-targets: %s\n' "$1" >&2; exit 1; }

token=$(curl -fsS \
  "https://ghcr.io/token?scope=repository:${REGISTRY_REPO}:pull&service=ghcr.io" \
  | jq -r '.token // empty') \
  || die "no pull token from GHCR for ${REGISTRY_REPO}"
[ -n "${token}" ] || die "GHCR returned an empty pull token for ${REGISTRY_REPO}"

tags=$(curl -fsS -H "Authorization: Bearer ${token}" \
  "https://ghcr.io/v2/${REGISTRY_REPO}/tags/list?n=1000" \
  | jq -r '[(.tags // [])[] | select(test("^steve-[0-9]+\\.[0-9]+\\.[0-9]+$"))]
           | sort_by(ltrimstr("steve-") | split(".") | map(tonumber))
           | .[-3:][]') \
  || die "could not list the tags of ${REGISTRY_REPO}"

targets='[]'
for tag in ${tags}; do
  for arch in amd64 arm64; do
    found=$(IMAGE_ARCH="${arch}" "${helper}" "${tag}" | jq -r '.architecture // empty') \
      || die "could not read ${tag}"
    if [ "${found}" = "${arch}" ]; then
      targets=$(jq -c --arg tag "${tag}" --arg arch "${arch}" '. + [{tag: $tag, arch: $arch}]' <<<"${targets}")
    fi
  done
done

echo "${targets}"

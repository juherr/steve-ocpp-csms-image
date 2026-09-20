#!/usr/bin/env bash
# Mirror a published `steve-X.Y.Z` from GHCR to Docker Hub, and read it back.
#
# GHCR is the canonical registry; Docker Hub is a second place to find the
# same image, for the people who look there first. So nothing is built and
# nothing is assembled here: the index the `publish` job made is copied as it
# is, with `crane copy`, which pushes the index and its two platform manifests
# byte for byte — the digest consumers pin is the same string on both
# registries (measured: same index digest and annotation on both sides, a
# second copy is a no-op the tool reports as "existing manifest").
# `docker buildx imagetools create`, the tool the publish step uses, cannot do
# this: its sources "must already exist in the registry where the new
# manifest is created" (its reference), which rules out a cross-registry copy.
#
# What is checked, and in which order: the tag is resolved to its digest,
# once, and compared with the one the caller hands over when it does — the
# publish job always does, and the tag must still resolve to what it just
# made. From there nothing reads the tag again: the digest is the source of
# the shape check — an index of exactly `linux/amd64` and `linux/arm64`, a
# tag from before the multi-arch build is not mirrored, the README promises
# both platforms on Docker Hub — of the login and copy, and of the read-back:
# same index digest, same platform digests. A read-back that disagrees
# or cannot be made exits 1 with the Docker Hub tag named — the tag exists
# there by then, and the message says to check it by hand rather than
# suggesting a retry would clear it.
#
# The Docker Hub credentials come from the environment and go to crane on
# stdin — `crane auth login --password-stdin` into a config directory made
# here and removed on exit, mounted into the crane container. Not `docker
# login`: the daemon never holds the token, and on a laptop Docker Desktop
# writes `credsStore` into whatever DOCKER_CONFIG it is given, which crane
# cannot read (measured on macOS). crane's login does not check the
# password; a wrong token fails at the copy, with a 401 from Docker Hub.
#
# It lives in a file so that the fixture registry and a recording `docker`
# (hack/test/mirror-tag.sh) exercise it, and so that it runs by hand — the
# first mirror of a tag published before this script existed, or a re-run
# after a Hub outage, with your own Docker Hub token and no build.
#
# Usage:  DOCKERHUB_USERNAME=<user> DOCKERHUB_TOKEN=<token> ./hack/mirror-tag.sh <tag> [index-digest]
# Env:    IMAGE         source, default ghcr.io/juherr/steve
#         MIRROR        destination, default docker.io/juherr/steve
#         CRANE_IMAGE   the crane image; default is the pin in build-image.yml
# Exit:   0 mirrored · 1 refused, or the mirror does not read back · 2 usage

set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/juherr/steve}"
MIRROR="${MIRROR:-docker.io/juherr/steve}"

usage() { echo "Usage: DOCKERHUB_USERNAME=<user> DOCKERHUB_TOKEN=<token> $0 <tag> [index-digest]" >&2; exit 2; }
[ $# -ge 1 ] && [ $# -le 2 ] || usage
tag=$1; expected=${2:-}
printf '%s' "${tag}" | grep -Eq '^steve-[0-9]+\.[0-9]+\.[0-9]+$' || usage
# Two arguments means the caller had a digest to hand over — the workflow
# always does; an empty one there is a broken hand-over, not a hand run —
# and a digest is `sha256:` and 64 hex digits, nothing shorter or looser.
[ $# -eq 1 ] || printf '%s' "${expected}" | grep -Eq '^sha256:[0-9a-f]{64}$' || usage
for var in DOCKERHUB_USERNAME DOCKERHUB_TOKEN; do
  [ -n "${!var:-}" ] || { echo "${var} is not set." >&2; usage; }
done

# One copy of the pin: the workflow's env block, which Renovate moves.
if [ -z "${CRANE_IMAGE:-}" ]; then
  workflow="$(dirname "$0")/../.github/workflows/build-image.yml"
  CRANE_IMAGE=$(sed -n 's/^  CRANE_IMAGE: "\(.*\)"$/\1/p' "${workflow}")
  [ -n "${CRANE_IMAGE}" ] || { echo "CRANE_IMAGE is unset and no pin was found in ${workflow}" >&2; exit 2; }
fi

die() { printf 'mirror-tag: %s\n' "$1" >&2; exit 1; }
summary() { cat >>"${GITHUB_STEP_SUMMARY:-/dev/null}"; }

config=$(mktemp -d "${TMPDIR:-/tmp}/steve-mirror.XXXXXX")
trap 'rm -rf "${config}"' EXIT
crane() { docker run --rm -i -v "${config}:/config" -e DOCKER_CONFIG=/config "${CRANE_IMAGE}" "$@"; }

# --- the source, before anything is written --------------------------------
#
# The tag is resolved exactly once. Everything after — the shape check, the
# copy, the read-back comparison — goes by `${IMAGE}@${source}`, which cannot
# move: a tag re-read for the copy could name another index than the one
# that was checked, and the guarantee here is that what lands on Docker Hub
# is the digest the publish job printed.

source=$(crane digest "${IMAGE}:${tag}") || die "could not read ${IMAGE}:${tag}"
if [ -n "${expected}" ] && [ "${source}" != "${expected}" ]; then
  die "${IMAGE}:${tag} resolves to ${source}, expected ${expected} — the tag moved since it was published"
fi
from="${IMAGE}@${source}"
manifest=$(crane manifest "${from}") || die "could not read ${from}"
jq -e '.manifests' <<<"${manifest}" >/dev/null \
  || die "${IMAGE}:${tag} is not an image index — a tag from before the multi-arch build is not mirrored"
jq -e '[.manifests[].platform | "\(.os)/\(.architecture)"] | sort == ["linux/amd64", "linux/arm64"]' \
  <<<"${manifest}" >/dev/null \
  || die "${IMAGE}:${tag} does not hold exactly linux/amd64 and linux/arm64: $(jq -c '[.manifests[].platform]' <<<"${manifest}")"

# --- the copy ----------------------------------------------------------------

printf '%s' "${DOCKERHUB_TOKEN}" | crane auth login "${MIRROR%%/*}" -u "${DOCKERHUB_USERNAME}" --password-stdin >/dev/null \
  || die "could not log in to ${MIRROR%%/*} as ${DOCKERHUB_USERNAME}"
crane copy "${from}" "${MIRROR}:${tag}" || die "could not copy ${from} to ${MIRROR}:${tag}"

# --- read back ---------------------------------------------------------------
#
# The mirror's tag is resolved once too; the platform check reads the digest
# it resolved to, so another writer moving the tag in between neither passes
# its index off as this copy nor fails a copy that landed as checked.

mirrored=$(crane digest "${MIRROR}:${tag}") \
  || die "${MIRROR}:${tag} cannot be read back after the copy — check it by hand"
[ "${mirrored}" = "${source}" ] \
  || die "${MIRROR}:${tag} reads back as ${mirrored}, not the ${source} that was copied — check it by hand"
platforms=$(crane manifest "${MIRROR}@${mirrored}" | jq -c '[.manifests[] | {digest, platform}] | sort_by(.digest)') \
  || die "${MIRROR}:${tag} cannot be read back after the copy — check it by hand"
[ "${platforms}" = "$(jq -c '[.manifests[] | {digest, platform}] | sort_by(.digest)' <<<"${manifest}")" ] \
  || die "${MIRROR}:${tag} does not list the platform digests of ${IMAGE}:${tag}: ${platforms} — check it by hand"

echo "Mirrored: ${MIRROR}:${tag}@${source}"
echo "Same index as ${IMAGE}:${tag} — the digest to pin is the one string on both registries."
summary <<EOF2
### Mirrored to \`${MIRROR}:${tag}\`

Same index as \`${IMAGE}:${tag}\`, digest \`${source}\` on both registries.
EOF2

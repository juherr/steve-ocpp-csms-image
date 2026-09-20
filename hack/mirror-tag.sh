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
# What is checked, and in which order: the source tag is an index of exactly
# `linux/amd64` and `linux/arm64` — a tag from before the multi-arch build is
# not mirrored, the README promises both platforms on Docker Hub — and, when
# the caller hands over the digest it just published, that the tag still
# resolves to it. Only then the login and the copy, and the mirror is read
# back: same index digest, same platform digests. A read-back that disagrees
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
[ -z "${expected}" ] || printf '%s' "${expected}" | grep -Eq '^sha256:[^[:space:]]+$' || usage
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

manifest=$(crane manifest "${IMAGE}:${tag}") || die "could not read ${IMAGE}:${tag}"
jq -e '.manifests' <<<"${manifest}" >/dev/null \
  || die "${IMAGE}:${tag} is not an image index — a tag from before the multi-arch build is not mirrored"
jq -e '[.manifests[].platform | "\(.os)/\(.architecture)"] | sort == ["linux/amd64", "linux/arm64"]' \
  <<<"${manifest}" >/dev/null \
  || die "${IMAGE}:${tag} does not hold exactly linux/amd64 and linux/arm64: $(jq -c '[.manifests[].platform]' <<<"${manifest}")"
source=$(crane digest "${IMAGE}:${tag}") || die "could not read the digest of ${IMAGE}:${tag}"
if [ -n "${expected}" ] && [ "${source}" != "${expected}" ]; then
  die "${IMAGE}:${tag} resolves to ${source}, expected ${expected} — the tag moved since it was published"
fi

# --- the copy ----------------------------------------------------------------

printf '%s' "${DOCKERHUB_TOKEN}" | crane auth login "${MIRROR%%/*}" -u "${DOCKERHUB_USERNAME}" --password-stdin >/dev/null \
  || die "could not log in to ${MIRROR%%/*} as ${DOCKERHUB_USERNAME}"
crane copy "${IMAGE}:${tag}" "${MIRROR}:${tag}" || die "could not copy ${IMAGE}:${tag} to ${MIRROR}:${tag}"

# --- read back ---------------------------------------------------------------

mirrored=$(crane digest "${MIRROR}:${tag}") \
  || die "${MIRROR}:${tag} cannot be read back after the copy — check it by hand"
[ "${mirrored}" = "${source}" ] \
  || die "${MIRROR}:${tag} reads back as ${mirrored}, not the ${source} that was copied — check it by hand"
platforms=$(crane manifest "${MIRROR}:${tag}" | jq -c '[.manifests[] | {digest, platform}] | sort_by(.digest)') \
  || die "${MIRROR}:${tag} cannot be read back after the copy — check it by hand"
[ "${platforms}" = "$(jq -c '[.manifests[] | {digest, platform}] | sort_by(.digest)' <<<"${manifest}")" ] \
  || die "${MIRROR}:${tag} does not list the platform digests of ${IMAGE}:${tag}: ${platforms} — check it by hand"

echo "Mirrored: ${MIRROR}:${tag}@${source}"
echo "Same index as ${IMAGE}:${tag} — the digest to pin is the one string on both registries."
summary <<EOF2
### Mirrored to \`${MIRROR}:${tag}\`

Same index as \`${IMAGE}:${tag}\`, digest \`${source}\` on both registries.
EOF2

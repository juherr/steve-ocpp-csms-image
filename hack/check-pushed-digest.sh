#!/usr/bin/env bash
# Is the digest a build job just pushed the image it probed?
#
# Each build job builds once with `--load`, runs the probes on that image, and
# exports the same build again by digest — a cache hit when the inputs are
# identical, and a silent rebuild when they are not (a BUILD_DATE taken twice
# would do it). The rebuilt image would pass every check downstream and still
# be a binary nobody ran. So: the pushed manifest's config, read back from the
# registry through hack/image-config.sh, must describe the loaded image —
# same architecture, same layer diff_ids in the same order. Measured to hold
# on a cache hit (the config came back byte-identical, `created` included).
#
# Usage:  ./hack/check-pushed-digest.sh <local-image> <digest>
# Env:    IMAGE   ghcr.io/<repo> the digest was pushed to, default ghcr.io/juherr/steve
# Exit:   0 same image · 1 not the same, or cannot tell · 2 usage

set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/juherr/steve}"

usage() { echo "Usage: $0 <local-image> <digest>" >&2; exit 2; }
[ $# -eq 2 ] || usage
local_image=$1; digest=$2
printf '%s' "${digest}" | grep -Eq '^sha256:[^[:space:]]+$' || usage
case "${IMAGE}" in ghcr.io/*) ;; *) echo "IMAGE must be under ghcr.io/, got '${IMAGE}'" >&2; exit 2 ;; esac
export REGISTRY_REPO="${IMAGE#ghcr.io/}"

die() { printf 'check-pushed-digest: %s\n' "$1" >&2; exit 1; }

arch=$(docker inspect --format '{{ .Architecture }}' "${local_image}") \
  || die "no local image ${local_image}"
loaded=$(docker inspect --format '{{ json .RootFS.Layers }}' "${local_image}" | jq -c .) \
  || die "could not read the layers of ${local_image}"

config=$(IMAGE_ARCH="${arch}" "$(dirname "$0")/image-config.sh" "${digest}") \
  || die "could not read the image config of ${digest}"
pushed_arch=$(jq -r '.architecture // empty' <<<"${config}")
pushed=$(jq -c '.rootfs.diff_ids // empty' <<<"${config}")

[ "${pushed_arch}" = "${arch}" ] \
  || die "${digest} is ${pushed_arch:-of no architecture}, the probed image is ${arch}"
if [ "${pushed}" != "${loaded}" ]; then
  {
    echo "${digest} does not have the layers of the image that was probed:"
    echo "  probed: ${loaded}"
    echo "  pushed: ${pushed}"
  } >&2
  die "${digest} is not the probed ${local_image}"
fi
echo "${digest} is the probed ${local_image} (linux/${arch}, $(jq 'length' <<<"${loaded}") layers)"

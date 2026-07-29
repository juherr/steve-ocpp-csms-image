#!/usr/bin/env bash
# Does the published image match what `release` says was shipped?
#
# Publishing is a push to `release`, so git already answers "what is waiting to
# go out" — `git log release..main`, offline, instantly. Git cannot answer the
# other question: whether that push actually produced an image. A build that
# fails after `release` has moved leaves the branch claiming a release that
# never landed, and the next person to diff the branches sees nothing pending
# and believes the image is current. Only the registry knows, and it is the one
# source that cannot lie about it.
#
# So this reads org.opencontainers.image.revision off the newest published tag
# and compares it with `release`. `main` being ahead of `release` is reported
# too, but as information, not a warning: an unreleased change is a deliberate
# state, and warning about it would be crying wolf at the normal case.
#
# It lives in a file rather than inline in the workflow so that verifying it
# means *running* it rather than retyping its logic into a terminal. That
# distinction is not academic: a hand-retyped version of this check once passed
# under zsh, which does not word-split unquoted variables, and so filtered on a
# single path that does not exist — reporting "in sync" while the trees
# differed. The shebang above is the fix; `${paths[@]}` below is the belt.
#
# Usage:  ./hack/release-drift.sh
# Always exits 0 — this reports, it does not gate.

set -euo pipefail

REGISTRY_REPO="${REGISTRY_REPO:-juherr/steve}"

# The files whose content reaches the image. Workflows are deliberately absent:
# an edit there *can* change the built image (a new build-arg would), but most
# are orchestration, and a warning that fires on every workflow tweak stops
# being read within a month.
paths=(Dockerfile .dockerignore entrypoint.sh flyway-callbacks)

# GitHub Actions renders `::warning::` and `::notice::` as annotations; a
# terminal should not have to read them.
in_ci() { [ -n "${GITHUB_ACTIONS:-}" ]; }
warn() { if in_ci; then printf '::warning::%s\n' "$1"; else printf 'WARNING: %s\n' "$1" >&2; fi; }
notice() { if in_ci; then printf '::notice::%s\n' "$1"; else printf 'NOTE: %s\n' "$1"; fi; }
summary() { cat >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"; }

git fetch --quiet --prune origin '+refs/heads/*:refs/remotes/origin/*'

token=$(curl -fsS \
  "https://ghcr.io/token?scope=repository:${REGISTRY_REPO}:pull&service=ghcr.io" \
  | jq -r .token)

tag=$(curl -fsS -H "Authorization: Bearer ${token}" \
  "https://ghcr.io/v2/${REGISTRY_REPO}/tags/list?n=1000" \
  | jq -r '[(.tags // [])[] | select(test("^steve-[0-9]+\\.[0-9]+\\.[0-9]+$"))]
           | sort_by(ltrimstr("steve-") | split(".") | map(tonumber))
           | last // empty')
if [ -z "${tag}" ]; then
  echo "Nothing published yet — nothing to compare."
  exit 0
fi

config=$(curl -fsS -H "Authorization: Bearer ${token}" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  "https://ghcr.io/v2/${REGISTRY_REPO}/manifests/${tag}" | jq -r .config.digest)
published=$(curl -fsSL -H "Authorization: Bearer ${token}" \
  "https://ghcr.io/v2/${REGISTRY_REPO}/blobs/${config}" \
  | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty')

if [ -z "${published}" ] || ! git cat-file -e "${published}^{commit}" 2>/dev/null; then
  warn "${tag} carries revision '${published}', which is not a commit in this repository — it predates the current history, or was built elsewhere. Cannot compare."
  exit 0
fi

# Before the release branch exists, fall back to main so this is useful from the
# first run rather than silently inert.
if git rev-parse --verify --quiet origin/release >/dev/null; then
  shipped="origin/release"
else
  shipped="origin/main"
  notice "No 'release' branch yet — comparing against main."
fi

# Compare the trees, not the commit count. It answers the question being asked —
# does the published image's packaging differ from what was meant to ship — and
# it stays right when a change is made and reverted, where counting commits
# would report two and mean nothing.
if git diff --quiet "${published}" "${shipped}" -- "${paths[@]}"; then
  echo "In sync: ${tag} was built from ${published}, whose packaging is ${shipped}'s."
else
  warn "The packaging on ${shipped} and that of the published ${tag} (built from ${published}) have diverged. Usually a publish that did not land; also possible if the release branch moved backwards. Re-run \"Build SteVe image\" from the release branch."
  {
    echo "### Published image does not match \`${shipped}\`"
    echo
    echo "\`${tag}\` was built from \`${published}\`, and its packaging differs from \`${shipped}\`:"
    echo
    echo '```'
    git diff --stat "${published}" "${shipped}" -- "${paths[@]}"
    echo '```'
    git log --format='- %h %s' "${published}..${shipped}" -- "${paths[@]}"
  } | summary
fi

# Informational only. main ahead of release is the normal state between a merge
# and the release that ships it.
if [ "${shipped}" = "origin/release" ] \
   && ! git diff --quiet origin/release origin/main -- "${paths[@]}"; then
  {
    echo "### Packaging changes waiting on \`main\`"
    echo
    git log --format='- %h %s' origin/release..origin/main -- "${paths[@]}"
    echo
    echo "Ship them with \`git push origin main:release\`."
  } | summary
  echo "Packaging changes are waiting on main — normal between a merge and the release that ships them."
fi

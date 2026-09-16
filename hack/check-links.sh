#!/usr/bin/env bash
# Are the links in the documentation still alive?
#
# README.md, AGENTS.md, CLAUDE.md and NOTICE point at upstream issues, Flyway,
# Temurin, GHCR and this repository's own files. A link does not break on the
# pull request that adds it; it breaks months later, when the page moves — the
# same shape as a published image drifting from clean, and answered the same
# way: a recurring check of what is there, not a gate on what arrives. This
# runs lychee over every tracked Markdown file and NOTICE, so a document added
# later is checked on arrival, and puts the report where the caller can read
# it: stdout, and the step summary when there is one.
#
# Usage:  ./hack/check-links.sh    (from anywhere in the repository)
# Env:    LYCHEE_IMAGE         the lychee image to run; defaults to the pin in
#                              the repository's .github/workflows/check-links.yml
#                              so that there is one copy of it
#         GITHUB_TOKEN         passed through to lychee, which checks github.com
#                              links through the API with it instead of running
#                              into the anonymous rate limit
#         GITHUB_STEP_SUMMARY  the report is appended there when set
# Exit:   0 every link reachable · 1 a link is not · 2 usage or tooling —
#         a lychee that could not check is not a clean tree

set -euo pipefail

# The tree under check is the repository of the working directory, and so is
# the workflow the image pin is read from — not a path relative to the
# script, which would leave the repository when the script is invoked
# relatively from a subdirectory.
root=$(git rev-parse --show-toplevel)
cd "${root}"

die() { printf 'check-links: %s\n' "$1" >&2; exit 2; }

workflow=".github/workflows/check-links.yml"
[ -f "${workflow}" ] || die "no ${workflow} in ${root}"
LYCHEE_IMAGE="${LYCHEE_IMAGE:-$(sed -n 's/^  LYCHEE_IMAGE: "\(.*\)"$/\1/p' "${workflow}")}"
[ -n "${LYCHEE_IMAGE}" ] || die "LYCHEE_IMAGE is unset and no pin was found in ${workflow}"

# Tracked files only: the working tree may hold notes and scratch directories
# that are nobody's documentation. A read loop, not mapfile: macOS ships
# bash 3.2.
files=()
while IFS= read -r -d '' file; do files+=("${file}"); done \
  < <(git ls-files -z '*.md' NOTICE)
[ "${#files[@]}" -gt 0 ] || die "nothing to check: no tracked Markdown file or NOTICE in ${root}"

# The tree is mounted where lychee runs, so relative links — LICENSE, the
# README's images — are resolved against the file they are in and checked
# like the others. `-e GITHUB_TOKEN` hands the variable over only when it
# is set (measured): by hand, with none, github.com is asked anonymously.
# lychee: 0 every link fine, 2 a link failed, 1 or 3 it could not check.
status=0
report=$(docker run --rm -v "${root}:/repo" -w /repo -e GITHUB_TOKEN "${LYCHEE_IMAGE}" \
  --no-progress --format markdown -- "${files[@]}") || status=$?

printf '%s\n' "${report}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '%s\n' "${report}" >>"${GITHUB_STEP_SUMMARY}"
fi

case "${status}" in
  0) exit 0 ;;
  2) echo "check-links: broken links, see the report" >&2; exit 1 ;;
  *) die "lychee exited ${status}" ;;
esac

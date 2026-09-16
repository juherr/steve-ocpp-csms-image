#!/usr/bin/env bash
# Is every pin Renovate is meant to manage one it actually extracts?
#
# A `# renovate:` comment next to a pin, or a documentation example in one of
# the shapes renovate.json matches, looks maintained; only Renovate's own
# extraction says whether it is. This runs that extraction — `--platform=local
# --dry-run=extract`, no datasource queried, nothing written — and compares it
# with the tree: every `# renovate:` comment in a tracked file must be inside
# a replaceString of that file, and every documentation file — Markdown, and
# the Kubernetes example manifests — must yield as many SteVe-tag dependencies
# as it has literals in the shapes renovate.json declares. The shapes and the
# files they apply to are read from renovate.json, not copied here.
#
# Usage:  ./hack/renovate-extract-check.sh    (from anywhere in the repository)
# Env:    RENOVATE_IMAGE    the Renovate image to run; defaults to the pin in
#                           the repository's .github/workflows/lint.yml so
#                           that there is one copy of it
#         RENOVATE_EXTRACT  a saved Renovate JSON log to read instead of
#                           running the image (hack/test/)
# Exit:   0 every pin extracted · 1 a pin is not · 2 usage or tooling

set -euo pipefail

# The tree under check is the repository of the working directory, and so is
# the workflow the image pin is read from — not a path relative to the
# script, which would leave the repository when the script is invoked
# relatively from a subdirectory (measured, from hack/).
root=$(git rev-parse --show-toplevel)
cd "${root}"

die() { printf 'renovate-extract-check: %s\n' "$1" >&2; exit 2; }

if [ -n "${RENOVATE_EXTRACT:-}" ]; then
  log=$(cat "${RENOVATE_EXTRACT}")
else
  workflow=".github/workflows/lint.yml"
  [ -f "${workflow}" ] || die "no ${workflow} in ${root}"
  RENOVATE_IMAGE="${RENOVATE_IMAGE:-$(sed -n 's/^  RENOVATE_IMAGE: "\(.*\)"$/\1/p' "${workflow}")}"
  [ -n "${RENOVATE_IMAGE}" ] || die "RENOVATE_IMAGE is unset and no pin was found in ${workflow}"
  log=$(docker run --rm -v "${root}:/repo" -w /repo -e LOG_LEVEL=debug -e LOG_FORMAT=json \
    "${RENOVATE_IMAGE}" --platform=local --dry-run=extract 2>&1) \
    || { status=$?; printf '%s\n' "${log}" >&2; die "renovate exited ${status}"; }
fi
# One JSON object per line at LOG_FORMAT=json; the extraction is the entry
# named below, its packageFiles keyed by manager. Lines that are not JSON —
# the image pull, which `docker run` prints on a runner that has never seen
# the image — are skipped rather than ending the read (measured: jq stops at
# the first one and the check failed with exit 5, not with a finding).
extracted=$(printf '%s\n' "${log}" \
  | jq -Rc 'fromjson? | select(.msg? == "Extracted dependencies") | .packageFiles' | tail -1)
[ -n "${extracted}" ] || die 'no "Extracted dependencies" entry in the Renovate log'

failed=0
refuse() { printf 'renovate-extract-check: %s\n' "$1" >&2; failed=1; }

# --- `# renovate:` comments: each inside a replaceString of its file ------

comments=0 comments_ok=0
while IFS=: read -r file _ comment; do
  comments=$((comments + 1))
  comment="${comment#"${comment%%[![:space:]]*}"}"
  if jq -e --arg f "${file}" --arg c "${comment}" \
      'any(.regex[]?; .packageFile == $f and any(.deps[]; .replaceString | contains($c)))' \
      <<<"${extracted}" >/dev/null; then
    comments_ok=$((comments_ok + 1))
  else
    refuse "${file}: not extracted: ${comment}"
  fi
done < <(git ls-files -z | xargs -0 grep -n '^[[:space:]]*# renovate: ' /dev/null)
echo "# renovate: comments: ${comments_ok} of ${comments} extracted"

# --- documentation literals: as many dependencies as shapes matched -------
#
# renovate.json declares the shapes once, as JavaScript regexes with named
# groups; perl reads those as they are, where grep -E would not.

while IFS=$'\t' read -r dep patterns matches; do
  files=$(git ls-files | grep -E "${patterns}" || true)
  for file in ${files}; do
    literals=$(RE="${matches}" perl -0777 -ne 'my $n = 0; $n++ while /$ENV{RE}/g; print $n' "${file}")
    deps=$(jq -r --arg f "${file}" --arg d "${dep}" \
      '[.regex[]? | select(.packageFile == $f) | .deps[] | select(.depName == $d)] | length' <<<"${extracted}")
    if [ "${literals}" -eq "${deps}" ]; then
      [ "${literals}" -eq 0 ] || echo "${file}: ${deps} of ${literals} SteVe tag literals extracted"
    else
      refuse "${file}: ${literals} SteVe tag literals, ${deps} extracted"
    fi
  done
done < <(jq -r '.customManagers[] | select(.depNameTemplate != null)
  | [.depNameTemplate,
     ([.managerFilePatterns[] | ltrimstr("/") | rtrimstr("/")] | join("|")),
     (.matchStrings | join("|"))] | join("\t")' renovate.json)

exit "${failed}"

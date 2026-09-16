#!/usr/bin/env bash
# The steps of .github/workflows/lint.yml, run here — read out of the
# workflow, not copied from it. That file pins the linter images and holds
# the exact commands, and AGENTS.md refuses a second copy of either; this
# script is the one way to run them locally that cannot drift, because it
# has nothing of its own to drift.
#
# What it reads: the `env:` block (exported as the runner would), then every
# `run:` step of every job, in file order — the single-line form and the
# `run: |` block, which are the two shapes the workflow uses. Any other
# shape (`run: >`, a bare `run:`, an unrecognised indent) is a refusal by
# line number, and so is a step count that differs from the number of
# `run:` lines in the file: a step the parser skipped would be a linter that
# silently stopped running locally. Steps run from the repository root
# under `bash -eo pipefail`, the runner's default shell, and the first
# failure ends the run, named. `uses:` steps are the runner's checkout and
# have no local counterpart.
#
# What it needs: Docker, which every step runs through — a pinned linter
# image, or `docker build --check` itself — and for the `renovate-extract`
# job the ~450 MB Renovate image; pass a job id to skip it:
# `./hack/lint.sh lint hack-tests`.
#
# Usage:  ./hack/lint.sh [-n] [job-id...]      # -n: print the steps, run nothing
# Env:    LINT_WORKFLOW=path                    # another workflow file (tests)
# Exit:   0 every step passed · 1 a step failed or the file did not parse

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
workflow="${LINT_WORKFLOW:-${root}/.github/workflows/lint.yml}"

dry_run=0
if [ "${1:-}" = "-n" ]; then dry_run=1; shift; fi
wanted=("$@")

# One pass over the file into a flat record stream — ENV, JOB, STEP, CMD,
# END, BAD — that the loop below consumes; awk has no closures, bash has no
# YAML. Block lines are the ones indented deeper than the `run:` key.
records=$(awk '
  /^env:$/  { section = "env";  next }
  /^jobs:$/ { section = "jobs"; next }
  section == "env" && /^  [A-Z][A-Z0-9_]*: / {
    name = $1; sub(/:$/, "", name)
    value = $0; sub(/^  [A-Z][A-Z0-9_]*: /, "", value); gsub(/^"|"$/, "", value)
    print "ENV\t" name "\t" value; next
  }
  section == "jobs" && /^  [a-z][a-z0-9-]*:$/ { job = $1; sub(/:$/, "", job); next }
  section == "jobs" && /^      - name: / { name = $0; sub(/^      - name: /, "", name); next }
  section == "jobs" && /^      (- |  )run:/ {
    if (block) { print "END"; block = 0 }
    # An unnamed step is shown as "run": bash `read` on a tab IFS would fold
    # an empty field away and shift the line number into the name.
    if (name == "") name = "run"
    command = $0; sub(/^      (- |  )run:/, "", command)
    if (command == " |") { block = 1; print "STEP\t" job "\t" name "\t" NR; name = ""; next }
    if (command ~ /^ [^ >|]/) { sub(/^ /, "", command); print "STEP\t" job "\t" name "\t" NR; print "CMD\t" command; print "END"; name = ""; next }
    print "BAD\t" NR; next
  }
  block && /^          / { line = $0; sub(/^          /, "", line); print "CMD\t" line; next }
  block && /^$/ { next }
  block { print "END"; block = 0 }
  END { if (block) print "END" }
' "${workflow}")

bad=$(printf '%s\n' "${records}" | awk -F'\t' '$1 == "BAD" { print $2 }')
if [ -n "${bad}" ]; then
  for line in ${bad}; do
    echo "FAIL ${workflow}: run: at line ${line} is not a shape this script reads (single line or 'run: |')" >&2
  done
  exit 1
fi
found=$(printf '%s\n' "${records}" | grep -c '^STEP' || true)
declared=$(grep -cE '^[[:space:]]+(- )?run:' "${workflow}" || true)
if [ "${found}" -ne "${declared}" ]; then
  echo "FAIL ${workflow}: ${declared} run: lines, ${found} steps read" >&2
  exit 1
fi

jobs=$(printf '%s\n' "${records}" | awk -F'\t' '$1 == "STEP" { print $2 }' | sort -u)
for want in "${wanted[@]+"${wanted[@]}"}"; do
  grep -qx -- "${want}" <<<"${jobs}" || { echo "FAIL no job named ${want} in ${workflow}" >&2; exit 1; }
done
selected() {
  [ "${#wanted[@]}" -eq 0 ] && return 0
  for want in "${wanted[@]}"; do [ "${want}" = "$1" ] && return 0; done
  return 1
}

cd "${root}"
job='' step='' line='' command='' skip=0
while IFS=$'\t' read -r kind a b c; do
  case "${kind}" in
    ENV)  export "${a}=${b}" ;;
    STEP) job="${a}"; step="${b}"; line="${c}"; command=''
          if selected "${job}"; then skip=0; echo "==> ${job} / ${step} (line ${line})"; else skip=1; fi ;;
    CMD)  command+="${a}"$'\n' ;;
    END)  [ "${skip}" -eq 1 ] && continue
          if [ "${dry_run}" -eq 1 ]; then printf '%s' "${command}" | sed 's/^/    /'; continue; fi
          if ! bash -eo pipefail -c "${command}"; then
            echo "FAIL ${job} / ${step} (line ${line})" >&2
            exit 1
          fi ;;
  esac
done <<<"${records}"

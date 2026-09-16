#!/usr/bin/env bash
# Offline tests for hack/lint.sh, which runs the steps of lint.yml locally by
# reading them out of the workflow — the pins and the commands — rather than
# from a copy of them.
#
# Against hack/test/lint/workflow.yml, a fixture holding the shapes the real
# file uses with commands that only echo, so the steps can run for real here;
# the shapes the script does not read are written into throwaway copies, and
# each must be a refusal, named. A shape the parser silently skipped would be
# a linter that stopped running locally with nothing to say so — the same
# failure the count guard exists for.
#
# Usage:  ./hack/test/lint-script.sh
# Exit:   0 all passed · 1 otherwise

# shellcheck disable=SC2016  # the ${…} in single quotes below are literal: what -n prints, what sed matches
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="${here}/../lint.sh"
fixture="${here}/lint/workflow.yml"

work=$(mktemp -d "${TMPDIR:-/tmp}/steve-ocpp-csms-image-lint-script.XXXXXX")
trap 'rm -rf "${work}"' EXIT

failed=0
out='' err='' status=0

run() {
  name="$1"; shift
  set +e
  out=$("$@" 2>"${work}/stderr"); status=$?
  set -e
  err=$(cat "${work}/stderr")
}
pass() { printf 'ok   %s\n' "${name}"; }
fail() { printf 'FAIL %s: %s\n  stdout: %s\n  stderr: %s\n' "${name}" "$1" "${out}" "${err}"; failed=1; }
expect_status() { [ "${status}" -eq "$1" ] || { fail "exit ${status}, expected $1"; return 1; }; }
expect_out()    { [[ "${out}" == *"$1"* ]] || { fail "stdout lacks '$1'"; return 1; }; }
expect_no_out() { [[ "${out}" != *"$1"* ]] || { fail "stdout has '$1'"; return 1; }; }
expect_err()    { [[ "${err}" == *"$1"* ]] || { fail "stderr lacks '$1'"; return 1; }; }

# --- runs every step, env exported, in file order -------------------------

run "runs every step of every job, with the workflow's env" \
  env LINT_WORKFLOW="${fixture}" "${script}"
expect_status 0 \
  && expect_out 'block one example/one:1.0' \
  && expect_out 'block two' \
  && expect_out 'single example/two:2.0' \
  && expect_out 'second job' \
  && { [[ "${out}" == *'block one'*'single'*'second job'* ]] || fail 'steps out of order'; } \
  && pass

# --- a job argument selects ----------------------------------------------

run "a job id runs that job only" \
  env LINT_WORKFLOW="${fixture}" "${script}" second
expect_status 0 && expect_out 'second job' && expect_no_out 'block one' && pass

run "an unknown job id is refused" \
  env LINT_WORKFLOW="${fixture}" "${script}" nosuchjob
expect_status 1 && expect_err 'no job named nosuchjob' && pass

# --- -n prints without running -------------------------------------------

run "-n lists the steps and their commands without running them" \
  env LINT_WORKFLOW="${fixture}" "${script}" -n
expect_status 0 \
  && expect_out 'first / block step' \
  && expect_out 'echo "block one ${ONE_IMAGE}"' \
  && expect_no_out 'block one example/one' \
  && pass

# --- a failing step fails the run, by name ---------------------------------

sed 's/echo "block two"/false/' "${fixture}" >"${work}/failing.yml"
run "a failing step fails the run and is named" \
  env LINT_WORKFLOW="${work}/failing.yml" "${script}"
expect_status 1 && expect_err 'FAIL first / block step' && expect_no_out 'single example' && pass

# --- shapes the parser does not read are refusals, not silent skips -------

sed 's/^        run: |$/        run: >/' "${fixture}" >"${work}/folded.yml"
run "a folded run: > step is refused" \
  env LINT_WORKFLOW="${work}/folded.yml" "${script}" -n
expect_status 1 && expect_err 'run: at line' && expect_err 'not a shape' && pass

sed 's/^      - run: echo "single ${TWO_IMAGE}"$/      - run:\n          echo "single"/' "${fixture}" >"${work}/bare.yml"
run "a bare run: with the command on the next line is refused" \
  env LINT_WORKFLOW="${work}/bare.yml" "${script}" -n
expect_status 1 && expect_err 'run: at line' && pass

# --- the real workflow parses: as many steps as run: lines -----------------

run "the real lint.yml parses, every run: accounted for" \
  "${script}" -n
expect_status 0 && expect_out 'lint / hadolint (Dockerfiles) (line ' && expect_out 'hack-tests / run (line ' && expect_out 'renovate-extract / run (line ' && pass

# --- the real workflow's shellcheck runs the pinned image, not the runner's -

# ubuntu-latest ships a shellcheck, so a step written back to a bare
# `xargs -r shellcheck` would stay green on CI with nothing pinned (#33) —
# the one linter whose absence from the pins no other check would notice.
# The step's command, as the dry-run prints it, must run the image variable.
run "the real lint.yml runs shellcheck from \${SHELLCHECK_IMAGE}, not the runner's" \
  "${script}" -n lint
step=$(printf '%s\n' "${out}" | sed -n '/^==> lint \/ shellcheck /,/^==>/p')
expect_step() { [[ "${step}" == *"$1"* ]] || { fail "shellcheck step lacks '$1'"; return 1; }; }
expect_status 0 && expect_step 'docker run' && expect_step '${SHELLCHECK_IMAGE}' && pass

exit "${failed}"

#!/usr/bin/env bash
# The harness the offline test suites under hack/test/ share: a fixture
# registry served by fake-curl.sh, a `docker` that records instead of acting
# (fake-docker.sh), a throwaway git repository whose HEAD is the commit the
# fixture images claim as their revision, and run/expect helpers.
#
# Sourced, not executed. The suite sets `here` (its own directory) first and
# calls `setup_fixtures`; everything below then runs against copies under a
# temporary directory that is removed on exit. Nothing reaches the network,
# and the scripts under test are the real ones, unmodified.
#
# Linting follows the `source` only when this file is among the inputs —
# `shellcheck $(git ls-files '*.sh')`, which is what lint.yml runs — or with
# `-x`; a suite checked on its own reports the variables set here as unset.

HACK_DIR="${HACK_DIR:-$(dirname "${here}")}"

work=$(mktemp -d "${TMPDIR:-/tmp}/steve-ocpp-csms-image-hack-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

# Fake curl and docker first on PATH, the fixture registry copied so that a
# test may edit it, and a repository whose HEAD the fixture blobs record.
setup_fixtures() {
  mkdir -p "${work}/bin"
  ln -s "${here}/fake-curl.sh" "${work}/bin/curl"
  ln -s "${here}/fake-docker.sh" "${work}/bin/docker"
  export PATH="${work}/bin:${PATH}"
  export FAKE_REGISTRY="${work}/registry"
  export FAKE_DOCKER="${work}/docker"
  cp -R "${here}/registry" "${FAKE_REGISTRY}"
  mkdir -p "${FAKE_DOCKER}"

  repo="${work}/repo"
  git init -q -b main "${repo}"
  git -C "${repo}" -c user.name=test -c user.email=test@example.invalid \
    commit -q --allow-empty -m 'the commit the fixture image records'
  git -C "${repo}" branch -q release
  git -C "${repo}" remote add origin "${repo}"
  revision=$(git -C "${repo}" rev-parse HEAD)
  for blob in "${FAKE_REGISTRY}"/v2/juherr/steve/blobs/*; do
    sed -i.bak "s/@REVISION@/${revision}/" "${blob}" && rm "${blob}.bak"
  done
}

failed=0
out='' err='' status=0

# The variables lint.yml exports: its `env:` block reaches every job, the one
# running these suites included, and a script whose fallback reads a pin from
# the tree under test would see the runner's value instead — green on a laptop
# where the variable does not exist, red in CI (measured, PR #37). Read from
# the workflow rather than listed here, so that a pin added there is dropped
# on arrival. A read loop, not mapfile: macOS ships bash 3.2.
workflow_env=()
while IFS= read -r var; do workflow_env+=(-u "${var}"); done \
  < <(sed -n 's/^  \([A-Z][A-Z0-9_]*\): .*/\1/p' "${HACK_DIR}/../.github/workflows/lint.yml")

# run <name> <command...>: captures stdout, stderr and the exit status. Every
# command runs from the throwaway repository, where the callers read the
# Dockerfile and git, and without the GitHub Actions variables — under them
# the scripts would write to the real step summary and format their messages
# as annotations — nor the workflow's own.
run() {
  name="$1"; shift
  set +e
  out=$(cd "${repo}" && env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY "${workflow_env[@]}" "$@" 2>"${work}/stderr"); status=$?
  set -e
  err=$(cat "${work}/stderr")
}

pass() { printf 'ok   %s\n' "${name}"; }
# shellcheck disable=SC2034  # read by the suite that sources this file
fail() { printf 'FAIL %s: %s\n  stdout: %s\n  stderr: %s\n' "${name}" "$1" "${out}" "${err}"; failed=1; }

expect_status() { [ "${status}" -eq "$1" ] || { fail "exit ${status}, expected $1"; return 1; }; }
expect_out()    { [[ "${out}" == *"$1"* ]] || { fail "stdout lacks '$1'"; return 1; }; }
expect_err()    { [[ "${err}" == *"$1"* ]] || { fail "stderr lacks '$1'"; return 1; }; }

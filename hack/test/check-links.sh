#!/usr/bin/env bash
# Offline tests for hack/check-links.sh, which runs lychee over the tracked
# documentation and reports where the workflow can show it.
#
# lychee itself does not run here: a `docker` shim put first on PATH records
# the invocation it is handed, prints a canned report and exits with the
# status a test chooses — the three lychee has, 0 clean, 2 broken links, and
# anything else for a run that could not check. What the suite proves is the
# script's side of that contract: which files reach lychee, which image, where
# the report goes, and that a lychee that could not run is neither a clean
# tree nor a broken link. Not the shim shared with the registry suites: that
# one refuses `docker run` on purpose, and hack/test/renovate-extract.sh
# asserts on the refusal.
#
# Usage:  ./hack/test/check-links.sh
#         HACK_DIR=/path/to/older/hack ./hack/test/check-links.sh   # red/green
# Exit:   0 all passed · 1 otherwise

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=hack/test/lib.sh
. "${here}/lib.sh"
check="${HACK_DIR}/check-links.sh"

# The shim: every argument on one line of ${work}/docker.log, the report from
# ${work}/report.md on stdout, the exit status from FAKE_LYCHEE_STATUS.
mkdir -p "${work}/bin"
cat >"${work}/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_LYCHEE_LOG}"
[ -f "${FAKE_LYCHEE_REPORT}" ] && cat "${FAKE_LYCHEE_REPORT}"
exit "${FAKE_LYCHEE_STATUS:-0}"
SHIM
chmod +x "${work}/bin/docker"
export PATH="${work}/bin:${PATH}"
export FAKE_LYCHEE_LOG="${work}/docker.log"
export FAKE_LYCHEE_REPORT="${work}/report.md"
printf '# Summary\n\n| Status | Count |\n| Total | 2 |\n' >"${FAKE_LYCHEE_REPORT}"
reset_log() { rm -f "${FAKE_LYCHEE_LOG}"; }
# The last invocation the shim recorded holds (or lacks) the given text.
expect_handed()     { [[ "$(tail -1 "${FAKE_LYCHEE_LOG}")" == *"$1"* ]] || { fail "lychee was not handed '$1': $(tail -1 "${FAKE_LYCHEE_LOG}")"; return 1; }; }
expect_not_handed() { [[ "$(tail -1 "${FAKE_LYCHEE_LOG}")" != *"$1"* ]] || { fail "lychee was handed '$1'"; return 1; }; }

# The tree under check: two tracked documents, one tracked script that is not
# one, one document that is not tracked, and the workflow the image pin is
# read from.
repo="${work}/repo"
git init -q -b main "${repo}"
mkdir -p "${repo}/.github/workflows"
cat >"${repo}/.github/workflows/check-links.yml" <<'EOT'
env:
  # renovate: datasource=docker depName=lycheeverse/lychee
  LYCHEE_IMAGE: "lycheeverse/lychee:0.0.1"
EOT
printf '[upstream](https://example.invalid/)\n' >"${repo}/README.md"
printf 'Source: https://example.invalid/source\n' >"${repo}/NOTICE"
printf '#!/bin/sh\n' >"${repo}/script.sh"
git -C "${repo}" add -A
git -C "${repo}" -c user.name=test -c user.email=test@example.invalid commit -q -m 'the tree under check'
printf '[stray](https://example.invalid/stray)\n' >"${repo}/UNTRACKED.md"

# --- the clean tree --------------------------------------------------------

reset_log
run 'a clean tree exits 0 with the report on stdout' "${check}"
expect_status 0 && expect_out '| Total | 2 |' && pass

run 'lychee is handed the tracked documents, and nothing else' true
expect_handed ' README.md' && expect_handed ' NOTICE' \
  && expect_not_handed 'script.sh' && expect_not_handed 'UNTRACKED.md' && pass

run 'lychee is run non-interactively, in markdown, with the GitHub token passed through' true
expect_handed '--no-progress' && expect_handed '--format markdown' && expect_handed '-e GITHUB_TOKEN' && pass

# --- the image pin --------------------------------------------------------

run 'the image pin is read from the workflow of the tree under check' true
expect_handed ' lycheeverse/lychee:0.0.1 ' && pass

reset_log
run 'LYCHEE_IMAGE overrides the pin' env LYCHEE_IMAGE=lycheeverse/lychee:override "${check}"
expect_status 0 && expect_handed ' lycheeverse/lychee:override ' && pass

# The script is documented as runnable by hand, and a hand runs it from
# wherever the shell is: the tree it checks and the workflow it reads the
# pin from are the repository of the working directory, not a path relative
# to the script.
reset_log
mkdir -p "${repo}/hack"
ln -s "${check}" "${repo}/hack/check-links.sh"
run 'invoked relatively from a subdirectory, the tree is still the repository' \
  bash -c 'cd hack && ./check-links.sh'
expect_status 0 && expect_handed ' lycheeverse/lychee:0.0.1 ' && expect_handed ' README.md' && pass
rm "${repo}/hack/check-links.sh"

# --- broken links ---------------------------------------------------------

printf '# Summary\n\n| Errors | 1 |\n\n## Errors per input\n\n### Errors in README.md\n\n* [404] <https://example.invalid/> (at 1:12)\n' >"${FAKE_LYCHEE_REPORT}"
run 'broken links exit 1, the report on stdout' env FAKE_LYCHEE_STATUS=2 "${check}"
expect_status 1 && expect_out '[404] <https://example.invalid/>' && expect_err 'broken links' && pass

run 'the report is appended to the step summary when there is one' \
  env FAKE_LYCHEE_STATUS=2 GITHUB_STEP_SUMMARY="${work}/summary.md" "${check}"
expect_status 1 \
  && { grep -q 'Errors in README.md' "${work}/summary.md" || fail 'the summary lacks the report'; } \
  && pass

# --- a lychee that could not check is a tooling failure, not a verdict ----

run 'a lychee runtime failure exits 2, not 0 and not 1' env FAKE_LYCHEE_STATUS=1 "${check}"
expect_status 2 && expect_err 'lychee exited 1' && pass

run 'a lychee configuration error exits 2' env FAKE_LYCHEE_STATUS=3 "${check}"
expect_status 2 && expect_err 'lychee exited 3' && pass

# --- nothing to check is the wrong directory, not a clean tree -------------

git -C "${repo}" rm -q README.md NOTICE
run 'a tree with no tracked documentation is refused' "${check}"
expect_status 2 && expect_err 'nothing to check' && pass

exit "${failed}"

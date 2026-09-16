#!/usr/bin/env bash
# Offline regression tests for hack/renovate-extract-check.sh, which fails
# when a pin Renovate is meant to manage is not one it extracts.
#
# Renovate itself does not run here: the script is handed a saved
# "Extracted dependencies" entry (RENOVATE_EXTRACT) and a throwaway tree that
# the entry describes — the real renovate.json, so that the shapes checked
# are the shapes shipped. Each test then edits the tree without editing the
# entry: that is what a pin that Renovate stopped extracting looks like, and
# every one of them must be a red step, named.
#
# Usage:  ./hack/test/renovate-extract.sh
#         HACK_DIR=/path/to/older/hack ./hack/test/renovate-extract.sh   # red/green
# Exit:   0 all passed · 1 otherwise

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=hack/test/lib.sh
. "${here}/lib.sh"
check="${HACK_DIR}/renovate-extract-check.sh"

setup_fixtures

# The tree the fixture entry describes: one docs literal of each managed
# shape, the Dockerfile ARG, and a workflow pin — every manager renovate.json
# declares, exercised once. The comment marker is spelled through a variable:
# the check reads every tracked file, this one included, and would otherwise
# count these fixtures as pins of a shell script no manager reads.
r='# renovate:'
cp "${here}/../../renovate.json" "${repo}/renovate.json"
cat >"${repo}/Dockerfile" <<EOF
${r} datasource=github-releases depName=steve-community/steve
ARG STEVE_REF=steve-1.0.1
FROM eclipse-temurin:25-jre
EOF
mkdir -p "${repo}/.github/workflows"
cat >"${repo}/.github/workflows/lint.yml" <<EOF
env:
  ${r} datasource=docker depName=hadolint/hadolint
  HADOLINT_IMAGE: "hadolint/hadolint:v2.0.0"
EOF
cat >"${repo}/README.md" <<'EOF'
docker pull ghcr.io/juherr/steve:steve-1.0.1
--build-arg STEVE_REF=steve-1.0.1
Illustrations name steve-X.Y.Z and are matched by nothing; steve-0.9.0 is a measurement.
EOF
git -C "${repo}" add -A
git -C "${repo}" -c user.name=test -c user.email=test@example.invalid commit -q -m 'the tree the extraction describes'
export RENOVATE_EXTRACT="${here}/renovate-extract.json"

# --- the tree the entry describes passes ----------------------------------

run 'every pin of the fixture tree is extracted' "${check}"
expect_status 0 && expect_out 'README.md: 2 of 2' && expect_out "${r} comments: 2 of 2" && pass

# --- a docs literal Renovate no longer extracts ---------------------------

cp "${repo}/README.md" "${work}/README.md.orig"
printf 'image: ghcr.io/juherr/steve:steve-1.0.1@sha256:<digest>\n' >>"${repo}/README.md"
run 'a docs literal missing from the extraction fails, naming the file' "${check}"
expect_status 1 && expect_err 'README.md: 3 SteVe tag literals, 2 extracted' && pass
cp "${work}/README.md.orig" "${repo}/README.md"

printf 'ghcr.io/juherr/steve:steve-1.0.1\n' >"${repo}/OTHER.md"
git -C "${repo}" add OTHER.md
run 'a Markdown file added with a literal and no extraction fails' "${check}"
expect_status 1 && expect_err 'OTHER.md: 1 SteVe tag literals, 0 extracted' && pass
git -C "${repo}" rm -q -f OTHER.md

# --- a `# renovate:` comment Renovate no longer reads ---------------------

cat >>"${repo}/.github/workflows/lint.yml" <<EOF
  ${r} datasource=docker depName=rhysd/actionlint
  ACTIONLINT_IMAGE: "rhysd/actionlint:1.0.0"
EOF
run 'a renovate comment whose pin is not extracted fails, naming the line' "${check}"
expect_status 1 && expect_err ".github/workflows/lint.yml: not extracted: ${r} datasource=docker depName=rhysd/actionlint" && pass

# --- the extraction itself ------------------------------------------------

run 'a log without an extraction entry is a tooling error, not a pass' \
  env RENOVATE_EXTRACT=/dev/null "${check}"
expect_status 2 && expect_err 'no "Extracted dependencies" entry' && pass

# On a runner the image is not cached, and `docker run` prints the pull on
# stderr, which the script captures with the log: lines that are not JSON
# come before the entry and must not end the read (measured, run 35075741084).
git -C "${repo}" checkout -q -- .github/workflows/lint.yml
{ printf 'Unable to find image %s locally\n44.93.6: Pulling from renovate/renovate\n' 'renovate/renovate:44.93.6'
  cat "${here}/renovate-extract.json"; } >"${work}/pulled.log"
run 'a log with the image pull before the entry is read past the pull' \
  env RENOVATE_EXTRACT="${work}/pulled.log" "${check}"
expect_status 0 && expect_out 'README.md: 2 of 2' && pass

exit "${failed}"

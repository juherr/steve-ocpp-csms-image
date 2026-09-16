#!/usr/bin/env bash
# The README states a runtime value that lives in entrypoint.sh: the share of
# the container's memory limit the JVM may give its heap, `-XX:MaxRAMPercentage`.
# The NAS section quotes the flag and derives its sizing advice from the
# number, so a bump in the entrypoint would leave the README describing an
# image that no longer exists. Read both and compare — no fixtures, no
# network. Both shapes the README uses are matched, `MaxRAMPercentage=<n>`
# and `<n> % of`, and a README that mentions neither is a failure too:
# a rewrite that drops the number must not pass as "consistent". The flag is
# a JVM double — `82.5` is a legal value — so the whole number is compared,
# decimals included: matching digits up to the point would let `82.5` at
# runtime pass against `82` in the README, the very drift this test exists
# to catch.
#
# Usage:  ./hack/test/readme-entrypoint.sh
# Exit:   0 consistent · 1 otherwise

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "${here}/../.." && pwd)
entrypoint="${root}/entrypoint.sh"
readme="${root}/README.md"

# Exactly one option, counted per occurrence and not per line: two on the
# same `exec java` line would be two answers as much as two lines, and a
# line-wise read would report only the last of them.
occurrences=$({ grep -o -- '-XX:MaxRAMPercentage=' "${entrypoint}" || true; } | wc -l | tr -d ' ')
case "${occurrences}" in
  0) echo "FAIL entrypoint.sh sets no -XX:MaxRAMPercentage" >&2; exit 1 ;;
  1) ;;
  *) echo "FAIL entrypoint.sh sets -XX:MaxRAMPercentage ${occurrences} times" >&2; exit 1 ;;
esac
set_in_entrypoint=$({ grep -oE -- '-XX:MaxRAMPercentage=[0-9]+(\.[0-9]+)?' "${entrypoint}" || true; } | sed 's/^-XX:MaxRAMPercentage=//')
if [ -z "${set_in_entrypoint}" ]; then
  echo "FAIL entrypoint.sh sets -XX:MaxRAMPercentage to something that is not a number" >&2
  exit 1
fi

documented=$(grep -oE 'MaxRAMPercentage=[0-9]+(\.[0-9]+)?|[0-9]+(\.[0-9]+)? % of' "${readme}" | grep -oE '[0-9]+(\.[0-9]+)?' || true)
if [ -z "${documented}" ]; then
  echo "FAIL README.md no longer states MaxRAMPercentage; the test matches nothing" >&2
  exit 1
fi

failed=0
count=0
while IFS= read -r value; do
  count=$((count + 1))
  if [ "${value}" != "${set_in_entrypoint}" ]; then
    echo "FAIL README.md says ${value} where entrypoint.sh sets MaxRAMPercentage=${set_in_entrypoint}" >&2
    failed=1
  fi
done <<<"${documented}"

[ "${failed}" -eq 0 ] || exit 1
echo "ok   README.md: ${count} mentions of MaxRAMPercentage, all ${set_in_entrypoint} as entrypoint.sh sets"

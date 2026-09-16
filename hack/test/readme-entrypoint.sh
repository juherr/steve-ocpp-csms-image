#!/usr/bin/env bash
# The README states a runtime value that lives in entrypoint.sh: the share of
# the container's memory limit the JVM may give its heap, `-XX:MaxRAMPercentage`.
# The NAS section quotes the flag and derives its sizing advice from the
# number, so a bump in the entrypoint would leave the README describing an
# image that no longer exists. Read both and compare — no fixtures, no
# network. Both shapes the README uses are matched, `MaxRAMPercentage=<n>`
# and `<n> % of`, and a README that mentions neither is a failure too:
# a rewrite that drops the number must not pass as "consistent".
#
# Usage:  ./hack/test/readme-entrypoint.sh
# Exit:   0 consistent · 1 otherwise

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "${here}/../.." && pwd)
entrypoint="${root}/entrypoint.sh"
readme="${root}/README.md"

# Only one JVM line sets the value; two would be two answers.
set_in_entrypoint=$(sed -n 's/.*-XX:MaxRAMPercentage=\([0-9][0-9]*\).*/\1/p' "${entrypoint}")
case "${set_in_entrypoint}" in
  '')  echo "FAIL entrypoint.sh sets no -XX:MaxRAMPercentage" >&2; exit 1 ;;
  *$'\n'*) echo "FAIL entrypoint.sh sets -XX:MaxRAMPercentage more than once" >&2; exit 1 ;;
esac

documented=$(grep -oE 'MaxRAMPercentage=[0-9]+|[0-9]+ % of' "${readme}" | grep -oE '[0-9]+' || true)
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

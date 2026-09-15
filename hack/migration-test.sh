#!/usr/bin/env bash
# Does the image do the one thing it promises — migrate an empty database and
# come up?
#
# The build database is thrown away, so the runtime database starts empty and
# `entrypoint.sh` replays the Flyway migrations on first start. Maven has
# already migrated the build database by the time the image exists, so testing
# the entrypoint against *that* database only proves the driver loads: the
# schema is current before Flyway even connects. What users hit is different —
# an empty schema, then the same schema on every restart, then a schema written
# by the previous release when they pull a new tag. Upstream has broken that
# path before — steve-community/steve#1212, migrations failing on MariaDB in
# Docker — and an empty schema is also the only one that takes the baseline
# migration of steve#956, which a Maven-migrated build database never runs.
# An image built here would carry such a regression straight to the registry.
#
# Three scenarios on two MariaDB instances, both started empty by this script:
#
#   fresh    the image migrates an empty database and SteVe becomes healthy
#   restart  a second container on that same, now migrated, database is a
#            Flyway no-op and healthy
#   upgrade  PREVIOUS_IMAGE migrates the second empty database, then IMAGE
#            takes over that database and SteVe becomes healthy (needs a
#            second argument; skipped with a notice otherwise)
#
# "Healthy" is the README's own Compose healthcheck command, set on the
# container and polled through `docker inspect` — not a log marker. It doubles
# as proof that the documented command works; the interval and start period
# are this script's own, see start_steve.
#
# The Flyway outcome lines asserted below were measured on the published image
# (Flyway 13 CLI), not taken from documentation.
#
# Usage:  ./hack/migration-test.sh IMAGE [PREVIOUS_IMAGE]
# Env:    MARIADB_IMAGE  runtime database image; defaults to the pin in
#                        .github/workflows/build-image.yml so that there is
#                        exactly one copy of it
# Exit:   0 every scenario passed · 1 a scenario failed, logs printed

set -euo pipefail

usage() { echo "Usage: $0 IMAGE [PREVIOUS_IMAGE]" >&2; exit 2; }
if [ $# -lt 1 ] || [ $# -gt 2 ]; then usage; fi
image=$1
previous=${2:-}

workflow="$(dirname "$0")/../.github/workflows/build-image.yml"
MARIADB_IMAGE="${MARIADB_IMAGE:-$(sed -n 's/^  DB_IMAGE: "\(.*\)"$/\1/p' "${workflow}")}"
[ -n "${MARIADB_IMAGE}" ] || { echo "MARIADB_IMAGE is unset and no DB_IMAGE pin was found in ${workflow}" >&2; exit 2; }

# Everything this script creates carries the run id in its name and a label,
# so cleanup and the log dump find their own resources and nothing of a
# concurrent run — the script is meant to be run by hand, possibly twice. The
# workflow's fallback cleanup filters on the label alone.
run="steve-it-$$-${RANDOM}"
label="steve-it=${run}"
network=${run}

# Timeouts in seconds. First boot runs every migration and, on an emulated
# architecture, can take well beyond the README's 150 s start period.
db_timeout=${DB_TIMEOUT:-120}
steve_timeout=${STEVE_TIMEOUT:-600}

# GitHub Actions folds `::group::` blocks and renders `::notice::`; a terminal
# should not have to read them.
in_ci() { [ -n "${GITHUB_ACTIONS:-}" ]; }
notice() { if in_ci; then printf '::notice::%s\n' "$1"; else printf 'NOTE: %s\n' "$1"; fi; }
group_start() { if in_ci; then printf '::group::%s\n' "$1"; else printf -- '--- %s ---\n' "$1"; fi; }
group_end() { if in_ci; then echo '::endgroup::'; fi; }
header() { printf '\n=== %s ===\n' "$1"; }

containers() { docker ps -a --filter "label=${label}" --format '{{.Names}}'; }

# On failure, every log first: the failing scenario is usually explained by the
# database or by the container that came before, not by the one that failed.
cleanup() {
  local status=$?
  if [ "${status}" -ne 0 ]; then
    for c in $(containers); do
      group_start "docker logs ${c}"
      docker logs "${c}" 2>&1 || true
      group_end
    done
  fi
  for c in $(containers); do docker rm -f "${c}" >/dev/null 2>&1 || true; done
  docker network rm "${network}" >/dev/null 2>&1 || true
  exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Same values as the README's Compose example and the build database: upstream
# public placeholders, no data, nothing that reaches an image.
start_db() {
  local name=$1
  echo "Starting ${name} (${MARIADB_IMAGE}), empty…"
  docker run -d --name "${name}" --network "${network}" --label "${label}" \
    -e MARIADB_ROOT_PASSWORD=root \
    -e MARIADB_DATABASE=stevedb \
    -e MARIADB_USER=steve \
    -e MARIADB_PASSWORD=changeme \
    -e TZ="+00:00" \
    "${MARIADB_IMAGE}" --innodb-use-native-aio=0 >/dev/null
  local i
  for ((i = 0; i < db_timeout; i += 2)); do
    if docker exec "${name}" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then
      echo "${name} ready."; return 0
    fi
    sleep 2
  done
  fail "${name} never became ready (${db_timeout}s)"
}

# The healthcheck command is the README's, character for character — keep them
# in sync. The timing is not: the README probes every 30 s, this every 5 s so
# that a failure surfaces in seconds; and the start period spans the whole wait
# so that a slow first boot ends as a timeout with the logs, not as three failed
# probes. `unhealthy` below is what a container that came up and then stopped
# answering would report.
start_steve() {
  local name=$1 img=$2 db=$3
  echo "Starting ${name} (${img}) against ${db}…"
  docker run -d --name "${name}" --network "${network}" --label "${label}" \
    -e DB_IP="${db}" -e DB_PASSWORD=changeme \
    --health-cmd 'curl -fsS -o /dev/null http://127.0.0.1:8180/steve/manager/signin' \
    --health-interval 5s --health-timeout 5s --health-retries 3 \
    --health-start-period "${steve_timeout}s" \
    "${img}" >/dev/null
}

wait_healthy() {
  local name=$1 i health
  for ((i = 0; i < steve_timeout; i += 5)); do
    if [ "$(docker inspect --format '{{ .State.Running }}' "${name}")" != "true" ]; then
      fail "${name} exited before becoming healthy"
    fi
    health=$(docker inspect --format '{{ .State.Health.Status }}' "${name}")
    case "${health}" in
      healthy)
        echo "${name} healthy after ~${i}s."
        docker logs "${name}" 2>&1 | grep -E '^\[entrypoint\]|^Flyway|^Schema|^Successfully' || true
        return 0 ;;
      unhealthy) fail "${name} reported unhealthy" ;;
    esac
    sleep 5
  done
  fail "${name} not healthy after ${steve_timeout}s"
}

# The one line Flyway prints for the outcome of `migrate`. The log is captured
# before grep sees it: `docker logs | grep -q` under pipefail is a race, grep
# closing the pipe on the first match kills `docker logs` with SIGPIPE.
assert_flyway() {
  local name=$1 pattern=$2 logs
  logs=$(docker logs "${name}" 2>&1)
  grep -qE "${pattern}" <<<"${logs}" \
    || fail "${name}: Flyway did not report '${pattern}'"
}
# The count is not asserted: upstream ships a baseline (B1_0_5), so an empty
# schema receives it plus the migrations after it, not one per file.
applied='^Successfully applied [0-9]+ migrations? to schema'
noop='^Schema .stevedb. is up to date\. No migration necessary\.'

docker network create --label "${label}" "${network}" >/dev/null

header "fresh: ${image} migrates an empty database"
start_db "${run}-db"
start_steve "${run}-fresh" "${image}" "${run}-db"
wait_healthy "${run}-fresh"
assert_flyway "${run}-fresh" "${applied}"

header "restart: a new container on the migrated database is a no-op"
docker rm -f "${run}-fresh" >/dev/null
start_steve "${run}-again" "${image}" "${run}-db"
wait_healthy "${run}-again"
assert_flyway "${run}-again" "${noop}"
docker rm -f "${run}-again" "${run}-db" >/dev/null

if [ -z "${previous}" ]; then
  notice "No previous image given — the upgrade scenario was skipped."
else
  header "upgrade: ${previous} migrates, then ${image} takes over its database"
  start_db "${run}-db-upgrade"
  start_steve "${run}-old" "${previous}" "${run}-db-upgrade"
  wait_healthy "${run}-old"
  assert_flyway "${run}-old" "${applied}"
  docker rm -f "${run}-old" >/dev/null
  start_steve "${run}-new" "${image}" "${run}-db-upgrade"
  wait_healthy "${run}-new"
  # Two adjacent releases may ship the same schema, so "applied at least one"
  # cannot be asserted — only that Flyway reached an outcome and SteVe came up.
  assert_flyway "${run}-new" "(${applied})|(${noop})"
fi

echo
echo "OK: every scenario passed."

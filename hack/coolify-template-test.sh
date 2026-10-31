#!/usr/bin/env bash
# Does the Coolify template bring SteVe up the way Coolify would, and twice?
#
# Coolify is not here; plain Compose stands in for it, which works because the
# template is kept plain Compose. What Coolify adds is played by this script:
# a value for every magic variable the template references — 32 alphanumeric
# characters for SERVICE_PASSWORD_*, 16 for SERVICE_USER_*, a URL for
# SERVICE_URL_* — and a project name per installation, which is how Coolify's
# per-resource network and volume prefix keep two installations apart.
#
# Three kinds of check. The file itself, rendered by Compose: the catalog
# header, only magic-variable families Coolify generates, every credential
# taken from one of them, and nothing a second installation would collide
# with or the server would expose — no ports, no container or project name,
# no bind mount. Then two installations at once, each with its own values:
# both healthy, the database migrated from empty, no host port bound, the
# generated administrator signs in where the upstream default and the other
# installation's administrator do not, the Web API refused, an unknown charge
# point refused. Then a restart of the first one, `down` without `-v`: the
# schema is up to date, a row written before is still there, and it never
# reached the second.
#
# The sign-in is the real form flow, `_csrf` included, from inside the
# container: nothing is published, by design. The upstream behaviour asserted
# below was measured on steve-3.14.1: the generated administrator lands on
# /steve/, the default one on signin?error; with WEBAPI_VALUE empty the
# administrator has no API password, so /steve/api/ answers 401 to Basic auth
# even with the UI password; an unknown charge point's WebSocket upgrade
# answers 404.
#
# Given no IMAGE, the template runs as pinned — the tag@digest Renovate moves
# is pulled and booted on the pull request that moves it. Given one, it
# replaces only the steve image, the rest of the template unchanged.
#
# Usage:  ./hack/coolify-template-test.sh [IMAGE]
# Env:    STEVE_TIMEOUT  seconds for both installations to become healthy
#                        (default 600)
# Exit:   0 every check passed · 1 a check failed, logs printed · 2 usage or
#         tooling

set -euo pipefail

usage() { echo "Usage: $0 [IMAGE]" >&2; exit 2; }
[ $# -le 1 ] || usage
image=${1:-}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "${here}/.." && pwd)
template="${root}/deploy/coolify/steve.yaml"

die() { printf 'coolify-template-test: %s\n' "$1" >&2; exit 2; }
for tool in docker jq; do
  command -v "${tool}" >/dev/null || die "${tool} not found"
done
# Output captured before grep sees it, here and below: `cmd | grep -q` under
# pipefail is a race, grep closing the pipe on the first match kills cmd.
help=$(docker compose config --help 2>&1 || true)
grep -q -- '--variables' <<<"${help}" \
  || die "docker compose has no 'config --variables' (Compose 2.24 or later needed)"
[ -f "${template}" ] || die "no ${template}"
steve_timeout=${STEVE_TIMEOUT:-600}

run="steve-coolify-$$-${RANDOM}"
projects=("${run}-a" "${run}-b")
work=$(mktemp -d "${TMPDIR:-/tmp}/steve-ocpp-csms-image-coolify.XXXXXX")
files=(-f "${template}")
if [ -n "${image}" ]; then
  docker image inspect "${image}" >/dev/null 2>&1 || die "${image} is not in the local daemon"
  printf 'services:\n  steve:\n    image: %s\n' "${image}" >"${work}/image.yaml"
  files+=(-f "${work}/image.yaml")
fi

in_ci() { [ -n "${GITHUB_ACTIONS:-}" ]; }
group_start() { if in_ci; then printf '::group::%s\n' "$1"; else printf -- '--- %s ---\n' "$1"; fi; }
group_end() { if in_ci; then echo '::endgroup::'; fi; }
header() { printf '\n=== %s ===\n' "$1"; }

# compose PROJECT ARGS…: one installation, with the values generated for it.
compose() {
  local p=$1; shift
  docker compose --progress quiet -p "${p}" --env-file "${work}/${p}.env" "${files[@]}" "$@"
}

started=0
cleanup() {
  local status=$?
  if [ "${started}" -eq 1 ]; then
    for p in "${projects[@]}"; do
      if [ "${status}" -ne 0 ]; then
        group_start "docker compose logs (${p})"
        compose "${p}" logs --no-color 2>&1 || true
        group_end
      fi
      compose "${p}" down -v --remove-orphans >/dev/null 2>&1 || true
    done
  fi
  rm -rf "${work}"
  exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# random LENGTH: alphanumeric, as Coolify's generated values are. head ends
# first and the rest read to the end, so pipefail sees no SIGPIPE.
random() { head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c "1-$1"; }

header "the catalog header"
for key in documentation slogan category tags logo port; do
  grep -qE "^# ${key}: [^ ]" "${template}" || fail "no '# ${key}:' line in the template header"
done
port=$(sed -n 's/^# port: *//p' "${template}")
[[ "${port}" =~ ^[0-9]+$ ]] || fail "'# port: ${port}' is not a port"
echo "documentation, slogan, category, tags, logo, port (${port})."

header "the magic variables"
# Compose lists what it interpolates; a bare `- SERVICE_URL_X_PORT` entry is
# passed through rather than interpolated, so it is read from the source form
# of the environment — a list of K=V strings or a map, whichever was written.
source_json=$(docker compose "${files[@]}" config --no-interpolate --format json) \
  || fail "Compose cannot read the template (its error is above)"
environment() {
  jq -r --arg s "$1" '.services[$s].environment // {}
    | if type == "array" then map(capture("^(?<k>[^=]+)(?<eq>=?)(?<v>.*)$")
        | {key: .k, value: (if .eq == "" then null else .v end)}) | from_entries else . end' <<<"${source_json}"
}
variables=$(docker compose "${files[@]}" config --variables --format json) \
  || fail "Compose cannot list the template's variables"
bare=$(jq -r '.services[].environment // {}
  | if type == "array" then .[] | select(contains("=") | not) else to_entries[] | select(.value == null) | .key end' <<<"${source_json}")
names=$( { jq -r 'keys[]' <<<"${variables}"; printf '%s\n' "${bare}"; } | grep . | sort -u)
for p in "${projects[@]}"; do : >"${work}/${p}.env"; done
for name in ${names}; do
  case "${name}" in
    SERVICE_PASSWORD_*) [[ "${name}" =~ ^SERVICE_PASSWORD_[A-Z0-9]+$ ]] || fail "${name}: Coolify takes one token after SERVICE_PASSWORD_"
      len=32 ;;
    SERVICE_USER_*) [[ "${name}" =~ ^SERVICE_USER_[A-Z0-9]+$ ]] || fail "${name}: Coolify takes one token after SERVICE_USER_"
      len=16 ;;
    SERVICE_URL_*) [[ "${name}" =~ ^SERVICE_URL_[A-Z0-9_]+_([0-9]+)$ ]] || fail "${name}: no port suffix for the proxy to route to"
      [ "${BASH_REMATCH[1]}" = "${port}" ] || fail "${name} routes to ${BASH_REMATCH[1]}, the header says ${port}"
      len=0 ;;
    SERVICE_*) fail "${name}: not a magic-variable family this template is checked for" ;;
    *) [ -n "$(jq -r --arg n "${name}" '.[$n].DefaultValue' <<<"${variables}")" ] \
        || fail "${name} has no default: an installation would start with it empty"
      continue ;;
  esac
  for p in "${projects[@]}"; do
    if [ "${len}" -eq 0 ]; then value="https://${p}.example.test"; else value=$(random "${len}"); fi
    [ "${len}" -eq 0 ] || [ "${#value}" -eq "${len}" ] || die "generated ${#value} characters, expected ${len}"
    printf '%s=%s\n' "${name}" "${value}" >>"${work}/${p}.env"
  done
  echo "${name}"
done

header "what the template declares"
grep -qE '^name:' "${template}" && fail "a top-level name: would be shared by every installation"
grep -qE '^networks:' "${template}" && fail "a top-level networks: is Coolify's to provide"
rendered=$(compose "${projects[0]}" config --format json) \
  || fail "Compose cannot render the template with generated values"
offenders() { jq -r "$1" <<<"${rendered}" | paste -sd, -; }
[ -z "$(offenders '.services | to_entries[] | select(.value.ports) | .key')" ] \
  || fail "publishes ports: $(offenders '.services | to_entries[] | select(.value.ports) | .key')"
[ -z "$(offenders '.services | to_entries[] | select(.value.container_name) | .key')" ] \
  || fail "fixed container_name: $(offenders '.services | to_entries[] | select(.value.container_name) | .key')"
[ -z "$(offenders '.services | to_entries[] | select((.value.healthcheck.test // []) | length == 0 or .[0] == "NONE") | .key')" ] \
  || fail "no healthcheck: $(offenders '.services | to_entries[] | select((.value.healthcheck.test // []) | length == 0 or .[0] == "NONE") | .key')"
[ -z "$(offenders '.services | to_entries[] | select(any(.value.volumes[]?; .type != "volume")) | .key')" ] \
  || fail "bind mount: $(offenders '.services | to_entries[] | select(any(.value.volumes[]?; .type != "volume")) | .key')"
echo "no ports, no container_name, a healthcheck each, named volumes only."

steve_image=$(jq -r '.services.steve.image // ""' <<<"${source_json}")
[[ "${steve_image}" =~ ^ghcr\.io/juherr/steve:steve-[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]] \
  || fail "steve image '${steve_image}' is not a published tag pinned by its index digest"
echo "image: ${steve_image}"
[ -n "$(jq -r '.services.steve.mem_limit // ""' <<<"${rendered}")" ] \
  || fail "steve has no mem_limit: its heap would be sized from the whole server"

# Credentials come from Coolify, in the source, before any value exists.
steve_env=$(environment steve)
db_env=$(environment steve-db)
expect() {
  local env=$1 key=$2 pattern=$3 actual
  actual=$(jq -r --arg k "${key}" 'if has($k) then .[$k] // "<bare>" else "<unset>" end' <<<"${env}")
  [[ "${actual}" =~ ${pattern} ]] || fail "${key}='${actual}', expected ${pattern}"
}
expect "${steve_env}" AUTH_USER '^\$\{SERVICE_USER_[A-Z0-9]+\}$'
expect "${steve_env}" AUTH_PASSWORD '^\$\{SERVICE_PASSWORD_[A-Z0-9]+\}$'
expect "${steve_env}" DB_PASSWORD '^\$\{SERVICE_PASSWORD_[A-Z0-9]+\}$'
expect "${steve_env}" WEBAPI_VALUE '^$'
expect "${steve_env}" AUTO_REGISTER_UNKNOWN_STATIONS '^false$'
expect "${db_env}" MARIADB_PASSWORD '^\$\{SERVICE_PASSWORD_[A-Z0-9]+\}$'
expect "${db_env}" MARIADB_ROOT_PASSWORD '^\$\{SERVICE_PASSWORD_[A-Z0-9]+\}$'
[ "$(jq -r .DB_PASSWORD <<<"${steve_env}")" = "$(jq -r .MARIADB_PASSWORD <<<"${db_env}")" ] \
  || fail "DB_PASSWORD and MARIADB_PASSWORD are not the same variable"
distinct=$( { jq -r '.AUTH_PASSWORD, .DB_PASSWORD' <<<"${steve_env}"; jq -r .MARIADB_ROOT_PASSWORD <<<"${db_env}"; } | sort -u | wc -l)
[ "${distinct}" -eq 3 ] || fail "the administrator, database and root passwords must be three variables"
echo "every credential generated; administrator, database and root distinct; Web API secret empty."

header "two installations"
started=1
for p in "${projects[@]}"; do
  echo "starting ${p}…"
  compose "${p}" up -d --quiet-pull
done
for p in "${projects[@]}"; do
  compose "${p}" up -d --wait --wait-timeout "${steve_timeout}" >/dev/null 2>&1 || fail "${p} not healthy after ${steve_timeout}s"
  echo "${p} healthy."
done

value() { sed -n "s/^$2=//p" "${work}/$1.env"; }
admin_user=$(jq -r '.AUTH_USER | ltrimstr("${") | rtrimstr("}")' <<<"${steve_env}")
admin_password=$(jq -r '.AUTH_PASSWORD | ltrimstr("${") | rtrimstr("}")' <<<"${steve_env}")

# signin PROJECT USER PASSWORD: the URL the sign-in form redirects to, then
# the status of the home page with that session.
# shellcheck disable=SC2016 # expanded by the container shell
signin_script='
base=http://127.0.0.1:8180/steve/manager jar=$(mktemp)
csrf=$(curl -sS -c "$jar" -b "$jar" "$base/signin" | sed -n "s/.*name=\"_csrf\" value=\"\([^\"]*\)\".*/\1/p")
[ -n "$csrf" ] || { echo "no-csrf"; exit 0; }
curl -sS -o /dev/null -c "$jar" -b "$jar" -w "%{redirect_url} " --data-urlencode "username=$1" \
  --data-urlencode "password=$2" --data-urlencode "_csrf=$csrf" "$base/signin"
curl -sS -o /dev/null -b "$jar" -w "%{http_code}" "$base/home"
rm -f "$jar"'
signin() { compose "$1" exec -T steve sh -c "${signin_script}" sh "$2" "$3"; }
signed_in() { [[ "$(signin "$@")" =~ ^http://127\.0\.0\.1:8180/steve/\ 200$ ]]; }
refused() { [[ "$(signin "$@")" =~ signin\?error\ 302$ ]]; }
in_container() { compose "$1" exec -T steve curl -sS -o /dev/null -w '%{http_code}' "${@:2}"; }
# shellcheck disable=SC2016 # expanded by the container shell
sql() { compose "$1" exec -T steve-db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -N -u steve stevedb -e "$1"' sh "$2"; }

for p in "${projects[@]}"; do
  header "${p}"
  logs=$(compose "${p}" logs --no-log-prefix steve 2>&1)
  grep -qE '^Successfully applied [0-9]+ migrations? to schema' <<<"${logs}" \
    || fail "${p}: Flyway did not migrate the empty database"
  echo "Flyway migrated the empty database."
  for id in $(compose "${p}" ps -q); do
    bound=$(docker inspect "${id}" | jq '[.[0].NetworkSettings.Ports // {} | .[] | select(. != null) | .[]] + [.[0].HostConfig.PortBindings // {} | .[] | .[]] | length')
    [ "${bound}" -eq 0 ] || fail "${p}: $(docker inspect -f '{{.Name}}' "${id}") binds a host port"
  done
  echo "no host port bound."
  signed_in "${p}" "$(value "${p}" "${admin_user}")" "$(value "${p}" "${admin_password}")" \
    || fail "${p}: the generated administrator does not sign in ($(signin "${p}" "$(value "${p}" "${admin_user}")" "$(value "${p}" "${admin_password}")"))"
  refused "${p}" admin 1234 || fail "${p}: the upstream default admin/1234 is not refused"
  echo "the generated administrator signs in; admin/1234 is refused."
  code=$(in_container "${p}" -u "$(value "${p}" "${admin_user}"):$(value "${p}" "${admin_password}")" http://127.0.0.1:8180/steve/api/v1/ocppTags)
  [ "${code}" = 401 ] || fail "${p}: the Web API answered ${code} to the administrator, expected 401"
  echo "Web API refused (401)."
  code=$(in_container "${p}" --max-time 10 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Protocol: ocpp1.6' \
    "http://127.0.0.1:8180/steve/websocket/CentralSystemService/${run}")
  [ "${code}" = 404 ] || fail "${p}: an unknown charge point's upgrade answered ${code}, expected 404"
  echo "unknown charge point refused (404)."
done

header "isolation"
a=${projects[0]} b=${projects[1]}
refused "${b}" "$(value "${a}" "${admin_user}")" "$(value "${a}" "${admin_password}")" \
  || fail "${a}'s administrator signs in on ${b}"
echo "${a}'s administrator is refused on ${b}."

header "restart with the data kept"
sql "${a}" "INSERT INTO ocpp_tag (id_tag, note) VALUES ('${run}', 'coolify-template-test')"
compose "${a}" down >/dev/null 2>&1
compose "${a}" up -d --wait --wait-timeout "${steve_timeout}" >/dev/null 2>&1 || fail "${a} not healthy after the restart"
logs=$(compose "${a}" logs --no-log-prefix steve 2>&1)
grep -qE '^Schema .stevedb. is up to date\. No migration necessary\.' <<<"${logs}" \
  || fail "${a}: Flyway did not find the schema up to date after the restart"
echo "Flyway: up to date."
[ "$(sql "${a}" "SELECT COUNT(*) FROM ocpp_tag WHERE id_tag = '${run}'")" = 1 ] || fail "${a}: the row written before the restart is gone"
[ "$(sql "${b}" "SELECT COUNT(*) FROM ocpp_tag WHERE id_tag = '${run}'")" = 0 ] || fail "${b} holds ${a}'s row"
signed_in "${a}" "$(value "${a}" "${admin_user}")" "$(value "${a}" "${admin_password}")" \
  || fail "${a}: the administrator no longer signs in after the restart"
echo "the row survived on ${a}, never reached ${b}; the administrator still signs in."

echo
echo "OK: the template came up twice, side by side, as Coolify would run it."

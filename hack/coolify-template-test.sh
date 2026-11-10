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
# point refused, a profile 2 one accepted only behind X-Forwarded-Proto. Then
# a restart of the first one, `down` without `-v`: the schema is up to date,
# a row written before is still there, and it never reached the second. Then,
# on the first one, the README's dump to a file outside the container, its
# administrator reset, and its restore of that file; on the second, steve-db
# killed and started again under a running steve.
#
# The sign-in is the real form flow, `_csrf` included, from inside the
# container: nothing is published, by design. The template serves SteVe at
# the root of its domain (CONTEXT_PATH empty), so every path below has no
# /steve prefix. The upstream behaviour asserted was measured on steve-3.14.1:
# the generated administrator lands on /, the default one on signin?error;
# with WEBAPI_VALUE empty the administrator has no API password, so /api/
# answers 401 to Basic auth even with the UI password; a registered charge
# point's WebSocket upgrade answers 101, an unknown one's 404.
#
# Given no IMAGE, the template runs as written — the tag Renovate moves is
# pulled and booted on the pull request that moves it. Given one, it
# replaces only the steve image the installations boot, the rest of the
# template unchanged; the checks of the file still read the tag it names.
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
# healthy PROJECT MESSAGE [SERVICE…]: up and healthy, or fail with MESSAGE.
healthy() {
  compose "$1" up -d --wait --wait-timeout "${steve_timeout}" "${@:3}" >/dev/null 2>&1 || fail "$2"
}

# random LENGTH: alphanumeric, as Coolify's generated values are. head ends
# first and the rest read to the end, so pipefail sees no SIGPIPE.
random() { head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c "1-$1"; }

header "the catalog header"
for key in documentation slogan category tags logo port; do
  grep -qE "^# ${key}: [^ ]" "${template}" || fail "no '# ${key}:' line in the template header"
done
port=$(sed -n 's/^# port: *//p' "${template}")
[[ "${port}" =~ ^[0-9]+$ ]] || fail "'# port: ${port}' is not a port"
# Coolify's catalog generator reads every line matching ^#(key):(value) as
# metadata, wherever it sits (Generate/Services.php in coollabsio/coolify):
# a comment starting at column 0 with a colon in it is a key, not a comment.
metadata=$(grep -E '^#.*:' "${template}" || true)
stray=$(grep -vE '^# (documentation|slogan|category|tags|logo|port|minversion|env_file|ignore|amd_only|arm_only): ' <<<"${metadata}" || true)
[ -z "${stray}" ] || fail "a column-0 comment with a colon is catalog metadata to Coolify: ${stray%%$'\n'*}"
echo "documentation, slogan, category, tags, logo, port (${port}); no stray metadata."

header "the magic variables"
# Compose lists what it interpolates; a bare `- SERVICE_URL_X_PORT` entry is
# passed through rather than interpolated, so it is read from the source form
# of the environment — a list of K=V strings or a map, whichever was written.
# The template alone, without the IMAGE override: these checks are about the
# file a one-click install runs, which names a published tag whatever image
# the installations below are booted on.
source_json=$(docker compose -f "${template}" config --no-interpolate --format json) \
  || fail "Compose cannot read the template (its error is above)"
environment() {
  jq -r --arg s "$1" '.services[$s].environment // {}
    | if type == "array" then map(capture("^(?<k>[^=]+)(?<eq>=?)(?<v>.*)$")
        | {key: .k, value: (if .eq == "" then null else .v end)}) | from_entries else . end' <<<"${source_json}"
}
variables=$(docker compose -f "${template}" config --variables --format json) \
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
    if [ "${len}" -eq 0 ]; then
      value="https://${p}.example.test"
    else
      value=$(random "${len}")
      [ "${#value}" -eq "${len}" ] || die "generated ${#value} characters, expected ${len}"
    fi
    printf '%s=%s\n' "${name}" "${value}" >>"${work}/${p}.env"
  done
  echo "${name}"
done

header "what the template declares"
grep -qE '^name:' "${template}" && fail "a top-level name: would be shared by every installation"
grep -qE '^networks:' "${template}" && fail "a top-level networks: is Coolify's to provide"
rendered=$(compose "${projects[0]}" config --format json) \
  || fail "Compose cannot render the template with generated values"
# no_service MESSAGE FILTER: fail naming every service FILTER selects.
no_service() {
  local offenders
  offenders=$(jq -r ".services | to_entries[] | select($2) | .key" <<<"${rendered}" | paste -sd, -)
  [ -z "${offenders}" ] || fail "$1: ${offenders}"
}
no_service "publishes ports" '.value.ports'
no_service "fixed container_name" '.value.container_name'
no_service "no healthcheck" '(.value.healthcheck.test // []) | length == 0 or .[0] == "NONE"'
no_service "bind mount" 'any(.value.volumes[]?; .type != "volume")'
echo "no ports, no container_name, a healthcheck each, named volumes only."

steve_image=$(jq -r '.services.steve.image // ""' <<<"${source_json}")
[[ "${steve_image}" =~ ^ghcr\.io/juherr/steve:steve-[0-9]+\.[0-9]+\.[0-9]+(@sha256:[0-9a-f]{64})?$ ]] \
  || fail "steve image '${steve_image}' is not a steve-X.Y.Z tag of ghcr.io/juherr/steve"
echo "image: ${steve_image}"
# Tags are per server: a pull for one installation moves the image every
# other one restarts on. A patch pin makes each MariaDB move a Renovate PR,
# which this test then boots; a floating 11.8 would move with no CI at all.
db_image=$(jq -r '.services["steve-db"].image // ""' <<<"${source_json}")
[[ "${db_image}" =~ ^mariadb:[0-9]+\.[0-9]+\.[0-9]+(@sha256:[0-9a-f]{64})?$ ]] \
  || fail "steve-db image '${db_image}' is not pinned to a mariadb patch release"
echo "image: ${db_image}"
# The pin moves only if Renovate reads the file, and the manager reads it only
# through the path renovate.json adds; hack/renovate-extract-check.sh proves
# the extraction, this that the path still names the template.
managed=$(jq -r '."docker-compose".managerFilePatterns // [] | map(ltrimstr("/") | rtrimstr("/")) | join("|")' "${root}/renovate.json")
if [ -z "${managed}" ] || ! grep -qE "${managed}" <<<"${template#"${root}/"}"; then
  fail "renovate.json's docker-compose manager does not read ${template#"${root}/"}: its pins would freeze"
fi
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
expect "${steve_env}" CONTEXT_PATH '^$'
# At the root, the old /steve/manager/signin answers a redirect, which
# `curl -f` counts as healthy: a healthcheck left on it would never fail.
health=$(jq -r '.services.steve.healthcheck.test | join(" ")' <<<"${rendered}")
[[ " ${health} " == *" http://127.0.0.1:8180/manager/signin "* ]] \
  || fail "steve's healthcheck '${health}' does not probe http://127.0.0.1:8180/manager/signin"
expect "${db_env}" MARIADB_PASSWORD '^\$\{SERVICE_PASSWORD_[A-Z0-9]+\}$'
expect "${db_env}" MARIADB_ROOT_PASSWORD '^\$\{SERVICE_PASSWORD_[A-Z0-9]+\}$'
[ "$(jq -r .DB_PASSWORD <<<"${steve_env}")" = "$(jq -r .MARIADB_PASSWORD <<<"${db_env}")" ] \
  || fail "DB_PASSWORD and MARIADB_PASSWORD are not the same variable"
distinct=$( { jq -r '.AUTH_PASSWORD, .DB_PASSWORD' <<<"${steve_env}"; jq -r .MARIADB_ROOT_PASSWORD <<<"${db_env}"; } | sort -u | wc -l)
[ "${distinct}" -eq 3 ] || fail "the administrator, database and root passwords must be three variables"
echo "every credential generated; administrator, database and root distinct; Web API secret empty."
echo "served at the root; healthcheck on /manager/signin."

header "two installations"
started=1
for p in "${projects[@]}"; do
  echo "starting ${p}…"
  compose "${p}" up -d --quiet-pull
done
for p in "${projects[@]}"; do
  healthy "${p}" "${p} not healthy after ${steve_timeout}s"
  echo "${p} healthy."
done

value() { sed -n "s/^$2=//p" "${work}/$1.env"; }
admin_user=$(jq -r '.AUTH_USER | ltrimstr("${") | rtrimstr("}")' <<<"${steve_env}")
admin_password=$(jq -r '.AUTH_PASSWORD | ltrimstr("${") | rtrimstr("}")' <<<"${steve_env}")

# signin PROJECT USER PASSWORD: the URL the sign-in form redirects to, then
# the status of the home page with that session.
# shellcheck disable=SC2016 # expanded by the container shell
signin_script='
base=http://127.0.0.1:8180/manager jar=$(mktemp)
csrf=$(curl -sS -c "$jar" -b "$jar" "$base/signin" | sed -n "s/.*name=\"_csrf\" value=\"\([^\"]*\)\".*/\1/p")
[ -n "$csrf" ] || { echo "no-csrf"; exit 0; }
curl -sS -o /dev/null -c "$jar" -b "$jar" -w "%{redirect_url} " --data-urlencode "username=$1" \
  --data-urlencode "password=$2" --data-urlencode "_csrf=$csrf" "$base/signin"
curl -sS -o /dev/null -b "$jar" -w "%{http_code}" "$base/home"
rm -f "$jar"'
signin() { compose "$1" exec -T steve sh -c "${signin_script}" sh "$2" "$3"; }
signed_in() { [[ "$(signin "$@")" =~ ^http://127\.0\.0\.1:8180/\ 200$ ]]; }
refused() { [[ "$(signin "$@")" =~ signin\?error\ 302$ ]]; }
# signin_admin / signed_in_admin PROJECT: with that installation's generated
# administrator.
signin_admin() { signin "$1" "$(value "$1" "${admin_user}")" "$(value "$1" "${admin_password}")"; }
signed_in_admin() { signed_in "$1" "$(value "$1" "${admin_user}")" "$(value "$1" "${admin_password}")"; }
in_container() { compose "$1" exec -T steve curl -sS -o /dev/null -w '%{http_code}' "${@:2}"; }
# upgrade PROJECT CHARGE_BOX_ID [CURL ARGS…]: the status of an OCPP 1.6
# WebSocket upgrade. An accepted one stays open until --max-time, and curl
# then exits 28 having printed 101, hence the `|| true`; an empty answer is
# still a mismatch.
upgrade() {
  in_container "$1" --max-time 5 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Protocol: ocpp1.6' "${@:3}" \
    "http://127.0.0.1:8180/websocket/CentralSystemService/$2" 2>/dev/null || true
}
# A charge point in security profile 2: SteVe stores the profile and a
# bcrypt hash of its Basic password on charge_box (read, steve-3.14.1:
# V1_1_1__ocpp16_security.sql, BCryptPasswordEncoder). The hash is of
# p2_password, made once with `htpasswd -nbBC 10`; a throwaway database's
# fixture, not a secret.
p2_password=profile2-test-password
# shellcheck disable=SC2016 # a bcrypt hash, not an expansion
p2_hash='$2y$10$XaVpwp2o6N/Tr2RR0UhZz.pX2/77c5CaNNDQZeNZxugz70RGHW2Bu'
# shellcheck disable=SC2016 # expanded by the container shell
sql() { compose "$1" exec -T steve-db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -N -u steve stevedb -e "$1"' sh "$2"; }
# tag_count PROJECT ID_TAG: how many ocpp_tag rows carry it, 0 or 1.
tag_count() { sql "$1" "SELECT COUNT(*) FROM ocpp_tag WHERE id_tag = '$2'"; }

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
  signed_in_admin "${p}" || fail "${p}: the generated administrator does not sign in ($(signin_admin "${p}"))"
  refused "${p}" admin 1234 || fail "${p}: the upstream default admin/1234 is not refused"
  echo "the generated administrator signs in; admin/1234 is refused."
  code=$(in_container "${p}" -u "$(value "${p}" "${admin_user}"):$(value "${p}" "${admin_password}")" http://127.0.0.1:8180/api/v1/ocppTags)
  [ "${code}" = 401 ] || fail "${p}: the Web API answered ${code} to the administrator, expected 401"
  echo "Web API refused (401)."
  code=$(upgrade "${p}" "${run}-unknown")
  [ "${code}" = 404 ] || fail "${p}: an unknown charge point's upgrade answered '${code}', expected 404"
  sql "${p}" "INSERT INTO charge_box (charge_box_id) VALUES ('${run}-cp')"
  code=$(upgrade "${p}" "${run}-cp")
  [ "${code}" = 101 ] || fail "${p}: a registered charge point's upgrade answered '${code}', expected 101"
  echo "a registered charge point connects (101); an unknown one is refused (404)."
  # Profile 2 is Basic over TLS, and the TLS is the proxy's: SteVe sees
  # plain HTTP and refuses the station unless the template names the header
  # carrying the original scheme. The proxy sets that header itself.
  sql "${p}" "INSERT INTO charge_box (charge_box_id, security_profile, auth_password) VALUES ('${run}-p2', 2, '${p2_hash}')"
  code=$(upgrade "${p}" "${run}-p2" -u "${run}-p2:${p2_password}")
  [ "${code}" = 401 ] || fail "${p}: a profile-2 charge point over plain HTTP answered '${code}', expected 401"
  code=$(upgrade "${p}" "${run}-p2" -u "${run}-p2:${p2_password}" -H 'X-Forwarded-Proto: https')
  [ "${code}" = 101 ] \
    || fail "${p}: a profile-2 charge point behind X-Forwarded-Proto: https answered '${code}', expected 101"
  code=$(upgrade "${p}" "${run}-p2" -u "${run}-p2:wrong-${p2_password}" -H 'X-Forwarded-Proto: https')
  [ "${code}" = 401 ] || fail "${p}: a profile-2 charge point with a wrong password answered '${code}', expected 401"
  echo "profile 2: 101 behind X-Forwarded-Proto: https; 401 without it, 401 with a wrong password."
done

header "isolation"
a=${projects[0]} b=${projects[1]}
refused "${b}" "$(value "${a}" "${admin_user}")" "$(value "${a}" "${admin_password}")" \
  || fail "${a}'s administrator signs in on ${b}"
echo "${a}'s administrator is refused on ${b}."

header "restart with the data kept"
sql "${a}" "INSERT INTO ocpp_tag (id_tag, note) VALUES ('${run}', 'coolify-template-test')"
compose "${a}" down >/dev/null 2>&1
healthy "${a}" "${a} not healthy after the restart"
logs=$(compose "${a}" logs --no-log-prefix steve 2>&1)
grep -qE '^Schema .stevedb. is up to date\. No migration necessary\.' <<<"${logs}" \
  || fail "${a}: Flyway did not find the schema up to date after the restart"
echo "Flyway: up to date."
[ "$(tag_count "${a}" "${run}")" = 1 ] || fail "${a}: the row written before the restart is gone"
[ "$(tag_count "${b}" "${run}")" = 0 ] || fail "${b} holds ${a}'s row"
signed_in_admin "${a}" || fail "${a}: the administrator no longer signs in after the restart"
echo "the row survived on ${a}, never reached ${b}; the administrator still signs in."

header "dump, administrator reset, restore"
# The commands of deploy/coolify/README.md, the part it quotes for the
# container's shell unchanged: in steve-db, with the password read there,
# never on a command line. The dump goes to stdout and lands outside the
# container, as the README's does: Coolify's Stop, Restart and Deploy
# destroy the container and its /tmp. The restore reads the file back on
# stdin. The README wraps them in `docker exec`, this in `docker compose
# exec -T`; and the reset names the administrator, which steve-db does not
# know: the value is put in for <AUTH_USER>, as an operator copies it from
# Coolify.
# shellcheck disable=SC2016 # expanded by the container shell
readme_dump='MYSQL_PWD="$MARIADB_PASSWORD" mariadb-dump --single-transaction --routines --events -u steve stevedb'
# shellcheck disable=SC2016
readme_reset='MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u steve stevedb -e "DELETE FROM web_user WHERE username = '\''<AUTH_USER>'\''"'
# shellcheck disable=SC2016
readme_drop='MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u steve -e "DROP DATABASE stevedb; CREATE DATABASE stevedb"'
# shellcheck disable=SC2016
readme_import='MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u steve stevedb'
in_db() { compose "$1" exec -T steve-db sh -c "$2"; }
# set_value PROJECT NAME VALUE: what changing a variable in Coolify does.
set_value() {
  local f="${work}/$1.env"
  { grep -v "^$2=" "${f}"; printf '%s=%s\n' "$2" "$3"; } >"${f}.new" && mv "${f}.new" "${f}"
}
restart_steve() {
  compose "$1" restart steve >/dev/null 2>&1 || fail "$1: steve did not restart"
  healthy "$1" "$1: steve not healthy after $2" steve
}

user=$(value "${a}" "${admin_user}")
old_password=$(value "${a}" "${admin_password}")
in_db "${a}" "${readme_dump}" >"${work}/dump.sql" || fail "${a}: the README's dump command failed"
[ "$(tail -n 1 "${work}/dump.sql" | cut -c1-17)" = '-- Dump completed' ] \
  || fail "${a}: the dump outside the container does not end with '-- Dump completed'"
echo "dumped to the host ($(wc -c <"${work}/dump.sql" | tr -d ' ') bytes, '-- Dump completed')."
sql "${a}" "INSERT INTO ocpp_tag (id_tag, note) VALUES ('${run}-late', 'coolify-template-test')"

new_password=$(random 32)
set_value "${a}" "${admin_password}" "${new_password}"
healthy "${a}" "${a}: steve not healthy after the variable changed" steve
signed_in "${a}" "${user}" "${old_password}" || fail "${a}: a changed variable alone replaced the administrator's password"
refused "${a}" "${user}" "${new_password}" || fail "${a}: the new password signs in before the reset"
echo "the variable alone changes nothing: the old password still signs in."
in_db "${a}" "${readme_reset//<AUTH_USER>/${user}}" || fail "${a}: the README's reset command failed"
restart_steve "${a}" "the reset"
signed_in "${a}" "${user}" "${new_password}" || fail "${a}: the new password does not sign in after the reset"
refused "${a}" "${user}" "${old_password}" || fail "${a}: the old password still signs in after the reset"
refused "${a}" admin 1234 || fail "${a}: admin/1234 signs in after the reset"
echo "after the README's reset and a restart: the new password signs in, the old one and admin/1234 do not."

compose "${a}" stop steve >/dev/null 2>&1 || fail "${a}: steve did not stop"
in_db "${a}" "${readme_drop}" || fail "${a}: the README's drop and create failed"
in_db "${a}" "${readme_import}" <"${work}/dump.sql" || fail "${a}: the README's import failed"
healthy "${a}" "${a}: steve not healthy after the restore" steve
[ "$(tag_count "${a}" "${run}")" = 1 ] || fail "${a}: the row in the dump is not restored"
[ "$(tag_count "${a}" "${run}-late")" = 0 ] || fail "${a}: a row written after the dump survived the restore"
# The dump carries web_user, so the administrator comes back as it was then.
signed_in "${a}" "${user}" "${old_password}" || fail "${a}: the dump's administrator does not sign in after the restore"
refused "${a}" "${user}" "${new_password}" || fail "${a}: the reset password still signs in after the restore"
echo "restored: the dump's rows and the dump's administrator are back, later ones gone."

header "steve-db lost alone"
# steve's healthcheck reads the sign-in page, which needs no database: with
# steve-db gone for 300 s it stayed healthy while sign-in and the upgrade
# failed (measured, plain Compose). So whether SteVe recovers when the
# database comes back is asked of a sign-in and an upgrade, both of which
# read it. `docker kill` stands for a crash only in what it does to steve's
# pool. A real crash, mariadbd killed from outside Docker, was restarted
# under `unless-stopped` (measured), which Coolify adds (read, RESTART_MODE
# in its constants.php); `docker kill` is a manual stop to Docker and is not
# restarted (measured), so the database is started by hand, steve left as
# it is.
steve_started() { docker inspect -f '{{.Id}} {{.State.StartedAt}}' "$(compose "${b}" ps -q steve)"; }
before=$(steve_started)
docker kill "$(compose "${b}" ps -q steve-db)" >/dev/null || fail "${b}: steve-db could not be killed"
compose "${b}" start steve-db >/dev/null 2>&1 || fail "${b}: steve-db did not start again"
healthy "${b}" "${b}: not healthy after steve-db came back"
signed_in_admin "${b}" || fail "${b}: the administrator does not sign in after steve-db came back"
code=$(upgrade "${b}" "${run}-cp")
[ "${code}" = 101 ] || fail "${b}: a registered charge point's upgrade answered '${code}' after steve-db came back, expected 101"
[ "$(steve_started)" = "${before}" ] || fail "${b}: steve was restarted or recreated, which proves nothing about its pool"
echo "steve-db killed and started again: sign-in and upgrade work, steve not restarted."

echo
echo "OK: the template came up twice, side by side, as Coolify would run it."

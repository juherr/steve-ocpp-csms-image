#!/usr/bin/env bash
# Does the Kubernetes example actually bring SteVe up under what it declares?
#
# kubeconform says the manifests are valid Kubernetes; nothing about whether a
# pod comes up under them — the read-only root filesystem with /tmp the one
# writable path, the dropped capabilities, the probes finding the sign-in page,
# the Service reaching the pod. This applies examples/kubernetes/ to a
# throwaway kind cluster and checks exactly that, with the database the example
# leaves out started in-cluster, empty, so the first-boot migration runs too.
#
# Two kinds of check. What a fresh deployment cannot exercise is read back from
# the applied Deployment and compared with what the example promises: one
# replica and Recreate, which only an upgrade would tell apart from the
# defaults; the security context, which a pod that came up says nothing about;
# the three probe paths, because any other path under /steve/manager/ answers
# a 302 to the sign-in page, which a Kubernetes HTTP probe counts as success
# (measured) — so a misspelt probe would come up green here and prove nothing
# in production. Then what only a running pod can tell: identity, filesystem,
# the Service, the environment the Secret injected — the database password is
# NOT the image's compiled-in default, so a Secret that stopped reaching the
# container fails Flyway instead of falling through to `changeme`.
#
# Two ways in. Given an IMAGE, one in the local daemon, it is loaded into the
# cluster and put in place of the manifest's image line: what CI does with the
# image it has just built, the only image that exists for a tag not yet
# published. Given none, the manifest is applied as it is and the cluster
# pulls the published tag it names — a laptop checking the example as a user
# would apply it.
#
# The manifest is edited in three places before it is applied, by exact
# string, and each edit must find its line: DB_IP to the in-cluster database,
# the image line, and — with a loaded image — the pull policy, because
# `Always` would go to the registry for an image that exists only here.
#
# The cluster has its own kubeconfig under a temporary directory: the
# current context of whoever runs this is neither read nor changed.
#
# Usage:  ./hack/k8s-example-test.sh [IMAGE]
# Env:    MARIADB_IMAGE  database image; defaults to the pin in
#                        .github/workflows/build-image.yml so that there is
#                        exactly one copy of it; pulled by the node
#         STEVE_TIMEOUT  seconds for the pod to become ready (default 600)
# Exit:   0 came up and every check passed · 1 a check failed, diagnostics
#         printed · 2 usage or tooling

set -euo pipefail

usage() { echo "Usage: $0 [IMAGE]" >&2; exit 2; }
[ $# -le 1 ] || usage
image=${1:-}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "${here}/.." && pwd)
manifests="${root}/examples/kubernetes"

die() { printf 'k8s-example-test: %s\n' "$1" >&2; exit 2; }
for tool in kind kubectl docker; do
  command -v "${tool}" >/dev/null || die "${tool} not found"
done

workflow="${root}/.github/workflows/build-image.yml"
MARIADB_IMAGE="${MARIADB_IMAGE:-$(sed -n 's/^  DB_IMAGE: "\(.*\)"$/\1/p' "${workflow}")}"
[ -n "${MARIADB_IMAGE}" ] || die "MARIADB_IMAGE is unset and no DB_IMAGE pin was found in ${workflow}"
steve_timeout=${STEVE_TIMEOUT:-600}

# Everything this script creates carries the run id: the cluster, so that two
# runs on one machine — the script is meant to be run by hand — do not meet,
# and the workflow's fallback cleanup finds a leftover by the prefix.
run="steve-k8s-$$-${RANDOM}"
work=$(mktemp -d "${TMPDIR:-/tmp}/steve-ocpp-csms-image-k8s.XXXXXX")
export KUBECONFIG="${work}/kubeconfig"

in_ci() { [ -n "${GITHUB_ACTIONS:-}" ]; }
group_start() { if in_ci; then printf '::group::%s\n' "$1"; else printf -- '--- %s ---\n' "$1"; fi; }
group_end() { if in_ci; then echo '::endgroup::'; fi; }
header() { printf '\n=== %s ===\n' "$1"; }

# On failure, the cluster's account of it first: the pod's events and its
# log, the previous container's too if it restarted, and the database's.
cleanup() {
  local status=$?
  if [ "${status}" -ne 0 ] && [ -f "${KUBECONFIG}" ]; then
    group_start 'kubectl get pods,events'
    kubectl get pods -o wide 2>&1 || true
    kubectl get events --sort-by=.lastTimestamp 2>&1 | tail -30 || true
    group_end
    group_start 'kubectl describe pod steve'
    kubectl describe pod -l app.kubernetes.io/name=steve 2>&1 || true
    group_end
    group_start 'kubectl logs steve'
    kubectl logs deployment/steve --all-containers 2>&1 || true
    kubectl logs deployment/steve --previous 2>&1 || true
    group_end
    group_start 'kubectl logs mariadb'
    kubectl logs deployment/mariadb 2>&1 || true
    group_end
  fi
  kind delete cluster --name "${run}" >/dev/null 2>&1 || true
  rm -rf "${work}"
  exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# edit FILE FROM TO: an exact-string edit that must change something — a
# manifest line that moved would otherwise leave the test applying the
# example against the wrong database, image or registry, silently.
edit() {
  local file=$1 from=$2 to=$3
  grep -qF -- "${from}" "${file}" || fail "no line matching '${from}' in ${file}"
  local tmp="${file}.edit"
  FROM="${from}" TO="${to}" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/' "${file}" >"${tmp}" && mv "${tmp}" "${file}"
}

header "kind cluster ${run}"
kind create cluster --name "${run}" --kubeconfig "${KUBECONFIG}" --wait 120s >/dev/null
echo "cluster ready."

header "MariaDB (${MARIADB_IMAGE}), empty"
# Pulled by the node, not loaded from the daemon even when the daemon holds
# it: under Docker Desktop's containerd image store a pulled multi-platform
# tag carries only its own platform's blobs, and `kind load` of it dies with
# `content digest … not found` (measured); a single-platform image — the one
# a build `--load`s, the one IMAGE names — loads fine.
#
# Same values as the README's Compose example and hack/migration-test.sh, but
# for the password: `changeme` is what the image falls back to when no
# DB_PASSWORD reaches it, and a test that used it could not tell the Secret
# from the default. Upstream public placeholders otherwise, no data. Ready
# when the image's own healthcheck says so, as in the Compose example.
db_password='not-the-default'
kubectl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mariadb
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mariadb
  template:
    metadata:
      labels:
        app: mariadb
    spec:
      containers:
        - name: mariadb
          image: ${MARIADB_IMAGE}
          args: ["--innodb-use-native-aio=0"]
          env:
            - { name: MARIADB_ROOT_PASSWORD, value: root }
            - { name: MARIADB_DATABASE, value: stevedb }
            - { name: MARIADB_USER, value: steve }
            - { name: MARIADB_PASSWORD, value: ${db_password} }
            - { name: TZ, value: "+00:00" }
          ports:
            - containerPort: 3306
          readinessProbe:
            exec:
              command: [healthcheck.sh, --connect, --innodb_initialized]
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: mariadb
spec:
  selector:
    app: mariadb
  ports:
    - port: 3306
YAML
kubectl rollout status deployment/mariadb --timeout=180s >/dev/null || fail "mariadb never became ready"
echo "mariadb ready."

header "the example"
auth_user='example-admin' auth_password='example-only'
kubectl create secret generic steve \
  --from-literal=DB_PASSWORD="${db_password}" --from-literal=AUTH_USER="${auth_user}" \
  --from-literal=AUTH_PASSWORD="${auth_password}" >/dev/null
cp "${manifests}/deployment.yaml" "${work}/deployment.yaml"
edit "${work}/deployment.yaml" 'value: mariadb.example.internal' 'value: mariadb'
if [ -n "${image}" ]; then
  docker image inspect "${image}" >/dev/null 2>&1 || die "${image} is not in the local daemon"
  echo "loading ${image} into the cluster…"
  kind load docker-image --name "${run}" "${image}" >/dev/null
  published=$(sed -n 's/^ *image: \(ghcr\.io\/juherr\/steve:steve-[0-9.]*\)$/\1/p' "${manifests}/deployment.yaml")
  [ "$(printf '%s\n' "${published}" | grep -c .)" -eq 1 ] || fail "expected exactly one image line in deployment.yaml"
  edit "${work}/deployment.yaml" "image: ${published}" "image: ${image}"
  edit "${work}/deployment.yaml" 'imagePullPolicy: Always' 'imagePullPolicy: Never'
  echo "applying with image ${image} (loaded, never pulled)."
else
  echo "applying as published."
fi
kubectl apply -f "${work}/deployment.yaml" -f "${manifests}/service.yaml" >/dev/null

header "what the Deployment declares"
# Read back from the API server, so that what is asserted is what the cluster
# holds — defaults filled in, the edits above included.
container='.spec.template.spec.containers[0]'
declared() {
  local path=$1 expected=$2 label=$3 actual
  actual=$(kubectl get deployment steve -o jsonpath="{${path}}")
  [ "${actual}" = "${expected}" ] || fail "${label}: '${actual}', expected '${expected}'"
  echo "${label}: ${actual}"
}
declared '.spec.replicas' '1' 'replicas'
declared '.spec.strategy.type' 'Recreate' 'strategy'
declared '.spec.template.spec.securityContext.runAsNonRoot' 'true' 'runAsNonRoot'
declared '.spec.template.spec.securityContext.seccompProfile.type' 'RuntimeDefault' 'seccompProfile'
declared "${container}.securityContext.allowPrivilegeEscalation" 'false' 'allowPrivilegeEscalation'
declared "${container}.securityContext.capabilities.drop" '["ALL"]' 'capabilities.drop'
declared "${container}.securityContext.readOnlyRootFilesystem" 'true' 'readOnlyRootFilesystem'
for probe in startupProbe readinessProbe livenessProbe; do
  declared "${container}.${probe}.httpGet.path" '/steve/manager/signin' "${probe} path"
done

header "the pod"
# Not `rollout status`: a container that cannot start is CrashLoopBackOff for
# the whole timeout under it, where the restart count says so at once. The
# startupProbe is the slow path — its budget is what the timeout has to cover.
echo "waiting for the pod (up to ${steve_timeout}s)…"
pod='' i=0
for ((i = 0; i < steve_timeout; i += 5)); do
  pod=$(kubectl get pods -l app.kubernetes.io/name=steve -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "${pod}" ]; then
    read -r ready restarts waiting <<<"$(kubectl get pod "${pod}" -o jsonpath='{.status.containerStatuses[0].ready} {.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo 'false 0')"
    [ "${restarts:-0}" -eq 0 ] || fail "${pod} restarted (${restarts}): the container died or a probe killed it"
    case "${waiting:-}" in
      CrashLoopBackOff|ImagePullBackOff|ErrImagePull|ErrImageNeverPull|CreateContainerConfigError|CreateContainerError)
        fail "${pod} is ${waiting}" ;;
    esac
    if [ "${ready}" = "true" ]; then echo "${pod} ready after ~${i}s."; break; fi
  fi
  sleep 5
done
[ "${ready:-false}" = "true" ] || fail "no ready pod after ${steve_timeout}s"

header "what only a running pod can tell"
uid=$(kubectl exec "${pod}" -- id -u); gid=$(kubectl exec "${pod}" -- id -g)
[ "${uid}:${gid}" = "10001:10001" ] || fail "runs as ${uid}:${gid}, expected 10001:10001"
echo "runs as ${uid}:${gid}."
if kubectl exec "${pod}" -- touch /app/.write-test 2>/dev/null; then fail "root filesystem is writable"; fi
echo "root filesystem read-only."
kubectl exec "${pod}" -- sh -c 'touch /tmp/.write-test && rm /tmp/.write-test' || fail "/tmp is not writable"
echo "/tmp writable."
# The Secret's keys, as the container sees them. Flyway has already proven
# DB_PASSWORD by connecting with a password that is not the default; the two
# the application reads are checked the same way, without a sign-in.
for var in DB_PASSWORD="${db_password}" AUTH_USER="${auth_user}" AUTH_PASSWORD="${auth_password}"; do
  actual=$(kubectl exec "${pod}" -- sh -c "printf '%s' \"\$${var%%=*}\"")
  [ "${actual}" = "${var#*=}" ] || fail "${var%%=*} in the container is '${actual}', expected '${var#*=}': the Secret is not reaching it"
done
echo "DB_PASSWORD, AUTH_USER, AUTH_PASSWORD injected from the Secret."
# Through the Service by its cluster DNS name, from inside the pod — the
# image ships curl for its healthcheck, so no second image is needed.
code=$(kubectl exec "${pod}" -- curl -sS -o /dev/null -w '%{http_code}' http://steve:8180/steve/manager/signin || true)
[ "${code}" = "200" ] || fail "sign-in page through the Service answered '${code}', expected 200"
echo "sign-in page through the Service: 200."
kubectl logs "${pod}" | grep -E '^\[entrypoint\]|^Successfully applied|^Schema .* is up to date' || fail "no Flyway outcome in the pod log"

echo
echo "OK: the example brought SteVe up under its own manifests."

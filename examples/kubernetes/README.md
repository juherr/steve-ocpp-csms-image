# Running the image on Kubernetes

A reference deployment, kept deliberately small: a `Deployment` and a
`Service`, plain manifests, no Helm chart. It is an **example**, not a
manifest for every cluster — the namespace, the Ingress, the certificate
issuer, the storage class and the database are your cluster's decisions, and
the manifests leave them out rather than guess. Upstream reached the same
conclusion about its own manifests ([steve#1351]); what this example fixes is
only what *this image* needs to run.

[steve#1351]: https://github.com/steve-community/steve/issues/1351

| File | What it declares |
| --- | --- |
| `deployment.yaml` | One pod of `ghcr.io/juherr/steve`, non-root, read-only root filesystem, credentials from a `Secret`, probes sized for the startup migration |
| `service.yaml` | A `ClusterIP` on `8180`, the one port the management UI and the OCPP endpoint share |

## Prerequisites

- **A MariaDB the pod can reach** — a managed instance, an operator's
  `Service`, a `StatefulSet` you run. It is not part of this example: a
  database topology is exactly the kind of choice the example refuses to make
  for you. It must hold an empty database `stevedb` owned by a user `steve`
  (other names: set `DB_SCHEMA` and `DB_USER`, see the
  [configuration table](../../README.md#configuration-is-injected-at-runtime)),
  and it must run in **UTC** — SteVe requires the database and application
  time zones to be aligned, which is what `TZ=+00:00` does in the Compose
  example.
- `kubectl` pointed at the cluster and namespace you want. The manifests
  carry no `namespace:`; `-n` chooses it.

## Deploy

1. Create the `Secret` the pod reads its credentials from. Nothing in this
   directory holds a credential, so the `Secret` is made out of band, once, and
   never committed:

   ```bash
   kubectl create secret generic steve \
     --from-literal=DB_PASSWORD='<your-db-password>' \
     --from-literal=AUTH_USER='<your-admin-user>' \
     --from-literal=AUTH_PASSWORD='<your-admin-password>'
   ```

   Every key becomes an environment variable of the container (`envFrom`), so
   any other setting from the configuration table — `DB_USER`, `WEBAPI_KEY` —
   goes in the same way. Keep the `Secret` to SteVe settings: a stray key
   would become a stray variable.

2. Point `DB_IP` in `deployment.yaml` at your database. It is the one value in
   the file that has to change; `mariadb.example.internal` is a placeholder.

3. Apply, and wait for the rollout:

   ```bash
   kubectl apply -f examples/kubernetes/
   kubectl rollout status deployment/steve
   ```

   The first start migrates the empty database before SteVe boots. The
   migration lines are in the pod log, the same ones the
   [main README](../../README.md#5-watch-the-migration) shows for Compose:

   ```bash
   kubectl logs -f deployment/steve
   ```

   ```
   [entrypoint] Flyway migrate -> mariadb:3306/stevedb
   Successfully validated 49 migrations (execution time 00:00.449s)
   Successfully applied 12 migrations to schema `stevedb`, now at version v1.1.6 (execution time 00:00.359s)
   [entrypoint] Starting SteVe…
   ```

   (Measured in a [kind](https://kind.sigs.k8s.io) cluster on an Apple Silicon
   laptop, where `steve-3.14.1` — an amd64-only tag — ran emulated: the pod
   was ready 130 s after `apply`, image pull included. A native run is
   faster; the probe budget below is sized for the slow case.)

4. Reach it. The `Service` is in-cluster only; for a look before any Ingress
   exists:

   ```bash
   kubectl port-forward service/steve 8180:8180
   ```

   The management UI is then at `http://localhost:8180/steve/manager`, and
   signs in with the `AUTH_USER` / `AUTH_PASSWORD` of the `Secret`.

The variable names are the ones the image documents — `DB_IP`, `AUTH_USER`,
`AUTH_PASSWORD` — because the `.war` is compiled with upstream's `docker`
profile. Upstream's own Kubernetes manifests used its `kubernetes` profile,
whose names differ (`DB_HOST`, `ADMIN_USERNAME`…); those do not apply here.

## What the manifest fixes, and why

**One replica.** The entrypoint replays the Flyway migrations at startup.
Two pods starting against the same empty schema would both set out to run
them, and SteVe keeps its OCPP sessions in the JVM, not in the database, so a
second instance would not share them anyway. Scale the database and the
reverse proxy, not this `Deployment`.

**`strategy: Recreate`.** On an upgrade the new pod migrates the schema, and
under the default `RollingUpdate` the old pod would still be serving on it
while that happens. `Recreate` stops the old pod first — the order the
Compose upgrade follows too. The cost is a gap of the migration plus a start:
87 s measured for `steve-3.14.0` → `steve-3.14.1`, emulated. When the old
pod stops, `kubectl get pods` may show it as `Failed` / `Error` for a moment:
the JVM exits with code 143 on `SIGTERM`, 128 + 15, which is its normal exit
on that signal — the pod was gone 6 s after the delete, measured.

**Non-root, read-only.** The image runs as UID/GID `10001`, and the manifest
says so (`runAsNonRoot`, `runAsUser`, `runAsGroup`) so the kubelet refuses an
image that does not. The root filesystem is read-only, every capability is
dropped, privilege escalation is off, the runtime seccomp profile is on. The
one writable path is `/tmp`, an `emptyDir`: Jetty unpacks the `.war` and Java
writes its jar caches there, about 160 MB at `steve-3.14.1` (measured); nothing
else is written.

**Memory limit.** The entrypoint starts Java with `-XX:MaxRAMPercentage=85`,
so the container's memory limit is what sizes the heap; without one the JVM
sizes itself on the node. `1Gi` is a starting point — 700 MiB in use after a
first boot, measured — not a recommendation for your load.

**Probes.** All three ask for the sign-in page, `GET /steve/manager/signin`,
the same URL as the Compose healthcheck. It answers once Jetty and the Spring
context are up, and does **not** touch the database — on purpose for
liveness, where a database outage should not restart SteVe, and for lack of
anything better for readiness: upstream exposes no health endpoint. The
`startupProbe` allows 30 × 10 s = 300 s before liveness starts counting,
which covers a first boot that migrates everything, emulated; a restart on a
migrated schema takes a fraction of it.

## Exposing it

The image serves **plain HTTP** on `8180`; internal HTTPS is left disabled.
Terminate TLS where a cluster does — an `Ingress` (or `Gateway`) in front of
the `Service`, or a reverse proxy outside the cluster. None is included: the
class, the certificate issuer and the hostnames are yours.

Two things to carry over from the [main README's security
note](../../README.md#security-note) when you write that `Ingress`:

- **OCPP is a WebSocket** at `/steve/websocket/CentralSystemService/…`, and a
  charge point keeps it open for hours. Most ingress controllers cut idle
  connections after a minute by default; raise the read/send timeouts on the
  route the charge points use, or they reconnect in a loop.
- **The UI and the OCPP endpoint share the port**, and charge points connect
  without an interactive login, so they cannot pass an authentication proxy.
  Route only the UI hostname to the public interface, and keep the OCPP route
  on an address only your charge points reach — a VPN, a private load
  balancer.

## Upgrading

Back up first, as the [main README](../../README.md#upgrading) describes;
then change the image line and apply. `Recreate` stops the old pod, the new
one migrates and starts, and the pod log shows what Flyway applied — the
`Migrating schema` lines. Pin by digest in production: this tag is republished
on a JRE update, and the digest to pin is the index's, see
[Tags](../../README.md#tags).

```bash
kubectl rollout status deployment/steve
kubectl logs deployment/steve | grep -E '^\[entrypoint\]|^Migrating|^Successfully'
```

A downgrade is not a supported path, for the reasons the main README gives;
the way back is the backup.

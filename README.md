# steve-ocpp-csms-image

Ready-to-run Docker images for [SteVe](https://github.com/steve-community/steve),
the open-source OCPP Central System (CSMS).

```
ghcr.io/juherr/steve
```

Unofficial and community-maintained. Not affiliated with the SteVe project.

## Why this image exists

Upstream publishes no official image, and its `docker-compose` setup
**recompiles the application every time the container starts** — `mvnw clean
package` sits in the `CMD`. That means Maven *and* a reachable database are
required on every restart, and several minutes of downtime each time.

Here the `.war` is compiled at **build** time, from a pinned upstream release
tag. Starting the container just starts the application.

The image is also **self-migrating**. SteVe applies its Flyway migrations during
the Maven build, against the code-generation database — which is thrown away
here. So the runtime database starts empty, and the entrypoint replays the
migrations against it on startup, using SteVe's exact Flyway configuration. This
is idempotent: on later restarts Flyway is a no-op. The migration scripts are
copied from the very same clone that produced the `.war`, so schema and binary
cannot drift apart.

## Tags

One tag per upstream release: `steve-<X.Y.Z>` names SteVe release
`steve-X.Y.Z`. There is deliberately no `latest` and no per-commit tag.

A tag published by the multi-architecture build is an image index holding
**`linux/amd64`** and **`linux/arm64`**. Both are built natively on their own
runner — no emulation anywhere — and each is migrated from an empty database
and restarted on it in CI before the tag is made. The third scenario, the
upgrade from the previous release's schema, runs on a platform that release
was published for: on the first multi-architecture release that is amd64
only, from the next one on both. `docker pull` picks the platform of
the host on its own, so a Raspberry Pi 4/5 on a 64-bit OS or an ARM NAS box
runs the same tag as a PC, with nothing to add; a 32-bit OS has no platform
to match. There is no per-architecture tag. Tags published before that build
are `linux/amd64` alone, a single manifest rather than an index, and
`imagetools inspect` below tells the two shapes apart.

The image currently runs on **Eclipse Temurin 25 (JRE)** — a build detail, not
part of the tag. A JRE update republishes the same tag with a new digest.

**Pin by digest — and you should.** The digest is what Docker actually resolves,
so the tag alongside it is documentation: a moving tag cannot change what you
run, and it keeps version-tracking tools pointed at something still being
republished.

An index tag has three digests, and only one of them is the one to pin: the
**index's**, which `imagetools inspect` prints first and which the release
prints as "Digest to pin". The two under `Manifests:` are the platform images
the index points at; pinning one of those pins one architecture, and a host
of the other one still pulls it — with a platform-mismatch warning — and then
runs it only if it can emulate it. The output below is the shape a tag from
the multi-architecture build has; on a tag from before it, the same command
prints one manifest and no `Manifests:` list.

```bash
docker buildx imagetools inspect ghcr.io/juherr/steve:steve-3.14.1
```

```
Name:      ghcr.io/juherr/steve:steve-3.14.1
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:<index digest>

Manifests:
  Name:      ghcr.io/juherr/steve:steve-3.14.1@sha256:<amd64 digest>
  MediaType: application/vnd.oci.image.manifest.v1+json
  Platform:  linux/amd64

  Name:      ghcr.io/juherr/steve:steve-3.14.1@sha256:<arm64 digest>
  MediaType: application/vnd.oci.image.manifest.v1+json
  Platform:  linux/arm64
```

```yaml
image: ghcr.io/juherr/steve:steve-3.14.1@sha256:<index digest>
```

The exact JRE of an image you already hold is readable from it:

```bash
docker run --rm --entrypoint java ghcr.io/juherr/steve:steve-3.14.1 -version
```

## Usage

```bash
docker pull ghcr.io/juherr/steve:steve-3.14.1
```

This fetches the platform of the host; `--platform linux/arm64` (or `amd64`)
fetches the other one on purpose, to inspect it for instance.

Minimal Compose setup:

```yaml
# Fixed project name: container and network names derive from it, and by
# default it derives from the directory — renaming the directory for a new
# release would then leave the old stack behind. See "Upgrading".
name: steve

services:
  steve:
    image: ghcr.io/juherr/steve:steve-3.14.1
    restart: unless-stopped
    depends_on:
      steve-db:
        condition: service_healthy
    environment:
      - DB_IP=steve-db
      - DB_PASSWORD=<your-db-password>
      - AUTH_USER=<your-admin-user>
      - AUTH_PASSWORD=<your-admin-password>
      # Reject any charge point that is not pre-registered in the database.
      # This is already the upstream default; pinning it guards against an
      # upstream default change.
      - AUTO_REGISTER_UNKNOWN_STATIONS=false
    ports:
      - "8180:8180"
    healthcheck:
      # 127.0.0.1 and not localhost: Jetty binds IPv4, localhost may resolve
      # to ::1 first.
      test: ["CMD", "curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:8180/steve/manager/signin"]
      interval: 30s
      timeout: 5s
      retries: 3
      # First boot runs the Flyway migrations against an empty database.
      start_period: 150s

  steve-db:
    image: mariadb:11.8
    restart: unless-stopped
    environment:
      # UTC is mandatory: SteVe requires the database and application time zones
      # to be aligned.
      - TZ=+00:00
      - MARIADB_ROOT_PASSWORD=<your-root-password>
      - MARIADB_DATABASE=stevedb
      - MARIADB_USER=steve
      - MARIADB_PASSWORD=<your-db-password>
    volumes:
      - ./data/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 30s
      interval: 10s
      timeout: 5s
      retries: 5
```

The management UI is then at `http://localhost:8180/steve/manager`.

### Configuration is injected at runtime

**No credentials are baked into this image.**

SteVe is a Spring Boot application: its `application.yml` resolves
`${db.password}`, `${auth.password}`, `${db.ip}`… from the environment, and
Spring's relaxed binding makes container environment variables win over the
defaults compiled into `application-docker.properties`.

Those compiled-in defaults — `changeme`, `admin`, `1234` — are **upstream public
placeholders, not secrets**. They are the values anyone gets from a stock
upstream build. Override every one of them that matters to you.

| Variable | Overrides | Default in the image |
| --- | --- | --- |
| `DB_IP` | database host | `mariadb` |
| `DB_PORT` | database port | `3306` |
| `DB_SCHEMA` | database name | `stevedb` |
| `DB_USER` | database user | `steve` |
| `DB_PASSWORD` | database password | `changeme` |
| `AUTH_USER` | management UI user | `admin` |
| `AUTH_PASSWORD` | management UI password | `1234` |
| `WEBAPI_KEY` | REST WebAPI key | upstream default |
| `SERVER_HOST` | bind address inside the container | `0.0.0.0` |
| `AUTO_REGISTER_UNKNOWN_STATIONS` | accept unknown charge points | `false` |

See upstream's `application.properties` for the full list.

> The image runs as UID/GID `10001`, not root.

### Networking

Two address spaces are in play, and mixing them up is where most Docker
support issues upstream come from. In `ports: "8180:8180"` the left side is
the **host** — the interface and port a browser or a charge point reaches from
outside — and the right side is the **container**, where SteVe actually
listens.

**With the Compose setup above, SteVe listens on `0.0.0.0:8180` inside the
container, and it should stay that way.** That is what the compiled-in
`docker` profile sets. Do not point `SERVER_HOST` at the machine's LAN address
to "make it reachable": on the default bridge network that address does not
exist in the container's network namespace, so Jetty cannot bind and the
application fails to start — `Failed to start bean 'webServerStartStop'`,
caused by `Cannot assign requested address`. The interface is chosen on the
host side of the mapping instead — `"192.168.1.10:8180:8180"` publishes on
one LAN address only, `"127.0.0.1:8180:8180"` when a reverse proxy on the
same host is the only client. The container side, `8180`, does not change.

Container-to-container traffic uses the Compose **service name** and the
**container port**. `DB_IP=steve-db` is resolved by Docker's embedded DNS,
and `DB_PORT` stays `3306` whatever the host mapping says: publishing the
database as `3307:3306` renames nothing inside the Compose network.

```yaml
  steve-db:
    ports:
      - "3307:3306"    # host:container — only the host side changed
  steve:
    environment:
      - DB_IP=steve-db
      - DB_PORT=3306   # still the container port: 3307 exists only on the host
```

For a normal deployment MariaDB needs no `ports:` at all — the minimal Compose
setup above publishes none, and the `3307:3306` mapping shown here is only
illustrative. SteVe reaches the database over the Compose network, and an
unpublished port is one less thing on the host to secure. Publish it only when
something *outside* Docker has to connect (a GUI client, a backup job), and
then that client is the one using the host port.

### Security note

The OCPP endpoint and the management UI share port `8180`. Charge points connect
over WebSocket without an interactive login, so they cannot pass an
authentication proxy. If you expose the UI publicly behind a reverse proxy,
route only the UI hostname and keep the OCPP endpoint off the public interface —
for example by publishing it on a VPN address only.

## Deploying on a NAS or a small board

What makes upstream's Compose setup heavy on a NAS or a single-board computer
is the `mvnw clean package` in its `CMD`: Maven, the dependency downloads it
makes — through whatever proxy the box sits behind — and a JDK to run them, on
every start (upstream
[#1919](https://github.com/steve-community/steve/issues/1919),
[#777](https://github.com/steve-community/steve/issues/777),
[#1094](https://github.com/steve-community/steve/issues/1094),
[#909](https://github.com/steve-community/steve/issues/909)). None of that
happens here. The `.war`, the JRE and the Flyway scripts are in the image;
**nothing is compiled or downloaded when the container starts**, and the only
thing the entrypoint reaches is the database — see *Why this image exists*.
Synology Container Manager, QNAP Container Station and Portainer deploy a
Compose file, and the one under *Usage* is meant for them too; what may need
adapting is the bind mount's host side. `./data/mariadb` is relative to the
Compose file, and a stack pasted into a web editor has no directory of its
own for it to be relative to — give it an absolute path on the volume you
mean. Not verified on each product; there are no vendor-specific steps in
this document.

**Platform.** A tag from before the multi-architecture build is
`linux/amd64` alone, and at the time of writing that is every tag published,
`steve-3.14.1` included: an ARM NAS or a Raspberry Pi does not run those
natively, only under emulation where the host offers one, and that is not a
supported setup. Native `linux/arm64` arrives with the first tag the
multi-architecture build publishes, an index holding both platforms — the
shape *Tags* shows. `docker buildx imagetools inspect` there tells which of
the two a given tag is. Either way the host needs a 64-bit OS.

**Restart policy.** `restart: unless-stopped`, as in the Compose file above:
the stack comes back after a host reboot, and a container stopped on purpose
with `docker compose stop` stays down until started again. (Docker's
documented semantics for the policy; not re-measured here.)

**What to persist and back up.** The application container is disposable:
running, it writes nothing outside `/tmp` — a jar cache, the JVM's perf data
and Jetty's compiled JSPs, per `docker diff` on `steve-3.14.1`. All state is
the MariaDB data directory, bind-mounted from `./data/mariadb`, so put that
path on the volume the NAS backs up. A filesystem snapshot of a running data
directory is not a consistent backup; the dump under *Upgrading*, step 1, is
— schedule it (the NAS task scheduler, or `cron`) and keep the dumps
somewhere other than the disk holding `./data/mariadb`.

**Memory.** The entrypoint starts the JVM with `-XX:MaxRAMPercentage=85`, so
the *heap* is sized from the container's memory limit — and, with no limit,
from the whole machine: 6.5 GiB of heap allowed on a 7.65 GiB host
(measured), shared with MariaDB and everything else the NAS runs. Set a limit
on the `steve` service. The heap is not the whole process: metaspace, thread
stacks and the JVM's own native memory sit on top of it, and the container
limit has to hold all of that — once the heap has grown to its cap, the
non-heap has only what the heap leaves of the limit to fit in. MariaDB sizes
itself independently and is left alone here.

```yaml
  steve:
    mem_limit: 1g   # the heap may grow to 85 % of this; the rest is non-heap
```

`1g` is an observed working value, not a sizing recommendation. Measured on
`steve-3.14.1` idle, no charge point connected — the amd64 image, emulated
on Apple Silicon: the heap arithmetic is the same on any host, the resident
figures are indicative — the container settles at about 525 MiB under `1g`.
Under `512m` it still migrates an empty database and becomes healthy, but
sits at about 490 MiB of its 512, heap capped at 436 MiB, with nothing to
spare. What your charge points add is yours to measure; `docker stats` reads
it. No CPU figure is given: none was measured.

**TLS.** Terminate it at a reverse proxy rather than inside SteVe, and keep
the two kinds of client apart, as the *Security note* says. For the
management UI: a proxy holding the certificate, forwarding to the container's
`8180` — published on `127.0.0.1` when the proxy is on the same host, see
*Networking* — and routing only the UI hostname, so that nothing on the
public side reaches the OCPP endpoint. For the charge points: a private path,
never the public proxy. Plain `ws://` straight to `8180`, published on that
interface alone (`"192.168.1.10:8180:8180"`, as *Networking* shows), is
cleartext — identifiers, RFID tags and meter values readable by anything on
that network — so it belongs on a network you hold end to end, a VPN or a
LAN nothing else is on. Anywhere else, `wss://`: a listener of the proxy on
that private address holds the certificate for the charge points, and it must
pass WebSocket upgrades through, or they cannot connect.

## Upgrading

The image is the only thing that moves. The database keeps its data, the new
image brings the `.war` *and* the Flyway scripts that go with it, and the
entrypoint applies the ones the database has not seen yet before SteVe starts.
So an upgrade is: back up, change the image line, `pull`, `up`. The commands
below assume the Compose file above.

### 1. Back up the database

Stop the application — the database stays up — and take a dump:

```bash
docker compose stop steve
f=steve-backup-$(date +%Y%m%dT%H%M%S).sql
docker compose exec -T steve-db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb-dump --single-transaction --routines --events -u steve stevedb' > "$f.partial" && mv "$f.partial" "$f"
tail -1 "$f"
```

The `tail` must print `-- Dump completed on …`, the last line `mariadb-dump`
writes. The rest of the shape is what keeps a bad dump from passing for a
good one: the timestamp is to the second, so a retry never overwrites an
earlier file; and since the redirection creates its file before
`mariadb-dump` has even connected, the output goes to `.partial` and is
renamed only when the command exits 0 — a refused login exits 2 and leaves a
0-byte `.partial` and no `.sql` (measured).

The password never appears on a command line: `MYSQL_PWD` is set inside the
container, from the `MARIADB_PASSWORD` it was started with, so there is
nothing to paste in and nothing left in the shell history. `--routines
--events` are there for the future: at `steve-3.14.1` the schema is 27 tables
and 4 views, which a bare dump already covers, but SteVe's migrations have
carried a stored procedure and an event before, and those two flags are what
keeps the dump complete if a release brings them back. The `steve` user is
enough to dump and restore all of it — checked on `mariadb:11.8` with a
procedure, an event and a trigger.

A logical dump rather than a copy of `./data/mariadb`: it is portable across
hosts and compatible MariaDB versions, where a copied data directory only
restores into a matching server. Any other backup you trust works too; the
dump is the way back this procedure relies on — see *Downgrading*.

### 2. Keep the identity of the stack

The upgrade changes one line. Do not rename the directory, the services, the
database name or the volume: `name: steve` in the Compose file exists so that
the project is not silently re-created next to the old one, which is how
upstream users ended up with a second stack and lost track of the first. Do
not bump `mariadb` in the same change either — one moving part per upgrade.

**If your Compose file predates `name:`**, the project is named after the
directory, and pinning a *different* name is the very mistake above: `up -d`
then starts a second project beside the running one, and `docker compose ps`,
`logs` and `stop` now address the new, empty one. (Measured: the second
MariaDB cannot lock `./data/mariadb` while the first holds it — `Can't lock
aria control file … error: 11` — so it never comes up; the original stack
keeps running, unmanaged.) Read the name in effect first, and pin exactly
that:

```bash
docker compose config | head -1
```

Run it the way you run `up` — same directory, same `-p`, same environment —
because `name:` is not the top of the chain: `-p` beats `COMPOSE_PROJECT_NAME`
(exported, or in `.env`), which beats `name:`, which beats the directory
(measured, all four). If the name comes from `-p` or `COMPOSE_PROJECT_NAME`,
either keep that override for good or move its value into `name:` and drop
it — one of the two, or `name:` pins nothing.
### 3. Change the image line

Pick the new tag and its index digest (see *Tags*), and edit the one line —
the old digest is whatever was pinned, an index's or, for a release from
before the multi-architecture build, a single manifest's:

```diff
-    image: ghcr.io/juherr/steve:steve-X.Y.Z@sha256:<old digest>
+    image: ghcr.io/juherr/steve:steve-3.14.1@sha256:<index digest>
```

### 4. Pull and start

```bash
docker compose pull steve
docker compose up -d steve
```

Compose recreates only the application container; the database is untouched.

### 5. Watch the migration

The entrypoint runs Flyway first and starts SteVe only if it succeeds. The
migration lines are in the container log:

```bash
docker compose logs -f steve
```

```
[entrypoint] Flyway migrate -> steve-db:3306/stevedb
Current version of schema `stevedb`: 1.1.4
Migrating schema `stevedb` to version "1.1.5 - update"
Migrating schema `stevedb` to version "1.1.6 - add timezone"
Successfully applied 2 migrations to schema `stevedb`, now at version v1.1.6 (execution time 00:00.127s)
[entrypoint] Starting SteVe…
```

(That is `steve-3.13.0` → `steve-3.14.1`, as measured. A restart with nothing
to apply says ``Schema `stevedb` is up to date. No migration necessary.`` at
the same place.) Flyway runs with `clean` disabled, so the entrypoint can add
to a schema but never wipe one. If Flyway fails, SteVe is not started: the
container exits and the Flyway error is the last thing in its log. That is
what the backup is for.

### 6. Verify

The container reports `healthy` once the sign-in page answers — the
healthcheck's `start_period` covers the migration:

```bash
docker compose ps
```

```
NAME               IMAGE                                  STATUS
steve-steve-1      ghcr.io/juherr/steve:steve-3.14.1      Up About a minute (healthy)
steve-steve-db-1   mariadb:11.8                           Up 7 minutes (healthy)
```

Then sign in at `http://localhost:8180/steve/manager`. The schema version is
in Flyway's history table, and must match the last `Migrating … to version`
line above:

```bash
docker compose exec -T steve-db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u steve stevedb \
  -e "SELECT version, success FROM schema_version ORDER BY installed_rank DESC LIMIT 1"'
```

### Downgrading

Migrations only go forward. The entrypoint does not stop you: on a schema
newer than the image's scripts, Flyway warns — ``Schema `stevedb` has a version
(1.1.6) that is newer than the latest available migration (1.1.4) !`` — and
hands over to SteVe anyway. Whether that older SteVe then works depends on what
the newer migrations did. Additive ones go unnoticed (`steve-3.14.1` →
`steve-3.13.0` boots and signs in, measured); a renamed or dropped column does
not, and nothing has tested the older release against the newer schema. **A
downgrade is not a supported path.** The way back this procedure relies on is
the dump from step 1:

```bash
docker compose stop steve
docker compose exec -T steve-db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u steve -e "DROP DATABASE stevedb; CREATE DATABASE stevedb"'
docker compose exec -T steve-db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u steve stevedb' < steve-backup-<timestamp>.sql
```

Put the previous image line back, `docker compose up -d steve`, and Flyway
finds the schema it expects: ``Current version of schema `stevedb`: 1.1.4``,
`up to date`.

## Building locally

The build needs a **live MariaDB**: SteVe's jOOQ code generation and its Flyway
migrations read a real schema during `mvn package`. These are exactly the
commands CI runs, so a CI failure reproduces locally:

```bash
docker run -d --name steve-build-db \
  -p 3306:3306 \
  -e MARIADB_ROOT_PASSWORD=root \
  -e MARIADB_DATABASE=stevedb \
  -e MARIADB_USER=steve \
  -e MARIADB_PASSWORD=changeme \
  -e TZ=+00:00 \
  mariadb:11.8 --innodb-use-native-aio=0

docker buildx create --name steve-builder --driver docker-container --driver-opt network=host

docker buildx build \
  --builder steve-builder \
  --build-arg STEVE_REF=steve-3.14.1 \
  --build-arg DB_IP=127.0.0.1 \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --build-arg VCS_REF="$(git rev-parse HEAD)" \
  --load -t steve:local .

docker rm -f steve-build-db
docker buildx rm steve-builder
```

`BUILD_DATE` and `VCS_REF` stamp the `org.opencontainers.image.created` and
`.revision` labels; omit them and those two labels come out empty.

Then the runtime checks CI runs on the built image — an empty MariaDB is
migrated and SteVe becomes healthy, a second container on that database is a
Flyway no-op, and, given a previously published tag as second argument, the
schema that tag wrote is upgraded by the new image:

```bash
./hack/migration-test.sh steve:local
```

The build goes through a `docker-container` builder created on the host
network rather than through a plain `docker build --network=host`, because
that is how CI builds: each architecture is built natively on its own runner
and pushed *by digest*, which the daemon's default builder refuses, and the two
digests are then merged into the one `steve-X.Y.Z` tag. With the builder itself
on the host network, its `RUN` steps reach the database on `127.0.0.1` with no
`--network` flag at all. Using the same builder locally is what keeps the claim
above true — a CI failure reproduces here, builder included.

What `--load` puts in the daemon is the image for the machine's own
architecture and nothing else — arm64 on Apple Silicon, amd64 on a PC — so
`steve:local` is one of the two published platforms, not the index. It always
was the machine's architecture; what changed with the multi-arch tag is that
it now matches something CI ships. The commands are the same either way.

## Releasing

Publishing is the `release` branch moving to `main`. From the **Actions** tab,
run the **Release** workflow on `main` — nothing else to fill in. Or, equally,
from a terminal:

```bash
git push origin main:release
```

Either way the image builds on GitHub-hosted runners, one per architecture, and
is pushed to GHCR; the index digest — the one to pin — is printed at the end,
with the two platform digests beside it in the run's summary. The version
built is whatever `ARG STEVE_REF` says in the `Dockerfile` on that commit —
the single place the release is pinned in code, which is why the workflow asks
for no version.

The workflow adds one check the bare push cannot make: it refuses when the tag
is already published *and* the packaging has not changed since, because that
release would republish an identical image under a new digest and move the tag
for everyone pinning it. A Temurin bump, which legitimately republishes the same
tag, is not affected. Run it yourself with `./hack/release-preflight.sh`.

Merging to `main` does **not** publish. "The packaging changed" and "a release
should go out" are different events, and tying them together moved the release
tag whenever a comment did. What merging does is run the same workflow on the
pull request, everything but the push, so a change is proven to build before it
lands. And because shipping still moves a branch, what is waiting to go out
stays a plain git question:

```bash
git log release..main -- Dockerfile .dockerignore entrypoint.sh flyway-callbacks
```

A `Release drift` workflow covers what git cannot answer: whether a push to
`release` actually produced an image. It compares the
`org.opencontainers.image.revision` label of the published tag against the
packaging on `release`, and warns when they diverge — a build that failed after
the branch moved would otherwise leave the branch claiming a release that never
landed.

Separately, the three most recent published `steve-X.Y.Z` tags are re-scanned
weekly with [Trivy](https://trivy.dev), each of their platforms separately, and
the results land in the repository's *Security* tab, one category per tag and
architecture. Scanning on a schedule rather than at build time is deliberate:
an image is clean the day it is built, and what you need to know is whether
the tag you pinned has drifted since. An older tag is not monitored: its CVE
list only ever grows, and the answer for whoever pinned it is always to move
up, which the newest scan already says.

## Third-party licenses

The packaging files in this repository are **Apache-2.0** (see [LICENSE](LICENSE)).

The **image they produce is not**: it aggregates SteVe (**GPL-3.0-or-later**,
built from an unmodified upstream tag), the Flyway CLI Open Source Edition
(Apache-2.0), and an Eclipse Temurin JRE (GPL-2.0 with Classpath Exception).

See [NOTICE](NOTICE) for the full breakdown and for how the GPLv3 corresponding
source requirement is met.

---

<a href="https://juherr.dev"><img src=".github/assets/juherr-dev.png" alt="" width="18" height="18" align="middle"> <sub>A project by <b>juherr.dev</b> ↗</sub></a>

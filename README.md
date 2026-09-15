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

The image currently runs on **Eclipse Temurin 25 (JRE)** — a build detail, not
part of the tag. A JRE update republishes the same tag with a new digest.

**Pin by digest — and you should.** The digest is what Docker actually resolves,
so the tag alongside it is documentation: a moving tag cannot change what you
run, and it keeps version-tracking tools pointed at something still being
republished.

```bash
docker buildx imagetools inspect ghcr.io/juherr/steve:steve-3.14.1
```

```yaml
image: ghcr.io/juherr/steve:steve-3.14.1@sha256:<digest>
```

The exact JRE of an image you already hold is readable from it:

```bash
docker run --rm --entrypoint java ghcr.io/juherr/steve:steve-3.14.1 -version
```

## Usage

```bash
docker pull ghcr.io/juherr/steve:steve-3.14.1
```

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
docker compose exec -T steve-db mariadb-dump --single-transaction -u steve -p<your-db-password> stevedb > steve-backup-$(date +%F).sql
```

A dump rather than a copy of `./data/mariadb`: it restores into any MariaDB,
while a copied data directory only restores into the same one. This dump is
the **only way back** once the schema has moved — see *Downgrading*.

### 2. Keep the identity of the stack

The upgrade changes one line. Do not rename the directory, the services, the
database name or the volume: `name: steve` in the Compose file exists so that
the project is not silently re-created next to the old one, which is how
upstream users ended up with a second stack and lost track of the first. Do
not bump `mariadb` in the same change either — one moving part per upgrade.

### 3. Change the image line

Pick the new tag and its digest (see *Tags*), and edit the one line:

```diff
-    image: ghcr.io/juherr/steve:steve-X.Y.Z@sha256:<old digest>
+    image: ghcr.io/juherr/steve:steve-3.14.1@sha256:<digest>
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
docker compose exec -T steve-db mariadb -u steve -p<your-db-password> stevedb \
  -e "SELECT version, success FROM schema_version ORDER BY installed_rank DESC LIMIT 1"
```

### Downgrading

Migrations only go forward. The entrypoint does not stop you: on a schema
newer than the image's scripts, Flyway warns — ``Schema `stevedb` has a version
(1.1.6) that is newer than the latest available migration (1.1.4) !`` — and
hands over to SteVe anyway. Whether that older SteVe then works depends on what
the newer migrations did. Additive ones go unnoticed (`steve-3.14.1` →
`steve-3.13.0` boots and signs in, measured); a renamed or dropped column does
not, and nothing has tested the older release against the newer schema. **A
downgrade is not a supported path.** The supported way back is the backup from
step 1:

```bash
docker compose stop steve
docker compose exec -T steve-db mariadb -u steve -p<your-db-password> -e "DROP DATABASE stevedb; CREATE DATABASE stevedb"
docker compose exec -T steve-db mariadb -u steve -p<your-db-password> stevedb < steve-backup-<date>.sql
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

docker build \
  --network=host \
  --build-arg STEVE_REF=steve-3.14.1 \
  --build-arg DB_IP=127.0.0.1 \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --build-arg VCS_REF="$(git rev-parse HEAD)" \
  -t steve:local .

docker rm -f steve-build-db
```

`BUILD_DATE` and `VCS_REF` stamp the `org.opencontainers.image.created` and
`.revision` labels; omit them and those two labels come out empty.

`--network=host` is what lets the `RUN` steps reach the database on
`127.0.0.1`. BuildKit only accepts `host`, `none` or `default` for `--network`,
so a dedicated Docker network is not an option; the legacy builder that allowed
one has been deprecated since Docker Engine 23.

## Releasing

Publishing is the `release` branch moving to `main`. From the **Actions** tab,
run the **Release** workflow on `main` — nothing else to fill in. Or, equally,
from a terminal:

```bash
git push origin main:release
```

Either way the image builds on a GitHub-hosted runner and is pushed to GHCR,
with the resulting digest printed at the end, ready to pin. The version built is
whatever `ARG STEVE_REF` says in the `Dockerfile` on that commit — the single
place the release is pinned in code, which is why the workflow asks for no
version.

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

Separately, every published `steve-X.Y.Z` tag is re-scanned weekly with
[Trivy](https://trivy.dev) and the results land in the repository's *Security*
tab. Scanning on a schedule rather than at build time is deliberate: an image is
clean the day it is built, and what you need to know is whether the tag you
pinned has drifted since.

## Third-party licenses

The packaging files in this repository are **Apache-2.0** (see [LICENSE](LICENSE)).

The **image they produce is not**: it aggregates SteVe (**GPL-3.0-or-later**,
built from an unmodified upstream tag), the Flyway CLI Open Source Edition
(Apache-2.0), and an Eclipse Temurin JRE (GPL-2.0 with Classpath Exception).

See [NOTICE](NOTICE) for the full breakdown and for how the GPLv3 corresponding
source requirement is met.

---

<a href="https://juherr.dev"><img src=".github/assets/juherr-dev.png" alt="" width="18" height="18" align="middle"> <sub>A project by <b>juherr.dev</b> ↗</sub></a>

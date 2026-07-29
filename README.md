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
docker buildx imagetools inspect ghcr.io/juherr/steve:steve-3.13.0
```

```yaml
image: ghcr.io/juherr/steve:steve-3.13.0@sha256:<digest>
```

The exact JRE of an image you already hold is readable from it:

```bash
docker run --rm --entrypoint java ghcr.io/juherr/steve:steve-3.13.0 -version
```

## Usage

```bash
docker pull ghcr.io/juherr/steve:steve-3.13.0
```

Minimal Compose setup:

```yaml
services:
  steve:
    image: ghcr.io/juherr/steve:steve-3.13.0
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
| `AUTO_REGISTER_UNKNOWN_STATIONS` | accept unknown charge points | `false` |

See upstream's `application.properties` for the full list.

> The image runs as UID/GID `10001`, not root.

### Security note

The OCPP endpoint and the management UI share port `8180`. Charge points connect
over WebSocket without an interactive login, so they cannot pass an
authentication proxy. If you expose the UI publicly behind a reverse proxy,
route only the UI hostname and keep the OCPP endpoint off the public interface —
for example by publishing it on a VPN address only.

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
  --build-arg STEVE_REF=steve-3.13.0 \
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

Publishing is a deliberate act. The `Build SteVe image` workflow is run by hand
(`workflow_dispatch`), takes a `steve_ref` input such as `steve-3.13.0`, builds
on a GitHub-hosted runner and pushes to GHCR, printing the resulting digest at
the end, ready to pin.

Merging to `main` does **not** publish. "The packaging changed" and "a release
should go out" are different events, and tying them together moved the release
tag whenever a comment did. What merging does is run the same workflow on the
pull request, everything but the push, so a change is proven to build before it
lands.

The trade is that a merged change can sit unreleased. A `Release drift` workflow
covers that: on every push to `main`, and again weekly, it compares the
`org.opencontainers.image.revision` label of the published tag against the
packaging files on `main`, and warns when they have parted company.

Separately, every published `steve-X.Y.Z` tag is re-scanned weekly with
[Trivy](https://trivy.dev) and the results land in the repository's *Security*
tab. Scanning on a schedule rather than at build time is deliberate: an image is
clean the day it is built, and what you need to know is whether the tag you
pinned has drifted since.

## Third-party licenses

The packaging files in this repository are **Apache-2.0** (see [LICENSE](LICENSE)).

The **image they produce is not**: it aggregates SteVe (**GPL-3.0-or-later**,
built from an unmodified upstream tag), the Flyway CLI Open Source Edition
(Apache-2.0), and Eclipse Temurin JREs (GPL-2.0 with Classpath Exception).

See [NOTICE](NOTICE) for the full breakdown and for how the GPLv3 corresponding
source requirement is met.

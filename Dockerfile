# Ready-to-run Docker image for SteVe (OCPP CSMS).
#
# Why this image exists: upstream publishes NO official image, and its own
# Dockerfile recompiles the application when the *container starts* (`mvnw` in
# the CMD), which requires Maven and a live database on every (re)start. Here
# the `.war` is compiled at *build* time, so startup is fast.
#
# No secrets in the image: SteVe >= 3.x is a Spring Boot application whose
# application.yml resolves ${db.password}, ${auth.password}, ${db.ip}… from the
# environment. Container environment variables (DB_PASSWORD, AUTH_PASSWORD,
# DB_IP…) take precedence over the defaults baked into
# application-docker.properties (changeme/admin/1234, which are upstream public
# placeholders — not secrets). Inject the real configuration at runtime.
#
# Build quirk: Flyway (migrations) and jOOQ (code generation) read the schema of
# a LIVE database during `mvn package`. The build therefore needs a throwaway
# MariaDB, reachable from the RUN steps — see README and
# .github/workflows/build-image.yml. Because that build database is thrown away,
# the runtime database starts empty: the entrypoint replays the Flyway
# migrations against it on startup (Flyway CLI + bundled scripts).

# --- Build stage: compile the .war from a pinned upstream release tag ---------
# renovate: datasource=github-releases depName=steve-community/steve
ARG STEVE_REF=steve-3.14.1

FROM eclipse-temurin:25.0.4_7-jdk AS build

ARG STEVE_REF
# Host of the throwaway database used by the jOOQ/Flyway code generation during
# the build. Overridden by the workflow; `mariadb` is the default value found in
# application-docker.properties.
ARG DB_IP=mariadb

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# DL3008: git is not version-pinned on purpose. Debian drops superseded point
# releases from its archive, so a pinned `git=1:2.47.2-0.1` turns the build red
# the day the mirror rotates — for a package that only clones upstream in this
# throwaway stage and never reaches the runtime image.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /code
RUN git clone --depth 1 --branch "${STEVE_REF}" https://github.com/steve-community/steve.git .

# -Pdocker  : envName=docker → the .war embeds application-docker.properties as
#             its default profile (console logback, etc.).
# -Pmariadb : databaseName=mariadb → jdbc:mariadb://... datasource.
# -Ddb.ip   : points Flyway/jOOQ at the throwaway build database (port/schema/
#             user/password keep the docker defaults: 3306 / stevedb / steve /
#             changeme).
# -DskipTests : we only want the .war; code generation runs in generate-sources.
#
# DL3059: kept as its own layer, separate from the clone above, so that
# iterating on the build does not re-clone SteVe. Nothing of this stage reaches
# the runtime image, so the extra layer costs nothing shipped.
# hadolint ignore=DL3059
RUN ./mvnw -B -V -DskipTests -Dmaven.javadoc.skip=true \
    -Pdocker,mariadb -Ddb.ip="${DB_IP}" \
    clean package

# --- Source of the Flyway CLI (migrates the runtime database on startup) ------
# Official glibc image (not -alpine): the CLI ships no JRE of its own and runs
# on the runtime stage's Temurin, which is glibc-based. Pinned tag.
FROM flyway/flyway:13.6.0 AS flyway

# Keep only the MariaDB path. The CLI ships ~20 JDBC drivers and their Flyway
# plugins; the entrypoint only ever opens jdbc:mariadb://, and the unused
# drivers carry CVEs this repository cannot fix (the Couchbase driver shades its
# own netty, still a vulnerable one in 13.6.0). Drivers and plugins go together:
# the plugin registry loads every flyway-database-* jar at startup and each
# needs its driver — measured, pruning drivers/ alone dies with
# ClassNotFoundException. MariaDB support lives in flyway-mysql, which stays.
# `flyway version` needs no database yet still runs that registry, so it fails
# the build if a Flyway bump ships a plugin whose driver is removed here.
# Done in this throwaway stage so nothing deleted lingers in a runtime layer.
RUN find /flyway/drivers -mindepth 1 ! -name 'mariadb-java-client-*.jar' -delete \
    && find /flyway/lib/flyway \( -name 'flyway-database-*.jar' -o -name 'flyway-gcp-*.jar' \
         -o -name 'flyway-sqlserver-*.jar' -o -name 'flyway-singlestore-*.jar' \
         -o -name 'flyway-firebird-*.jar' -o -name 'flyway-locations-s3-*.jar' \) -delete \
    && rm -rf /flyway/lib/netty /flyway/lib/aad \
    && /flyway/flyway version

# --- Runtime stage: JRE + Flyway CLI + migration scripts + the .war -----------
FROM eclipse-temurin:25.0.4_7-jre

ARG STEVE_REF
# Build metadata. Without these, the image would silently inherit the base
# image's own created/revision labels, which describe Temurin, not this build.
ARG BUILD_DATE=""
ARG VCS_REF=""

LABEL org.opencontainers.image.source="https://github.com/juherr/steve-ocpp-csms-image"
LABEL org.opencontainers.image.url="https://github.com/juherr/steve-ocpp-csms-image"
LABEL org.opencontainers.image.documentation="https://github.com/juherr/steve-ocpp-csms-image#readme"
LABEL org.opencontainers.image.version="${STEVE_REF}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.revision="${VCS_REF}"
LABEL org.opencontainers.image.licenses="GPL-3.0-or-later"
LABEL org.opencontainers.image.title="SteVe (OCPP CSMS)"
LABEL org.opencontainers.image.description="SteVe OCPP Central System, compiled at build time from an unmodified upstream release tag."

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# DL3008: curl is not version-pinned, same reason as the build stage — and here
# it backs the documented Compose healthcheck, nothing else. A package added to
# this line later should re-earn the exemption rather than inherit it.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && groupadd --system --gid 10001 steve \
    && useradd --system --uid 10001 --gid steve --home-dir /nonexistent --shell /usr/sbin/nologin steve \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
# Flyway CLI (pruned above to the MariaDB driver) + SteVe's migration scripts
# taken from the very clone that produced the .war — binary and schema
# therefore cannot drift apart.
COPY --from=flyway /flyway /flyway
COPY --from=build /code/src/main/resources/db/migration /flyway/sql
# Flyway callbacks (afterConnect.sql) — replaces `-initSql`, removed in Flyway 13.
COPY flyway-callbacks /flyway/callbacks
COPY --from=build /code/target/steve.war /app/steve.war
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Flyway and SteVe only need network and read access to the packaged files.
USER 10001:10001

# Application HTTP port (management UI + OCPP endpoints). Internal HTTPS is left
# disabled: terminate TLS at your reverse proxy.
EXPOSE 8180

# The entrypoint migrates the database (Flyway) and then starts the .war.
ENTRYPOINT ["/entrypoint.sh"]

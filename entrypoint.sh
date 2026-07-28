#!/bin/sh
# SteVe entrypoint — migrate the runtime database, then start the application.
#
# Why migrate here: SteVe applies its Flyway migrations during the Maven build
# (flyway-maven-plugin), against the code-generation database — which is
# THROWAWAY in this pipeline. The runtime database is therefore empty on first
# start. We replay the migrations against it here, using SteVe's exact
# configuration (table=schema_version, outOfOrder, InnoDB via the afterConnect
# callback — see upstream pom.xml; `-initSql` was removed in Flyway 13).
# Idempotent: on subsequent restarts Flyway is a no-op (schema_version current).
set -e

: "${DB_IP:=steve-db}"
: "${DB_PORT:=3306}"
: "${DB_SCHEMA:=stevedb}"
: "${DB_USER:=steve}"

echo "[entrypoint] Flyway migrate -> ${DB_IP}:${DB_PORT}/${DB_SCHEMA}"
/flyway/flyway \
  -url="jdbc:mariadb://${DB_IP}:${DB_PORT}/${DB_SCHEMA}?useSSL=false&allowPublicKeyRetrieval=true" \
  -user="${DB_USER}" \
  -password="${DB_PASSWORD}" \
  -schemas="${DB_SCHEMA}" \
  -table=schema_version \
  -outOfOrder=true \
  -locations=filesystem:/flyway/sql,filesystem:/flyway/callbacks \
  -cleanDisabled=true \
  -connectRetries=30 \
  -connectRetriesInterval=2 \
  migrate

echo "[entrypoint] Starting SteVe…"
exec java -XX:MaxRAMPercentage=85 -Djava.net.preferIPv4Stack=true -jar /app/steve.war

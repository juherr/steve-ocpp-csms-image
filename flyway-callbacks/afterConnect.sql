-- Flyway "afterConnect" callback: runs on every connection, right after Flyway
-- connects to the database. Replaces the old `-initSql` CLI flag (removed in
-- Flyway 13). Forces InnoDB as the session default storage engine for the
-- CREATE TABLE statements of SteVe's migrations (upstream's original setting,
-- see its pom.xml).
SET default_storage_engine=InnoDB;

#!/bin/sh
# Invoked by the official Postgres entrypoint only for an empty PGDATA.
set -eu
migrator_password=$(cat /run/secrets/migrator_password)
runtime_password=$(cat /run/secrets/runtime_password)
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set=ON_ERROR_STOP=1 \
  --set=migrator_password="$migrator_password" --set=runtime_password="$runtime_password" <<'SQL'
SELECT format('CREATE ROLE omega_migrator LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD %L', :'migrator_password') \gexec
SELECT format('CREATE ROLE omega_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD %L', :'runtime_password') \gexec
REVOKE ALL ON DATABASE omega FROM PUBLIC;
GRANT CONNECT ON DATABASE omega TO omega_migrator, omega_runtime;
GRANT CREATE ON DATABASE omega TO omega_migrator;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL
unset migrator_password runtime_password

#!/usr/bin/env bash
# Runs solely inside the dedicated network-none acceptance daemon container.
set -Eeuo pipefail
umask 077
ARCHIVE_SHA=$1; VERSION=$2; MANIFEST_SHA=$3; OLD_SHA=$4; OLD_VERSION=$5; OLD_MANIFEST=$6
mkdir -p /evidence /instances
snapshot() {
  local code=$? input
  trap - EXIT
  docker ps -a > /evidence/containers-final.txt
  docker image ls --no-trunc > /evidence/images-final.txt
  docker events --since "$START" --until "$(date -u +%FT%TZ)" > /evidence/docker-events.txt 2>&1 || true
  for input in /instances/*; do
    [ ! -d "$input/.release" ] || cp -a "$input/.release" "/evidence/$(basename "$input")-operations"
  done
  printf 'exit=%s\nversion=%s\nmanifest=%s\n' "$code" "$VERSION" "$MANIFEST_SHA" > /evidence/result.txt
  exit "$code"
}
START=$(date -u +%FT%TZ)
trap snapshot EXIT
source /operator/scripts/release-common.sh
expect_failure() { local result=0; "$@" || result=$?; [ "$result" -ne 0 ] || fail 'negative case unexpectedly succeeded'; echo "Expected refusal exit=$result"; }
docker info --format '{{.OSType}}/{{.Architecture}}' > /evidence/target-platform.txt
uname -sm >> /evidence/target-platform.txt
! command -v python; ! command -v jq
[ -z "$(docker image ls -q)" ] && [ -z "$(docker ps -aq)" ] && [ -z "$(docker volume ls -q)" ]
echo 'Empty isolated target image/container/volume store confirmed'
expect_failure curl --noproxy '*' --max-time 5 https://1.1.1.1
expect_failure curl --noproxy '*' --max-time 5 https://registry-1.docker.io/v2/
expect_failure timeout 10 docker pull alpine:3.22.1
bash /operator/scripts/import-release.sh /candidate.tar "$ARCHIVE_SHA" /releases/candidate
if [ -n "$OLD_SHA" ]; then bash /operator/scripts/import-release.sh /old.tar "$OLD_SHA" /releases/old; fi
TOOLS=$(docker image inspect --platform linux/amd64 --format '{{.Id}}' "omega-release/tools:$VERSION")
DB_IMAGE=$(docker image inspect --platform linux/amd64 --format '{{.Id}}' "omega-release/db:$VERSION")
op() { /releases/candidate/materials/scripts/release.sh "$1" --env "$2" --input "/instances/$3" --version "$VERSION" --manifest-sha256 "$MANIFEST_SHA"; }
prepare() {
  local name=$1 environment=$2 http=$3 https=$4 input="/instances/$1" file role
  mkdir -p "$input/secrets" "$input/tls"
  cp -p /releases/candidate/templates/* "$input/"
  for file in "$input"/*; do
    [ -f "$file" ] || continue
    sed -i -e "s/replace-instance/offline-$name/g" -e "s/replace-release-version/$VERSION/g" -e "s/omega.example.invalid/omega.$name/g" "$file"
  done
  sed -i -e "s/ENVIRONMENT=test/ENVIRONMENT=$environment/" -e "s/HTTP_PORT=80/HTTP_PORT=$http/" -e "s/HTTPS_PORT=443/HTTPS_PORT=$https/" "$input/instance.env"
  sed -i "s/environment: test/environment: $environment/" "$input"/*.yaml
  sed -i "s/\"environment\": \"test\"/\"environment\": \"$environment\"/" "$input"/*.json
  for role in admin migrator runtime; do openssl rand -hex 32 > "$input/secrets/$role"; done
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3 -nodes -keyout "$input/tls/key.pem" -out "$input/tls/cert.pem" -subj "/CN=omega.$name" -addext "subjectAltName=DNS:omega.$name" >/dev/null 2>&1
  chmod 600 "$input"/secrets/* "$input/tls/key.pem"
  chmod 644 "$input"/*.yaml "$input"/*.json "$input/tls/cert.pem"
}
prepare test test 18080 18443
prepare prod prod 28080 28443
op deploy test test
op deploy prod prod
for service in db api web console edge; do
  test_id=$(docker inspect --format '{{.Image}}' "omega-offline-test-$service-1")
  prod_id=$(docker inspect --format '{{.Image}}' "omega-offline-prod-$service-1")
  [ "$test_id" = "$prod_id" ] || fail "promotion rebuilt $service"
  printf '%s\t%s\n' "$service" "$test_id" >> /evidence/promotion-images.tsv
done
op deploy test test
op status test test
echo 'Same-image promotion, repeat and status passed'
API=$(docker ps -q --filter label=com.docker.compose.project=omega-offline-test --filter label=com.docker.compose.service=api)
docker run --rm --pull never --network "container:$API" "$TOOLS" python -c '
import urllib.request
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
for url in ["https://1.1.1.1", "https://example.com", "http://127.0.0.1:8080/api/v1/ping"]:
 try:
  response=opener.open(url,timeout=3); print(url,response.status)
  assert url.startswith("http://127.0.0.1"),"unexpected outbound network"
 except (OSError,urllib.error.URLError) as error:
  print(url,type(error).__name__)
  assert not url.startswith("http://127.0.0.1"),"internal API probe failed"
'
echo 'Application namespace direct-IP and hostname/TLS egress refused; internal API succeeds'
cp /candidate.tar /bad.tar
printf '\001' | dd of=/bad.tar bs=1 seek=100 conv=notrunc status=none
expect_failure bash /operator/scripts/import-release.sh /bad.tar "$ARCHIVE_SHA" /releases/rejected
[ ! -e /releases/rejected ]
cp -al /releases/candidate /releases/tampered
cp /releases/tampered/OPERATIONS.md /tmp/tampered-document
echo tampered >> /tmp/tampered-document
mv /tmp/tampered-document /releases/tampered/OPERATIONS.md
expect_failure /releases/tampered/materials/scripts/release.sh deploy --env test --input /instances/test --version "$VERSION" --manifest-sha256 "$MANIFEST_SHA"
cp /releases/tampered/manifest.tsv /tmp/tampered-manifest
echo replaced >> /tmp/tampered-manifest
mv /tmp/tampered-manifest /releases/tampered/manifest.tsv
expect_failure /releases/tampered/materials/scripts/release.sh deploy --env test --input /instances/test --version "$VERSION" --manifest-sha256 "$MANIFEST_SHA"
docker tag "$TOOLS" omega-acceptance/retained-tools:once
docker image rm "omega-release/tools:$VERSION"
expect_failure op deploy test test
docker tag "$DB_IMAGE" "omega-release/tools:$VERSION"
expect_failure op deploy test test
docker tag omega-acceptance/retained-tools:once "omega-release/tools:$VERSION"
docker image rm omega-acceptance/retained-tools:once
[ ! -f /instances/test/edge/maintenance ]
mkdir /instances/wrong
cp /instances/test/instance.env /instances/wrong/instance.env
expect_failure op down test wrong
[ "$(docker inspect --format '{{.State.Running}}' omega-offline-test-api-1)" = true ]
echo 'Trusted archive/manifest/file, missing image, wrong image ID and input ownership refusals passed before maintenance'

# Actual permission failure after a valid migration must retain maintenance/data.
docker exec omega-offline-test-db-1 psql -U postgres -d omega -v ON_ERROR_STOP=1 -c 'REVOKE SELECT ON omega.installation FROM omega_runtime;'
expect_failure op deploy test test
[ -f /instances/test/edge/maintenance ]
docker volume inspect omega-offline-test_db_data >/dev/null
[ "$(curl --noproxy '*' --cacert /instances/test/tls/cert.pem --resolve omega.test:18443:127.0.0.1 --max-time 8 -s -o /dev/null -w '%{http_code}' https://omega.test:18443/api/v1/ping)" = 503 ]
docker exec omega-offline-test-db-1 psql -U postgres -d omega -v ON_ERROR_STOP=1 -c 'GRANT SELECT ON omega.installation TO omega_runtime;'
op deploy test test
[ ! -f /instances/test/edge/maintenance ]
echo 'Real readiness failure retains maintenance/data; explicit repaired retry passed'

# Hold a real database table lock so one operation stays inside db-status;
# prove wrapper exclusion, signal cleanup of its actual one-off, then retry.
docker exec -e PGAPPNAME=omega_acceptance_lock omega-offline-test-db-1 psql -U postgres -d omega -v ON_ERROR_STOP=1 -c 'BEGIN; LOCK TABLE omega.installation IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(120); COMMIT;' >/evidence/held-lock.log 2>&1 & lock_client=$!
for attempt in $(seq 1 30); do
  if [ "$(docker exec omega-offline-test-db-1 psql -U postgres -d omega -Atc "SELECT count(*) FROM pg_stat_activity WHERE application_name='omega_acceptance_lock' AND wait_event='PgSleep'")" = 1 ]; then break; fi
  [ "$attempt" -lt 30 ] || fail 'database fixture lock deadline'
  sleep 1
done
/releases/candidate/materials/scripts/release.sh deploy --env test --input /instances/test --version "$VERSION" --manifest-sha256 "$MANIFEST_SHA" >/evidence/canceled-operation.log 2>&1 & operation=$!
for attempt in $(seq 1 60); do
  if [ -d /instances/test/.lock ] && docker ps --format '{{.Names}}' | grep -q "omega-offline-test-release-task-$operation"; then break; fi
  [ "$attempt" -lt 60 ] || fail 'release one-off startup deadline'
  sleep 1
done
conflict=0; op deploy test test || conflict=$?
[ "$conflict" = 6 ] || fail 'concurrent instance command must exit6'
kill -TERM "$operation"
canceled=0; wait "$operation" || canceled=$?
[ "$canceled" = 130 ] && [ ! -d /instances/test/.lock ]
[ -z "$(docker ps -q --filter "name=omega-offline-test-release-task-$operation")" ]
docker exec omega-offline-test-db-1 psql -U postgres -d omega -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='omega_acceptance_lock';"
wait "$lock_client" || true
op deploy test test >/evidence/parallel-test.log 2>&1 & test_operation=$!
op deploy prod prod >/evidence/parallel-prod.log 2>&1 & prod_operation=$!
wait "$test_operation"; wait "$prod_operation"
echo 'Actual held operation rejects concurrent same-instance command, cancels130 without orphan, and independent test/prod retries run concurrently'

# Replace TLS inputs atomically. Failed later preflight must not corrupt the
# key/certificate pair still bind-mounted by the running old edge.
fingerprint() { openssl s_client -connect 127.0.0.1:18443 -servername omega.test </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256; }
old_fingerprint=$(fingerprint)
openssl req -x509 -newkey rsa:2048 -sha256 -days 3 -nodes -keyout /instances/test/tls/key.new -out /instances/test/tls/cert.new -subj /CN=omega.test -addext subjectAltName=DNS:omega.test >/dev/null 2>&1
chmod 600 /instances/test/tls/key.new; chmod 644 /instances/test/tls/cert.new
mv /instances/test/tls/key.new /instances/test/tls/key.pem
mv /instances/test/tls/cert.new /instances/test/tls/cert.pem
sed -i "s/$VERSION/wrong-version/g" /instances/test/web.json
expect_failure op tls-reload test test
docker exec omega-offline-test-edge-1 nginx -t
[ "$(fingerprint)" = "$old_fingerprint" ]
sed -i "s/wrong-version/$VERSION/g" /instances/test/web.json
op tls-reload test test
[ "$(fingerprint)" != "$old_fingerprint" ]
echo 'Atomic TLS input renewal: failed preflight keeps old pair, explicit recreation serves new pair'

if [ -n "$OLD_VERSION" ]; then
  sed -i "s/$VERSION/$OLD_VERSION/g" /instances/test/*.json
  /releases/old/materials/scripts/release.sh rollback --env test --input /instances/test --version "$OLD_VERSION" --manifest-sha256 "$OLD_MANIFEST"
  sed -i "s/$OLD_VERSION/$VERSION/g" /instances/test/*.json
  op deploy test test
  # Disposable real newer-schema fixture, not a changed manifest declaration.
  docker exec omega-offline-test-db-1 psql -U postgres -d omega -v ON_ERROR_STOP=1 -c "CREATE TABLE omega.future_fixture(id integer); INSERT INTO omega.schema_migrations(version,checksum) VALUES(2,repeat('0',64));"
  sed -i "s/$VERSION/$OLD_VERSION/g" /instances/test/*.json
  expect_failure /releases/old/materials/scripts/release.sh rollback --env test --input /instances/test --version "$OLD_VERSION" --manifest-sha256 "$OLD_MANIFEST"
  [ ! -f /instances/test/edge/maintenance ]
  docker exec omega-offline-test-db-1 psql -U postgres -d omega -v ON_ERROR_STOP=1 -c 'DELETE FROM omega.schema_migrations WHERE version=2; DROP TABLE omega.future_fixture;'
  sed -i "s/$OLD_VERSION/$VERSION/g" /instances/test/*.json
  op deploy test test
  echo 'Old actual binary compatible rollback passed; unknown newer physical schema refused before switching'
fi

# Seed only the technical database, with an acceptance-only DDL event trigger
# which forces the actual published installation migration to fail in transaction.
prepare migration test 38080 38443
docker run --rm --pull never --network none --mount type=bind,src=/instances/migration,dst=/inputs "$TOOLS" python /tools/inputs.py render /inputs /inputs/edge test
docker volume create --label org.omega.instance=offline-migration --label org.omega.environment=test --label org.omega.input=/instances/migration --label com.docker.compose.project=omega-offline-migration --label com.docker.compose.volume=db_data omega-offline-migration_db_data
docker run -d --rm --pull never --name migration-fixture --network none -e POSTGRES_DB=omega -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD_FILE=/run/secrets/admin_password -e POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --mount type=volume,src=omega-offline-migration_db_data,dst=/var/lib/postgresql/data --mount type=bind,src=/instances/migration/.runtime-secrets/db-admin,dst=/run/secrets/admin_password,readonly --mount type=bind,src=/instances/migration/.runtime-secrets/db-migrator,dst=/run/secrets/migrator_password,readonly --mount type=bind,src=/instances/migration/.runtime-secrets/db-runtime,dst=/run/secrets/runtime_password,readonly --mount type=bind,src=/releases/candidate/materials/infra/db/10-omega.sh,dst=/docker-entrypoint-initdb.d/10-omega.sh,readonly "$DB_IMAGE"
for attempt in $(seq 1 90); do
  if docker logs migration-fixture 2>&1 | grep -q 'PostgreSQL init process complete'; then break; fi
  [ "$attempt" -lt 90 ] || fail 'fixture technical initialization deadline'
  sleep 1
done
docker exec -i migration-fixture psql -U postgres -d omega -v ON_ERROR_STOP=1 <<'SQL'
CREATE FUNCTION public.reject_installation() RETURNS event_trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_event_trigger_ddl_commands() WHERE object_identity='omega.installation') THEN
    RAISE EXCEPTION 'acceptance injected installation DDL failure';
  END IF;
END $$;
CREATE EVENT TRIGGER acceptance_reject_installation ON ddl_command_end WHEN TAG IN ('CREATE TABLE') EXECUTE FUNCTION public.reject_installation();
SQL
docker stop --time 20 migration-fixture
expect_failure op deploy test migration
[ -f /instances/migration/edge/maintenance ]
docker exec omega-offline-migration-db-1 psql -U postgres -d omega -v ON_ERROR_STOP=1 -c "SELECT version,result FROM omega.migration_attempts; SELECT to_regclass('omega.installation'); SELECT count(*) FROM omega.schema_migrations;" > /evidence/migration-failure-state.txt
[ "$(docker exec omega-offline-migration-db-1 psql -U postgres -d omega -Atc "SELECT count(*) FROM omega.migration_attempts WHERE result NOT IN ('running','success') AND finished_at IS NOT NULL")" -ge 1 ]
[ "$(docker exec omega-offline-migration-db-1 psql -U postgres -d omega -Atc 'SELECT count(*) FROM omega.schema_migrations')" = 0 ]
docker exec omega-offline-migration-db-1 psql -U postgres -d omega -v ON_ERROR_STOP=1 -c 'DROP EVENT TRIGGER acceptance_reject_installation; DROP FUNCTION public.reject_installation();'
op deploy test migration
echo 'Actual migration SQL failure rolled back transaction, persisted failed attempt and maintenance; repaired retry passed'

for name in test prod migration; do
  cp -a "/instances/$name/.release" "/evidence/$name-operations-scan"
done
docker run --rm --pull never --network none --mount type=bind,src=/releases/candidate,dst=/bundle,readonly --mount type=bind,src=/instances,dst=/instances,readonly --mount type=bind,src=/evidence,dst=/evidence,readonly --mount type=bind,src=/operator/scan_secrets.py,dst=/scan.py,readonly "$TOOLS" python /scan.py /bundle /instances /evidence
expect_failure curl --noproxy '*' --max-time 5 https://1.1.1.1
echo 'OFFLINE ACCEPTANCE PASSED (native platform status recorded separately)'

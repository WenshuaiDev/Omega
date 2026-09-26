// Package database owns the application's schema, identity and forward-only migrations.
package database

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/WenshuaiDev/Omega/services/api/internal/config"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const LockID int64 = 718293410
const SchemaVersion = 1
const migration = `CREATE TABLE omega.installation (singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton), instance_id text NOT NULL, environment text NOT NULL CHECK (environment IN ('dev','test','prod')), installed_at timestamptz NOT NULL DEFAULT now());
GRANT SELECT ON omega.installation TO omega_runtime;
REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON omega.installation FROM omega_runtime;`

var checksum = func() string { h := sha256.Sum256([]byte(migration)); return hex.EncodeToString(h[:]) }()

type Failure struct {
	Code    int
	Message string
}

func (e *Failure) Error() string { return e.Message }
func Reject(s string) error      { return &Failure{3, s} }
func Classify(err error) (int, string) {
	if err == nil {
		return 0, "ok"
	}
	var f *Failure
	if errors.As(err, &f) {
		return f.Code, f.Message
	}
	if errors.Is(err, context.Canceled) {
		return 130, "operation canceled"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return 5, "operation timed out"
	}
	var p *pgconn.PgError
	if errors.As(err, &p) {
		if p.Code == "57014" {
			return 5, "database operation timed out"
		}
		return 4, "database operation failed (SQLSTATE " + p.Code + ")"
	}
	return 4, "dependency or operation failed"
}
func Connect(ctx context.Context, c config.Config) (*pgx.Conn, error) {
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		if strings.HasPrefix(key, "PG") {
			return nil, Reject("inherited PG variables are forbidden; use explicit application configuration")
		}
	}
	password, err := c.Password()
	if err != nil {
		return nil, err
	}
	u := url.URL{Scheme: "postgres", Host: net.JoinHostPort(c.Database.Host, strconv.Itoa(c.Database.Port)), Path: "/" + c.Database.Name, User: url.UserPassword(c.Database.User, password)}
	q := u.Query()
	q.Set("sslmode", c.Database.SSLMode)
	q.Set("connect_timeout", strconv.Itoa(max(1, int(config.Duration(c.Database.ConnectTimeout).Seconds()))))
	q.Set("application_name", "omega")
	u.RawQuery = q.Encode()
	cfg, err := pgx.ParseConfig(u.String())
	if err != nil {
		return nil, errors.New("invalid database connection configuration")
	}
	cfg.ConnectTimeout = config.Duration(c.Database.ConnectTimeout)
	cfg.RuntimeParams = map[string]string{"application_name": "omega", "statement_timeout": strconv.FormatInt(config.Duration(c.OperationTimeout).Milliseconds(), 10), "search_path": "pg_catalog"}
	cfg.OnNotice = nil
	return pgx.ConnectConfig(ctx, cfg)
}
func Close(c *pgx.Conn) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = c.Close(ctx)
}

type Status struct {
	State         string `json:"state"`
	Schema        int    `json:"schema"`
	Instance      string `json:"instance_id,omitempty"`
	Environment   string `json:"environment,omitempty"`
	Compatible    bool   `json:"compatible"`
	LastMigration string `json:"last_migration,omitempty"`
}

func Inspect(ctx context.Context, db *pgx.Conn, c config.Config, requireIdentity bool) (Status, error) {
	s := Status{State: "empty"}
	var exists bool
	if err := db.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname='omega')`).Scan(&exists); err != nil {
		return s, err
	}
	if !exists {
		var existingObjects int
		if err := db.QueryRow(ctx, `SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname<>'information_schema' AND c.relkind IN ('r','p','S','v','m','f')`).Scan(&existingObjects); err != nil {
			return s, err
		}
		if existingObjects != 0 {
			return s, Reject("unrecognized nonempty database; explicit initialization refused")
		}
		if requireIdentity {
			return s, Reject("database is empty; run db migrate and data ensure explicitly")
		}
		return s, nil
	}
	s.State = "partial"
	var tables int
	if err := db.QueryRow(ctx, `SELECT count(*) FROM pg_class r JOIN pg_namespace n ON r.relnamespace=n.oid WHERE n.nspname='omega' AND r.relkind='r' AND r.relname IN ('schema_migrations','migration_attempts')`).Scan(&tables); err != nil {
		return s, err
	}
	if tables != 2 {
		return s, Reject("database metadata is partially initialized")
	}
	if err := db.QueryRow(ctx, `SELECT result FROM omega.migration_attempts ORDER BY id DESC LIMIT 1`).Scan(&s.LastMigration); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return s, err
	}
	rows, err := db.Query(ctx, `SELECT version,checksum FROM omega.schema_migrations ORDER BY version`)
	if err != nil {
		return s, err
	}
	for rows.Next() {
		var v int
		var sum string
		if err = rows.Scan(&v, &sum); err != nil {
			break
		}
		if v != 1 || sum != checksum || s.Schema != 0 {
			err = Reject("unknown schema version or migration checksum mismatch")
			break
		}
		s.Schema = v
	}
	rows.Close()
	if err != nil {
		return s, err
	}
	if rows.Err() != nil {
		return s, rows.Err()
	}
	if s.Schema == 0 {
		var installationExists bool
		if err := db.QueryRow(ctx, `SELECT to_regclass('omega.installation') IS NOT NULL`).Scan(&installationExists); err != nil {
			return s, err
		}
		if installationExists {
			return s, Reject("installation exists without a valid schema record; partial metadata requires diagnosis")
		}
		if requireIdentity {
			return s, Reject("schema migration incomplete")
		}
		s.State = "unmigrated"
		return s, nil
	}
	var count int
	if err = db.QueryRow(ctx, `SELECT count(*) FROM omega.installation`).Scan(&count); err != nil {
		return s, err
	}
	s.Compatible = true
	if count == 0 {
		s.State = "unbound"
		if requireIdentity {
			return s, Reject("installation identity absent; run data ensure explicitly")
		}
		return s, nil
	}
	if count != 1 {
		return s, Reject("installation identity metadata invalid")
	}
	if err = db.QueryRow(ctx, `SELECT instance_id,environment FROM omega.installation WHERE singleton=true`).Scan(&s.Instance, &s.Environment); err != nil {
		return s, Reject("installation identity metadata invalid")
	}
	if s.Instance != c.InstanceID || s.Environment != c.Environment {
		return s, Reject("database instance/environment does not match explicit configuration")
	}
	s.State = "ready"
	return s, nil
}
func lock(ctx context.Context, db *pgx.Conn) (func(), error) {
	var ok bool
	err := db.QueryRow(ctx, `SELECT pg_try_advisory_lock($1)`, LockID).Scan(&ok)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, &Failure{6, "another application maintenance operation holds the database lock"}
	}
	return func() {
		c, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_, _ = db.Exec(c, `SELECT pg_advisory_unlock($1)`, LockID)
	}, nil
}
func migrationRole(ctx context.Context, db *pgx.Conn) error {
	var role string
	var super bool
	if err := db.QueryRow(ctx, `SELECT current_user,rolsuper FROM pg_roles WHERE rolname=current_user`).Scan(&role, &super); err != nil {
		return err
	}
	if role != "omega_migrator" || super {
		return Reject("write maintenance requires the non-superuser omega_migrator role")
	}
	return nil
}
func RuntimeRole(ctx context.Context, db *pgx.Conn) error {
	var role string
	var unsafe bool
	err := db.QueryRow(ctx, `SELECT current_user, rolsuper OR rolcreatedb OR rolcreaterole OR has_database_privilege(current_user,current_database(),'CREATE') OR has_schema_privilege(current_user,'omega','CREATE') OR has_table_privilege(current_user,'omega.installation','INSERT,UPDATE,DELETE,TRUNCATE') FROM pg_roles WHERE rolname=current_user`).Scan(&role, &unsafe)
	if err != nil {
		return err
	}
	if role != "omega_runtime" || unsafe {
		return Reject("API requires restricted omega_runtime privileges")
	}
	return nil
}
func Migrate(ctx context.Context, db *pgx.Conn, c config.Config) (Status, error) {
	var s Status
	if err := migrationRole(ctx, db); err != nil {
		return s, err
	}
	unlock, err := lock(ctx, db)
	if err != nil {
		return s, err
	}
	defer unlock()
	s, err = Inspect(ctx, db, c, false)
	if err != nil {
		return s, err
	}
	if s.Schema == SchemaVersion {
		return s, nil
	}
	if s.State == "empty" {
		_, err = db.Exec(ctx, `BEGIN; CREATE SCHEMA omega AUTHORIZATION omega_migrator; REVOKE ALL ON SCHEMA omega FROM PUBLIC; GRANT USAGE ON SCHEMA omega TO omega_runtime; CREATE TABLE omega.schema_migrations(version integer PRIMARY KEY,checksum text NOT NULL,applied_at timestamptz NOT NULL DEFAULT now()); CREATE TABLE omega.migration_attempts(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,version integer NOT NULL,started_at timestamptz NOT NULL DEFAULT now(),finished_at timestamptz,result text NOT NULL); GRANT SELECT ON omega.schema_migrations,omega.migration_attempts TO omega_runtime; ALTER DEFAULT PRIVILEGES IN SCHEMA omega GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO omega_runtime; ALTER DEFAULT PRIVILEGES IN SCHEMA omega GRANT USAGE,SELECT ON SEQUENCES TO omega_runtime; COMMIT;`)
		if err != nil {
			return s, err
		}
	}
	var id int64
	if err = db.QueryRow(ctx, `INSERT INTO omega.migration_attempts(version,result) VALUES(1,'running') RETURNING id`).Scan(&id); err != nil {
		return s, err
	}
	tx, err := db.Begin(ctx)
	if err != nil {
		return s, err
	}
	_, err = tx.Exec(ctx, migration)
	if err == nil {
		_, err = tx.Exec(ctx, `INSERT INTO omega.schema_migrations(version,checksum) VALUES(1,$1)`, checksum)
	}
	if err == nil {
		_, err = tx.Exec(ctx, `UPDATE omega.migration_attempts SET result='success',finished_at=now() WHERE id=$1`, id)
	}
	if err == nil {
		err = tx.Commit(ctx)
	}
	if err != nil {
		cleanup, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = tx.Rollback(cleanup)
		_, message := Classify(err)
		_, _ = db.Exec(cleanup, `UPDATE omega.migration_attempts SET result=$1,finished_at=now() WHERE id=$2`, message, id)
		return s, err
	}
	return Inspect(ctx, db, c, false)
}
func Ensure(ctx context.Context, db *pgx.Conn, c config.Config) (Status, error) {
	var s Status
	if err := migrationRole(ctx, db); err != nil {
		return s, err
	}
	unlock, err := lock(ctx, db)
	if err != nil {
		return s, err
	}
	defer unlock()
	s, err = Inspect(ctx, db, c, false)
	if err != nil {
		return s, err
	}
	if s.Schema != SchemaVersion {
		return s, Reject("data ensure requires migrated compatible schema")
	}
	if s.State == "ready" {
		return s, nil
	}
	if s.State != "unbound" {
		return s, Reject("unexpected installation state")
	}
	_, err = db.Exec(ctx, `INSERT INTO omega.installation(singleton,instance_id,environment) VALUES(true,$1,$2)`, c.InstanceID, c.Environment)
	if err != nil {
		return s, err
	}
	return Inspect(ctx, db, c, true)
}
func Description() string {
	return fmt.Sprintf("supported schema %d..%d", SchemaVersion, SchemaVersion)
}

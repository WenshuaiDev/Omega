// Package integration tests the actual executables against an isolated real PostgreSQL database.
package integration

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestProcesses(t *testing.T) {
	dir := t.TempDir()
	cli := filepath.Join(dir, "omega")
	api := filepath.Join(dir, "omega-api")
	for target, output := range map[string]string{"omega": cli, "omega-api": api} {
		cmd := exec.Command("go", "build", "-o", output, "../cmd/"+target)
		if b, e := cmd.CombinedOutput(); e != nil {
			t.Fatalf("build: %s %v", b, e)
		}
	}
	run := func(want int, args ...string) string {
		t.Helper()
		cmd := exec.Command(cli, args...)
		var out, stderr bytes.Buffer
		cmd.Stdout = &out
		cmd.Stderr = &stderr
		e := cmd.Run()
		code := 0
		if e != nil {
			if x, ok := e.(*exec.ExitError); ok {
				code = x.ExitCode()
			} else {
				t.Fatal(e)
			}
		}
		if code != want {
			t.Fatalf("%v: want %d got %d stdout=%s stderr=%s", args, want, code, out.String(), stderr.String())
		}
		if strings.Contains(out.String(), "test-secret") || strings.Contains(stderr.String(), "test-secret") {
			t.Fatal("secret leaked")
		}
		return out.String()
	}
	run(0, "version")
	run(0, "--help")
	run(2, "unknown")
	run(2, "config", "validate")
	secret := filepath.Join(dir, "password")
	if e := os.WriteFile(secret, []byte("test-secret\n"), 0600); e != nil {
		t.Fatal(e)
	}
	host, port := "127.0.0.1", "1"
	dsn := os.Getenv("OMEGA_TEST_ADMIN_DSN")
	var admin *pgx.Conn
	if dsn != "" {
		var e error
		admin, e = pgx.Connect(context.Background(), dsn)
		if e != nil {
			t.Fatal(e)
		}
		defer admin.Close(context.Background())
		host = admin.Config().Host
		port = fmt.Sprint(admin.Config().Port)
	}
	cfg := fmt.Sprintf("environment: dev\ninstance_id: test-instance\nhttp:\n  address: 127.0.0.1:18091\n  shutdown_timeout: 10s\ndatabase:\n  host: %s\n  port: %s\n  name: omega\n  user: omega_migrator\n  password_file: %s\n  sslmode: disable\n  connect_timeout: 1s\noperation_timeout: 2s\n", host, port, secret)
	configPath := filepath.Join(dir, "config.yaml")
	write := func(s string) {
		t.Helper()
		if e := os.WriteFile(configPath, []byte(s), 0600); e != nil {
			t.Fatal(e)
		}
	}
	write(cfg)
	run(0, "--config", configPath, "config", "validate")
	if e := os.Chmod(secret, 0644); e != nil {
		t.Fatal(e)
	}
	run(2, "--config", configPath, "config", "validate")
	if e := os.Chmod(secret, 0600); e != nil {
		t.Fatal(e)
	}
	for _, bad := range []string{cfg + "unknown: true\n", cfg + "environment: prod\n", strings.Replace(cfg, "test-instance", "123", 1), strings.Replace(cfg, "dev", "true", 1), strings.Replace(cfg, "dev", "staging", 1), strings.Replace(cfg, "127.0.0.1:18091", "127.0.0.1:no-port", 1), strings.Replace(cfg, "2s", "-1s", 1), cfg + "---\nenvironment: dev\n", strings.Replace(cfg, "environment: dev", "environment: &env dev\ninstance_id: *env", 1)} {
		write(bad)
		run(2, "--config", configPath, "config", "validate")
	}
	write(cfg)
	if dsn == "" {
		t.Log("PostgreSQL process scenarios skipped: set OMEGA_TEST_ADMIN_DSN for isolated DB")
		return
	}
	sql := func(q string) {
		t.Helper()
		if _, e := admin.Exec(context.Background(), q); e != nil {
			t.Fatal(e)
		}
	}
	sql(`CREATE ROLE omega_migrator LOGIN PASSWORD 'test-secret'; CREATE ROLE omega_runtime LOGIN PASSWORD 'test-secret'; REVOKE ALL ON DATABASE omega FROM PUBLIC; GRANT CONNECT ON DATABASE omega TO omega_migrator,omega_runtime; GRANT CREATE ON DATABASE omega TO omega_migrator; REVOKE CREATE ON SCHEMA public FROM PUBLIC`)
	maintenance := func(code int, words ...string) string {
		t.Helper()
		return run(code, append([]string{"--json", "--config", configPath}, words...)...)
	}
	if !strings.Contains(maintenance(0, "db", "status"), `"state":"empty"`) {
		t.Fatal("empty state absent")
	}
	cmd := exec.Command(api, "--config", configPath)
	if e := cmd.Run(); e == nil {
		t.Fatal("API started on empty DB")
	}
	sql(`CREATE TABLE public.unrelated(id int)`)
	maintenance(3, "db", "migrate")
	sql(`DROP TABLE public.unrelated`)
	maintenance(0, "db", "migrate")
	maintenance(0, "db", "migrate")
	maintenance(3, "health", "check")
	maintenance(0, "data", "ensure")
	maintenance(0, "data", "ensure")
	maintenance(0, "doctor")
	maintenance(5, "health", "check")
	write(strings.Replace(cfg, "test-instance", "wrong-instance", 1))
	maintenance(3, "db", "migrate")
	maintenance(3, "data", "ensure")
	write(cfg)
	sql(`SELECT pg_advisory_lock(718293410)`)
	maintenance(6, "db", "migrate")
	sql(`SELECT pg_advisory_unlock(718293410)`)

	var checksum string
	if e := admin.QueryRow(context.Background(), `SELECT checksum FROM omega.schema_migrations WHERE version=1`).Scan(&checksum); e != nil {
		t.Fatal(e)
	}
	sql(`UPDATE omega.schema_migrations SET checksum='modified'`)
	maintenance(3, "db", "status")
	sql(`UPDATE omega.schema_migrations SET checksum='` + checksum + `'`)
	sql(`UPDATE omega.schema_migrations SET version=2`)
	maintenance(3, "db", "status")
	sql(`UPDATE omega.schema_migrations SET version=1`)
	// Exercise failure journaling and transaction rollback, then retry the same migration.
	sql(`DROP TABLE omega.installation; DELETE FROM omega.schema_migrations;
 CREATE FUNCTION public.fail_test_migration() RETURNS event_trigger LANGUAGE plpgsql AS $$ BEGIN IF current_user='omega_migrator' THEN RAISE EXCEPTION 'test migration rejected'; END IF; END $$;
 CREATE EVENT TRIGGER fail_test_migration ON ddl_command_start WHEN TAG IN ('CREATE TABLE') EXECUTE FUNCTION public.fail_test_migration()`)
	maintenance(4, "db", "migrate")
	var failures int
	if e := admin.QueryRow(context.Background(), `SELECT count(*) FROM omega.migration_attempts WHERE result LIKE 'database operation failed%'`).Scan(&failures); e != nil || failures != 1 {
		t.Fatalf("failed migration journal: %d %v", failures, e)
	}
	sql(`DROP EVENT TRIGGER fail_test_migration; DROP FUNCTION public.fail_test_migration()`)
	maintenance(0, "db", "migrate")
	maintenance(0, "data", "ensure")
	// Runtime identity is read-only; future table defaults allow application DML, never DDL.
	runtimeConfig := admin.Config().Copy()
	runtimeConfig.User = "omega_runtime"
	runtimeConfig.Password = "test-secret"
	runtime, e := pgx.ConnectConfig(context.Background(), runtimeConfig)
	if e != nil {
		t.Fatal(e)
	}
	defer runtime.Close(context.Background())
	for _, q := range []string{`CREATE TABLE omega.forbidden(id int)`, `UPDATE omega.installation SET environment='prod'`, `DELETE FROM omega.schema_migrations`, `CREATE SCHEMA forbidden`} {
		if _, e = runtime.Exec(context.Background(), q); e == nil {
			t.Fatalf("runtime privilege unexpectedly allowed: %s", q)
		}
	}
	sql(`SET ROLE omega_migrator; CREATE TABLE omega.future_test(id int); RESET ROLE`)
	if _, e = runtime.Exec(context.Background(), `INSERT INTO omega.future_test VALUES(1)`); e != nil {
		t.Fatal(e)
	}
	sql(`DROP TABLE omega.future_test`)
	runtimeCfg := strings.Replace(cfg, "omega_migrator", "omega_runtime", 1)
	listener, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	address := listener.Addr().String()
	listener.Close()
	runtimeCfg = strings.Replace(runtimeCfg, "127.0.0.1:18091", address, 1)
	write(runtimeCfg)
	maintenance(3, "db", "migrate")
	maintenance(3, "data", "ensure")
	cmd = exec.Command(api, "--config", configPath)
	var logs bytes.Buffer
	cmd.Stderr = &logs
	if e = cmd.Start(); e != nil {
		t.Fatal(e)
	}
	defer func() {
		if cmd.ProcessState == nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
	}()
	client := &http.Client{Timeout: time.Second}
	get := func(path string) int {
		resp, e := client.Get("http://" + address + path)
		if e != nil {
			return 0
		}
		defer resp.Body.Close()
		return resp.StatusCode
	}
	deadline := time.Now().Add(10 * time.Second)
	for get("/health/ready") != 204 && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	maintenance(0, "health", "check")
	if get("/api/v1/ping") != 200 || get("/health/live") != 204 {
		t.Fatalf("HTTP startup failed: %s", logs.String())
	}
	sql(`REVOKE SELECT ON omega.installation FROM omega_runtime`)
	if get("/health/ready") != 503 || get("/api/v1/ping") != 503 || get("/health/live") != 204 {
		t.Fatal("dependency failure must affect readiness/ping but not liveness")
	}
	sql(`GRANT SELECT ON omega.installation TO omega_runtime`)
	if get("/health/ready") != 204 {
		t.Fatal("readiness did not recover")
	}
	client.CloseIdleConnections()
	if e = cmd.Process.Signal(syscall.SIGTERM); e != nil {
		t.Fatal(e)
	}
	if e = cmd.Wait(); e != nil {
		t.Fatalf("graceful shutdown: %v %s", e, logs.String())
	}
	// PostgreSQL lock creates a real statement timeout and bounded maintenance exit.
	sql(`BEGIN; LOCK TABLE omega.installation IN ACCESS EXCLUSIVE MODE`)
	maintenance(5, "doctor")
	cancelCmd := exec.Command(cli, "--config", configPath, "doctor")
	if e = cancelCmd.Start(); e != nil {
		t.Fatal(e)
	}
	time.Sleep(100 * time.Millisecond)
	_ = cancelCmd.Process.Signal(syscall.SIGINT)
	if e = cancelCmd.Wait(); e == nil {
		t.Fatal("canceled command succeeded")
	} else if x, ok := e.(*exec.ExitError); !ok || x.ExitCode() != 130 {
		t.Fatalf("cancel exit: %v", e)
	}
	sql(`ROLLBACK`)
}

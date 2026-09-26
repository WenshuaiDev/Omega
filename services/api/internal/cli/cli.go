package cli

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/WenshuaiDev/Omega/services/api/internal/app"
	"github.com/WenshuaiDev/Omega/services/api/internal/config"
	"github.com/WenshuaiDev/Omega/services/api/internal/database"
)

const Help = `omega [--config PATH] [--json] COMMAND
Commands: version | config validate | doctor | health check | db status | db migrate | data ensure
Exit codes: 0 success; 2 input; 3 policy; 4 failure; 5 timeout/unhealthy; 6 lock conflict; 130 canceled.
`

type Result struct {
	OperationID string    `json:"operation_id"`
	Version     string    `json:"version"`
	Commit      string    `json:"commit"`
	Instance    string    `json:"instance_id,omitempty"`
	Command     string    `json:"command"`
	Started     time.Time `json:"started_at"`
	Finished    time.Time `json:"finished_at"`
	Code        int       `json:"exit_code"`
	Result      string    `json:"result"`
	Data        any       `json:"data,omitempty"`
}

func Run(ctx context.Context, args []string, out, diagnostics io.Writer) int {
	var path string
	jsonMode := false
	var words []string
	invalid := false
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--json":
			jsonMode = true
		case "--config":
			i++
			if i == len(args) {
				invalid = true
			} else {
				path = args[i]
			}
		case "--help", "-h":
			fmt.Fprint(out, Help)
			return 0
		default:
			if strings.HasPrefix(args[i], "-") {
				invalid = true
			}
			words = append(words, args[i])
		}
	}
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	r := Result{OperationID: hex.EncodeToString(b), Version: app.Version, Commit: app.Commit, Command: strings.Join(words, " "), Started: time.Now().UTC()}
	finish := func(code int, message string, data any) int {
		r.Code = code
		r.Result = message
		r.Data = data
		r.Finished = time.Now().UTC()
		if jsonMode {
			_ = json.NewEncoder(out).Encode(r)
		} else {
			fmt.Fprintf(out, "%s: %s (operation=%s version=%s instance=%s started=%s finished=%s)\n", r.Command, message, r.OperationID, r.Version, r.Instance, r.Started.Format(time.RFC3339Nano), r.Finished.Format(time.RFC3339Nano))
			if data != nil {
				v, _ := json.Marshal(data)
				fmt.Fprintln(out, string(v))
			}
		}
		if code != 0 {
			fmt.Fprintln(diagnostics, message)
		}
		return code
	}
	if len(args) == 0 {
		fmt.Fprint(out, Help)
		return 0
	}
	if invalid {
		return finish(2, "invalid arguments", nil)
	}
	switch r.Command {
	case "version":
		return finish(0, "ok", map[string]any{"schema_min": app.SchemaMin, "schema_max": app.SchemaMax})
	case "config validate", "doctor", "health check", "db status", "db migrate", "data ensure":
	default:
		return finish(2, "unknown command", nil)
	}
	c, err := config.Load(path)
	if err != nil {
		return finish(2, err.Error(), nil)
	}
	r.Instance = c.InstanceID
	if r.Command == "config validate" {
		return finish(0, "configuration valid", nil)
	}
	ctx, cancel := context.WithTimeout(ctx, config.Duration(c.OperationTimeout))
	defer cancel()
	db, err := database.Connect(ctx, c)
	if err != nil {
		code, message := database.Classify(err)
		if r.Command == "health check" && code == 4 {
			code = 5
		}
		return finish(code, message, nil)
	}
	defer database.Close(db)
	var data any
	switch r.Command {
	case "db migrate":
		data, err = database.Migrate(ctx, db, c)
	case "data ensure":
		data, err = database.Ensure(ctx, db, c)
	case "db status":
		data, err = database.Inspect(ctx, db, c, false)
	case "doctor", "health check":
		data, err = database.Inspect(ctx, db, c, true)
	}
	if err == nil && r.Command == "health check" {
		host, port, _ := net.SplitHostPort(c.HTTP.Address)
		if host == "" || host == "0.0.0.0" || host == "::" {
			host = "127.0.0.1"
		}
		req, requestErr := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+net.JoinHostPort(host, port)+"/health/ready", nil)
		if requestErr != nil {
			err = &database.Failure{Code: 5, Message: "invalid health endpoint"}
		} else {
			transport := &http.Transport{Proxy: nil}
			client := &http.Client{Transport: transport, Timeout: config.Duration(c.OperationTimeout)}
			resp, healthErr := client.Do(req)
			if healthErr != nil {
				if ctx.Err() != nil {
					err = ctx.Err()
				} else {
					err = &database.Failure{Code: 5, Message: "HTTP endpoint unhealthy"}
				}
			} else {
				resp.Body.Close()
				if resp.StatusCode != http.StatusNoContent {
					err = &database.Failure{Code: 5, Message: "HTTP endpoint not ready"}
				}
			}
			transport.CloseIdleConnections()
		}
	}
	code, message := database.Classify(err)
	if r.Command == "health check" && code == 4 {
		code = 5
	}
	return finish(code, message, data)
}

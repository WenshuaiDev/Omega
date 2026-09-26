package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/WenshuaiDev/Omega/services/api/internal/config"
	"github.com/WenshuaiDev/Omega/services/api/internal/database"
)

func Serve(ctx context.Context, c config.Config) error {
	startup, cancel := context.WithTimeout(ctx, config.Duration(c.OperationTimeout))
	db, err := database.Connect(startup, c)
	if err == nil {
		_, err = database.Inspect(startup, db, c, true)
	}
	if err == nil {
		err = database.RuntimeRole(startup, db)
	}
	if db != nil {
		database.Close(db)
	}
	cancel()
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", c.HTTP.Address)
	if err != nil {
		return errors.New("cannot bind HTTP address")
	}
	var ready atomic.Bool
	ready.Store(true)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health/live", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) })
	check := func(r *http.Request) bool {
		if !ready.Load() {
			return false
		}
		ctx, cancel := context.WithTimeout(r.Context(), min(2*time.Second, config.Duration(c.OperationTimeout)))
		defer cancel()
		db, err := database.Connect(ctx, c)
		if err != nil {
			return false
		}
		defer database.Close(db)
		_, err = database.Inspect(ctx, db, c, true)
		return err == nil
	}
	mux.HandleFunc("GET /health/ready", func(w http.ResponseWriter, r *http.Request) {
		if !check(r) {
			http.Error(w, "not ready", 503)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /api/v1/ping", func(w http.ResponseWriter, r *http.Request) {
		if !check(r) {
			http.Error(w, "service unavailable", 503)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(map[string]string{"project": "Omega", "environment": c.Environment, "version": Version, "status": "ok"})
	})
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second}
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	select {
	case err = <-done:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	case <-ctx.Done():
	}
	ready.Store(false)
	shutdown, cancel := context.WithTimeout(context.Background(), config.Duration(c.HTTP.ShutdownTimeout))
	defer cancel()
	if err = server.Shutdown(shutdown); err != nil {
		_ = server.Close()
		return fmt.Errorf("HTTP shutdown budget exhausted")
	}
	return nil
}

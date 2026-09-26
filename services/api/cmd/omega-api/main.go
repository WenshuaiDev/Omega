package main

import (
	"context"
	"fmt"
	"github.com/WenshuaiDev/Omega/services/api/internal/app"
	"github.com/WenshuaiDev/Omega/services/api/internal/config"
	"github.com/WenshuaiDev/Omega/services/api/internal/database"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Printf("%s %s\n", app.Version, app.Commit)
		return
	}
	if len(os.Args) != 3 || os.Args[1] != "--config" {
		fmt.Fprintln(os.Stderr, "usage: omega-api --config PATH")
		os.Exit(2)
	}
	c, err := config.Load(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err = app.Serve(ctx, c); err != nil {
		code, message := database.Classify(err)
		fmt.Fprintln(os.Stderr, message)
		os.Exit(code)
	}
}

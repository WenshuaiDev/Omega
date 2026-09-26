// devwatch deliberately stops the previous program before compiling new source.
// A failed build leaves the API unavailable, so an old response cannot masquerade as new code.
package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func fingerprint() [32]byte {
	h := sha256.New()
	_ = filepath.WalkDir(".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			switch d.Name() {
			case ".git", "node_modules", ".omega", "dist", ".yarn":
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(path, ".go") || d.Name() == "go.mod" || d.Name() == "go.sum" || d.Name() == "go.work" || d.Name() == "go.work.sum" {
			b, e := os.ReadFile(path)
			if e == nil {
				_, _ = h.Write([]byte(path))
				_, _ = h.Write(b)
			}
		}
		return nil
	})
	var sum [32]byte
	copy(sum[:], h.Sum(nil))
	return sum
}
func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	dir, err := os.MkdirTemp("", "omega-devwatch-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "cannot create watcher build directory")
		os.Exit(1)
	}
	defer os.RemoveAll(dir)
	binary := filepath.Join(dir, "omega-api")
	var child *exec.Cmd
	var done chan error
	stop := func() {
		if child == nil {
			return
		}
		_ = child.Process.Signal(syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			_ = child.Process.Kill()
			<-done
		}
		child = nil
	}
	defer stop()
	var previous [32]byte
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		current := fingerprint()
		if current != previous {
			previous = current
			stop()
			fmt.Fprintln(os.Stderr, "omega devwatch: building current source; API stopped")
			build := exec.CommandContext(ctx, "go", "build", "-o", binary, "./services/api/cmd/omega-api")
			build.Stdout = os.Stdout
			build.Stderr = os.Stderr
			if err := build.Run(); err != nil {
				fmt.Fprintln(os.Stderr, "omega devwatch: BUILD FAILED; API remains stopped")
			} else if ctx.Err() == nil {
				child = exec.Command(binary, os.Args[1:]...)
				child.Stdout = os.Stdout
				child.Stderr = os.Stderr
				if err = child.Start(); err != nil {
					fmt.Fprintln(os.Stderr, "omega devwatch: API start failed")
					child = nil
				} else {
					done = make(chan error, 1)
					running := child
					go func() { done <- running.Wait() }()
					fmt.Fprintln(os.Stderr, "omega devwatch: API started from current source")
				}
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

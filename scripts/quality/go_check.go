// Container-only workspace checks. Discover actual Go modules from go.work.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func fail(format string, args ...any) { fmt.Fprintf(os.Stderr, format+"\n", args...); os.Exit(1) }
func output(dir, name string, args ...string) []byte {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Stderr = os.Stderr
	data, err := cmd.Output()
	if err != nil {
		fail("%s %v: %v", name, args, err)
	}
	return data
}
func run(dir, name string, args ...string) {
	fmt.Printf("[%s] %s %s\n", dir, name, strings.Join(args, " "))
	cmd := exec.Command(name, args...)
	cmd.Dir, cmd.Stdout, cmd.Stderr = dir, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		fail("%s failed: %v", name, err)
	}
}
func main() {
	mode := os.Args[1]
	var workspace struct {
		Go      string
		Use     []struct{ DiskPath string }
		Replace []struct {
			New struct{ Path, Version string }
		}
	}
	if err := json.Unmarshal(output(".", "go", "work", "edit", "-json"), &workspace); err != nil {
		fail("read workspace: %v", err)
	}
	root, _ := os.Getwd()
	if len(workspace.Use) == 0 {
		fail("go.work has no modules")
	}
	for _, replace := range workspace.Replace {
		if replace.New.Version == "" {
			validatePath(root, replace.New.Path)
		}
	}
	modules := map[string]bool{}
	for _, use := range workspace.Use {
		modules[validatePath(root, use.DiskPath)] = true
	}
	before := map[string][32]byte{}
	_ = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			fail("walk: %v", err)
		}
		if d.IsDir() && (d.Name() == ".git" || d.Name() == "node_modules" || d.Name() == ".yarn" || d.Name() == ".quality-go" || d.Name() == "artifacts") {
			return filepath.SkipDir
		}
		if d.Name() == "go.mod" {
			if !modules[filepath.Dir(path)] {
				fail("Go module missing from go.work: %s", path)
			}
		}
		if !d.IsDir() && (d.Name() == "go.mod" || d.Name() == "go.sum" || d.Name() == "go.work" || d.Name() == "go.work.sum") {
			b, _ := os.ReadFile(path)
			before[path] = sha256.Sum256(b)
		}
		return nil
	})
	version := strings.TrimSpace(string(output(root, "go", "env", "GOVERSION")))
	dockerfile, err := os.ReadFile("services/api/Dockerfile")
	if err != nil {
		fail("%v", err)
	}
	if !strings.Contains(string(dockerfile), "FROM golang:"+strings.TrimPrefix(version, "go")+"-") {
		fail("running Go %s differs from pinned development image", version)
	}
	for _, use := range workspace.Use {
		dir := validatePath(root, use.DiskPath)
		var module struct {
			Module  struct{ Path string }
			Replace []struct {
				New struct{ Path, Version string }
			}
		}
		if err := json.Unmarshal(output(dir, "go", "mod", "edit", "-json"), &module); err != nil {
			fail("%v", err)
		}
		if !strings.HasPrefix(module.Module.Path, "github.com/WenshuaiDev/Omega/") {
			fail("module path does not match repository: %s", module.Module.Path)
		}
		for _, replace := range module.Replace {
			if replace.New.Version == "" {
				validatePath(root, filepath.Join(dir, replace.New.Path))
			}
		}
		if mode == "check" {
			_ = filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
				if err != nil {
					fail("%v", err)
				}
				if d.IsDir() && (d.Name() == "vendor" || d.Name() == "node_modules") {
					return filepath.SkipDir
				}
				if !d.IsDir() && strings.HasSuffix(path, ".go") {
					if b := output(root, "gofmt", "-l", path); len(b) != 0 {
						fail("Go formatting required: %s", b)
					}
				}
				return nil
			})
			run(dir, "go", "vet", "./...")
			run(dir, "go", "mod", "verify")
		}
		run(dir, "go", "test", "-count=1", "-timeout=180s", "-v", "./...")
		if mode == "check" {
			run(dir, "go", "build", "./...")
		}
	}
	for path, want := range before {
		got, e := os.ReadFile(path)
		if e != nil || sha256.Sum256(got) != want {
			fail("dependency metadata changed: %s", path)
		}
	}
}
func validatePath(root, path string) string {
	if !filepath.IsAbs(path) {
		path = filepath.Join(root, path)
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		fail("workspace path: %v", err)
	}
	rel, err := filepath.Rel(root, resolved)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		fail("workspace dependency escapes repository: %s", path)
	}
	return resolved
}

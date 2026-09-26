// Package config loads one explicit complete configuration; environment variables never override it.
package config

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

type Config struct {
	Environment string `yaml:"environment"`
	InstanceID  string `yaml:"instance_id"`
	HTTP        struct {
		Address         string `yaml:"address"`
		ShutdownTimeout string `yaml:"shutdown_timeout"`
	} `yaml:"http"`
	Database struct {
		Host           string `yaml:"host"`
		Port           int    `yaml:"port"`
		Name           string `yaml:"name"`
		User           string `yaml:"user"`
		PasswordFile   string `yaml:"password_file"`
		SSLMode        string `yaml:"sslmode"`
		ConnectTimeout string `yaml:"connect_timeout"`
	} `yaml:"database"`
	OperationTimeout string `yaml:"operation_timeout"`
}

var identifier = regexp.MustCompile(`^[a-z][a-z0-9_-]{2,62}$`)

func Duration(v string) time.Duration { d, _ := time.ParseDuration(v); return d }
func Load(path string) (Config, error) {
	var c Config
	if path == "" {
		return c, errors.New("an explicit --config path is required")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return c, errors.New("cannot read configuration file")
	}
	var node yaml.Node
	if yaml.Unmarshal(b, &node) != nil || !validTypes(&node, "") {
		return c, errors.New("configuration contains a wrong YAML type or alias")
	}
	d := yaml.NewDecoder(bytes.NewReader(b))
	d.KnownFields(true)
	if err := d.Decode(&c); err != nil {
		return c, errors.New("invalid YAML: unknown/duplicate field, type, or syntax")
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return c, errors.New("configuration must contain exactly one YAML document")
	}
	if c.Environment != "dev" && c.Environment != "test" && c.Environment != "prod" {
		return c, errors.New("environment must be dev, test, or prod")
	}
	if !identifier.MatchString(c.InstanceID) {
		return c, errors.New("invalid instance_id")
	}
	host, port, addressErr := net.SplitHostPort(c.HTTP.Address)
	_ = host
	portNumber, portErr := strconv.Atoi(port)
	if addressErr != nil || portErr != nil || portNumber < 1 || portNumber > 65535 {
		return c, errors.New("http.address must include host and port")
	}
	if c.Database.Host == "" || c.Database.Name == "" || c.Database.User == "" || c.Database.PasswordFile == "" || c.Database.Port < 1 || c.Database.Port > 65535 {
		return c, errors.New("all database fields are required and port must be valid")
	}
	if c.Database.SSLMode != "disable" && c.Database.SSLMode != "require" && c.Database.SSLMode != "verify-full" {
		return c, errors.New("database.sslmode must be disable, require, or verify-full")
	}
	for name, v := range map[string]string{"http.shutdown_timeout": c.HTTP.ShutdownTimeout, "database.connect_timeout": c.Database.ConnectTimeout, "operation_timeout": c.OperationTimeout} {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 || d > 5*time.Minute {
			return c, fmt.Errorf("%s must be a positive duration no greater than 5m", name)
		}
	}
	if Duration(c.HTTP.ShutdownTimeout) >= 30*time.Second {
		return c, errors.New("http.shutdown_timeout must be shorter than container grace period (30s)")
	}
	if _, err := c.Password(); err != nil {
		return c, err
	}
	return c, nil
}
func (c Config) Password() (string, error) {
	f, err := os.Open(c.Database.PasswordFile)
	if err != nil {
		return "", errors.New("cannot read database password file")
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0037 != 0 {
		return "", errors.New("password file must be regular and owner-only or owner/group-readable (0600/0640/0400/0440)")
	}
	b, err := io.ReadAll(io.LimitReader(f, 4097))
	if err != nil || len(b) > 4096 {
		return "", errors.New("invalid password file")
	}
	p := strings.TrimSuffix(string(b), "\n")
	if p == "" || strings.ContainsAny(p, "\r\n\x00") {
		return "", errors.New("password file must contain one nonempty line")
	}
	return p, nil
}

// Require exact scalar types; YAML string coercion would silently accept invalid input.
func validTypes(n *yaml.Node, key string) bool {
	switch n.Kind {
	case yaml.DocumentNode:
		return len(n.Content) == 1 && validTypes(n.Content[0], "")
	case yaml.MappingNode:
		for i := 0; i < len(n.Content); i += 2 {
			if n.Content[i].Tag != "!!str" || !validTypes(n.Content[i+1], n.Content[i].Value) {
				return false
			}
		}
		return true
	case yaml.ScalarNode:
		if key == "port" {
			return n.Tag == "!!int"
		}
		return n.Tag == "!!str"
	default:
		return false
	}
}

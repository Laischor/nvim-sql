// Package config loads the connections.toml file that declares database
// servers. Passwords are resolved from the config itself, an environment
// variable, or the macOS keychain — in that order.
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/pelletier/go-toml/v2"

	"github.com/Laischor/nvim-sql/internal/keychain"
)

type Server struct {
	Name    string `toml:"name" json:"name"`
	Adapter string `toml:"adapter" json:"adapter"` // "postgres" or "sqlite"

	// postgres
	Host     string            `toml:"host" json:"host,omitempty"`
	Port     int               `toml:"port" json:"port,omitempty"`
	User     string            `toml:"user" json:"user,omitempty"`
	Database string            `toml:"database" json:"database,omitempty"` // maintenance/default db
	SSLMode  string            `toml:"sslmode" json:"-"`
	Params   map[string]string `toml:"params" json:"-"`

	// sqlite
	Path string `toml:"path" json:"path,omitempty"`

	// password resolution (first non-empty wins)
	Password         string `toml:"password" json:"-"`
	PasswordEnv      string `toml:"password_env" json:"-"`
	PasswordKeychain string `toml:"password_keychain" json:"-"` // keychain service name
	KeychainAccount  string `toml:"keychain_account" json:"-"`  // defaults to User

	Prod     bool `toml:"prod" json:"prod"`
	ReadOnly bool `toml:"readonly" json:"readonly"`
}

type Config struct {
	Servers []Server `toml:"servers"`

	// FilePath is where the config was loaded from (informational).
	FilePath string `toml:"-"`
}

// DefaultPath returns $SQLEDIT_CONFIG, or ~/.config/sqledit/connections.toml
// ($XDG_CONFIG_HOME respected).
func DefaultPath() string {
	if p := os.Getenv("SQLEDIT_CONFIG"); p != "" {
		return p
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "sqledit", "connections.toml")
}

// Load reads and validates the config. A missing file is not an error: it
// yields an empty config so the frontend can report "nothing configured yet".
func Load(path string) (*Config, error) {
	cfg := &Config{FilePath: path}
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return cfg, nil
	}
	if err != nil {
		return nil, err
	}
	if err := toml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	cfg.FilePath = path

	seen := map[string]bool{}
	for i := range cfg.Servers {
		s := &cfg.Servers[i]
		if s.Name == "" {
			return nil, fmt.Errorf("%s: server #%d has no name", path, i+1)
		}
		if seen[s.Name] {
			return nil, fmt.Errorf("%s: duplicate server name %q", path, s.Name)
		}
		seen[s.Name] = true
		switch s.Adapter {
		case "postgres":
			if s.Host == "" {
				s.Host = "localhost"
			}
			if s.Port == 0 {
				s.Port = 5432
			}
			if s.Database == "" {
				s.Database = "postgres"
			}
		case "sqlite":
			if s.Path == "" {
				return nil, fmt.Errorf("%s: sqlite server %q needs path", path, s.Name)
			}
			s.Path = expandHome(s.Path)
		default:
			return nil, fmt.Errorf("%s: server %q: unknown adapter %q (want postgres or sqlite)", path, s.Name, s.Adapter)
		}
	}
	return cfg, nil
}

// Find returns the server with the given name.
func (c *Config) Find(name string) (*Server, error) {
	for i := range c.Servers {
		if c.Servers[i].Name == name {
			return &c.Servers[i], nil
		}
	}
	return nil, fmt.Errorf("unknown server %q (config: %s)", name, c.FilePath)
}

// ResolvePassword resolves the server password: inline value, then
// password_env, then the macOS keychain.
func (s *Server) ResolvePassword() (string, error) {
	if s.Password != "" {
		return s.Password, nil
	}
	if s.PasswordEnv != "" {
		if v := os.Getenv(s.PasswordEnv); v != "" {
			return v, nil
		}
		return "", fmt.Errorf("server %q: env var %s is empty or unset", s.Name, s.PasswordEnv)
	}
	if s.PasswordKeychain != "" {
		account := s.KeychainAccount
		if account == "" {
			account = s.User
		}
		return keychain.Get(s.PasswordKeychain, account)
	}
	return "", nil // no password configured — may be fine (trust auth, .pgpass, …)
}

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		home, err := os.UserHomeDir()
		if err == nil {
			return filepath.Join(home, strings.TrimPrefix(p, "~"))
		}
	}
	return p
}

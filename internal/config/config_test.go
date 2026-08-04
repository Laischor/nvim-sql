package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "connections.toml")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadDefaults(t *testing.T) {
	cfg, err := Load(write(t, `
[[servers]]
name = "local"
adapter = "postgres"

[[servers]]
name = "site1-prod"
adapter = "postgres"
host = "site1.example.com"
user = "admin"
password_keychain = "sqledit/site1"
prod = true

[[servers]]
name = "analytics"
adapter = "sqlite"
path = "~/data/analytics.db"
`))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Servers) != 3 {
		t.Fatalf("got %d servers", len(cfg.Servers))
	}
	local := cfg.Servers[0]
	if local.Host != "localhost" || local.Port != 5432 || local.Database != "postgres" {
		t.Fatalf("defaults not applied: %+v", local)
	}
	if !cfg.Servers[1].Prod {
		t.Fatal("prod flag lost")
	}
	if strings.HasPrefix(cfg.Servers[2].Path, "~") {
		t.Fatalf("home not expanded: %s", cfg.Servers[2].Path)
	}
	if _, err := cfg.Find("site1-prod"); err != nil {
		t.Fatal(err)
	}
	if _, err := cfg.Find("nope"); err == nil {
		t.Fatal("Find(nope) should fail")
	}
}

func TestLoadMissingFileIsEmpty(t *testing.T) {
	cfg, err := Load(filepath.Join(t.TempDir(), "nope.toml"))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Servers) != 0 || cfg.FilePath == "" {
		t.Fatalf("want empty config with path, got %+v", cfg)
	}
}

func TestLoadRejectsBadConfig(t *testing.T) {
	cases := map[string]string{
		"duplicate name": "[[servers]]\nname = \"a\"\nadapter = \"postgres\"\n[[servers]]\nname = \"a\"\nadapter = \"postgres\"\n",
		"missing name":   "[[servers]]\nadapter = \"postgres\"\n",
		"bad adapter":    "[[servers]]\nname = \"a\"\nadapter = \"mysql\"\n",
		"sqlite no path": "[[servers]]\nname = \"a\"\nadapter = \"sqlite\"\n",
	}
	for name, content := range cases {
		if _, err := Load(write(t, content)); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
}

func TestResolvePasswordEnv(t *testing.T) {
	s := &Server{Name: "x", PasswordEnv: "SQLEDIT_TEST_PW"}
	t.Setenv("SQLEDIT_TEST_PW", "secret")
	pw, err := s.ResolvePassword()
	if err != nil || pw != "secret" {
		t.Fatalf("pw=%q err=%v", pw, err)
	}
	t.Setenv("SQLEDIT_TEST_PW", "")
	if _, err := s.ResolvePassword(); err == nil {
		t.Fatal("empty env var should error")
	}
}

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

func TestDefaultsAndGroups(t *testing.T) {
	cfg, err := Load(write(t, `
[defaults]
adapter = "postgres"
user = "infosys"
password_keychain = "sqledit/infosys"

[[servers]]
name = "local"
port = 102

[[groups]]
names = ["purina", "bonzo"]

[[groups.servers]]
name = "{name}-prod"
host = "{name}.tst-tool.com"
prod = true

[[groups.servers]]
name = "{name}-staging"
host = "t-{name}.tst-tool.com"
`))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Servers) != 5 { // local + 2 names x 2 templates
		t.Fatalf("got %d servers: %+v", len(cfg.Servers), cfg.Servers)
	}

	local, err := cfg.Find("local")
	if err != nil {
		t.Fatal(err)
	}
	if local.User != "infosys" || local.PasswordKeychain != "sqledit/infosys" ||
		local.Port != 102 || local.Host != "localhost" || local.Adapter != "postgres" {
		t.Fatalf("defaults not applied to plain server: %+v", local)
	}

	prod, err := cfg.Find("purina-prod")
	if err != nil {
		t.Fatal(err)
	}
	if prod.Host != "purina.tst-tool.com" || !prod.Prod || prod.User != "infosys" ||
		prod.Port != 5432 || prod.PasswordKeychain != "sqledit/infosys" {
		t.Fatalf("purina-prod: %+v", prod)
	}

	staging, err := cfg.Find("bonzo-staging")
	if err != nil {
		t.Fatal(err)
	}
	if staging.Host != "t-bonzo.tst-tool.com" || staging.Prod {
		t.Fatalf("bonzo-staging: %+v", staging)
	}
}

func TestGroupValidation(t *testing.T) {
	if _, err := Load(write(t, "[[groups]]\n[[groups.servers]]\nname = \"x\"\nadapter = \"postgres\"\n")); err == nil {
		t.Fatal("group without names should fail")
	}
	if _, err := Load(write(t, "[[groups]]\nnames = [\"a\"]\n")); err == nil {
		t.Fatal("group without templates should fail")
	}
	// template without {name} in the name collides across names
	if _, err := Load(write(t, `
[[groups]]
names = ["a", "b"]
[[groups.servers]]
name = "static"
adapter = "postgres"
`)); err == nil {
		t.Fatal("colliding generated names should fail")
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

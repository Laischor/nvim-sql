package db

import (
	"context"
	"net/url"
	"os"
	"strconv"
	"testing"

	"github.com/Laischor/nvim-sql/internal/config"
)

// pgServer builds a config.Server from $SQLEDIT_TEST_PG
// (postgres://user:pass@host:port/db). Tests skip when unset.
func pgServer(t *testing.T) *config.Server {
	t.Helper()
	dsn := os.Getenv("SQLEDIT_TEST_PG")
	if dsn == "" {
		t.Skip("SQLEDIT_TEST_PG not set (e.g. postgres://user:pass@localhost:5432/db)")
	}
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal(err)
	}
	port := 5432
	if p := u.Port(); p != "" {
		port, _ = strconv.Atoi(p)
	}
	pass, _ := u.User.Password()
	return &config.Server{
		Name:     "pgtest",
		Adapter:  "postgres",
		Host:     u.Hostname(),
		Port:     port,
		User:     u.User.Username(),
		Password: pass,
		Database: u.Path[1:],
		SSLMode:  "disable",
	}
}

func TestPGEndToEnd(t *testing.T) {
	srv := pgServer(t)
	ctx := context.Background()

	dbs, err := PGListDatabases(ctx, srv)
	if err != nil {
		t.Fatal(err)
	}
	if len(dbs) == 0 {
		t.Fatal("no databases listed")
	}

	conn, err := PGConnect(ctx, srv, srv.Database)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	mustExec := func(sql string) {
		t.Helper()
		if _, err := conn.Query(ctx, sql, nil, 10); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}
	mustExec("DROP SCHEMA IF EXISTS sqledit_t CASCADE")
	mustExec("CREATE SCHEMA sqledit_t")
	t.Cleanup(func() { conn.Query(ctx, "DROP SCHEMA sqledit_t CASCADE", nil, 10) })
	mustExec("CREATE TABLE sqledit_t.owners (id serial PRIMARY KEY, name text NOT NULL)")
	mustExec(`CREATE TABLE sqledit_t.dogs (id serial PRIMARY KEY, name text,
	          owner_id int REFERENCES sqledit_t.owners(id))`)
	mustExec("INSERT INTO sqledit_t.owners (name) VALUES ('anna'), ('ben')")
	mustExec("INSERT INTO sqledit_t.dogs (name, owner_id) VALUES ('waldi', 1), ('strolch', NULL)")

	// query with text params + NULL handling
	res, err := conn.Query(ctx,
		"SELECT id, name, owner_id FROM sqledit_t.dogs WHERE name = $1", []any{"waldi"}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if res.RowCount != 1 || res.Rows[0][1] != "waldi" {
		t.Fatalf("param select: %+v", res.Rows)
	}
	res, err = conn.Query(ctx, "SELECT owner_id FROM sqledit_t.dogs ORDER BY id", nil, 10)
	if err != nil {
		t.Fatal(err)
	}
	if res.Rows[1][0] != nil {
		t.Fatalf("NULL not preserved: %v", res.Rows[1][0])
	}

	// parameterized update (the edit grid path)
	res, err = conn.Query(ctx,
		"UPDATE sqledit_t.dogs SET name = $1 WHERE id = $2", []any{"bello", "1"}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if res.RowsAffected != 1 {
		t.Fatalf("update: rows_affected = %d", res.RowsAffected)
	}

	objs, err := conn.Objects(ctx)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, o := range objs {
		if o.Schema == "sqledit_t" && o.Name == "dogs" && o.Type == "table" {
			found = true
		}
	}
	if !found {
		t.Fatalf("dogs not in objects: %+v", objs)
	}

	// the regression: Columns must survive the FK struct field
	cols, err := conn.Columns(ctx, "sqledit_t", "dogs")
	if err != nil {
		t.Fatalf("Columns: %v", err)
	}
	if len(cols) != 3 {
		t.Fatalf("columns: %+v", cols)
	}
	if !cols[0].PK || cols[0].Name != "id" {
		t.Fatalf("pk: %+v", cols[0])
	}
	fk := cols[2].FK
	if fk == nil || fk.Schema != "sqledit_t" || fk.Table != "owners" || fk.Column != "id" {
		t.Fatalf("fk: %+v", fk)
	}
	if cols[0].FK != nil || cols[1].FK != nil {
		t.Fatalf("unexpected fk: %+v", cols)
	}
}

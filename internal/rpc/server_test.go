package rpc

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/Laischor/nvim-sql/internal/config"
)

// client drives a Server over pipes, one request/response at a time like the Lua frontend.
type client struct {
	in   io.WriteCloser
	out  *bufio.Scanner
	next int
}

func newClient(t *testing.T, cfg *config.Config) *client {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	srv := NewServer(cfg, "test")
	go srv.Serve(inR, outW)
	t.Cleanup(func() { inW.Close() })
	sc := bufio.NewScanner(outR)
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	return &client{in: inW, out: sc}
}

func (c *client) call(t *testing.T, method string, params any) map[string]any {
	t.Helper()
	res, errMsg := c.callRaw(t, method, params)
	if errMsg != "" {
		t.Fatalf("%s: unexpected error: %s", method, errMsg)
	}
	return res
}

func (c *client) callErr(t *testing.T, method string, params any) string {
	t.Helper()
	_, errMsg := c.callRaw(t, method, params)
	if errMsg == "" {
		t.Fatalf("%s: expected error, got success", method)
	}
	return errMsg
}

func (c *client) callRaw(t *testing.T, method string, params any) (map[string]any, string) {
	t.Helper()
	c.next++
	req := map[string]any{"jsonrpc": "2.0", "id": c.next, "method": method}
	if params != nil {
		req["params"] = params
	}
	data, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.in.Write(append(data, '\n')); err != nil {
		t.Fatal(err)
	}
	if !c.out.Scan() {
		t.Fatalf("%s: no response: %v", method, c.out.Err())
	}
	var resp struct {
		ID     int            `json:"id"`
		Result map[string]any `json:"result"`
		Error  *rpcError      `json:"error"`
	}
	if err := json.Unmarshal(c.out.Bytes(), &resp); err != nil {
		t.Fatalf("%s: bad response %q: %v", method, c.out.Text(), err)
	}
	if resp.ID != c.next {
		t.Fatalf("%s: response id %d, want %d", method, resp.ID, c.next)
	}
	if resp.Error != nil {
		return nil, resp.Error.Message
	}
	return resp.Result, ""
}

func sqliteConfig(t *testing.T) *config.Config {
	t.Helper()
	dir := t.TempDir()
	toml := fmt.Sprintf("[[servers]]\nname = \"testdb\"\nadapter = \"sqlite\"\npath = %q\n", filepath.Join(dir, "test.db"))
	path := filepath.Join(dir, "connections.toml")
	if err := os.WriteFile(path, []byte(toml), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

func TestSQLiteEndToEnd(t *testing.T) {
	c := newClient(t, sqliteConfig(t))

	res := c.call(t, "ping", nil)
	if res["ok"] != true {
		t.Fatalf("ping: %v", res)
	}

	res = c.call(t, "connections.active", nil)
	if n := len(res["connections"].([]any)); n != 0 {
		t.Fatalf("connections.active before connect: %d entries", n)
	}

	res = c.call(t, "connect", map[string]any{"server": "testdb"})
	connID, _ := res["id"].(string)
	if connID != "testdb/main" {
		t.Fatalf("connect: got id %q", connID)
	}

	res = c.call(t, "connections.active", nil)
	active := res["connections"].([]any)
	if len(active) != 1 || active[0].(map[string]any)["id"] != connID {
		t.Fatalf("connections.active: %v", active)
	}

	c.call(t, "query", map[string]any{"id": connID,
		"sql": "CREATE TABLE users (id integer primary key, name text not null, age int)"})

	res = c.call(t, "query", map[string]any{"id": connID,
		"sql": "INSERT INTO users (name, age) VALUES ('alice', 30), ('bob', NULL)"})
	if res["rows_affected"].(float64) != 2 {
		t.Fatalf("insert: rows_affected = %v", res["rows_affected"])
	}

	res = c.call(t, "query", map[string]any{"id": connID, "sql": "SELECT * FROM users ORDER BY id"})
	rows := res["rows"].([]any)
	if len(rows) != 2 {
		t.Fatalf("select: %d rows", len(rows))
	}
	row0 := rows[0].([]any)
	if row0[1] != "alice" || row0[2].(float64) != 30 {
		t.Fatalf("select row0: %v", row0)
	}
	if rows[1].([]any)[2] != nil {
		t.Fatalf("select row1: NULL not preserved: %v", rows[1])
	}

	// max_rows pagination
	res = c.call(t, "query", map[string]any{"id": connID, "sql": "SELECT * FROM users", "max_rows": 1})
	if res["more"] != true || res["row_count"].(float64) != 1 {
		t.Fatalf("pagination: more=%v count=%v", res["more"], res["row_count"])
	}

	// INSERT ... RETURNING must yield rows despite being a write
	res = c.call(t, "query", map[string]any{"id": connID,
		"sql": "INSERT INTO users (name) VALUES ('carol') RETURNING id, name"})
	if len(res["rows"].([]any)) != 1 {
		t.Fatalf("returning: %v", res["rows"])
	}

	// parameterized update — text params, NULL as JSON null
	res = c.call(t, "query", map[string]any{"id": connID,
		"sql": "UPDATE users SET age = ? WHERE name = ?", "params": []any{"31", "alice"}})
	if res["rows_affected"].(float64) != 1 {
		t.Fatalf("param update: rows_affected = %v", res["rows_affected"])
	}
	res = c.call(t, "query", map[string]any{"id": connID,
		"sql": "SELECT age FROM users WHERE name = ?", "params": []any{"alice"}})
	if res["rows"].([]any)[0].([]any)[0].(float64) != 31 {
		t.Fatalf("param update not applied: %v", res["rows"])
	}
	res = c.call(t, "query", map[string]any{"id": connID,
		"sql": "UPDATE users SET age = ? WHERE name = ?", "params": []any{nil, "alice"}})
	if res["rows_affected"].(float64) != 1 {
		t.Fatalf("null param update: %v", res["rows_affected"])
	}
	// non-string params rejected
	c.callErr(t, "query", map[string]any{"id": connID,
		"sql": "SELECT ?", "params": []any{42}})

	res = c.call(t, "objects", map[string]any{"id": connID})
	objs := res["objects"].([]any)
	if len(objs) != 1 {
		t.Fatalf("objects: %v", objs)
	}
	obj := objs[0].(map[string]any)
	if obj["name"] != "users" || obj["type"] != "table" || obj["schema"] != "main" {
		t.Fatalf("objects[0]: %v", obj)
	}

	res = c.call(t, "columns", map[string]any{"id": connID, "schema": "main", "table": "users"})
	cols := res["columns"].([]any)
	if len(cols) != 3 {
		t.Fatalf("columns: %v", cols)
	}
	col0 := cols[0].(map[string]any)
	if col0["name"] != "id" || col0["pk"] != true {
		t.Fatalf("columns[0]: %v", col0)
	}
	col1 := cols[1].(map[string]any)
	if col1["not_null"] != true {
		t.Fatalf("columns[1]: %v", col1)
	}

	// foreign key metadata (explicit target column and implicit-pk reference)
	c.call(t, "query", map[string]any{"id": connID,
		"sql": "CREATE TABLE owners (id integer primary key, name text)"})
	c.call(t, "query", map[string]any{"id": connID,
		"sql": `CREATE TABLE dogs (id integer primary key,
		        owner_id int REFERENCES owners(id),
		        sitter_id int REFERENCES owners)`})
	res = c.call(t, "columns", map[string]any{"id": connID, "schema": "main", "table": "dogs"})
	fkByName := map[string]map[string]any{}
	for _, raw := range res["columns"].([]any) {
		col := raw.(map[string]any)
		if fk, ok := col["fk"].(map[string]any); ok {
			fkByName[col["name"].(string)] = fk
		}
	}
	for _, name := range []string{"owner_id", "sitter_id"} {
		fk := fkByName[name]
		if fk == nil || fk["table"] != "owners" || fk["column"] != "id" || fk["schema"] != "main" {
			t.Fatalf("fk on %s: %v", name, fk)
		}
	}
	if len(fkByName) != 2 {
		t.Fatalf("unexpected fks: %v", fkByName)
	}

	// batch: per-statement rows_affected, all-or-nothing transaction
	res = c.call(t, "batch", map[string]any{"id": connID, "statements": []any{
		map[string]any{"sql": "UPDATE users SET age = ? WHERE name = ?", "params": []any{"40", "alice"}},
		map[string]any{"sql": "UPDATE users SET age = ? WHERE name = ?", "params": []any{"41", "bob"}},
	}})
	counts := res["rows_affected"].([]any)
	if len(counts) != 2 || counts[0].(float64) != 1 || counts[1].(float64) != 1 {
		t.Fatalf("batch: rows_affected = %v", counts)
	}
	res = c.call(t, "query", map[string]any{"id": connID, "sql": "SELECT age FROM users WHERE name = 'bob'"})
	if res["rows"].([]any)[0].([]any)[0].(float64) != 41 {
		t.Fatalf("batch not applied: %v", res["rows"])
	}
	// second statement fails -> first must be rolled back
	c.callErr(t, "batch", map[string]any{"id": connID, "statements": []any{
		map[string]any{"sql": "UPDATE users SET age = ? WHERE name = ?", "params": []any{"99", "alice"}},
		map[string]any{"sql": "UPDATE nope SET x = 1"},
	}})
	res = c.call(t, "query", map[string]any{"id": connID, "sql": "SELECT age FROM users WHERE name = 'alice'"})
	if res["rows"].([]any)[0].([]any)[0].(float64) != 40 {
		t.Fatalf("batch rollback failed: %v", res["rows"])
	}
	// non-string params rejected
	c.callErr(t, "batch", map[string]any{"id": connID, "statements": []any{
		map[string]any{"sql": "SELECT ?", "params": []any{42}},
	}})

	// bad SQL surfaces as rpc error, not a dead server
	c.callErr(t, "query", map[string]any{"id": connID, "sql": "SELEC nope"})
	// unknown connection
	c.callErr(t, "query", map[string]any{"id": "nope/main", "sql": "SELECT 1"})

	c.call(t, "disconnect", map[string]any{"id": connID})
	c.callErr(t, "query", map[string]any{"id": connID, "sql": "SELECT 1"})

	res = c.call(t, "connections.active", nil)
	if n := len(res["connections"].([]any)); n != 0 {
		t.Fatalf("connections.active after disconnect: %d entries", n)
	}
}

func TestSQLiteScriptAndTransactions(t *testing.T) {
	c := newClient(t, sqliteConfig(t))
	res := c.call(t, "connect", map[string]any{"server": "testdb"})
	connID := res["id"].(string)
	age := func() float64 {
		t.Helper()
		r := c.call(t, "query", map[string]any{"id": connID, "sql": "SELECT age FROM users WHERE name = 'alice'"})
		return r["rows"].([]any)[0].([]any)[0].(float64)
	}

	// script: statements run in order, every result comes back, no tx afterwards
	res = c.call(t, "script", map[string]any{"id": connID, "sql": `
		CREATE TABLE users (id integer primary key, name text, age int);
		INSERT INTO users (name, age) VALUES ('alice', 30), ('bob', 40); -- seed
		SELECT name FROM users ORDER BY id;`})
	results := res["results"].([]any)
	if len(results) != 3 || res["failed"] != nil || res["tx"] != false {
		t.Fatalf("script: %v", res)
	}
	if results[1].(map[string]any)["rows_affected"].(float64) != 2 {
		t.Fatalf("script insert: %v", results[1])
	}
	last := results[2].(map[string]any)
	if len(last["rows"].([]any)) != 2 || last["sql"] != "SELECT name FROM users ORDER BY id" {
		t.Fatalf("script select: %v", last)
	}

	// failure mid-script: earlier results kept, failed carries index + message
	res = c.call(t, "script", map[string]any{"id": connID,
		"sql": "SELECT 1 AS a; SELEC nope; SELECT 2"})
	failed := res["failed"].(map[string]any)
	if len(res["results"].([]any)) != 1 || failed["index"].(float64) != 2 || failed["sql"] != "SELEC nope" || failed["message"] == "" {
		t.Fatalf("script failure: %v", res)
	}

	// explicit begin/commit/rollback
	if r := c.call(t, "begin", map[string]any{"id": connID}); r["tx"] != true {
		t.Fatalf("begin: %v", r)
	}
	c.callErr(t, "begin", map[string]any{"id": connID})
	res = c.call(t, "query", map[string]any{"id": connID, "sql": "UPDATE users SET age = 31 WHERE name = 'alice'"})
	if res["tx"] != true || age() != 31 {
		t.Fatalf("update in tx: %v", res)
	}
	if r := c.call(t, "rollback", map[string]any{"id": connID}); r["tx"] != false {
		t.Fatalf("rollback: %v", r)
	}
	if age() != 30 {
		t.Fatalf("rollback not applied: %v", age())
	}
	c.callErr(t, "commit", map[string]any{"id": connID})
	c.callErr(t, "rollback", map[string]any{"id": connID})

	c.call(t, "begin", map[string]any{"id": connID})
	c.call(t, "query", map[string]any{"id": connID, "sql": "UPDATE users SET age = 32 WHERE name = 'alice'"})
	// batch inside an open transaction: savepoint, failure leaves the outer tx intact
	res = c.call(t, "batch", map[string]any{"id": connID, "statements": []any{
		map[string]any{"sql": "UPDATE users SET age = ? WHERE name = ?", "params": []any{"50", "bob"}},
	}})
	if res["tx"] != true {
		t.Fatalf("batch in tx: %v", res)
	}
	c.callErr(t, "batch", map[string]any{"id": connID, "statements": []any{
		map[string]any{"sql": "UPDATE users SET age = ? WHERE name = ?", "params": []any{"99", "alice"}},
		map[string]any{"sql": "UPDATE nope SET x = 1"},
	}})
	if age() != 32 {
		t.Fatalf("savepoint rollback: %v", age())
	}
	if r := c.call(t, "commit", map[string]any{"id": connID}); r["tx"] != false {
		t.Fatalf("commit: %v", r)
	}
	if age() != 32 {
		t.Fatalf("commit not applied: %v", age())
	}
	res = c.call(t, "query", map[string]any{"id": connID, "sql": "SELECT age FROM users WHERE name = 'bob'"})
	if res["rows"].([]any)[0].([]any)[0].(float64) != 50 {
		t.Fatalf("batch in tx not committed: %v", res["rows"])
	}

	// BEGIN typed in a script leaves the transaction open for later calls
	res = c.call(t, "script", map[string]any{"id": connID,
		"sql": "BEGIN; UPDATE users SET age = 33 WHERE name = 'alice';"})
	if res["tx"] != true {
		t.Fatalf("script begin: %v", res)
	}
	res = c.call(t, "query", map[string]any{"id": connID, "sql": "COMMIT"})
	if res["tx"] != false || age() != 33 {
		t.Fatalf("typed commit: %v age=%v", res, age())
	}

	// disconnect with an open transaction rolls it back
	c.call(t, "begin", map[string]any{"id": connID})
	c.call(t, "query", map[string]any{"id": connID, "sql": "UPDATE users SET age = 99 WHERE name = 'alice'"})
	c.call(t, "disconnect", map[string]any{"id": connID})
	c.call(t, "connect", map[string]any{"server": "testdb"})
	if age() != 33 {
		t.Fatalf("disconnect did not roll back: %v", age())
	}
}

func TestConnectionsListEmptyConfig(t *testing.T) {
	cfg, err := config.Load(filepath.Join(t.TempDir(), "missing.toml"))
	if err != nil {
		t.Fatal(err)
	}
	c := newClient(t, cfg)
	res := c.call(t, "connections.list", nil)
	if res["config_path"] == "" {
		t.Fatal("config_path missing")
	}
}

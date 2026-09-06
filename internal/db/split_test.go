package db

import (
	"reflect"
	"testing"
)

func TestSplitStatements(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want []string
	}{
		{"single", "SELECT 1", []string{"SELECT 1"}},
		{"trailing semicolon", "SELECT 1;", []string{"SELECT 1"}},
		{"two", "SELECT 1; SELECT 2;", []string{"SELECT 1", "SELECT 2"}},
		{"empty pieces", ";;  SELECT 1 ;; ", []string{"SELECT 1"}},
		{"semicolon in string", "SELECT 'a;b'; SELECT 2", []string{"SELECT 'a;b'", "SELECT 2"}},
		{"doubled quote", "SELECT 'it''s;'; SELECT 2", []string{"SELECT 'it''s;'", "SELECT 2"}},
		{"escape string", `SELECT E'\';'; SELECT 2`, []string{`SELECT E'\';'`, "SELECT 2"}},
		{"double quoted ident", `SELECT "a;b" FROM t; SELECT 2`, []string{`SELECT "a;b" FROM t`, "SELECT 2"}},
		{"line comment", "SELECT 1; -- done; really\nSELECT 2", []string{"SELECT 1", "SELECT 2"}},
		{"leading block comment", "/* head */ SELECT 1 /* tail */; SELECT 2", []string{"SELECT 1 /* tail */", "SELECT 2"}},
		{"trailing comment only", "SELECT 1;\n-- the end", []string{"SELECT 1"}},
		{"block comment", "SELECT /* a; b */ 1; SELECT 2", []string{"SELECT /* a; b */ 1", "SELECT 2"}},
		{"nested block comment", "SELECT /* a /* ; */ ; */ 1; SELECT 2", []string{"SELECT /* a /* ; */ ; */ 1", "SELECT 2"}},
		{"dollar quote", "CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql; SELECT f()",
			[]string{"CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql", "SELECT f()"}},
		{"tagged dollar quote", "SELECT $x$ a; $$ b $x$; SELECT 2", []string{"SELECT $x$ a; $$ b $x$", "SELECT 2"}},
		{"positional param is no tag", "SELECT $1; SELECT $2", []string{"SELECT $1", "SELECT $2"}},
		{"sqlite trigger body", "CREATE TRIGGER tr AFTER INSERT ON t BEGIN UPDATE t SET a = 1; DELETE FROM u; END; SELECT 1",
			[]string{"CREATE TRIGGER tr AFTER INSERT ON t BEGIN UPDATE t SET a = 1; DELETE FROM u; END", "SELECT 1"}},
		{"trigger body with case", "CREATE TRIGGER tr BEFORE UPDATE ON t BEGIN SELECT CASE WHEN 1 THEN RAISE(ABORT, 'x;') END; END; SELECT 1",
			[]string{"CREATE TRIGGER tr BEFORE UPDATE ON t BEGIN SELECT CASE WHEN 1 THEN RAISE(ABORT, 'x;') END; END", "SELECT 1"}},
		{"pg trigger without body", "CREATE TRIGGER tr AFTER INSERT ON t EXECUTE FUNCTION f(); SELECT 1",
			[]string{"CREATE TRIGGER tr AFTER INSERT ON t EXECUTE FUNCTION f()", "SELECT 1"}},
		{"begin atomic", "CREATE FUNCTION f() RETURNS void LANGUAGE sql BEGIN ATOMIC UPDATE t SET a = 1; END; SELECT 1",
			[]string{"CREATE FUNCTION f() RETURNS void LANGUAGE sql BEGIN ATOMIC UPDATE t SET a = 1; END", "SELECT 1"}},
		{"case outside body", "CREATE VIEW v AS SELECT CASE WHEN a THEN 1 END FROM t; SELECT 1",
			[]string{"CREATE VIEW v AS SELECT CASE WHEN a THEN 1 END FROM t", "SELECT 1"}},
		{"transaction words", "BEGIN; UPDATE t SET a = 1; COMMIT", []string{"BEGIN", "UPDATE t SET a = 1", "COMMIT"}},
		{"bracket ident", "SELECT [a;b] FROM t; SELECT 2", []string{"SELECT [a;b] FROM t", "SELECT 2"}},
		{"unterminated string swallows rest", "SELECT 'a; SELECT 2", []string{"SELECT 'a; SELECT 2"}},
		{"only comments", "-- nothing\n/* here */", nil},
	}
	for _, c := range cases {
		got := SplitStatements(c.in)
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

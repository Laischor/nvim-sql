package db

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"

	"github.com/Laischor/nvim-sql/internal/config"
)

type SQLiteConn struct {
	db *sql.DB

	mu sync.Mutex // one connection, one statement at a time
	tx *sql.Conn  // session held while a transaction is open
}

type sqlQuerier interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

var rollbackToRe = regexp.MustCompile(`(?i)^\s*rollback\s+(transaction\s+)?to\b`)

// sqlite has no autocommit probe: transaction state follows the statements' first word.
func opensTx(word string) bool { return word == "begin" || word == "savepoint" }

func closesTx(word, sqlText string) bool {
	switch word {
	case "commit", "end":
		return true
	case "rollback":
		return !rollbackToRe.MatchString(sqlText)
	}
	return false
}

func firstWord(sqlText string) string {
	m := firstWordRe.FindStringSubmatch(sqlText)
	if m == nil {
		return ""
	}
	return strings.ToLower(m[1])
}

// session picks the querier for one statement (mu held); a BEGIN pins a dedicated connection first.
func (c *SQLiteConn) session(ctx context.Context, sqlText string) (sqlQuerier, error) {
	if c.tx != nil {
		return c.tx, nil
	}
	if !opensTx(firstWord(sqlText)) {
		return c.db, nil
	}
	conn, err := c.db.Conn(ctx)
	if err != nil {
		return nil, err
	}
	c.tx = conn
	return conn, nil
}

// settle drops the session once a statement ended the transaction (mu held).
func (c *SQLiteConn) settle(sqlText string, err error) {
	if c.tx == nil {
		return
	}
	word := firstWord(sqlText)
	ended := err == nil && closesTx(word, sqlText)
	if err != nil && (opensTx(word) || strings.Contains(err.Error(), "no transaction is active")) {
		ended = true
	}
	if ended {
		c.tx.Close()
		c.tx = nil
	}
}

func (c *SQLiteConn) InTx() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.tx != nil
}

func (c *SQLiteConn) Begin(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.tx != nil {
		return ErrInTx
	}
	_, err := c.exec(ctx, "BEGIN", nil, 0)
	return err
}

func (c *SQLiteConn) Commit(ctx context.Context) error {
	return c.finish(ctx, "COMMIT")
}

func (c *SQLiteConn) Rollback(ctx context.Context) error {
	return c.finish(ctx, "ROLLBACK")
}

func (c *SQLiteConn) finish(ctx context.Context, stmt string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.tx == nil {
		return ErrNoTx
	}
	_, err := c.exec(ctx, stmt, nil, 0)
	return err
}

func SQLiteConnect(ctx context.Context, s *config.Server) (*SQLiteConn, error) {
	dsn := "file:" + s.Path
	if s.ReadOnly {
		dsn += "?" + url.Values{"mode": {"ro"}}.Encode()
	}
	d, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	d.SetMaxOpenConns(1) // avoid SQLITE_BUSY between concurrent statements
	if err := d.PingContext(ctx); err != nil {
		d.Close()
		return nil, err
	}
	return &SQLiteConn{db: d}, nil
}

func (c *SQLiteConn) Close() {
	c.mu.Lock()
	if c.tx != nil {
		c.tx.Close()
		c.tx = nil
	}
	c.mu.Unlock()
	c.db.Close()
}

var (
	firstWordRe = regexp.MustCompile(`(?is)^\s*(?:--[^\n]*\n\s*|/\*.*?\*/\s*)*([a-z]+)`)
	returningRe = regexp.MustCompile(`(?i)\breturning\b`)
)

// returnsRows decides Query vs Exec: writes need Exec for RowsAffected, RETURNING needs Query.
func returnsRows(sqlText string) bool {
	m := firstWordRe.FindStringSubmatch(sqlText)
	if m == nil {
		return true
	}
	switch strings.ToLower(m[1]) {
	case "select", "with", "values", "explain", "pragma":
		return true
	}
	return returningRe.MatchString(sqlText)
}

func (c *SQLiteConn) Query(ctx context.Context, sqlText string, params []any, maxRows int) (*Result, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.exec(ctx, sqlText, params, maxRows)
}

func (c *SQLiteConn) Script(ctx context.Context, sqlText string, maxRows int) (*ScriptResult, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return runScript(ctx, sqlText, maxRows, func(ctx context.Context, sql string, maxRows int) (*Result, error) {
		return c.exec(ctx, sql, nil, maxRows)
	}), nil
}

// exec runs one statement on the session and tracks the transaction state (mu held).
func (c *SQLiteConn) exec(ctx context.Context, sqlText string, params []any, maxRows int) (*Result, error) {
	q, err := c.session(ctx, sqlText)
	if err != nil {
		return nil, err
	}
	res, err := sqliteQuery(ctx, q, sqlText, params, maxRows)
	c.settle(sqlText, err)
	return res, err
}

func sqliteQuery(ctx context.Context, q sqlQuerier, sqlText string, params []any, maxRows int) (*Result, error) {
	start := time.Now()
	if !returnsRows(sqlText) {
		r, err := q.ExecContext(ctx, sqlText, params...)
		if err != nil {
			return nil, err
		}
		affected, _ := r.RowsAffected()
		return &Result{
			Columns:      []ColumnMeta{},
			Rows:         [][]any{},
			RowsAffected: affected,
			DurationMS:   time.Since(start).Milliseconds(),
		}, nil
	}

	rows, err := q.QueryContext(ctx, sqlText, params...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	names, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	res := &Result{Columns: make([]ColumnMeta, len(names)), Rows: [][]any{}}
	types, _ := rows.ColumnTypes()
	for i, name := range names {
		typeName := ""
		if types != nil {
			typeName = strings.ToLower(types[i].DatabaseTypeName())
		}
		res.Columns[i] = ColumnMeta{Name: name, Type: typeName}
	}

	vals := make([]any, len(names))
	ptrs := make([]any, len(names))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	for rows.Next() {
		if len(res.Rows) >= maxRows {
			res.More = true
			break
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		row := make([]any, len(vals))
		for i, v := range vals {
			row[i] = Normalize(v)
		}
		res.Rows = append(res.Rows, row)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	res.RowCount = len(res.Rows)
	res.DurationMS = time.Since(start).Milliseconds()
	return res, nil
}

func (c *SQLiteConn) Batch(ctx context.Context, stmts []Statement) ([]int64, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.tx != nil {
		return sqliteBatch(ctx, c.tx, stmts, "SAVEPOINT sqledit_batch", "ROLLBACK TO SAVEPOINT sqledit_batch", "RELEASE SAVEPOINT sqledit_batch")
	}
	conn, err := c.db.Conn(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	return sqliteBatch(ctx, conn, stmts, "BEGIN", "ROLLBACK", "COMMIT")
}

func sqliteBatch(ctx context.Context, q sqlQuerier, stmts []Statement, begin, rollback, commit string) ([]int64, error) {
	if _, err := q.ExecContext(ctx, begin); err != nil {
		return nil, err
	}
	affected := make([]int64, len(stmts))
	for i, st := range stmts {
		res, err := q.ExecContext(ctx, st.SQL, st.Params...)
		if err != nil {
			q.ExecContext(ctx, rollback)
			return nil, fmt.Errorf("statement %d: %w", i+1, err)
		}
		affected[i], _ = res.RowsAffected()
	}
	if _, err := q.ExecContext(ctx, commit); err != nil {
		q.ExecContext(ctx, rollback)
		return nil, err
	}
	return affected, nil
}

// q is the querier for metadata calls (mu held).
func (c *SQLiteConn) q() sqlQuerier {
	if c.tx != nil {
		return c.tx
	}
	return c.db
}

func (c *SQLiteConn) Objects(ctx context.Context) ([]Object, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	rows, err := c.q().QueryContext(ctx, `
		SELECT name, type FROM sqlite_master
		WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'
		ORDER BY type, name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var objs []Object
	for rows.Next() {
		var o Object
		o.Schema = "main"
		if err := rows.Scan(&o.Name, &o.Type); err != nil {
			return nil, err
		}
		objs = append(objs, o)
	}
	return objs, rows.Err()
}

func (c *SQLiteConn) Columns(ctx context.Context, schema, table string) ([]Column, error) {
	if schema != "" && schema != "main" {
		return nil, fmt.Errorf("sqlite: unknown schema %q", schema)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	rows, err := c.q().QueryContext(ctx,
		`SELECT name, type, "notnull", pk FROM pragma_table_info(?) ORDER BY cid`, table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var cols []Column
	for rows.Next() {
		var col Column
		var notnull, pk int
		if err := rows.Scan(&col.Name, &col.Type, &notnull, &pk); err != nil {
			return nil, err
		}
		col.Type = strings.ToLower(col.Type)
		col.NotNull = notnull != 0
		col.PK = pk != 0
		cols = append(cols, col)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	fks, err := c.foreignKeys(ctx, table)
	if err != nil {
		return nil, err
	}
	for i := range cols {
		if fk, ok := fks[cols[i].Name]; ok {
			cols[i].FK = fk
		}
	}
	return cols, nil
}

// foreignKeys returns single-column FKs as from-column -> target (mu held).
func (c *SQLiteConn) foreignKeys(ctx context.Context, table string) (map[string]*FKRef, error) {
	rows, err := c.q().QueryContext(ctx,
		`SELECT id, "table", "from", "to" FROM pragma_foreign_key_list(?) ORDER BY id, seq`, table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	type entry struct {
		count int
		from  string
		ref   FKRef
	}
	byID := map[int]*entry{}
	var order []int
	for rows.Next() {
		var id int
		var target, from string
		var to sql.NullString
		if err := rows.Scan(&id, &target, &from, &to); err != nil {
			return nil, err
		}
		e := byID[id]
		if e == nil {
			e = &entry{}
			byID[id] = e
			order = append(order, id)
		}
		e.count++
		e.from = from
		e.ref = FKRef{Schema: "main", Table: target, Column: to.String}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	fks := map[string]*FKRef{}
	for _, id := range order {
		e := byID[id]
		if e.count != 1 { // composite FK — no single cell to jump from
			continue
		}
		if e.ref.Column == "" {
			// implicit reference to the target's primary key
			pk, err := c.primaryKeyColumn(ctx, e.ref.Table)
			if err != nil || pk == "" {
				continue
			}
			e.ref.Column = pk
		}
		ref := e.ref
		fks[e.from] = &ref
	}
	return fks, nil
}

func (c *SQLiteConn) primaryKeyColumn(ctx context.Context, table string) (string, error) {
	var name string
	err := c.q().QueryRowContext(ctx,
		`SELECT name FROM pragma_table_info(?) WHERE pk = 1`, table).Scan(&name)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return name, err
}

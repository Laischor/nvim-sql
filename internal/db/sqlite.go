package db

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"github.com/Laischor/nvim-sql/internal/config"
)

type SQLiteConn struct {
	db *sql.DB
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

func (c *SQLiteConn) Close() { c.db.Close() }

var (
	firstWordRe = regexp.MustCompile(`(?is)^\s*(?:--[^\n]*\n\s*|/\*.*?\*/\s*)*([a-z]+)`)
	returningRe = regexp.MustCompile(`(?i)\breturning\b`)
)

// returnsRows decides Query vs Exec: database/sql needs Exec for writes to
// report RowsAffected, but statements with RETURNING must go through Query.
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
	start := time.Now()
	if !returnsRows(sqlText) {
		r, err := c.db.ExecContext(ctx, sqlText, params...)
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

	rows, err := c.db.QueryContext(ctx, sqlText, params...)
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
	tx, err := c.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	affected := make([]int64, len(stmts))
	for i, st := range stmts {
		res, err := tx.ExecContext(ctx, st.SQL, st.Params...)
		if err != nil {
			return nil, fmt.Errorf("statement %d: %w", i+1, err)
		}
		affected[i], _ = res.RowsAffected()
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return affected, nil
}

func (c *SQLiteConn) Objects(ctx context.Context) ([]Object, error) {
	rows, err := c.db.QueryContext(ctx, `
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
	rows, err := c.db.QueryContext(ctx,
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

// foreignKeys returns single-column FKs as from-column -> target.
func (c *SQLiteConn) foreignKeys(ctx context.Context, table string) (map[string]*FKRef, error) {
	rows, err := c.db.QueryContext(ctx,
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
	err := c.db.QueryRowContext(ctx,
		`SELECT name FROM pragma_table_info(?) WHERE pk = 1`, table).Scan(&name)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return name, err
}

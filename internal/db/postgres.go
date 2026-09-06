package db

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Laischor/nvim-sql/internal/config"
)

type PGConn struct {
	pool *pgxpool.Pool

	mu sync.Mutex
	tx *pgxpool.Conn // session held while a transaction is open
}

type pgQuerier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

func pgInTx(conn *pgxpool.Conn) bool {
	return conn.Conn().PgConn().TxStatus() != 'I'
}

// acquire hands out the transaction session (serialized) or a fresh pool connection; release must follow.
func (c *PGConn) acquire(ctx context.Context) (*pgxpool.Conn, func(), error) {
	c.mu.Lock()
	if c.tx != nil {
		return c.tx, c.releaseSession, nil
	}
	c.mu.Unlock()
	conn, err := c.pool.Acquire(ctx)
	if err != nil {
		return nil, nil, err
	}
	return conn, func() { c.releaseFresh(conn) }, nil
}

func (c *PGConn) releaseSession() {
	if !pgInTx(c.tx) {
		c.tx.Release()
		c.tx = nil
	}
	c.mu.Unlock()
}

// releaseFresh keeps the connection as session when a statement opened a transaction on it.
func (c *PGConn) releaseFresh(conn *pgxpool.Conn) {
	if !pgInTx(conn) {
		conn.Release()
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.tx != nil {
		conn.Release() // pool destroys a connection mid-transaction: implicit rollback
		return
	}
	c.tx = conn
}

func (c *PGConn) InTx() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.tx != nil
}

func (c *PGConn) Begin(ctx context.Context) error {
	conn, release, err := c.acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	if pgInTx(conn) {
		return ErrInTx
	}
	_, err = conn.Exec(ctx, "BEGIN")
	return err
}

func (c *PGConn) Commit(ctx context.Context) error {
	return c.finish(ctx, "COMMIT")
}

func (c *PGConn) Rollback(ctx context.Context) error {
	return c.finish(ctx, "ROLLBACK")
}

func (c *PGConn) finish(ctx context.Context, stmt string) error {
	conn, release, err := c.acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	if !pgInTx(conn) {
		return ErrNoTx
	}
	tag, err := conn.Exec(ctx, stmt)
	if err != nil {
		return err
	}
	if stmt == "COMMIT" && tag.String() == "ROLLBACK" {
		return TxWarning("transaction was aborted by an earlier error — rolled back instead")
	}
	return nil
}

func pgConnString(s *config.Server, database string) (string, error) {
	password, err := s.ResolvePassword()
	if err != nil {
		return "", err
	}
	u := &url.URL{
		Scheme: "postgres",
		Host:   net.JoinHostPort(s.Host, strconv.Itoa(s.Port)),
		Path:   "/" + database,
	}
	if s.User != "" {
		if password != "" {
			u.User = url.UserPassword(s.User, password)
		} else {
			u.User = url.User(s.User)
		}
	}
	q := url.Values{}
	if s.SSLMode != "" {
		q.Set("sslmode", s.SSLMode)
	}
	for k, v := range s.Params {
		q.Set(k, v)
	}
	if s.ReadOnly {
		q.Set("options", "-c default_transaction_read_only=on")
	}
	u.RawQuery = q.Encode()
	return u.String(), nil
}

// PGListDatabases lists connectable databases via the maintenance database.
func PGListDatabases(ctx context.Context, s *config.Server) ([]string, error) {
	connStr, err := pgConnString(s, s.Database)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	conn, err := pgx.Connect(ctx, connStr)
	if err != nil {
		return nil, err
	}
	defer conn.Close(ctx)
	rows, err := conn.Query(ctx,
		`SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

func PGConnect(ctx context.Context, s *config.Server, database string) (*PGConn, error) {
	connStr, err := pgConnString(s, database)
	if err != nil {
		return nil, err
	}
	cfg, err := pgxpool.ParseConfig(connStr)
	if err != nil {
		return nil, err
	}
	cfg.MaxConns = 4
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	pingCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, err
	}
	return &PGConn{pool: pool}, nil
}

func (c *PGConn) Close() {
	c.mu.Lock()
	if c.tx != nil {
		c.tx.Release()
		c.tx = nil
	}
	c.mu.Unlock()
	c.pool.Close()
}

func (c *PGConn) Query(ctx context.Context, sqlText string, params []any, maxRows int) (*Result, error) {
	conn, release, err := c.acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer release()
	return pgQuery(ctx, conn, sqlText, params, maxRows)
}

func (c *PGConn) Script(ctx context.Context, sqlText string, maxRows int) (*ScriptResult, error) {
	conn, release, err := c.acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer release()
	return runScript(ctx, sqlText, maxRows, func(ctx context.Context, sql string, maxRows int) (*Result, error) {
		return pgQuery(ctx, conn, sql, nil, maxRows)
	}), nil
}

func pgQuery(ctx context.Context, q pgQuerier, sqlText string, params []any, maxRows int) (*Result, error) {
	start := time.Now()
	rows, err := q.Query(ctx, sqlText, params...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	typeMap := rows.Conn().TypeMap()
	flds := rows.FieldDescriptions()
	res := &Result{Columns: make([]ColumnMeta, len(flds)), Rows: [][]any{}}
	for i, fd := range flds {
		typeName := fmt.Sprintf("oid %d", fd.DataTypeOID)
		if t, ok := typeMap.TypeForOID(fd.DataTypeOID); ok {
			typeName = t.Name
		}
		res.Columns[i] = ColumnMeta{Name: fd.Name, Type: typeName}
	}

	for rows.Next() {
		if len(res.Rows) >= maxRows {
			res.More = true
			break
		}
		vals, err := rows.Values()
		if err != nil {
			return nil, err
		}
		row := make([]any, len(vals))
		for i, v := range vals {
			row[i] = Normalize(v)
		}
		res.Rows = append(res.Rows, row)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if !res.More {
		res.RowsAffected = rows.CommandTag().RowsAffected()
	}
	res.RowCount = len(res.Rows)
	res.DurationMS = time.Since(start).Milliseconds()
	return res, nil
}

func (c *PGConn) Batch(ctx context.Context, stmts []Statement) ([]int64, error) {
	conn, release, err := c.acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer release()
	begin, rollback, commit := "BEGIN", "ROLLBACK", "COMMIT"
	if pgInTx(conn) {
		begin, rollback, commit = "SAVEPOINT sqledit_batch", "ROLLBACK TO SAVEPOINT sqledit_batch", "RELEASE SAVEPOINT sqledit_batch"
	}
	if _, err := conn.Exec(ctx, begin); err != nil {
		return nil, err
	}
	affected := make([]int64, len(stmts))
	for i, st := range stmts {
		tag, err := conn.Exec(ctx, st.SQL, st.Params...)
		if err != nil {
			conn.Exec(ctx, rollback)
			return nil, fmt.Errorf("statement %d: %w", i+1, err)
		}
		affected[i] = tag.RowsAffected()
	}
	if _, err := conn.Exec(ctx, commit); err != nil {
		conn.Exec(ctx, rollback)
		return nil, err
	}
	return affected, nil
}

func (c *PGConn) Objects(ctx context.Context) ([]Object, error) {
	conn, release, err := c.acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer release()
	rows, err := conn.Query(ctx, `
		SELECT n.nspname, c.relname,
		       CASE c.relkind
		         WHEN 'r' THEN 'table' WHEN 'p' THEN 'table'
		         WHEN 'v' THEN 'view'  WHEN 'm' THEN 'matview'
		         WHEN 'f' THEN 'foreign' END
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE c.relkind IN ('r','p','v','m','f')
		  AND n.nspname NOT IN ('pg_catalog','information_schema')
		  AND n.nspname NOT LIKE 'pg_toast%'
		  AND n.nspname NOT LIKE 'pg_temp%'
		ORDER BY n.nspname, c.relname`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Object])
}

func (c *PGConn) Columns(ctx context.Context, schema, table string) ([]Column, error) {
	conn, release, err := c.acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer release()
	rows, err := conn.Query(ctx, `
		SELECT a.attname,
		       pg_catalog.format_type(a.atttypid, a.atttypmod),
		       a.attnotnull,
		       EXISTS (SELECT 1 FROM pg_constraint ct
		               WHERE ct.conrelid = c.oid AND ct.contype = 'p'
		                 AND a.attnum = ANY (ct.conkey)) AS pk
		FROM pg_attribute a
		JOIN pg_class c ON c.oid = a.attrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = $1 AND c.relname = $2
		  AND a.attnum > 0 AND NOT a.attisdropped
		ORDER BY a.attnum`, schema, table)
	if err != nil {
		return nil, err
	}
	cols, err := pgx.CollectRows(rows, pgx.RowToStructByPos[Column])
	if err != nil {
		return nil, err
	}

	// single-column foreign keys (composite FKs have no obvious cell to jump from)
	fkRows, err := conn.Query(ctx, `
		SELECT a.attname, fn.nspname, fc.relname, fa.attname
		FROM pg_constraint ct
		JOIN pg_class c ON c.oid = ct.conrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_class fc ON fc.oid = ct.confrelid
		JOIN pg_namespace fn ON fn.oid = fc.relnamespace
		JOIN pg_attribute a ON a.attrelid = ct.conrelid AND a.attnum = ct.conkey[1]
		JOIN pg_attribute fa ON fa.attrelid = ct.confrelid AND fa.attnum = ct.confkey[1]
		WHERE ct.contype = 'f' AND cardinality(ct.conkey) = 1
		  AND n.nspname = $1 AND c.relname = $2`, schema, table)
	if err != nil {
		return nil, err
	}
	type fkRow struct {
		Col, Schema, Table, Column string
	}
	fks, err := pgx.CollectRows(fkRows, pgx.RowToStructByPos[fkRow])
	if err != nil {
		return nil, err
	}
	for _, fk := range fks {
		for i := range cols {
			if cols[i].Name == fk.Col {
				cols[i].FK = &FKRef{Schema: fk.Schema, Table: fk.Table, Column: fk.Column}
			}
		}
	}
	return cols, nil
}

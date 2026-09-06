// Package db is the adapter interface for postgres and sqlite plus JSON-friendly result types.
package db

import (
	"context"
	"database/sql/driver"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

type Object struct {
	Schema string `json:"schema"`
	Name   string `json:"name"`
	Type   string `json:"type"` // table | view | matview | foreign
}

// FKRef is the target of a single-column foreign key.
type FKRef struct {
	Schema string `json:"schema"`
	Table  string `json:"table"`
	Column string `json:"column"`
}

type Column struct {
	Name    string `json:"name"`
	Type    string `json:"type"`
	NotNull bool   `json:"not_null"`
	PK      bool   `json:"pk"`
	// db:"-" — filled by a second query, not by the row scan
	FK *FKRef `json:"fk,omitempty" db:"-"`
}

type ColumnMeta struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type Result struct {
	Columns      []ColumnMeta `json:"columns"`
	Rows         [][]any      `json:"rows"`
	RowCount     int          `json:"row_count"`
	More         bool         `json:"more"` // true if maxRows was hit
	RowsAffected int64        `json:"rows_affected"`
	DurationMS   int64        `json:"duration_ms"`
}

// Statement is one parameterized statement of a Batch.
type Statement struct {
	SQL    string `json:"sql"`
	Params []any  `json:"params"`
}

// StatementResult is one statement of a script with its result.
type StatementResult struct {
	SQL string `json:"sql"`
	*Result
}

// StatementError is the statement a script stopped at.
type StatementError struct {
	Index   int    `json:"index"`
	SQL     string `json:"sql"`
	Message string `json:"message"`
}

// ScriptResult holds the results up to the first failure, if any.
type ScriptResult struct {
	Results []StatementResult `json:"results"`
	Failed  *StatementError   `json:"failed,omitempty"`
}

// TxWarning is a Commit/Rollback outcome the caller should know about.
type TxWarning string

func (w TxWarning) Error() string { return string(w) }

// Conn is one live connection to a specific database; an open transaction pins one session for all calls.
type Conn interface {
	// Query runs one statement; params are strings or nil, servers cast text to the column type.
	Query(ctx context.Context, sql string, params []any, maxRows int) (*Result, error)
	// Batch runs the statements atomically (own transaction, or a savepoint inside an open one).
	Batch(ctx context.Context, stmts []Statement) ([]int64, error)
	// Script splits sql into statements and runs them in order until one fails.
	Script(ctx context.Context, sql string, maxRows int) (*ScriptResult, error)
	Begin(ctx context.Context) error
	Commit(ctx context.Context) error
	Rollback(ctx context.Context) error
	InTx() bool
	Objects(ctx context.Context) ([]Object, error)
	Columns(ctx context.Context, schema, table string) ([]Column, error)
	Close()
}

// ErrNoTx / ErrInTx are the Begin/Commit/Rollback state errors.
var (
	ErrNoTx = errors.New("no transaction open")
	ErrInTx = errors.New("transaction already open")
)

func runScript(ctx context.Context, sql string, maxRows int, run func(ctx context.Context, sql string, maxRows int) (*Result, error)) *ScriptResult {
	stmts := SplitStatements(sql)
	out := &ScriptResult{Results: make([]StatementResult, 0, len(stmts))}
	for i, st := range stmts {
		res, err := run(ctx, st, maxRows)
		if err != nil {
			out.Failed = &StatementError{Index: i + 1, SQL: st, Message: err.Error()}
			break
		}
		out.Results = append(out.Results, StatementResult{SQL: st, Result: res})
	}
	return out
}

// Normalize maps a driver value to nil/bool/number/string for JSON; exotic types are stringified.
func Normalize(v any) any {
	switch t := v.(type) {
	case nil:
		return nil
	case bool, string,
		int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64,
		float32, float64:
		return v
	case time.Time:
		return t.Format("2006-01-02 15:04:05.999999999Z07:00")
	case []byte:
		return "\\x" + hex.EncodeToString(t)
	case [16]byte: // uuid
		return fmt.Sprintf("%x-%x-%x-%x-%x", t[0:4], t[4:6], t[6:8], t[8:10], t[10:16])
	}
	if dv, ok := v.(driver.Valuer); ok {
		if val, err := dv.Value(); err == nil {
			return Normalize(val)
		}
	}
	if s, ok := v.(fmt.Stringer); ok {
		return s.String()
	}
	// arrays, json columns, etc. — keep structure if it marshals
	if b, err := json.Marshal(v); err == nil {
		return json.RawMessage(b)
	}
	return fmt.Sprint(v)
}

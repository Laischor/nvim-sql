// Package db defines the adapter interface shared by the postgres and
// sqlite backends, plus JSON-friendly result types.
package db

import (
	"context"
	"database/sql/driver"
	"encoding/hex"
	"encoding/json"
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
	FK      *FKRef `json:"fk,omitempty"`
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

// Conn is one live connection to a specific database.
type Conn interface {
	// Query runs sql with optional positional params ($1… for postgres,
	// ? for sqlite). Param values are strings or nil — servers cast text
	// to the target column type.
	Query(ctx context.Context, sql string, params []any, maxRows int) (*Result, error)
	Objects(ctx context.Context) ([]Object, error)
	Columns(ctx context.Context, schema, table string) ([]Column, error)
	Close()
}

// Normalize converts a driver value into something that serializes cleanly
// to JSON: nil, bool, number, or string. Anything exotic is stringified.
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

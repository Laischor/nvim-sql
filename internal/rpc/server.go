// Package rpc implements newline-delimited JSON-RPC 2.0 over stdio.
// One request per line in, one response per line out. Requests are handled
// concurrently so a slow query never blocks a picker.
package rpc

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"sync"

	"github.com/Laischor/nvim-sql/internal/config"
	"github.com/Laischor/nvim-sql/internal/db"
)

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      any             `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type response struct {
	JSONRPC string    `json:"jsonrpc"`
	ID      any       `json:"id"`
	Result  any       `json:"result,omitempty"`
	Error   *rpcError `json:"error,omitempty"`
}

type connInfo struct {
	ID       string `json:"id"`
	Server   string `json:"server"`
	Database string `json:"database"`
	Adapter  string `json:"adapter"`
	Prod     bool   `json:"prod"`
	ReadOnly bool   `json:"readonly"`
}

type Server struct {
	cfg     *config.Config
	version string

	outMu sync.Mutex
	out   *bufio.Writer

	connMu sync.Mutex
	conns  map[string]db.Conn
	infos  map[string]connInfo
}

func NewServer(cfg *config.Config, version string) *Server {
	return &Server{
		cfg:     cfg,
		version: version,
		conns:   map[string]db.Conn{},
		infos:   map[string]connInfo{},
	}
}

func (s *Server) Serve(r io.Reader, w io.Writer) error {
	s.out = bufio.NewWriter(w)
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)

	var wg sync.WaitGroup
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var req request
		if err := json.Unmarshal(line, &req); err != nil {
			s.write(response{JSONRPC: "2.0", Error: &rpcError{Code: -32700, Message: "parse error: " + err.Error()}})
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.handle(&req)
		}()
	}
	wg.Wait()
	s.closeAll()
	return scanner.Err()
}

func (s *Server) write(resp response) {
	resp.JSONRPC = "2.0"
	data, err := json.Marshal(resp)
	if err != nil {
		data, _ = json.Marshal(response{JSONRPC: "2.0", ID: resp.ID,
			Error: &rpcError{Code: -32603, Message: "marshal error: " + err.Error()}})
	}
	s.outMu.Lock()
	defer s.outMu.Unlock()
	s.out.Write(data)
	s.out.WriteByte('\n')
	s.out.Flush()
}

func (s *Server) handle(req *request) {
	result, err := s.dispatch(req)
	if err != nil {
		s.write(response{ID: req.ID, Error: &rpcError{Code: -32000, Message: err.Error()}})
		return
	}
	s.write(response{ID: req.ID, Result: result})
}

func (s *Server) dispatch(req *request) (any, error) {
	ctx := context.Background()
	switch req.Method {
	case "ping":
		return map[string]any{"ok": true, "version": s.version}, nil

	case "connections.list":
		return map[string]any{
			"config_path": s.cfg.FilePath,
			"servers":     s.cfg.Servers,
		}, nil

	case "connections.active":
		s.connMu.Lock()
		infos := make([]connInfo, 0, len(s.infos))
		for _, info := range s.infos {
			infos = append(infos, info)
		}
		s.connMu.Unlock()
		sort.Slice(infos, func(i, j int) bool { return infos[i].ID < infos[j].ID })
		return map[string]any{"connections": infos}, nil

	case "databases.list":
		var p struct {
			Server string `json:"server"`
		}
		if err := unmarshalParams(req.Params, &p); err != nil {
			return nil, err
		}
		srv, err := s.cfg.Find(p.Server)
		if err != nil {
			return nil, err
		}
		switch srv.Adapter {
		case "sqlite":
			return map[string]any{"databases": []string{"main"}}, nil
		default:
			names, err := db.PGListDatabases(ctx, srv)
			if err != nil {
				return nil, err
			}
			return map[string]any{"databases": names}, nil
		}

	case "connect":
		var p struct {
			Server   string `json:"server"`
			Database string `json:"database"`
		}
		if err := unmarshalParams(req.Params, &p); err != nil {
			return nil, err
		}
		return s.connect(ctx, p.Server, p.Database)

	case "disconnect":
		var p struct {
			ID string `json:"id"`
		}
		if err := unmarshalParams(req.Params, &p); err != nil {
			return nil, err
		}
		s.connMu.Lock()
		defer s.connMu.Unlock()
		if c, ok := s.conns[p.ID]; ok {
			c.Close()
			delete(s.conns, p.ID)
			delete(s.infos, p.ID)
		}
		return map[string]any{"ok": true}, nil

	case "query":
		var p struct {
			ID      string `json:"id"`
			SQL     string `json:"sql"`
			MaxRows int    `json:"max_rows"`
			Params  []any  `json:"params"`
		}
		if err := unmarshalParams(req.Params, &p); err != nil {
			return nil, err
		}
		if p.MaxRows <= 0 {
			p.MaxRows = 500
		}
		// only text params: servers cast text to the column type, which
		// avoids client-side type guessing (and float64 from JSON numbers)
		for i, v := range p.Params {
			switch v.(type) {
			case string, nil:
			default:
				return nil, fmt.Errorf("param %d: must be string or null, got %T", i+1, v)
			}
		}
		conn, err := s.conn(p.ID)
		if err != nil {
			return nil, err
		}
		return conn.Query(ctx, p.SQL, p.Params, p.MaxRows)

	case "batch":
		var p struct {
			ID         string         `json:"id"`
			Statements []db.Statement `json:"statements"`
		}
		if err := unmarshalParams(req.Params, &p); err != nil {
			return nil, err
		}
		if len(p.Statements) == 0 {
			return nil, fmt.Errorf("empty batch")
		}
		for si, st := range p.Statements {
			for i, v := range st.Params {
				switch v.(type) {
				case string, nil:
				default:
					return nil, fmt.Errorf("statement %d param %d: must be string or null, got %T", si+1, i+1, v)
				}
			}
		}
		conn, err := s.conn(p.ID)
		if err != nil {
			return nil, err
		}
		affected, err := conn.Batch(ctx, p.Statements)
		if err != nil {
			return nil, err
		}
		return map[string]any{"rows_affected": affected}, nil

	case "objects":
		var p struct {
			ID string `json:"id"`
		}
		if err := unmarshalParams(req.Params, &p); err != nil {
			return nil, err
		}
		conn, err := s.conn(p.ID)
		if err != nil {
			return nil, err
		}
		objs, err := conn.Objects(ctx)
		if err != nil {
			return nil, err
		}
		return map[string]any{"objects": objs}, nil

	case "columns":
		var p struct {
			ID     string `json:"id"`
			Schema string `json:"schema"`
			Table  string `json:"table"`
		}
		if err := unmarshalParams(req.Params, &p); err != nil {
			return nil, err
		}
		conn, err := s.conn(p.ID)
		if err != nil {
			return nil, err
		}
		cols, err := conn.Columns(ctx, p.Schema, p.Table)
		if err != nil {
			return nil, err
		}
		return map[string]any{"columns": cols}, nil

	default:
		return nil, fmt.Errorf("unknown method %q", req.Method)
	}
}

func (s *Server) connect(ctx context.Context, serverName, database string) (any, error) {
	srv, err := s.cfg.Find(serverName)
	if err != nil {
		return nil, err
	}
	if database == "" {
		if srv.Adapter == "sqlite" {
			database = "main"
		} else {
			database = srv.Database
		}
	}
	id := serverName + "/" + database

	s.connMu.Lock()
	if info, ok := s.infos[id]; ok {
		s.connMu.Unlock()
		return info, nil
	}
	s.connMu.Unlock()

	// connect outside the lock — slow networks must not block other requests
	var conn db.Conn
	switch srv.Adapter {
	case "sqlite":
		conn, err = db.SQLiteConnect(ctx, srv)
	default:
		conn, err = db.PGConnect(ctx, srv, database)
	}
	if err != nil {
		return nil, err
	}

	info := connInfo{
		ID: id, Server: serverName, Database: database,
		Adapter: srv.Adapter, Prod: srv.Prod, ReadOnly: srv.ReadOnly,
	}
	s.connMu.Lock()
	defer s.connMu.Unlock()
	if existing, ok := s.infos[id]; ok { // lost the race, keep the first
		conn.Close()
		return existing, nil
	}
	s.conns[id] = conn
	s.infos[id] = info
	return info, nil
}

func (s *Server) conn(id string) (db.Conn, error) {
	s.connMu.Lock()
	defer s.connMu.Unlock()
	c, ok := s.conns[id]
	if !ok {
		return nil, fmt.Errorf("not connected: %q (connect first)", id)
	}
	return c, nil
}

func (s *Server) closeAll() {
	s.connMu.Lock()
	defer s.connMu.Unlock()
	for id, c := range s.conns {
		c.Close()
		delete(s.conns, id)
		delete(s.infos, id)
	}
}

func unmarshalParams(raw json.RawMessage, dst any) error {
	if len(raw) == 0 {
		return fmt.Errorf("missing params")
	}
	if err := json.Unmarshal(raw, dst); err != nil {
		return fmt.Errorf("bad params: %w", err)
	}
	return nil
}

# Backend protocol

The Lua frontend spawns `bin/sqledit` and talks newline-delimited JSON-RPC 2.0
over stdin/stdout: one JSON object per line in each direction. Responses may
arrive out of order (requests are handled concurrently); match them by `id`.
Logs go to stderr.

```
--> {"jsonrpc":"2.0","id":1,"method":"connect","params":{"server":"site3-prod"}}
<-- {"jsonrpc":"2.0","id":1,"result":{"id":"site3-prod/app","server":"site3-prod","database":"app","adapter":"postgres","prod":true,"readonly":false}}
```

Errors: `{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"..."}}`

## Methods

### `ping` → `{ok, version}`

### `connections.list` → `{config_path, servers: [{name, adapter, host?, port?, user?, database?, path?, prod, readonly}]}`
Configured servers from `connections.toml`. Never includes secrets.

### `databases.list {server}` → `{databases: [string]}`
Live list from `pg_database` — ad-hoc database copies show up without config
changes. sqlite always returns `["main"]`.

### `connect {server, database?}` → connInfo
Opens (or reuses) a connection pool. `database` defaults to the configured
maintenance database (postgres) or `main` (sqlite). The returned `id`
(`"<server>/<database>"`) is the handle for all later calls.

### `disconnect {id}` → `{ok}`

### `query {id, sql, max_rows?}` → result
```
{columns: [{name, type}], rows: [[...]], row_count, more,
 rows_affected, duration_ms}
```
- `max_rows` defaults to 500; `more: true` means the result was truncated.
- Cell values are JSON null/bool/number/string; timestamps and byte arrays are
  stringified, json/array columns keep their structure.
- Statements without a result set return empty `columns` and `rows_affected`.

### `objects {id}` → `{objects: [{schema, name, type}]}`
Tables, views, matviews. `type` ∈ `table | view | matview | foreign`.

### `columns {id, schema, table}` → `{columns: [{name, type, not_null, pk}]}`

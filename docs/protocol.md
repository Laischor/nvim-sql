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

### `connections.active` → `{connections: [connInfo]}`
Currently open connections, sorted by `id`. The frontend lists these at the
top of the connect picker so switching to an open connection skips the
server/database prompts.

### `databases.list {server}` → `{databases: [string]}`
Live list from `pg_database` — ad-hoc database copies show up without config
changes. sqlite always returns `["main"]`.

### `connect {server, database?}` → connInfo
Opens (or reuses) a connection pool. `database` defaults to the configured
maintenance database (postgres) or `main` (sqlite). The returned `id`
(`"<server>/<database>"`) is the handle for all later calls.

### `disconnect {id}` → `{ok}`

### `query {id, sql, max_rows?, params?}` → result
```
{columns: [{name, type}], rows: [[...]], row_count, more,
 rows_affected, duration_ms, tx}
```
- One statement. `max_rows` defaults to 500; `more: true` means the result
  was truncated.
- `params` are positional (`$1…` postgres, `?` sqlite) and must be strings
  or null — servers cast text to the column type. Used by the edit grid so
  values are never concatenated into SQL.
- Cell values are JSON null/bool/number/string; timestamps and byte arrays are
  stringified, json/array columns keep their structure.
- Statements without a result set return empty `columns` and `rows_affected`.
- `tx` is true while the connection has a transaction open afterwards (see
  below).

### `script {id, sql, max_rows?}` → `{results: [{sql, ...result}], failed?, tx}`
Splits `sql` into statements (quotes, comments, `$$` bodies and
`CREATE TRIGGER … BEGIN … END` respected) and runs them in order on one
session. `results` holds one `query`-shaped result per statement that ran,
each with its `sql`. Execution stops at the first error:
`failed: {index, sql, message}` (1-based). Without an open transaction,
statements before the failure stay applied (autocommit).

### `batch {id, statements: [{sql, params}]}` → `{rows_affected: [int], tx}`
Runs the statements atomically; any failure rolls everything back. Same
text-or-null param rule as `query`. Used by the grid's cell block paste
(one UPDATE per row). Inside an open transaction the batch runs in a
savepoint, so a failure leaves the outer transaction intact.

### `begin {id}` / `commit {id}` / `rollback {id}` → `{tx, message?}`
Explicit transaction control. While a transaction is open, the connection
pins one database session and every method on that `id` runs on it
(serialized). A `BEGIN` typed into `query`/`script` opens one the same way,
a typed `COMMIT`/`ROLLBACK` ends it; the `tx` flag on every response tells
the frontend the current state. `commit` on a postgres transaction that an
earlier error aborted succeeds with `tx: false` and a `message` (postgres
rolled back). `begin` with a transaction open and `commit`/`rollback`
without one are errors. `disconnect` rolls an open transaction back.
sqlite has no autocommit probe, so its state follows the statements'
first word (`begin`/`savepoint` open, `commit`/`end`/`rollback` close).

### `objects {id}` → `{objects: [{schema, name, type}]}`
Tables, views, matviews. `type` ∈ `table | view | matview | foreign`.

### `columns {id, schema, table}` → `{columns: [{name, type, not_null, pk, fk?}]}`
`fk` is present on single-column foreign keys: `{schema, table, column}`.
sqlite FKs declared without a target column resolve to the target's
primary key. Composite FKs carry no `fk` (no single cell to jump from).

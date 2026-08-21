# nvim-sql

SQL client for Neovim: postgres + sqlite, built for people who juggle many
similar databases (N sites × prod/staging × local dev) and want real vim
editing instead of a re-implementation.

- **Fuzzy-first navigation** — pick servers, databases, and tables through
  `vim.ui.select` (renders in telescope/fzf-lua/snacks if you use them).
  No tree drilling.
- **Cheap connection switching** — `:Sqledit switch` changes connection and
  offers to re-run your last query there (confirm with preview; write
  statements are never offered). Already-open connections sit at the top of
  the picker and connect instantly, skipping the database prompt. Databases
  are listed live from the server, so ad-hoc copies appear without config
  changes.
- **Per-buffer connections** — every query buffer is pinned to the
  connection it was opened under and shows it in its name
  (`sqledit://query-3@site3/analytics`). Switching while inside a query
  buffer re-pins that buffer; other buffers keep running against their own
  connection. Completion and the statusline follow the buffer's pin.
- **Real vim** — queries live in normal `sql` buffers: your keymaps, your
  LSP, your treesitter.
- **Schema-aware completion** — blink.cmp source fed from live
  introspection: tables after `FROM`/`JOIN`, columns after `alias.` /
  `table.` (aliases resolved from the buffer), tables after `schema.`.
  Cached per connection; `:Sqledit refresh` after DDL.
- **Editable grid** — `c` on a cell opens an input and writes the change
  back as a parameterized `UPDATE … WHERE <pk>`. Visually select rows
  and press `c` to set one column across all of them in a single UPDATE
  (always confirmed, with row count and statement preview). Only for
  plain single-table SELECTs with the primary key in the result;
  everything else stays read-only. Input semantics: `NULL` = SQL NULL,
  `''` = empty string, empty input = no change (NULL cells prefill
  empty), `=column` copies another column's value row by row (server-side
  `SET a = b` — each row gets its own value; the way to move data from
  one column into another). `dd` / visual `d` deletes rows — always
  behind a confirm. `r` re-runs the query.
- **FK jump** — `gd` on a foreign-key cell opens the referenced row.
  Works recursively: the target grid is a normal grid.
- **Copy & paste between servers** — yank rows as CSV (`yc`), JSON
  (`yj`) or a ready INSERT statement (`yi`) into register + clipboard;
  `p` in any grid parses CSV/JSON from the clipboard and inserts into
  that grid's table on the current connection (confirmed, columns
  matched by name, extras ignored). When the payload contains primary
  key columns, the prompt offers "Without pk" so the target database
  assigns fresh ids. Copy prod → switch → paste staging.
- **Cell block copy between tables** — select cells with `<C-v>` and
  `y` to yank the block (works in any grid, joins included; a TSV copy
  lands in the unnamed register and the system clipboard, so it pastes
  as plain text into any buffer too). In the target grid, select a same-shaped
  block and `p`: one UPDATE per row, all in a single transaction
  (all-or-nothing), rows and columns matched by position. The way to
  move a column's values from one table into another when cleaning up
  data.
- **Insert form** — `o` in a grid opens a float with one field per
  column: aligned virtual labels (pk highlighted, can't be mangled),
  type/pk/not-null hints pinned right, ghost `default` on empty fields.
  `<Tab>`/`<S-Tab>` (and `<CR>` while typing) hop between fields, the
  cursor starts on the first non-pk column. `<CR>` or `:w` runs the
  INSERT. Empty field = column omitted (DB default / serial), `NULL` =
  SQL NULL, `''` = empty string, `q` closes.
- **Tree view** — `:Sqledit tree` toggles a sidebar for secondary
  browsing: servers → databases → schemas → tables → columns (pk/nn/fk
  marked). `l`/`h` drill and climb, `<CR>` on a table opens its data in
  the grid while the cursor stays in the tree, `c` adopts a node's
  connection, `R` refetches a subtree. Children load lazily and are
  cached; lone schemas are skipped. Prod servers keep their warning tag.
- **Query history** — `:Sqledit history` fuzzy-picks from this
  connection's past queries (persisted across sessions) and opens the
  pick in a query buffer — it never executes directly.
- **Prod guard** — servers marked `prod = true` get a warning tag and a
  confirm prompt before any write statement, including cell edits.
- **Go backend** — `pgx`/`modernc.org/sqlite` over JSON-RPC, no `psql`
  text-scraping.

## Install

Requires Go 1.26+ to build the backend.

```lua
-- lazy.nvim
{
  "Laischor/nvim-sql",
  build = "make build",
  config = function()
    require("sqledit").setup({
      -- max_rows = 500,
      -- confirm_prod_writes = true,
      -- run_key = "<localleader>r",
    })
  end,
}
```

## Connections

`~/.config/sqledit/connections.toml` (or `$SQLEDIT_CONFIG`):

```toml
# applied to every server where the field is not set explicitly
# (prod/readonly are intentionally not defaultable)
[defaults]
adapter = "postgres"
user = "support"
password_keychain = "sqledit/support"   # macOS keychain service name

[[servers]]
name = "local"                # host/port default to localhost:5432

[[servers]]
name = "analytics"
adapter = "sqlite"
path = "~/data/analytics.db"

# many similar deployments: templates expanded once per name,
# "{name}" replaced in every string field
[[groups]]
names = ["site1", "site2", "site3"]

[[groups.servers]]
name = "{name}-prod"
host = "{name}.example.com"
prod = true                   # tag + confirm before writes
# readonly = true             # default_transaction_read_only

[[groups.servers]]
name = "{name}-staging"
host = "staging.{name}.example.com"
password_env = "STAGING_PW"   # overrides the keychain default
```

This yields `local`, `analytics`, `site1-prod`, `site1-staging`, … —
a new deployment is one entry in `names`.

Store keychain passwords once:

```sh
security add-generic-password -s sqledit/site3 -a support -w
```

Password resolution order: `password` (inline, avoid), `password_env`,
`password_keychain`.

## Usage

| Command | |
|---|---|
| `:Sqledit connect` | pick a connection: open ones first (instant), else server → database |
| `:Sqledit switch` | reconnect elsewhere, offer re-run of last query (confirmed, reads only) |
| `:Sqledit tree` | toggle the tree sidebar (`l`/`h` drill/climb, `<CR>` open table, `c` use connection, `R` refetch, `q` close) |
| `:Sqledit tables` | fuzzy-pick a table/view → `SELECT * … LIMIT n` |
| `:Sqledit filter` | like `tables`, plus prompts for `WHERE` / `ORDER BY` |
| `:Sqledit refilter` | re-edit the last filter's clauses (prefilled), re-run |
| `:Sqledit query` | open a scratch SQL buffer pinned to the connection (run: `<localleader>r`) |
| `:Sqledit run [sql]` | run argument, visual range, or current buffer |
| `:Sqledit history` | pick a past query → opens in a query buffer |
| `:Sqledit refresh` | clear schema cache (completion re-introspects) |
| `:Sqledit disconnect` | drop the buffer's connection (unpins its buffers) |

Statusline: `require("sqledit").status()` → `"site3-prod/app [PROD]"`
(buffer-aware: pinned query buffers show their own connection).

### Completion (blink.cmp)

Registers itself with blink.cmp automatically for `sql` buffers —
no blink config needed. To manage it manually instead (custom source
order etc.), define the provider yourself and the auto-registration
backs off:

```lua
-- in your blink.cmp opts
sources = {
  per_filetype = { sql = { "sqledit", "buffer" } },
  providers = {
    sqledit = { name = "sqledit", module = "sqledit.blink" },
  },
}
```

Suggestions need an active connection (`:Sqledit connect`);
`:checkhealth sqledit` shows the registration status. Quoted
identifiers in alias definitions are not resolved yet.

Grid keys: `c` edit cell (visual: edit column for selected rows),
`dd`/visual `d` delete row(s) with confirm,
`yc`/`yj`/`yi` yank row(s) as CSV/JSON/INSERT (visual: selection),
`p` insert clipboard rows into this grid's table, `o` insert-row form,
`gd` follow foreign key, `w`/`b` next/previous
column, `gc` jump to column by name, `F` edit the last filter's
`WHERE`/`ORDER BY`, `r` re-run query, `q` close. Column
names stay sticky in a header line above the grid — it follows
horizontal scrolling, survives vertical scrolling, and window
navigation (`<C-w>k`/`j`) passes through it as if it weren't there. The winbar shows
the current column (`col 4/23: created_at (timestamptz)`) plus the
result status.

`:checkhealth sqledit` verifies backend binary and config.

## Roadmap

- multi-statement support for postgres (single statement per run for now)

## Development

```sh
make build      # builds bin/sqledit (the Go backend)
make test       # Go tests
make test-e2e   # headless plugin suite (needs nvim + make build)
```

Postgres integration tests run when `SQLEDIT_TEST_PG` points at a
scratch database (`postgres://user:pass@localhost:5432/db`); they are
skipped otherwise.

Protocol between Lua and Go: [docs/protocol.md](docs/protocol.md).

## License

[MIT](LICENSE) © Laischor

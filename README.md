# nvim-sql

SQL client for Neovim: postgres + sqlite, built for people who juggle many
similar databases (N sites × prod/staging × local dev) and want real vim
editing instead of a re-implementation.

- **Fuzzy-first navigation** — pick servers, databases, and tables through
  `vim.ui.select` (renders in telescope/fzf-lua/snacks if you use them).
  No tree drilling.
- **Cheap connection switching** — `:Sqledit switch` changes connection and
  offers to re-run your last query there (confirm with preview; write
  statements are never offered). Databases are listed live from the server,
  so ad-hoc copies appear without config changes.
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
  empty). `dd` / visual `d` deletes rows — always behind a confirm.
  `r` re-runs the query.
- **FK jump** — `gd` on a foreign-key cell opens the referenced row.
  Works recursively: the target grid is a normal grid.
- **Copy & paste between servers** — yank rows as CSV (`yc`), JSON
  (`yj`) or a ready INSERT statement (`yi`) into register + clipboard;
  `p` in any grid parses CSV/JSON from the clipboard and inserts into
  that grid's table on the current connection (confirmed, columns
  matched by name, extras ignored). When the payload contains primary
  key columns, the prompt offers "Without pk" so the target database
  assigns fresh ids. Copy prod → switch → paste staging.
- **Insert form** — `o` in a grid opens a float with one line per
  column (type, pk, not-null shown inline); `:w` runs the INSERT.
  Empty field = column omitted (DB default / serial), `NULL` = SQL
  NULL, `q` closes.
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
| `:Sqledit connect` | pick server → database → connect |
| `:Sqledit switch` | reconnect elsewhere, offer re-run of last query (confirmed, reads only) |
| `:Sqledit tables` | fuzzy-pick a table/view → `SELECT * … LIMIT n` |
| `:Sqledit filter` | like `tables`, plus prompts for `WHERE` / `ORDER BY` |
| `:Sqledit refilter` | re-edit the last filter's clauses (prefilled), re-run |
| `:Sqledit query` | open a scratch SQL buffer (run: `<localleader>r`) |
| `:Sqledit run [sql]` | run argument, visual range, or current buffer |
| `:Sqledit history` | pick a past query → opens in a query buffer |
| `:Sqledit refresh` | clear schema cache (completion re-introspects) |
| `:Sqledit disconnect` | drop current connection |

Statusline: `require("sqledit").status()` → `"site3-prod/app [PROD]"`.

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

- tree view as secondary browsing
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

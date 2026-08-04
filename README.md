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
  back as a parameterized `UPDATE … WHERE <pk>`. Only for plain
  single-table SELECTs with the primary key in the result; everything
  else stays read-only. `NULL` as input means SQL NULL, `r` re-runs the
  query.
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
[[servers]]
name = "local"
adapter = "postgres"          # host/port default to localhost:5432
user = "mr"

[[servers]]
name = "site3-prod"
adapter = "postgres"
host = "site3.example.com"
user = "support"
password_keychain = "sqledit/site3"   # macOS keychain service name
prod = true                            # confirm before writes
# readonly = true                      # default_transaction_read_only

[[servers]]
name = "site3-staging"
adapter = "postgres"
host = "staging.site3.example.com"
user = "support"
password_env = "SITE3_STAGING_PW"

[[servers]]
name = "analytics"
adapter = "sqlite"
path = "~/data/analytics.db"
```

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
| `:Sqledit query` | open a scratch SQL buffer (run: `<localleader>r`) |
| `:Sqledit run [sql]` | run argument, visual range, or current buffer |
| `:Sqledit refresh` | clear schema cache (completion re-introspects) |
| `:Sqledit disconnect` | drop current connection |

Statusline: `require("sqledit").status()` → `"site3-prod/app [PROD]"`.

### Completion (blink.cmp)

```lua
-- in your blink.cmp opts
sources = {
  per_filetype = { sql = { "sqledit", "buffer" } },
  providers = {
    sqledit = { name = "sqledit", module = "sqledit.blink" },
  },
}
```

Suggestions need an active connection (`:Sqledit connect`). Quoted
identifiers in alias definitions are not resolved yet.

Grid keys: `c` edit cell, `r` re-run query, `q` close.

`:checkhealth sqledit` verifies backend binary and config.

## Roadmap

- FK jump: `gd` on a foreign-key cell opens the referenced row
- query history per connection
- tree view as secondary browsing

## Development

```sh
make build   # builds bin/sqledit (the Go backend)
make test
```

Protocol between Lua and Go: [docs/protocol.md](docs/protocol.md).

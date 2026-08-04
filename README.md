# nvim-sql

SQL client for Neovim: postgres + sqlite, built for people who juggle many
similar databases (N sites × prod/staging × local dev) and want real vim
editing instead of a re-implementation.

- **Fuzzy-first navigation** — pick servers, databases, and tables through
  `vim.ui.select` (renders in telescope/fzf-lua/snacks if you use them).
  No tree drilling.
- **Cheap connection switching** — `:Sqledit switch` changes connection and
  re-runs your last query there. Databases are listed live from the server,
  so ad-hoc copies appear without config changes.
- **Real vim** — queries live in normal `sql` buffers: your keymaps, your
  LSP, your treesitter.
- **Prod guard** — servers marked `prod = true` get a warning tag and a
  confirm prompt before any write statement.
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
| `:Sqledit switch` | reconnect elsewhere, re-run last query there |
| `:Sqledit tables` | fuzzy-pick a table/view → `SELECT * … LIMIT n` |
| `:Sqledit query` | open a scratch SQL buffer (run: `<localleader>r`) |
| `:Sqledit run [sql]` | run argument, visual range, or current buffer |
| `:Sqledit disconnect` | drop current connection |

Statusline: `require("sqledit").status()` → `"site3-prod/app [PROD]"`.

`:checkhealth sqledit` verifies backend binary and config.

## Roadmap

- completion source (blink.cmp) fed from schema introspection
- editable grid: change a cell, `:write` emits `UPDATE … WHERE <pk>`
- FK jump: `gd` on a foreign-key cell opens the referenced row
- query history per connection
- tree view as secondary browsing

## Development

```sh
make build   # builds bin/sqledit (the Go backend)
make test
```

Protocol between Lua and Go: [docs/protocol.md](docs/protocol.md).

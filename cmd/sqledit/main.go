// Command sqledit is the backend for the sqledit.nvim plugin. It speaks
// newline-delimited JSON-RPC 2.0 on stdin/stdout and manages database
// connections (postgres, sqlite) on behalf of the Lua frontend.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/Laischor/nvim-sql/internal/config"
	"github.com/Laischor/nvim-sql/internal/rpc"
)

var version = "0.1.0"

func main() {
	cfgPath := flag.String("config", "", "path to connections.toml (default: $SQLEDIT_CONFIG or ~/.config/sqledit/connections.toml)")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Println(version)
		return
	}

	path := *cfgPath
	if path == "" {
		path = config.DefaultPath()
	}
	cfg, err := config.Load(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "sqledit: %v\n", err)
		os.Exit(1)
	}

	srv := rpc.NewServer(cfg, version)
	if err := srv.Serve(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "sqledit: %v\n", err)
		os.Exit(1)
	}
}

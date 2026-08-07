GO ?= go
NVIM ?= nvim

.PHONY: build test test-e2e clean

build:
	$(GO) build -o bin/sqledit ./cmd/sqledit

test:
	$(GO) test ./...

# headless plugin suite against a throwaway sqlite db (needs `make build`)
test-e2e:
	XDG_STATE_HOME=$$(mktemp -d) $(NVIM) --headless --clean -u NONE -l tests/e2e.lua

clean:
	rm -rf bin

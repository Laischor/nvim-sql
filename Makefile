GO ?= go

.PHONY: build test clean

build:
	$(GO) build -o bin/sqledit ./cmd/sqledit

test:
	$(GO) test ./...

clean:
	rm -rf bin

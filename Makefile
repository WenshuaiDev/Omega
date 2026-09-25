SHELL := /bin/sh
.DEFAULT_GOAL := check

# Keep these lists aligned with go.work and actual executable packages.
GO_MODULES := libs services/example-service
GO_PROGRAMS := services/example-service/cmd/example-service
export GOTOOLCHAIN := local

.PHONY: toolchain bootstrap fmt check build

toolchain:
	@sh scripts/toolchain.sh

bootstrap: toolchain
	@set -eu; for module in $(GO_MODULES); do go -C "$$module" list -deps -test ./... >/dev/null; done
	corepack yarn install --immutable

fmt: toolchain
	@set -eu; for module in $(GO_MODULES); do go -C "$$module" fmt ./...; done
	corepack yarn format

check: toolchain
	@set -eu; files=$$(find $(GO_MODULES) -name '*.go' -exec "$$(go env GOROOT)/bin/gofmt" -l {} +); \
		if [ -n "$$files" ]; then printf 'Go format errors (run make fmt):\n%s\n' "$$files"; exit 1; fi
	corepack yarn format:check
	@set -eu; for module in $(GO_MODULES); do go -C "$$module" vet ./...; go -C "$$module" test ./...; done
	corepack yarn typecheck
	corepack yarn lint

build: toolchain
	@mkdir -p build
	@set -eu; for program in $(GO_PROGRAMS); do go build -o "build/$${program##*/}" "./$$program"; done
	corepack yarn build

.DEFAULT_GOAL := help
.PHONY: help sync warm update check lint fmt test test-unit test-smoke test-e2e test-lsp

help:
	@echo "Targets:"
	@echo "  sync       Restore plugins, parsers, and mason tools to pinned versions"
	@echo "  warm       Alias for sync (run once after clone)"
	@echo "  update     Bump all pin files (lazy-lock, mason-tool-versions, parser-revisions)"
	@echo "  check      Verify the cache matches all pin files (no installs)"
	@echo "  lint       Run stylua --check"
	@echo "  fmt        Run stylua --write"
	@echo "  test       Run unit + smoke + e2e tests"
	@echo "  test-unit  Run unit tests (plenary-only harness)"
	@echo "  test-smoke Run smoke tests (full init, no real LSP)"
	@echo "  test-e2e   Run end-to-end tests (full init)"
	@echo "  test-lsp   Run slow LSP end-to-end tests"

# Make this machine match the committed pins: plugins (lazy-lock.json),
# treesitter parsers (parser-revisions.lua), and mason tools
# (mason-tool-versions.lock). Idempotent — safe to re-run.
sync warm:
	@./scripts/warm-cache.sh

update:
	@./scripts/update-pins.sh

# Verify-only path through warm-cache.sh: assert the installed plugins, parsers,
# and mason tools already match the committed pins, without installing anything.
# Exits non-zero on the first drift (handy in CI / pre-commit).
check:
	@./scripts/warm-cache.sh --check-only

lint:
	@stylua --check lua init.lua tests parser-revisions.lua

fmt:
	@stylua lua init.lua tests parser-revisions.lua

test: test-unit test-smoke test-e2e

# All test targets go through run-plenary.sh, which reaps child nvims that a
# hung spec would otherwise leave orphaned when the parent exits.
test-unit:
	@scripts/run-plenary.sh tests/minimal_init.lua tests/spec/unit

test-smoke:
	@scripts/run-plenary.sh tests/full_init.lua tests/spec/smoke

test-e2e:
	@scripts/run-plenary.sh tests/full_init.lua tests/spec/e2e

test-lsp:
	@scripts/run-plenary.sh tests/full_init.lua tests/spec/e2e-lsp

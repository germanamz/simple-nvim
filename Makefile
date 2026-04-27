.DEFAULT_GOAL := help
.PHONY: help warm update lint fmt test test-unit test-smoke test-e2e test-lsp

help:
	@echo "Targets:"
	@echo "  warm       Populate the deterministic plugin cache (run once after clone)"
	@echo "  update     Bump all pin files (lazy-lock, mason-tool-versions, parser-revisions)"
	@echo "  lint       Run stylua --check"
	@echo "  fmt        Run stylua --write"
	@echo "  test       Run unit + smoke + e2e tests"
	@echo "  test-unit  Run unit tests (plenary-only harness)"
	@echo "  test-smoke Run smoke tests (full init, no real LSP)"
	@echo "  test-e2e   Run end-to-end tests (full init)"
	@echo "  test-lsp   Run slow LSP end-to-end tests"

warm:
	@./scripts/warm-cache.sh

update:
	@./scripts/update-pins.sh

lint:
	@stylua --check lua init.lua tests

fmt:
	@stylua lua init.lua tests

test: test-unit test-smoke test-e2e

test-unit:
	@nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/spec/unit { minimal_init = 'tests/minimal_init.lua' }"

test-smoke:
	@nvim --headless -u tests/full_init.lua \
		-c "PlenaryBustedDirectory tests/spec/smoke { minimal_init = 'tests/full_init.lua' }"

test-e2e:
	@nvim --headless -u tests/full_init.lua \
		-c "PlenaryBustedDirectory tests/spec/e2e { minimal_init = 'tests/full_init.lua' }"

test-lsp:
	@nvim --headless -u tests/full_init.lua \
		-c "PlenaryBustedDirectory tests/spec/e2e-lsp { minimal_init = 'tests/full_init.lua' }"

.DEFAULT_GOAL := help
.PHONY: help warm update lint fmt

help:
	@echo "Targets:"
	@echo "  warm    Populate the deterministic plugin cache (run once after clone)"
	@echo "  update  Bump all pin files (lazy-lock, mason-tool-versions, parser-revisions)"
	@echo "  lint    Run stylua --check"
	@echo "  fmt     Run stylua --write"

warm:
	@./scripts/warm-cache.sh

update:
	@./scripts/update-pins.sh

lint:
	@stylua --check lua init.lua

fmt:
	@stylua lua init.lua

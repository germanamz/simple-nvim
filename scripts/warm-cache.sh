#!/bin/sh
# warm-cache.sh — populate / verify the deterministic Neovim plugin cache.
#
# Usage:
#   scripts/warm-cache.sh              # full warm: install plugins, parsers, mason tools, then check
#   scripts/warm-cache.sh --check-only # just verify the cache matches all pin files
#
# Exits non-zero with a clear message on the first mismatch.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARSER_INFO_DIR="${HOME}/.local/share/nvim/site/parser-info"
MASON_PKG_DIR="${HOME}/.local/share/nvim/mason/packages"
LOCKFILE="${REPO_ROOT}/mason-tool-versions.lock"
PARSER_REVS_LUA="${REPO_ROOT}/tests/parser-revisions.lua"

CHECK_ONLY=0
case "${1:-}" in
  --check-only) CHECK_ONLY=1 ;;
  "")           ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

err() { printf '%s\n' "$*" >&2; }

# --- install steps ---------------------------------------------------------

install_plugins() {
  # `Lazy! restore` waits for restore (the bang) and pins to lockfile SHAs.
  nvim --headless "+Lazy! restore" "+qa" >/dev/null 2>&1 \
    || { err "Lazy! restore failed"; return 1; }
}

install_parsers() {
  # Plugin config calls config.ts_pinned.apply() before install(), so a normal
  # bootstrap installs at the pinned revisions. TSUpdate sync re-runs install
  # with the pins applied for any parsers that drifted.
  nvim --headless "+TSUpdate sync" "+qa" >/dev/null 2>&1 \
    || { err "TSUpdate sync failed"; return 1; }
}

install_mason_tools() {
  # mason-tool-installer's run_on_start fires on VimEnter; the Sync variant
  # blocks until the install queue drains.
  nvim --headless "+MasonToolsInstallSync" "+qa" >/dev/null 2>&1 \
    || { err "MasonToolsInstallSync failed"; return 1; }
}

# --- check block -----------------------------------------------------------

check_lockfile_honored() {
  # Snapshot the file content (not git-index state) before/after restore so
  # the check works whether or not lazy-lock.json has uncommitted changes.
  before=$(git -C "$REPO_ROOT" hash-object lazy-lock.json)
  nvim --headless "+Lazy! restore" "+qa" >/dev/null 2>&1 \
    || { err "Lazy! restore failed (during check)"; return 1; }
  after=$(git -C "$REPO_ROOT" hash-object lazy-lock.json)
  if [ "$before" != "$after" ]; then
    err "lazy-lock.json was modified by Lazy! restore — pins drifted"
    return 1
  fi
}

check_parser_revisions() {
  # tests/parser-revisions.lua format:  name = "<rev>",  (one per line)
  # Compare each entry to ~/.local/share/nvim/site/parser-info/<name>.revision.
  awk '/^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*"[^"]+",/' "$PARSER_REVS_LUA" \
    | while IFS= read -r line; do
        name=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*([a-zA-Z_]+)[[:space:]]*=.*/\1/')
        expected=$(printf '%s' "$line" | sed -E 's/.*"([^"]+)".*/\1/')
        rev_file="${PARSER_INFO_DIR}/${name}.revision"
        if [ ! -f "$rev_file" ]; then
          err "parser ${name} not installed (expected ${expected})"
          exit 1
        fi
        actual=$(cat "$rev_file")
        if [ "$actual" != "$expected" ]; then
          err "parser ${name} revision mismatch: expected ${expected} got ${actual}"
          exit 1
        fi
      done
}

check_mason_tools() {
  # No native MasonToolsCheck command; compare lockfile vs each receipt.
  python3 - "$LOCKFILE" "$MASON_PKG_DIR" <<'PY'
import json, re, sys, os
lockfile, pkg_dir = sys.argv[1], sys.argv[2]
with open(lockfile) as f:
    pins = json.load(f)
fail = False
for name, expected in sorted(pins.items()):
    receipt = os.path.join(pkg_dir, name, "mason-receipt.json")
    if not os.path.isfile(receipt):
        print(f"mason tool {name} not installed (expected {expected})", file=sys.stderr)
        fail = True
        continue
    with open(receipt) as f:
        data = json.load(f)
    raw_id = data.get("source", {}).get("id", "")
    m = re.search(r"@([^@]+)$", raw_id)
    actual = m.group(1) if m else None
    if actual != expected:
        print(f"mason tool {name} version mismatch: expected {expected} got {actual}", file=sys.stderr)
        fail = True
sys.exit(1 if fail else 0)
PY
}

run_checks() {
  check_lockfile_honored
  check_parser_revisions
  check_mason_tools
}

# --- main ------------------------------------------------------------------

if [ "$CHECK_ONLY" -eq 1 ]; then
  run_checks
else
  install_plugins
  install_parsers
  install_mason_tools
  run_checks
fi

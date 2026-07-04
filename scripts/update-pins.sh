#!/bin/sh
# update-pins.sh — bump every pin file to the current upstream state.
#
# 1. `Lazy! sync`  — pull plugins, rewrite lazy-lock.json
# 2. Refresh mason-tool-versions.lock from installed mason packages
# 3. Refresh parser-revisions.lua from installed treesitter parsers
# 4. Show `git status --short` — user reviews and commits manually.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARSER_INFO_DIR="${HOME}/.local/share/nvim/site/parser-info"
MASON_PKG_DIR="${HOME}/.local/share/nvim/mason/packages"
LOCKFILE="${REPO_ROOT}/mason-tool-versions.lock"
PARSER_REVS_LUA="${REPO_ROOT}/parser-revisions.lua"

err() { printf '%s\n' "$*" >&2; }

# Step 1: bump plugins ------------------------------------------------------

nvim --headless "+Lazy! sync" "+qa" >/dev/null 2>&1 \
  || { err "Lazy! sync failed"; exit 1; }

# After sync, run mason-tool-installer's update so any version drift in the
# bumped registry is reflected on disk before we re-snapshot.
nvim --headless "+MasonToolsUpdateSync" "+qa" >/dev/null 2>&1 \
  || { err "MasonToolsUpdateSync failed"; exit 1; }

# Also re-install treesitter parsers so their .revision files match whatever
# the bumped nvim-treesitter pins are.
nvim --headless "+TSUpdate sync" "+qa" >/dev/null 2>&1 \
  || { err "TSUpdate sync failed"; exit 1; }

# Step 2: refresh mason-tool-versions.lock ----------------------------------

python3 - "$LOCKFILE" "$MASON_PKG_DIR" <<'PY'
import json, os, re, sys
lockfile, pkg_dir = sys.argv[1], sys.argv[2]
with open(lockfile) as f:
    pins = json.load(f)
out = {}
for name in pins:
    receipt = os.path.join(pkg_dir, name, "mason-receipt.json")
    if not os.path.isfile(receipt):
        print(f"warning: {name} not installed; keeping previous pin", file=sys.stderr)
        out[name] = pins[name]
        continue
    with open(receipt) as f:
        data = json.load(f)
    raw_id = data.get("source", {}).get("id", "")
    m = re.search(r"@([^@]+)$", raw_id)
    if not m:
        print(f"warning: cannot parse version from {raw_id}; keeping previous pin", file=sys.stderr)
        out[name] = pins[name]
        continue
    out[name] = m.group(1)
with open(lockfile, "w") as f:
    json.dump(dict(sorted(out.items())), f, indent=2)
    f.write("\n")
PY

# Step 3: refresh parser-revisions.lua --------------------------------

python3 - "$PARSER_REVS_LUA" "$PARSER_INFO_DIR" <<'PY'
import os, re, sys
revs_path, parser_info = sys.argv[1], sys.argv[2]
# Read the existing file to recover (a) the maintainer header verbatim — every
# line before `return {`, including the `--` separator and the `make update`/
# ts_pinned note — and (b) the parser order/list, so we re-emit the same
# preamble and don't drop entries even if a parser is missing locally (we keep
# its prior pin in that case).
prelude = []
existing = {}
order = []
with open(revs_path) as f:
    in_body = False
    for line in f:
        if not in_body:
            if line.lstrip().startswith("return {"):
                in_body = True
                continue
            prelude.append(line.rstrip("\n"))
            continue
        m = re.match(r"\s*([a-zA-Z_]+)\s*=\s*\"([^\"]+)\"", line)
        if m:
            order.append(m.group(1))
            existing[m.group(1)] = m.group(2)
new_revs = {}
for name in order:
    rev_file = os.path.join(parser_info, f"{name}.revision")
    if os.path.isfile(rev_file):
        with open(rev_file) as f:
            new_revs[name] = f.read().strip()
    else:
        print(f"warning: parser {name} not installed; keeping previous pin", file=sys.stderr)
        new_revs[name] = existing[name]
# Single-space `name = "..."` assignments (no column alignment) so the result
# passes `stylua --check`, which the repo lints with.
lines = list(prelude)
lines.append("return {")
for name in order:
    lines.append(f'  {name} = "{new_revs[name]}",')
lines.append("}")
lines.append("")
with open(revs_path, "w") as f:
    f.write("\n".join(lines))
PY

# Step 4: show diff ---------------------------------------------------------

git -C "$REPO_ROOT" status --short
printf '\nReview the diff above, then commit manually.\n'

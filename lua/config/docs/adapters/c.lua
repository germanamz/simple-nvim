-- C/C++/ObjC docs — and the blunt part first: there is no docs answer here.
--
-- Why there is no `url`
-- --------------------
-- cppreference is the only site worth linking, and its path carries an
-- editorial category segment that is not computable from a symbol name:
-- `std::sort` lives under /w/cpp/algorithm/sort, `std::vector` under
-- /w/cpp/container/vector, `std::stoi` under /w/cpp/string/basic_string/stol
-- (note: stol, not stoi). Nothing in "sort" says "algorithm". The only ways to
-- produce that segment are a hand-maintained lookup table — which is a
-- guaranteed-stale liability that would still miss every symbol not in it — or
-- probing the site, which is banned here and would not work anyway: cppreference
-- 403s scripted clients, so a guessed URL cannot even be validated. A URL
-- builder that is wrong for most inputs is worse than no builder, because the
-- driver's search fallback actually finds the page. So: no url, no table.
--
-- Why there is no `manifest`, `manifest_line` or `deps`
-- ----------------------------------------------------
-- C has no manifest. CMakeLists.txt / Makefile / vcpkg.json / conanfile are
-- build inputs, not a dependency graph with a docs host behind it, and there is
-- no npmjs/docs.rs/pkg.go.dev equivalent to point a picker's rows at. There is
-- nothing to list, so nothing is listed.
--
-- Why there is no `#include` handling
-- -----------------------------------
-- clangd answers textDocument/documentLink on every `#include` with the
-- resolved header on disk, and lua/config/docs/resolve.lua already turns that
-- into a buffer. Re-deriving header paths from the include text here would
-- duplicate a mechanism that is both warm and authoritative.
--
-- What is left is `man`, which for libc/POSIX is genuinely good.
local M = {}

M.ft = { "c", "cpp", "objc", "objcpp" }

-- There is no `url` at all, so this changes no behavior today. It is declared
-- so the adapter's shape states the intent — this thing has a local answer and
-- no web answer — rather than silently inheriting the "web" default.
M.prefer = "local"

-- Section list, most specific first. Plain `man 3` is wrong on darwin in two
-- separate ways, both verified on this machine:
--
--   • Section 3 does not hold the syscalls. `man 3 write`, `man 3 read`,
--     `man 3 close`, `man 3 stat` and `man 3 mmap` all fail outright with "No
--     manual entry" — those pages are write(2), read(2), etc. That is a large
--     hole for exactly the C code that reaches for a man page.
--   • Worse, when section 3 does answer for a syscall name it answers with
--     Perl. `man -w 3 open` resolves to .../share/man/man3/open.3pm, the Perl
--     `open` pragma, because the SDK manpath drops 3pm pages into man3. A C
--     programmer pressing this on open(2) would get Perl documentation and no
--     indication anything went wrong.
--
-- Preferring 2 over 3 fixes both: open/write/read/close/stat/mmap resolve to
-- the syscall, while printf/malloc/memcpy/strlen/pthread_create/abs are absent
-- from 2 and still fall through to 3. Section 1 is deliberately excluded so
-- `printf` cannot resolve to the shell command. One residual miss stays: `sort`
-- still lands on sort.3pm, since macOS ships no sort(3) for it to lose to.
local MAN_SECTIONS = "2:3"

-- macOS man emits backspace-overstrike bold even when stdout is not a tty —
-- raw output for printf(3) is 29714 bytes of `p\bpr\bri\bin\bnt\btf\bf`, vs
-- 22303 once stripped. vim.system hands the driver those raw bytes, so an
-- unfiltered pane renders literal ^H sequences over every bolded word.
--
-- `-b` strips the overstrike. `-x` is not optional decoration: col re-tabulates
-- runs of spaces into tabs by default (256 tab-bearing lines in printf(3)
-- alone), and man pages are column-aligned with spaces — so without -x the
-- pane's `tabstop` setting, not the page, decides where the SYNOPSIS and the
-- conversion-specifier tables land, shearing them. UTF-8 survives either way
-- (the en dash in the NAME line comes through intact).
--
-- This is one argv element because man shell-evaluates its -P argument. It is a
-- constant with nothing interpolated into it, and the page name is a separate
-- argv element that is validated below, so there is no shell exposure here.
local MAN_PAGER = "col -bx"

--- Is `word` usable as a man page name?
---
--- ctx.word arrives with dots included, which for this language family means
--- the two commonest cursor targets are not page names at all: a C member
--- expression (`sb.st_mode`) and a C++ qualified name (`std::vector`). Neither
--- has a man page — `man std::vector` exits 1 — so declining here costs nothing
--- and saves a process spawn per keypress. The narrow charset also guarantees
--- the name can never begin with `-` and be parsed as a flag by man.
---@param word string|nil
---@return string|nil
local function man_page_name(word)
  if type(word) ~= "string" then
    return nil
  end
  return word:match("^[A-Za-z_][A-Za-z0-9_]*$")
end

--- Coordinates for the identifier under the cursor.
---
--- `pkg` is nil because C has no package identity to carry, and `stdlib` is
--- left nil rather than guessed: nothing in an identifier distinguishes libc
--- from project code, and man's exit status — the only oracle that can tell
--- them apart — is not available until after the command has run.
---@param ctx DocCtx
---@return DocCoord|nil
function M.coord(ctx)
  local name = man_page_name(ctx and ctx.word)
  if not name then
    return nil
  end
  return { symbol = name }
end

--- The man invocation for a coordinate, as a viewer page.
---
--- A man page is already whole — there is no index-versus-full distinction to
--- make here, so unlike `go doc` this needs no extra flag to become a page the
--- viewer can outline.
---
--- Re-validates rather than trusting `c.symbol`, since the driver unit-tests
--- these functions independently against fixture values and a coord it did not
--- produce must not become an argv this one would not have built.
---
--- The driver distinguishes hit from miss by exit status, which is why nothing
--- here tries to interpret the output: a found page exits 0 with the page on
--- stdout and an empty stderr; a missing one exits 1 with empty stdout and
--- "No manual entry for <name>" on stderr. That status survives the -P pipe
--- (verified: `man -S 2:3 -P 'col -bx' zzzznope` exits 1), so forcing the
--- pager does not mask the miss.
---@param c DocCoord
---@param _ctx DocCtx
---@return DocPage|nil
function M.page(c, _ctx)
  local name = man_page_name(c and c.symbol)
  if not name then
    return nil
  end
  return {
    cmd = { "man", "-S", MAN_SECTIONS, "-P", MAN_PAGER, name },
    title = name,
  }
end

--- An outline of a man page: its SECTIONS.
---
--- The one adapter whose outline is not a symbol list, and deliberately so. A
--- man page has no symbol table to expose — it documents ONE name, and what a
--- reader navigates is RETURN VALUES, ERRORS, EXAMPLES. Pretending otherwise
--- would mean inventing structure the page does not have.
---
--- Column 0 is the whole test. `man` indents body text by four and subsection
--- headers by three, so only true section headers reach the left margin, and
--- the running header (`PRINTF(3) ... PRINTF(3)`) carries digits and parens
--- that an all-caps-and-spaces match cannot accept.
---@param lines string[]
---@return DocEntry[]
function M.outline(lines)
  if type(lines) ~= "table" then
    return {}
  end
  local out = {}
  for i, line in ipairs(lines) do
    if line:match("^[A-Z][A-Z ]*$") then
      out[#out + 1] = { label = line, lnum = i, kind = "section" }
    end
  end
  return out
end

--- Follow a `name(3)` cross-reference.
---
--- Gated on the cursor's LINE actually spelling the reference with its section
--- number, which is how SEE ALSO writes them. Without that gate every word in
--- the prose would look followable and <CR> would spawn `man` on English.
---@param word string
---@param _c DocCoord
---@param ctx DocCtx
---@return DocCoord|nil
function M.xref(word, _c, ctx)
  local name = man_page_name(word)
  if not name then
    return nil
  end
  local line = ctx and ctx.line
  if type(line) ~= "string" or not line:find(name .. "(", 1, true) then
    return nil
  end
  -- The reference must carry a section number; a bare `name(` is a function
  -- call in a SYNOPSIS or an EXAMPLES block, not a link to another page.
  if not line:match(name:gsub("%W", "%%%0") .. "%(%d%w*%)") then
    return nil
  end
  return { symbol = name }
end

return M

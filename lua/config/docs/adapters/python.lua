-- Documentation for a Python name, in the one ecosystem that never agreed on
-- where documentation lives.
--
-- Why this adapter is the awkward one
-- -----------------------------------
-- Go has pkg.go.dev, Rust has docs.rs, Haskell has Hackage — one host, one
-- URL shape, computable from the package name alone. PyPI has nothing of the
-- kind: every project points wherever it likes. Across the 1268 wheel METADATA
-- files installed on this machine, 545 declare a documentation URL and those
-- URLs name well over a hundred distinct hosts (readthedocs subdomains,
-- project domains, GitHub READMEs, googleapis.dev, mongodb.com). In one real
-- 108-package venv the 29 declared doc URLs pointed at 28 different hosts.
-- There is therefore no URL to *construct* for a third-party package, and this
-- file does not pretend otherwise. It only reports what the package itself
-- recorded at install time, runs the interpreter that already has the package,
-- or links out to the PyPI project page — which at least names the thing.
--
-- Hence prefer = "local": pydoc against the project's own interpreter is the
-- only mechanism here that is always right when it answers at all.
--
-- The four traps this file exists to handle
-- -----------------------------------------
-- 1. Import name != distribution name. `yaml` ships in PyYAML, `cv2` in
--    opencv-python, `dateutil` in python-dateutil, `attr` in attrs. The
--    mapping is only recorded on disk, in `top_level.txt` (legacy setuptools,
--    absent from 60 of 108 dists in a modern uv venv) or in `RECORD` (PEP 376,
--    present in all of them). Measured over every site-packages on this
--    machine: of 483 installed top-level names, 375 are just the normalized
--    dist name, 65 need top_level.txt and 43 need RECORD. All three paths are
--    implemented below because dropping any one of them loses real packages.
-- 2. pydoc IMPORTS the module. Side effects are real and unavoidable — that is
--    the price of the only accurate local answer — and it means the argv must
--    name the PROJECT's interpreter. Verified: `.venv/bin/python -m pydoc
--    fastapi` renders the page, the same command via the pyenv `python3` on
--    PATH prints "No Python documentation found for 'fastapi'".
-- 3. pydoc exits 0 on that failure and writes the apology to stdout, so the
--    driver's `res.code ~= 0` fallback never fires and the float would render
--    the apology. `cmd` therefore refuses to emit argv unless something on
--    disk already proves the module is importable.
-- 4. `.venv/bin/python` is a symlink to the base interpreter (uv, virtualenv
--    and venv all do this), so site-packages must be derived from the venv
--    DIRECTORY, never from the resolved interpreter path — following the link
--    lands in the shared toolchain install, which has none of the project's
--    packages.
--
-- Everything below reads files. No network, and no `pip show` / `pip list` /
-- `importlib.metadata` subprocess on the keypress path.

local M = {}

local state = require("util.state")

M.ft = { "python" }

M.manifest = { "pyproject.toml", "requirements.txt", "setup.py" }

-- pydoc against the project interpreter beats every link we could build, and
-- the driver still resolves the web URL in the background and binds it to `o`.
M.prefer = "local"

-- Static, not `python -c "import sys; print(sys.stdlib_module_names)"`.
--
-- Three reasons, in order of weight. The set is needed inside `coord`, which
-- the driver calls synchronously on the keypress and unit-tests as a pure
-- function — a subprocess there either blocks or makes the first press wrong.
-- The set barely moves: taken from the three interpreters installed here
-- (3.10.14, 3.12.10, 3.14.6) the union of non-underscore names is 220, and no
-- release changed it by more than the PEP 594 "dead batteries" removal, which
-- this union deliberately keeps — a 3.14 interpreter no longer ships `telnetlib`
-- but someone reading a 3.9 codebase still wants its page. And half of
-- `sys.stdlib_module_names` is underscore-prefixed C accelerators (86 of 303 on
-- 3.10) that have no docs.python.org page, so the runtime answer would need
-- filtering anyway.
--
-- `_thread` is the one underscore name kept, because CPython's own
-- pydoc.Doc.getdocloc special-cases it into the documented-module list.
local STDLIB_NAMES = [[
_thread abc aifc annotationlib antigravity argparse array ast asynchat asyncio asyncore atexit
audioop base64 bdb binascii binhex bisect builtins bz2 cProfile calendar cgi cgitb chunk cmath cmd
code codecs codeop collections colorsys compileall compression concurrent configparser contextlib
contextvars copy copyreg crypt csv ctypes curses dataclasses datetime dbm decimal difflib dis
distutils doctest email encodings ensurepip enum errno faulthandler fcntl filecmp fileinput fnmatch
fractions ftplib functools gc genericpath getopt getpass gettext glob graphlib grp gzip hashlib
heapq hmac html http idlelib imaplib imghdr imp importlib inspect io ipaddress itertools json
keyword lib2to3 linecache locale logging lzma mailbox mailcap marshal math mimetypes mmap
modulefinder msilib msvcrt multiprocessing netrc nis nntplib nt ntpath nturl2path numbers opcode
operator optparse os ossaudiodev pathlib pdb pickle pickletools pipes pkgutil platform plistlib
poplib posix posixpath pprint profile pstats pty pwd py_compile pyclbr pydoc pydoc_data pyexpat
queue quopri random re readline reprlib resource rlcompleter runpy sched secrets select selectors
shelve shlex shutil signal site smtpd smtplib sndhdr socket socketserver spwd sqlite3 sre_compile
sre_constants sre_parse ssl stat statistics string stringprep struct subprocess sunau symtable sys
sysconfig syslog tabnanny tarfile telnetlib tempfile termios textwrap this threading time timeit
tkinter token tokenize tomllib trace traceback tracemalloc tty turtle turtledemo types typing
unicodedata unittest urllib uu uuid venv warnings wave weakref webbrowser winreg winsound wsgiref
xdrlib xml xmlrpc zipapp zipfile zipimport zlib zoneinfo
]]

local STDLIB = {}
for name in STDLIB_NAMES:gmatch("%S+") do
  STDLIB[name] = true
end

-- Which `Project-URL` labels mean "the documentation", matched exactly rather
-- than by substring. Counted over the 3067 Project-URL lines on this machine:
-- `documentation` 545, `docs: rtd` 30, `docs` 2 — but also `docs: changelog`
-- 25, which a `find("docs")` would happily hand back as the API reference. The
-- label's case varies between projects (numpy and dnspython write it
-- lowercase, everyone else capitalizes), so comparison is on a lowered copy;
-- the field NAME never varies, all 3067 lines start with exactly `Project-URL:`.
local DOC_LABELS = {
  ["documentation"] = true,
  ["docs"] = true,
  ["docs: rtd"] = true,
}

-- Words that are valid identifiers to the driver's dotted-word scan but never
-- name a package. `import` is the one that actually bites: the cursor sitting
-- on it inside `from yaml import x` is, by column, on the right-hand side, and
-- without this it would resolve to `yaml.import` and then to a pypi.org page
-- for a project called "import".
local KEYWORD_NAMES = [[
False None True and as assert async await break class continue def del elif else except finally
for from global if import in is lambda nonlocal not or pass raise return try while with yield
self match case
]]

local KEYWORDS = {}
for word in KEYWORD_NAMES:gmatch("%S+") do
  KEYWORDS[word] = true
end

--- PEP 503 name normalization: the form two spellings of the same package
--- collapse to. `PyYAML`, `pyyaml` and `Py-YAML` all normalize equal, which is
--- what lets a manifest's `python-dotenv` find the `python_dotenv-*.dist-info`
--- directory that pip actually wrote (wheels escape the separator to `_`,
--- METADATA keeps the author's `-`).
---@param name string
---@return string
function M._normalize(name)
  return (name:lower():gsub("[-_.]+", "_"))
end

--- The canonical pypi.org path segment for a distribution: PEP 503 form with
--- `-` as the separator. PyPI redirects the other spellings, but the canonical
--- one is the only spelling we can be sure of without asking the network.
---@param name string
---@return string
local function pypi_slug(name)
  return (name:lower():gsub("[-_.]+", "-"))
end

--- Entry names in `dir`, or nil when it cannot be listed.
---@param dir string|nil
---@return string[]|nil
local function entries(dir)
  local fd = dir and vim.uv.fs_scandir(dir)
  if not fd then
    return nil
  end
  local out = {}
  while true do
    local name = vim.uv.fs_scandir_next(fd)
    if not name then
      break
    end
    out[#out + 1] = name
  end
  return out
end

-- Interpreter, site-packages and the import-name map are all keyed by the
-- directory they were derived from (a project root, or a site-packages path)
-- and all go stale for the same reasons: a venv is created, a package is
-- installed. Both events change the mtime of the directory the answer was
-- derived from, so each slot records that mtime and drops itself when it
-- moves. Cheaper and less coupled than an autocmd, and it matters most for the
-- NEGATIVE answers — "this project has no venv" is the one a long-lived
-- session is most likely to still be believing an hour after `uv sync` fixed it.
local cache = {}

--- Test seam and escape hatch: drop everything memoized about a project.
function M._reset()
  cache = {}
end

--- The memo slot for `dir`, emptied if `dir` has been written to since it was
--- filled.
---@param dir string|nil
---@return table
local function slot(dir)
  local key = dir or ""
  local st = dir and vim.uv.fs_stat(dir)
  -- Nanoseconds as well as seconds. APFS reports both, and a `uv venv` finishing
  -- inside the same wall-clock second as the press that found no venv is not a
  -- hypothetical: it is what happens when someone runs `uv sync` because `gK`
  -- just told them there was nothing installed.
  local mtime = st and st.mtime and (st.mtime.sec .. "." .. (st.mtime.nsec or 0)) or ""
  local entry = cache[key]
  if not entry or entry.mtime ~= mtime then
    entry = { mtime = mtime }
    cache[key] = entry
  end
  return entry
end

--- Resolve a pyenv-managed interpreter for a version request.
---
--- `.python-version` is not the pyenv-only file it used to be: uv writes one
--- too, and it writes a bare minor version. Four of the five `.python-version`
--- files on this machine say `3.12` or `3.13` while `~/.pyenv/versions` holds
--- `3.10.14` and `3.12.10` — an exact directory match finds nothing. So an
--- exact hit is tried first (that is pyenv's own rule) and a component-boundary
--- prefix match is the fallback, taking the highest such version. The boundary
--- check matters: a plain prefix test would let `3.1` claim `3.10.14`.
---@param want string
---@return string|nil
local function pyenv_interpreter(want)
  local pyenv = vim.env.PYENV_ROOT
  if not pyenv or pyenv == "" then
    pyenv = vim.fs.joinpath(vim.env.HOME or "", ".pyenv")
  end
  local versions = vim.fs.joinpath(pyenv, "versions")
  local exact = vim.fs.joinpath(versions, want, "bin", "python")
  if vim.uv.fs_stat(exact) then
    return exact
  end
  local best = nil
  for _, name in ipairs(entries(versions) or {}) do
    if name:sub(1, #want + 1) == want .. "." and (not best or name > best) then
      best = name
    end
  end
  if not best then
    return nil
  end
  local exe = vim.fs.joinpath(versions, best, "bin", "python")
  return vim.uv.fs_stat(exe) and exe or nil
end

--- The virtualenv directory this project's packages live in, if there is one.
---
--- An activated `$VIRTUAL_ENV` only counts when it sits under the project root.
--- Neovim inherits whatever shell it was launched from, and an env var pointing
--- at some other project's venv is worse than no answer: it resolves imports
--- against packages this project never declared.
---@param root string|nil
---@return string|nil
local function venv_dir(root)
  if root then
    for _, name in ipairs({ ".venv", "venv" }) do
      local dir = vim.fs.joinpath(root, name)
      if vim.uv.fs_stat(vim.fs.joinpath(dir, "pyvenv.cfg")) then
        return dir
      end
    end
  end
  local active = vim.env.VIRTUAL_ENV
  if active and active ~= "" and (not root or vim.startswith(active, root)) then
    if vim.uv.fs_stat(vim.fs.joinpath(active, "pyvenv.cfg")) then
      return active
    end
  end
  return nil
end

--- The interpreter that can actually import this project's dependencies.
---
--- The ladder ends at `python3` on PATH, which on this machine is a pyenv shim
--- — a shell script that re-reads `.python-version` relative to the process
--- CWD. `cmd` argv is run by the driver with Neovim's cwd, not the project's,
--- so the shim would resolve against the wrong directory. That is exactly why
--- the pyenv rung above it returns an absolute `versions/<v>/bin/python`
--- instead of deferring to the shim; the shim is only ever the last resort,
--- when nothing else identified an interpreter at all.
---@param ctx DocCtx
---@return string|nil
local function interpreter(ctx)
  local s = slot(ctx.root)
  if s.exe ~= nil then
    return s.exe or nil
  end

  local exe = nil
  local venv = venv_dir(ctx.root)
  if venv then
    local candidate = vim.fs.joinpath(venv, "bin", "python")
    exe = vim.uv.fs_stat(candidate) and candidate or nil
  end
  if not exe and ctx.root then
    local pinned = state.read_file(vim.fs.joinpath(ctx.root, ".python-version"))
    local want = pinned and pinned:match("^%s*([%w%.%-_]+)")
    if want then
      exe = pyenv_interpreter(want)
    end
  end
  if not exe then
    local found = vim.fn.exepath("python3")
    exe = found ~= "" and found or nil
  end

  s.exe = exe or false
  return exe
end

--- The project's site-packages directory.
---
--- Built from the venv DIRECTORY, never from the interpreter path: every venv
--- builder symlinks `bin/python` at the base install, so `dirname(dirname())`
--- of the resolved exe points at the toolchain, which holds none of the
--- project's packages. With no venv, the same `<prefix>/lib/python*/
--- site-packages` shape does hold for a pyenv version directory, so the
--- interpreter's grandparent is a correct fallback there — it is only the
--- symlink that makes it wrong for a venv.
---@param ctx DocCtx
---@return string|nil
local function site_packages(ctx)
  -- The picker resolves a URL from a row rather than a cursor, so `url` can be
  -- called with no context at all. Everything below reads ctx.root; without one
  -- there is no interpreter to find and no site-packages to scan.
  if type(ctx) ~= "table" then
    return nil
  end
  if slot(ctx.root).sp ~= nil then
    return slot(ctx.root).sp or nil
  end

  local base = venv_dir(ctx.root)
  if not base then
    local exe = interpreter(ctx)
    -- The pyenv shim has no lib/ of its own; its grandparent is ~/.pyenv.
    -- A miss here just means no METADATA, which the caller already handles.
    base = exe and vim.fs.dirname(vim.fs.dirname(exe)) or nil
  end

  local found = nil
  for _, name in ipairs(entries(base and vim.fs.joinpath(base, "lib")) or {}) do
    if name:match("^python%d") then
      local dir = vim.fs.joinpath(base, "lib", name, "site-packages")
      if vim.uv.fs_stat(dir) then
        found = dir
        break
      end
    end
  end

  -- Re-fetched rather than held across the `interpreter` call above: that call
  -- also goes through `slot`, which hands back a fresh table if the root was
  -- written to in between, and the answer must land in the live one.
  slot(ctx.root).sp = found or false
  return found
end

--- The `.dist-info` directories in `sp`, indexed by normalized dist name.
--- `slot` already drops this when an install has touched `sp`.
---@param sp string
---@return { dists: string[], by_dist: table<string, string>, by_module: table|nil }
local function dist_index(sp)
  local s = slot(sp)
  if s.index then
    return s.index
  end

  local index = { dists = {}, by_dist = {}, by_module = nil }
  for _, name in ipairs(entries(sp) or {}) do
    local stem = name:match("^(.+)%.dist%-info$")
    if stem then
      -- `<name>-<version>.dist-info`; versions never contain a hyphen, so the
      -- last one is the split point.
      local dist = stem:match("^(.*)%-[^%-]*$") or stem
      index.dists[#index.dists + 1] = name
      index.by_dist[M._normalize(dist)] = name
    end
  end
  s.index = index
  return index
end

--- Top-level import names a dist-info directory claims.
---
--- top_level.txt first because it is tiny (583 bytes for all 108 dists in a
--- real venv) — but it is a legacy setuptools artifact that hatchling, flit,
--- poetry-core and uv_build all omit, missing from 60 of those 108. RECORD is
--- the PEP 376 file every installer writes, at the cost of being three orders
--- of magnitude larger (723 KB for the same 108), so it is only read when
--- top_level.txt was absent.
---
--- RECORD lists installed paths, which is not the same as importable names:
--- `../../../bin/black` is a console script outside site-packages entirely,
--- `<dist>.data/` is the wheel data tree, `six.py` is a single-file module that
--- has to lose its extension, and `_lola_common.pth` is an editable install's
--- path hook whose real package lives somewhere else on disk. All four are
--- filtered; the editable case is why the caller tries the normalized dist name
--- before it ever gets here.
---@param dir string
---@return string[]
local function top_levels(dir)
  local out = {}
  local raw = state.read_file(vim.fs.joinpath(dir, "top_level.txt"))
  if raw then
    for line in raw:gmatch("[^\r\n]+") do
      local name = vim.trim(line)
      if name ~= "" then
        out[#out + 1] = name
      end
    end
    return out
  end

  raw = state.read_file(vim.fs.joinpath(dir, "RECORD"))
  if not raw then
    return out
  end
  local seen = {}
  for line in raw:gmatch("[^\r\n]+") do
    local path = line:match("^([^,]+)")
    local first = path and path:match("^([^/]+)")
    if first and not vim.startswith(first, "..") and not first:match("%.dist%-info$") then
      if not first:match("%.data$") and not first:match("%.pth$") then
        -- A top-level single-file module: strip the source or extension-module
        -- suffix (`six.py`, `_cffi_backend.cpython-312-darwin.so`).
        local name = first:match("^([^%.]+)%.[%w%.%-]+$") or first
        if name ~= "" and not seen[name] then
          seen[name] = true
          out[#out + 1] = name
        end
      end
    end
  end
  return out
end

--- Which installed distribution owns the top-level import name `module`.
---
--- Cheap path first: 375 of the 483 installed top-level names on this machine
--- are just the normalized dist name, and that answer costs one directory
--- listing and no file reads. Only a miss pays for the reverse map, and only
--- when the module is present in site-packages at all — the map is built by
--- opening every dist's metadata, which is not something to do to conclude
--- "that name is not installed here".
---@param sp string
---@param module string
---@return string|nil dist-info directory name
local function dist_for_module(sp, module)
  local index = dist_index(sp)
  local direct = index.by_dist[M._normalize(module)]
  if direct then
    return direct
  end
  if
    not vim.uv.fs_stat(vim.fs.joinpath(sp, module))
    and not vim.uv.fs_stat(vim.fs.joinpath(sp, module .. ".py"))
  then
    return nil
  end
  if not index.by_module then
    local map = {}
    for _, name in ipairs(index.dists) do
      for _, top in ipairs(top_levels(vim.fs.joinpath(sp, name))) do
        map[top] = map[top] or name
      end
    end
    index.by_module = map
  end
  return index.by_module[module]
end

--- Parse a wheel METADATA blob.
---
--- Only the header block, which ends at the first truly empty line — the
--- description body that follows is a whole README and would otherwise be
--- scanned for headers it may well contain. "Truly empty" is load-bearing:
--- pandas folds its entire BSD license into the `License:` field as indented
--- continuation lines, several of which are whitespace-only, so a `blank line`
--- test that trimmed first would cut the header block in half. Continuation
--- lines are indented and so can never match a column-0 field name; verified
--- across all 1268 METADATA files on this machine, zero body lines would
--- false-match under this rule.
---@param raw string|nil
---@return { name: string|nil, version: string|nil, doc: string|nil }
function M._metadata(raw)
  local out = {}
  if type(raw) ~= "string" then
    return out
  end
  for physical in raw:gmatch("([^\n]*)\n?") do
    -- A wheel built on Windows carries CRLF, and a trailing \r would ride along
    -- inside the captured URL and produce an unopenable target.
    local line = (physical:gsub("\r$", ""))
    if line == "" then
      break
    end
    local label, url = line:match("^Project%-URL:%s*([^,]+),%s*(%S+)")
    if label and not out.doc and DOC_LABELS[vim.trim(label):lower()] then
      out.doc = url
    elseif not out.name then
      out.name = line:match("^Name:%s*(%S+)")
    end
    out.version = out.version or line:match("^Version:%s*(%S+)")
  end
  return out
end

--- Is this dist a local checkout rather than something published to an index?
---
--- PEP 610 writes `direct_url.json` only for installs from a path, VCS or URL.
--- In a real workspace venv here it marks exactly the 12 editable first-party
--- packages out of 108. They have no pypi.org page, and offering one produces a
--- confident link to a 404 — the picker would rather say "no documentation URL
--- for lola-common", which is the truth.
---@param dir string
---@return boolean
local function is_local_dist(dir)
  return vim.uv.fs_stat(vim.fs.joinpath(dir, "direct_url.json")) ~= nil
end

--- The dotted module path the cursor is really pointing at.
---
--- `from yaml import safe_load` is the trap: on `safe_load` the driver's dotted
--- word is just `safe_load`, which names nothing importable and would resolve
--- to a project-local guess or a search. The `from` clause on the same line
--- carries the missing half. The cursor's column decides which half it is on,
--- so `from yaml import safe_load` resolves to `yaml` from the left of the
--- `import` and `yaml.safe_load` from the right.
---
--- A leading dot (`from .models import User`) is a relative import: nothing to
--- look up, and the pattern's `^[%a_]` anchor drops it.
---@param ctx DocCtx
---@return string|nil
function M._target(ctx)
  local word = ctx.word or ""
  if not word:match("^[%a_][%w_%.]*$") or KEYWORDS[word] then
    return nil
  end
  local line = ctx.line or ""
  if not word:find("%.", 1, true) then
    local from = line:match("^%s*from%s+([%a_][%w_%.]*)%s+import%f[%W]")
    local ipos = line:find("%f[%w]import%f[%W]")
    if from and ipos and (ctx.col or 0) >= ipos then
      return from .. "." .. word
    end
  end
  return word
end

--- Does the project define this top-level name itself?
---
--- A buffer's own `types.py` or `email.py` shadows the stdlib at import time,
--- and pointing at docs.python.org for it is not a near miss, it is the wrong
--- module entirely. Returning nil here lets the driver fall through to the LSP
--- hover, which knows about the user's own code. Only the two layouts a
--- manifest root implies are probed (flat and `src/`), because a deeper search
--- on every keypress buys almost nothing.
---@param root string|nil
---@param module string
---@return boolean
local function is_project_module(root, module)
  if not root then
    return false
  end
  for _, base in ipairs({ root, vim.fs.joinpath(root, "src") }) do
    if
      vim.uv.fs_stat(vim.fs.joinpath(base, module, "__init__.py"))
      or vim.uv.fs_stat(vim.fs.joinpath(base, module .. ".py"))
    then
      return true
    end
  end
  return false
end

--- Cursor position -> package coordinates.
---
--- Stdlib is tested before site-packages because that is the import order
--- CPython itself uses: the stdlib directory precedes site-packages on
--- sys.path, so a dist that installs a top-level `profile` module does not in
--- fact shadow `profile`.
---@param ctx DocCtx
---@return DocCoord|nil
function M.coord(ctx)
  if type(ctx) ~= "table" then
    return nil
  end
  local target = M._target(ctx)
  if not target then
    return nil
  end
  local module = target:match("^([%a_][%w_]*)")
  if not module then
    return nil
  end

  if is_project_module(ctx.root, module) then
    return nil
  end

  if STDLIB[module] then
    return { pkg = module, symbol = target ~= module and target or nil, stdlib = true }
  end

  local sp = site_packages(ctx)
  local dist = sp and dist_for_module(sp, module)
  if dist then
    local meta = M._metadata(state.read_file(vim.fs.joinpath(sp, dist, "METADATA")))
    -- The METADATA `Name` is the author's spelling (`python-dateutil`); the
    -- directory name is the wheel-escaped one (`python_dateutil`). Both
    -- normalize to the same key, so either finds the dist again later, but the
    -- author's spelling is the one a human recognizes in the picker.
    return { pkg = meta.name or dist:match("^(.*)%-[^%-]*%.dist%-info$") or module, symbol = target }
  end

  -- Nothing on disk to consult: no venv, or a package this environment never
  -- installed. The import name is the only guess available, and it is right
  -- for the majority of packages (requests, numpy, click) — the ones where it
  -- is wrong are exactly the ones a resolvable site-packages would have fixed.
  return { pkg = module, symbol = target ~= module and target or nil }
end

--- Coordinates -> a documentation URL.
---
--- Stdlib is the only computable case here, and the template is not invented:
--- CPython's own pydoc.Doc.getdocloc builds `<docs root>/library/<module
--- lowered>.html`, and that lowercasing is mirrored rather than reasoned about.
--- `/3/` rather than the pinned `/3.12/` pydoc emits, because no version is
--- resolved anywhere in this file.
---
--- The page is the ROOT module and the anchor is the fully qualified name,
--- which is the Sphinx `py:` object id. Right for the overwhelmingly common
--- `module.member` shape (`json.dumps` -> json.html#json.dumps), and a near
--- miss for a dotted submodule that was granted its own page: `os.path.join`
--- lands at the top of os.html instead of the anchor on os.path.html. Closing
--- that gap offline would take a hand-maintained list of which stdlib
--- submodules have their own page — `os.path` and `xml.etree.ElementTree` do,
--- `email.mime.text` does not — and nothing on disk records the difference,
--- including pydoc, which happily reports a docs URL for all three.
---@param c DocCoord
---@param ctx DocCtx
---@return string|nil
function M.url(c, ctx)
  if not c or not c.pkg then
    return nil
  end

  if c.stdlib then
    local url = "https://docs.python.org/3/library/" .. c.pkg:lower() .. ".html"
    return c.symbol and (url .. "#" .. c.symbol) or url
  end

  local sp = site_packages(ctx)
  local dist = sp and dist_index(sp).by_dist[M._normalize(c.pkg)]
  if dist then
    local dir = vim.fs.joinpath(sp, dist)
    if is_local_dist(dir) then
      return nil
    end
    -- Version-exact, offline, and the only thing that works for private and
    -- Artifactory-hosted packages, where the PyPI API has nothing to say. It
    -- is also the only source that is ever *right*: 545 of 1268 wheels here
    -- declare one, and no two ecosystems' worth of guessing would reproduce
    -- the other host names.
    local doc = M._metadata(state.read_file(vim.fs.joinpath(dir, "METADATA"))).doc
    if doc then
      return doc
    end
  end

  -- The honest floor. Not a documentation page — the PyPI project page is a
  -- README and a links sidebar — but it names the right package and carries
  -- whatever links the author did publish.
  return "https://pypi.org/project/" .. pypi_slug(c.pkg) .. "/"
end

--- Coordinates -> argv for the float.
---
--- Gated on evidence, because `python -m pydoc nonexistent` exits 0 and prints
--- "No Python documentation found for 'nonexistent'." to stdout. The driver
--- falls back on a nonzero exit or empty stdout, so an ungated argv would
--- render that apology in the float and never reach the web URL behind it.
--- Emitting nothing instead is a supported outcome and lets the cascade run.
---
--- Nothing here can stop pydoc importing the module and running whatever its
--- `__init__` does. That is inherent to pydoc and is the reason this adapter's
--- local answer is accurate at all; there is no read-only mode to ask for.
---@param c DocCoord
---@param ctx DocCtx
---@return string[]|nil
function M.cmd(c, ctx)
  if not c then
    return nil
  end
  local target = c.symbol or c.pkg
  if not target then
    return nil
  end
  local module = target:match("^([%a_][%w_]*)")
  if not module then
    return nil
  end

  local exe = interpreter(ctx)
  if not exe then
    return nil
  end
  if not c.stdlib then
    local sp = site_packages(ctx)
    if not sp or not dist_for_module(sp, module) then
      return nil
    end
  end
  return { exe, "-m", "pydoc", target }
end

--- Strip a trailing `#` comment, respecting quotes.
---
--- `dependencies = ["ruff>=0.9",  # linter` is ordinary formatting, but so is
--- a `#` inside a requirement string, so a plain `gsub("#.*", "")` cannot be
--- used on either manifest.
---@param line string
---@return string
local function strip_comment(line)
  local quote = nil
  for i = 1, #line do
    local c = line:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == "#" then
      return line:sub(1, i - 1)
    end
  end
  return line
end

--- Split a PEP 508 requirement into a name and the declared constraint.
---
--- Real shapes verified against manifests on this machine: `click>=8.1`,
--- `fastapi[standard]>=0.128.8` and poetry-core's parenthesized export
--- `langgraph (>=0.3.34,<0.4.0)`. The constraint is reported verbatim; nothing
--- here resolves it to an installed version, which is deliberate — the picker
--- shows what the project declared.
---@param text string
---@return string|nil name
---@return string|nil constraint
function M._requirement(text)
  text = vim.trim((strip_comment(text):gsub(";.*$", "")))
  local name = text:match("^([%a%d][%w._-]*)")
  if not name then
    return nil
  end
  local rest = vim.trim((text:sub(#name + 1):gsub("^%b[]", "")))
  rest = rest:match("^%((.*)%)$") or rest
  return name, rest ~= "" and rest or nil
end

--- Dependencies declared in a pyproject.toml.
---
--- A deliberately small TOML reader rather than a parser: the only shapes that
--- matter are a table header, an array of requirement strings, and poetry's
--- `name = constraint` rows. An array is accumulated until a line whose last
--- non-space character is `]`, which is quote-safe in a way that scanning for
--- the character is not — `"fastapi[standard]>=0.128.8",` contains a `]` that
--- closes nothing.
---
--- Optional extras and dependency groups are collected as `direct`: they are
--- things the project itself asked for, and the picker's only other kind
--- (`indirect`) means "not declared here", which would misfile them.
---@param raw string|nil
---@return table[]
function M._parse_pyproject(raw)
  local rows, seen = {}, {}
  if type(raw) ~= "string" then
    return rows
  end

  local function add(name, version, kind)
    if name and not seen[name] then
      seen[name] = true
      rows[#rows + 1] = { name = name, version = version, kind = kind }
    end
  end

  local section, buffered = "", nil
  for physical in raw:gmatch("[^\r\n]+") do
    local line = strip_comment(physical)
    if buffered then
      buffered = buffered .. " " .. line
      if line:match("%]%s*$") then
        for item in buffered:gmatch("[\"']([^\"']+)[\"']") do
          add(M._requirement(item))
        end
        buffered = nil
      end
    else
      -- `[[tool.poetry.packages]]` is an array-of-tables header, and it has to
      -- be recognized even though nothing is collected from it: missing it
      -- leaves `section` pointing at the dependency table above, and poetry's
      -- `include = "pkg"` rows then get filed as dependencies named "include".
      local header = line:match("^%s*%[%[%s*([^%]]-)%s*%]%]%s*$")
        or line:match("^%s*%[%s*([^%]]-)%s*%]%s*$")
      if header then
        section = header
      elseif section == "project" and line:match("^%s*dependencies%s*=") then
        buffered = line
      elseif section == "project.optional-dependencies" or section == "dependency-groups" then
        if line:match("=%s*%[") then
          buffered = line
        end
      elseif
        section == "tool.poetry.dependencies"
        or section == "tool.poetry.dev-dependencies"
        or section:match("^tool%.poetry%.group%.[^%.]+%.dependencies$")
      then
        -- Poetry's own table form, still the shape in projects that never
        -- migrated to PEP 621. `python = "^3.12"` is the interpreter
        -- constraint, not a dependency, and has no PyPI page.
        local name, value = line:match("^%s*([%w._-]+)%s*=%s*(.+)$")
        if name and name ~= "python" then
          local version = value:match("[\"']([^\"']+)[\"']")
          add(name, version, "direct")
        end
      end
      -- A one-line array closes in the same iteration it opened.
      if buffered and buffered:match("%]%s*$") then
        for item in buffered:gmatch("[\"']([^\"']+)[\"']") do
          add(M._requirement(item))
        end
        buffered = nil
      end
    end
  end

  for _, row in ipairs(rows) do
    row.kind = row.kind or "direct"
  end
  return rows
end

--- Dependencies declared in a requirements.txt.
---
--- `-r other.txt` is not followed and `-e path` is skipped: the first would
--- turn a file read into a walk of unknown depth, and the second names a local
--- checkout with no package page to open.
---@param raw string|nil
---@return table[]
function M._parse_requirements(raw)
  local rows, seen = {}, {}
  if type(raw) ~= "string" then
    return rows
  end
  for physical in raw:gmatch("[^\r\n]+") do
    local line = vim.trim(strip_comment(physical))
    if line ~= "" and not line:match("^-") then
      local name, version = M._requirement(line)
      if name and not seen[name] then
        seen[name] = true
        rows[#rows + 1] = { name = name, version = version, kind = "direct" }
      end
    end
  end
  return rows
end

--- Direct dependencies of the project around `ctx.root`, for the picker.
---
--- Manifest first, always. The fallback to site-packages only fires when the
--- manifest declared nothing — which is a real configuration, not a
--- pathological one: a uv or poetry workspace root carries a pyproject.toml
--- whose members hold all the actual dependencies. Those rows are marked
--- `indirect` so the picker sinks and labels them, because "everything
--- installed in the venv" is a different and weaker claim than "what this
--- project asked for", and the driver's row kinds have no third word for it.
---
--- The fallback reads no METADATA: 100+ header blocks (pandas' alone is 30 KB)
--- to recover a hyphen the picker does not need, since `url` normalizes the
--- directory spelling back to the same distribution anyway.
---@param ctx DocCtx
---@return table[]|nil
function M.deps(ctx)
  if not ctx.root then
    return nil
  end

  local rows = M._parse_pyproject(state.read_file(vim.fs.joinpath(ctx.root, "pyproject.toml")))
  if #rows == 0 then
    rows = M._parse_requirements(state.read_file(vim.fs.joinpath(ctx.root, "requirements.txt")))
  end
  if #rows > 0 then
    return rows
  end

  local sp = site_packages(ctx)
  if not sp then
    return nil
  end
  local out = {}
  for _, dir in ipairs(dist_index(sp).dists) do
    local stem = dir:match("^(.+)%.dist%-info$")
    local name, version = stem:match("^(.*)%-([^%-]*)$")
    out[#out + 1] = { name = name or stem, version = version, kind = "indirect" }
  end
  return out
end

return M

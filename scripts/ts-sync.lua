-- Install treesitter parsers at the revisions parser-revisions.lua holds, and
-- verify it happened. Driven by scripts/warm-cache.sh and scripts/update-pins.sh.
--
-- Driven from a file rather than inlined into `nvim -c` for the same reason as
-- scripts/mason-sync.lua: what stood here before — `nvim --headless
-- "+TSUpdate sync" "+qa"` — was a double no-op that still exited 0.
--
-- 1. `sync` IS NOT A MODE, IT IS A LANGUAGE. `:TSUpdateSync` belongs to
--    nvim-treesitter's master branch; on `main` the args of `:TSUpdate` go
--    straight to norm_languages, which drops `sync` (not installed, no registry
--    entry) and returns an empty list. update() then logs "All parsers are
--    up-to-date" and returns true. Verified against the live plugin:
--    norm_languages({ "sync" }, { missing = true, unsupported = true }) == {}.
--
-- 2. INSTALL IS ASYNC. install()/update() return an async task; the `+qa` that
--    followed quit before the first download finished, so even the correct
--    command installed nothing. Verified by corrupting a parser's revision
--    stamp: it survived both `+TSUpdate sync` and a bare `+TSUpdate`
--    untouched, and was rebuilt only once the task was awaited.
--
-- Both bugs predate the pins becoming prescriptive, but they matter more now:
-- config.ts_pinned rewrites install_info.revision, so the pin decides which
-- grammar tarball is downloaded, while the QUERIES are symlinked live out of
-- the nvim-treesitter checkout. The two must move together, which needs an
-- install path that actually runs and is actually checked.
--
-- The order below is not arbitrary. Each step exists because the step after it
-- cannot survive the state the step before it leaves:
--
--   1. SKIP PINS THE REGISTRY DROPPED, with a warning. Upstream removes
--      grammars; a pin it no longer carries is drift for the maintainer to
--      resolve, not a reason to abort before the other 30-odd parsers are
--      touched. This used to fail the run outright ("want no registry entry").
--
--   2. FORCE-INSTALL EVERY HALF-INSTALLED LANGUAGE, before update() is allowed
--      near them. update() reads the revision stamp under an assert(), and
--      get_installed() calls a language installed on the strength of its
--      queries directory alone — so one missing stamp threw a traceback out of
--      the whole run, took the mason step down with it (`set -e`), and left
--      the stamp missing, which meant the next run failed identically. Forced,
--      because install() without force early-returns for anything
--      get_installed() claims is already there. See config.ts_sync.unbuilt.
--
--   3. UPDATE THE REST, which is the only call that compares the installed
--      stamp against the pin and rebuilds what differs. Safe by now: step 2
--      guarantees every remaining language has both files on disk.
--
--   4. VERIFY ON DISK, twice — the revision that was really installed, and
--      the pin that was really applied. See config.ts_sync for why the return
--      values of install()/update() are worth nothing here.
--
-- There is deliberately no mode switch. The pins are prescriptive in both
-- directions: `make warm` and `make update` run this script identically, so
-- neither can install a revision parser-revisions.lua does not name. Advancing
-- a pin to follow an nvim-treesitter bump is a hand edit — see the comment on
-- the parser step in scripts/update-pins.sh.

local function fail(msg)
  io.stderr:write("ts-sync: " .. msg .. "\n")
  os.exit(1)
end

local function warn(msg)
  io.stderr:write("ts-sync: warning: " .. msg .. "\n")
end

-- Every require goes through this. Headless nvim exits 0 even when a
-- `-c luafile` script throws, so an unguarded require of a plugin that isn't
-- installed yet would read as success to the calling shell script. (The last
-- line of defence is warm-cache.sh's check block, which compares the stamps to
-- the pin file immediately afterwards — but failing here names the cause.)
local function need(mod)
  local ok, m = pcall(require, mod)
  if not ok then
    fail("could not load " .. mod .. " — is nvim-treesitter installed? " .. tostring(m))
  end
  return m
end

-- Generous: a cold cache compiles every pinned grammar from source, and a
-- single slow clone shouldn't fail the run.
local TIMEOUT = 900000

local function main()
  -- stdpath("config"), not the repo root the calling script computed: this is
  -- the path lua/plugins/treesitter.lua reads, so it is the one that decides
  -- what was installed. The two normally agree; naming it makes it obvious when
  -- they don't.
  local revs_path = vim.fs.joinpath(vim.fn.stdpath("config"), "parser-revisions.lua")
  if vim.fn.filereadable(revs_path) ~= 1 then
    fail("no readable pin file at " .. revs_path .. "; nothing is pinned")
  end
  local revisions = dofile(revs_path)
  local languages = vim.tbl_keys(revisions)
  table.sort(languages)
  if #languages == 0 then
    fail(revs_path .. " pins no parsers; refusing to sync")
  end

  local install = need("nvim-treesitter.install")
  local sync = need("config.ts_sync")
  local ts_config = need("nvim-treesitter.config")
  local info_dir = ts_config.get_install_dir("parser-info")
  local parser_dir = ts_config.get_install_dir("parser")

  -- Read the registry the way nvim-treesitter's own reload_parsers() does, in
  -- the same order: drop the cached module so the table is rebuilt from the
  -- plugin's current source, then fire `User TSUpdate` so config.ts_pinned
  -- writes its pins into that fresh table. A table read any other way is one
  -- the installer is about to throw away, and judging pins against it would be
  -- judging the wrong table.
  package.loaded["nvim-treesitter.parsers"] = nil
  vim.api.nvim_exec_autocmds("User", { pattern = "TSUpdate" })

  -- Step 1: pins upstream no longer carries. Warn, name them, carry on.
  local dropped = sync.unregistered(languages, need("nvim-treesitter.parsers"))
  if #dropped > 0 then
    for _, lang in ipairs(dropped) do
      warn(
        ("%s is pinned but nvim-treesitter's registry has no entry for it; "):format(lang)
          .. ("drop it from %s"):format(revs_path)
      )
    end
    languages = vim.tbl_filter(function(lang)
      return not vim.list_contains(dropped, lang)
    end, languages)
    if #languages == 0 then
      fail("every pinned parser was dropped from nvim-treesitter's registry; nothing to install")
    end
  end

  -- Step 2 + 3. Both calls are awaited, and both are needed: a forced install
  -- is the only thing that repairs a half-installed language, and update() is
  -- the only thing that notices a pin that MOVED. install() is not called for
  -- the whole set — without force it early-returns for everything already on
  -- disk, so it would only ever repeat what step 2 just did.
  local unbuilt = sync.unbuilt(languages, info_dir, parser_dir)
  local ok, err = pcall(function()
    if #unbuilt > 0 then
      install.install(unbuilt, { force = true }):wait(TIMEOUT)
    end
  end)
  if not ok then
    fail("parser install failed: " .. tostring(err))
  end

  -- Re-stat before update() rather than trusting the call above: a forced
  -- install that failed for one language leaves it stampless, and update()
  -- would then throw the very traceback this step exists to prevent. Failing
  -- here names the language instead of pointing at nvim-treesitter's internals.
  local still_unbuilt = sync.unbuilt(languages, info_dir, parser_dir)
  if #still_unbuilt > 0 then
    fail(
      "parsers still not installed after a forced install:\n  "
        .. table.concat(still_unbuilt, "\n  ")
    )
  end

  ok, err = pcall(function()
    install.update(languages):wait(TIMEOUT)
  end)
  if not ok then
    fail("parser update failed: " .. tostring(err))
  end

  -- Step 4a: what is on disk. The parser table is re-read after the calls
  -- above, because install()/update() each reloaded it.
  local parsers = need("nvim-treesitter.parsers")
  local drift = sync.drift(languages, parsers, info_dir, parser_dir)
  if #drift > 0 then
    fail("parsers left at the wrong revision:\n  " .. table.concat(drift, "\n  "))
  end

  -- Step 4b: the pin seam itself. If config.ts_pinned's autocmd were not
  -- registered (or were registered too late), the parser table would still hold
  -- the bundled revisions here and the drift check above would have passed
  -- against those — silently installing something other than what
  -- parser-revisions.lua pins.
  local unpinned = {}
  for _, lang in ipairs(languages) do
    local entry = parsers[lang]
    local want = entry and entry.install_info and entry.install_info.revision
    if want ~= revisions[lang] then
      unpinned[#unpinned + 1] = ("%s: pinned %s, registry %s"):format(
        lang,
        revisions[lang],
        tostring(want)
      )
    end
  end
  if #unpinned > 0 then
    fail("pins never reached the installer:\n  " .. table.concat(unpinned, "\n  "))
  end
end

-- Everything above is a function so that this guard can cover all of it. A
-- statement left outside it would be a statement whose error headless nvim
-- swallows: `nvim --headless -c luafile` prints the traceback and still exits
-- 0, which the calling shell script reads as a clean sync. Verified, not
-- assumed. fail() is what makes the exit non-zero, so every path out of main()
-- has to reach it — including the ones nobody predicted, hence xpcall.
local ok, err = xpcall(main, debug.traceback)
if not ok then
  fail("unhandled error:\n" .. tostring(err))
end

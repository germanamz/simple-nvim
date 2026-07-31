-- Install/verify mason tools at the pinned versions, for scripts/warm-cache.sh.
--
-- Driven from a file rather than inlined into `nvim -c` because it has to do
-- three things a bare `+MasonToolsInstallSync` could not, and each needs
-- explaining.
--
-- 1. LOAD THE PLUGIN. mason-tool-installer is lazy-loaded on
--    BufReadPre/BufNewFile (its spec in lua/plugins/lsp.lua), so in a bare
--    headless invocation lazy.nvim never sources the plugin/ file that defines
--    the MasonTools* commands. `+MasonToolsInstallSync` therefore failed with
--    E492 "Not an editor command" — and headless nvim exits 0 regardless, so
--    `make sync` installed nothing and reported success. Loaded explicitly
--    instead of by opening a dummy file: the file would be incidental, the load
--    is what is actually meant.
--
-- 2. USE THE COMMAND THAT IGNORES THE DEBOUNCE. InstallSync passes
--    force_update = false, which makes the plugin honour our
--    debounce_hours = 24 and skip the whole run if any nvim checked within the
--    last day — a second way for a sync to quietly do nothing. UpdateSync
--    passes force_update = true. It cannot drift past the lockfile: every
--    ensure_installed entry carries an explicit `version`, and on that branch
--    mason-tool-installer only ever installs the pinned version, with
--    force_update reaching no further than the debounce gate.
--
-- 3. FAIL LOUDLY. Every failure below exits non-zero. A failed INSTALL is not
--    detected here — warm-cache.sh's check block compares the lockfile against
--    each mason receipt immediately afterwards, and that is what catches it.
--
-- Success deliberately does NOT call os.exit: warm-cache.sh passes "+qa" after
-- this, so a normal shutdown flushes as usual.

local function fail(msg)
  io.stderr:write("mason-sync: " .. msg .. "\n")
  os.exit(1)
end

local ok, err = pcall(function()
  require("lazy").load({ plugins = { "mason-tool-installer.nvim" } })
end)
if not ok then
  fail("could not load mason-tool-installer.nvim: " .. tostring(err))
end

-- The direct assertion that bug 1 above is fixed: if the plugin did not load,
-- the command does not exist and every later step would be a no-op.
if vim.fn.exists(":MasonToolsUpdateSync") ~= 2 then
  fail("MasonToolsUpdateSync undefined after loading mason-tool-installer.nvim")
end

local ran, cmd_err = pcall(vim.cmd, "MasonToolsUpdateSync")
if not ran then
  fail("MasonToolsUpdateSync failed: " .. tostring(cmd_err))
end

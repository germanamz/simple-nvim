-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
-- True on a fresh machine where lazy.nvim is not yet present. lazy.nvim
-- auto-installs missing plugins at branch HEAD (it ignores lazy-lock.json on
-- first install), so we restore to the locked commits afterwards.
local fresh_install = not (vim.uv or vim.loop).fs_stat(lazypath)
if fresh_install then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out =
    vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Skip python3 provider detection: the bundled python ftplugin's has('python3')
-- check otherwise probes every interpreter on PATH (pyenv shims, ~0.7-1.4s),
-- stalling the first Python buffer. Nothing here uses :python3/pynvim —
-- completion is blink.cmp + pyright, formatting is conform.
vim.g.loaded_python3_provider = 0

-- `.tmpl` defaults to filetype `template` (no parser/LSP). Go projects use it
-- for html/template, so treat it as gohtmltmpl: html treesitter + autotag (see
-- lua/plugins/treesitter.lua, lua/plugins/nvim-ts-autotag.lua) without pulling
-- in the html LSP/prettier, which would choke on `{{ ... }}` actions.
vim.filetype.add({ extension = { mdx = "mdx", tmpl = "gohtmltmpl" } })

require("config.options")
require("config.lsp_refs").setup()
require("config.statusline").setup()
require("config.block_guides").setup()
require("config.markdown_preview").setup()
require("config.wikilinks").setup()
require("config.dir_cache").setup()

vim.keymap.set("n", "<leader>k?", function()
  vim.cmd.edit(vim.fn.stdpath("config") .. "/docs/keybindings.md")
end, { desc = "Open keybindings cheatsheet" })

-- netrw fallback (nvim-tree owns <leader>e). Buffers stay loaded (just
-- hidden); `:b#` or <C-^> jumps back to the previous buffer.
vim.keymap.set("n", "<leader>E", "<cmd>Explore<cr>", { desc = "Open file tree (netrw)" })

-- Slurp a whole file as a string (or nil if it can't be opened). Shared by the
-- two plain-file readers below — plugin HEADs and lazy-lock.json — so the
-- open/read/close dance lives in one place.
local function read_file(p)
  local f = io.open(p, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

-- Resolve the commit a plugin clone is sitting on, via plain file reads (no
-- process spawns): detached HEAD holds the sha directly; a `ref:` HEAD is
-- resolved through the loose ref file, falling back to packed-refs.
local function installed_commit(dir)
  local head = read_file(dir .. "/.git/HEAD")
  if not head then
    return nil
  end
  head = vim.trim(head)
  local ref = head:match("^ref:%s*(.+)$")
  if not ref then
    return head
  end
  local loose = read_file(dir .. "/.git/" .. ref)
  if loose then
    return vim.trim(loose)
  end
  for line in (read_file(dir .. "/.git/packed-refs") or ""):gmatch("[^\n]+") do
    local sha, name = line:match("^(%x+) (.+)$")
    if name == ref then
      return sha
    end
  end
  return nil
end

-- Fresh installs restore to the lockfile below, but an existing machine that
-- pulls lockfile updates never re-applied them: plugins silently drift from
-- their pins (or never install at all). Compare installed commits against
-- lazy-lock.json after startup and warn so drift is never silent.
local function warn_on_lock_drift()
  local raw = read_file(vim.fn.stdpath("config") .. "/lazy-lock.json")
  if not raw then
    return
  end
  local ok, lock = pcall(vim.json.decode, raw)
  if not ok or type(lock) ~= "table" then
    return
  end
  local drifted = {}
  for name, pin in pairs(lock) do
    local dir = vim.fn.stdpath("data") .. "/lazy/" .. name
    if installed_commit(dir) ~= pin.commit then
      drifted[#drifted + 1] = name
    end
  end
  if #drifted > 0 then
    table.sort(drifted)
    vim.notify(
      "Plugins out of sync with lazy-lock.json: "
        .. table.concat(drifted, ", ")
        .. " — run :Lazy restore",
      vim.log.levels.WARN
    )
  end
end

if vim.env.NVIM_BOOTSTRAP ~= "0" then
  require("lazy").setup("plugins")

  -- On a fresh machine, snap every plugin to the commit pinned in
  -- lazy-lock.json so all computers load identical versions.
  if fresh_install then
    require("lazy").restore({ wait = true })
  end

  vim.defer_fn(warn_on_lock_drift, 1000)
end

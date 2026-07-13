local opt = vim.opt
local ft_util = require("util.ft")

-- Line numbers
opt.number = true
opt.relativenumber = false
opt.numberwidth = 4
opt.signcolumn = "yes" -- always show sign column (prevents jitter)
opt.cursorline = true

-- Whitespace rendering
opt.list = true
opt.listchars = {
  tab = "» ",
  lead = "·",
  space = "·", -- show interior spaces too, not just leading/trailing
  trail = "·",
  extends = "›",
  precedes = "‹",
  nbsp = "␣",
}
opt.fillchars = { eob = " " }

-- Go (and go.mod) keep real tabs by gofmt convention. Render those tabs with
-- the same leading-space dots ('lead') instead of the global '»' glyph, while
-- preserving the other whitespace markers (trailing spaces, nbsp, …). Width
-- stays at 'tabstop' (2), so each tab shows as 'lead'-repeated columns.
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "go", "gomod" },
  callback = function()
    local chars = vim.opt.listchars:get()
    local dot = chars.lead or "·"
    chars.tab = dot .. dot -- 1st char shown, 2nd repeated to fill the tab width
    vim.opt_local.listchars = chars
  end,
})

-- Indentation
opt.expandtab = true
opt.shiftwidth = 2
opt.tabstop = 2
opt.softtabstop = 2

-- Search
opt.ignorecase = true
opt.smartcase = true
opt.hlsearch = true
opt.incsearch = true

-- Esc clears the active search, mirroring how VSCode/IntelliJ dismiss a find:
-- drop the match highlights and the search pattern so `n`/`N` won't jump back to
-- stale matches. A fresh `/` search highlights again from scratch. The trailing
-- <esc> preserves Esc's normal job of cancelling a pending count/command.
vim.keymap.set(
  "n",
  "<Esc>",
  "<cmd>nohlsearch<cr><cmd>let @/ = ''<cr><esc>",
  { desc = "Clear search highlight" }
)

-- Native vim.snippet sessions (blink.cmp expands LSP/friendly-snippets items
-- through vim.snippet.expand and never calls vim.snippet.stop) end on their own
-- only from insert/select mode: the runtime's CursorMoved guard early-returns
-- in normal mode, so after <Esc> the session survives and its SnippetTabstop
-- extmark — Visual-linked by default — keeps the inserted text painted like a
-- stuck visual selection (and later edits/formatting stretch it). Stop the
-- session once the editor *settles* in plain normal mode. Tabstop jumps pass
-- through normal mode transiently and must survive, in two shapes: core's own
-- jump feedkeys "<Esc>…v…<C-g>" (typeahead drains before deferred callbacks
-- run), and blink's snippet_forward, which vim.schedule()s its jump from a
-- select-mode mapping whose s→n mode switch fires this autocmd BEFORE the
-- mapping body queues that jump. Two defenses below, both order-independent
-- of the exact event/typeahead interleaving:
--   * the double schedule hops the check behind such a same-tick deferred
--     jump, so the jump has RUN by the time the check reads state;
--   * a fingerprint of the tabstop extmark highlight assignments taken when
--     the autocmd fired. vim.snippet.jump() re-points SnippetTabstopActive at
--     the destination tabstop synchronously — before its select keys drain —
--     so "fingerprint changed" means a jump took over and the session must
--     live, even while the editor still reads as normal mode. Buffer edits
--     shift mark positions but never the id:hl assignment, so plain
--     normal-mode editing can't spoof it.
-- The "*:n" pattern needs new-mode exactly "n", so i_CTRL-O's "niI" never
-- matches and a quick <C-o> command keeps the session too.
local function snippet_tabstop_fingerprint()
  local ns = vim.api.nvim_get_namespaces()["nvim.snippet"]
  if not ns then
    return ""
  end
  local parts = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
    parts[#parts + 1] = m[1] .. ":" .. (m[4].hl_group or "")
  end
  table.sort(parts)
  return table.concat(parts, ";")
end

vim.api.nvim_create_autocmd("ModeChanged", {
  pattern = "*:n",
  desc = "End lingering snippet session on return to normal mode",
  callback = function()
    if not vim.snippet.active() then
      return
    end
    local fingerprint = snippet_tabstop_fingerprint()
    vim.schedule(function()
      vim.schedule(function()
        if
          vim.snippet.active()
          and vim.api.nvim_get_mode().mode == "n"
          and snippet_tabstop_fingerprint() == fingerprint
        then
          vim.snippet.stop()
        end
      end)
    end)
  end,
})

-- netrw: tree-style listing with banner. g:netrw_treedepthstring doesn't always
-- take effect (newer netrw caches it), so we also hide the bar character by
-- setting its highlight foreground to the Normal background. Re-applied on
-- ColorScheme so :colorscheme changes don't bring the bars back.
vim.g.netrw_liststyle = 3

-- Bundled netrw maps quickhelp to <F1>, not ?. Restore the familiar ? binding.
vim.api.nvim_create_autocmd("FileType", {
  pattern = "netrw",
  callback = function(args)
    vim.keymap.set("n", "?", "<cmd>help netrw-quickmap<cr>", {
      buffer = args.buf,
      desc = "netrw quickmap help",
    })
  end,
})

local function hide_netrw_tree_bar()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
  local bg = normal and normal.bg
  if bg then
    vim.api.nvim_set_hl(0, "netrwTreeBar", { fg = string.format("#%06x", bg) })
  end
end
hide_netrw_tree_bar()
vim.api.nvim_create_autocmd("ColorScheme", { callback = hide_netrw_tree_bar })

-- Misc quality-of-life
opt.termguicolors = true
-- Light-only config (github_light_high_contrast). Set explicitly so Neovim's
-- background-sensitive UI defaults are correct from the first frame — before
-- lazy loads the theme — rather than relying on the theme to flip it.
opt.background = "light"
opt.mouse = "a"
opt.clipboard = "unnamedplus"

-- Delete the current buffer without closing its window, falling back to the
-- nvim-tree explorer when the last real buffer goes. The decision logic (real-
-- buffer filter, alternate-target pick, last-buffer fallback, [No Name] sweep)
-- lives in config.buffers so it's unit-testable.
vim.keymap.set(
  "n",
  "<leader>bd",
  require("config.buffers").delete_current,
  { desc = "Delete buffer" }
)

-- Close every buffer without unsaved changes -- the "clean up my session"
-- sibling of <leader>bd, with the same tree fallback when nothing is left.
vim.keymap.set(
  "n",
  "<leader>bad",
  require("config.buffers").delete_all_saved,
  { desc = "Delete all saved buffers" }
)

-- Quit all windows, discarding unsaved changes
vim.keymap.set("n", "<leader>qa", "<cmd>qa!<cr>", { desc = "Quit all (force)" })

-- Save all buffers and quit
vim.keymap.set("n", "<leader>qw", "<cmd>wqa<cr>", { desc = "Save all and quit" })

-- OSC52 clipboard provider for containers/SSH (host uses pbcopy/xclip natively)
local in_container = vim.env.REMOTE_CONTAINERS == "true"
  or vim.env.CODESPACES == "true"
  or vim.uv.fs_stat("/.dockerenv") ~= nil
if in_container or vim.env.SSH_TTY then
  local osc52 = require("vim.ui.clipboard.osc52")
  vim.g.clipboard = {
    name = "OSC 52",
    copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
    paste = { ["+"] = osc52.paste("+"), ["*"] = osc52.paste("*") },
  }
end

opt.undofile = true
opt.updatetime = 250
opt.timeoutlen = 400
opt.splitbelow = true
opt.splitright = true
opt.scrolloff = 8
opt.sidescrolloff = 8
opt.laststatus = 3
opt.wrap = false -- no soft-wrap; long lines (incl. wide tables) scroll horizontally

-- The single entry point for markdown-family buffers. This autocmd is
-- registered at startup (before any file is read), so `nvim file.md` hits it on
-- the first FileType -- no per-module backfill of already-open buffers needed.
-- markdown_preview and wikilinks expose set_keymap(buf) instead of each
-- registering their own duplicate FileType autocmd. ft_util.markdown covers
-- markdown + mdx.
vim.api.nvim_create_autocmd("FileType", {
  pattern = ft_util.markdown,
  callback = function(args)
    -- Writing-friendly markdown: paragraph numbering in the gutter. 't' is
    -- cleared because the bundled markdown ftplugin sets it; otherwise an
    -- editorconfig 'max_line_length' would set 'textwidth' and start auto-hard-
    -- wrapping prose as you type.
    vim.opt_local.formatoptions:remove("t") -- never auto-hard-wrap prose
    -- Prose spellcheck. 'camel' splits CamelCase/identifier-ish words on case
    -- boundaries so code-flavored names (e.g. nvim_buf_set_lines) raise fewer
    -- false positives than a whole-word check would.
    vim.opt_local.spell = true
    vim.opt_local.spelllang = "en"
    vim.opt_local.spelloptions = "camel"
    require("config.markdown_paragraphs").attach(args.buf)
    require("config.markdown_preview").set_keymap(args.buf)
    require("config.wikilinks").set_keymap(args.buf)
  end,
})

-- Re-apply / tear down the paragraph gutter as windows show markdown or not.
-- Gate the require so a session that never touches markdown doesn't load the
-- module: only enter it for a markdown buffer, or to detach a window that the
-- gutter is still active on (markdown_writing_active is the marker apply_window
-- sets and detach_window clears).
vim.api.nvim_create_autocmd("BufWinEnter", {
  callback = function(args)
    local ft = vim.bo[args.buf].filetype
    if ft_util.is_markdown(ft) then
      require("config.markdown_paragraphs").apply_window()
    elseif vim.w.markdown_writing_active then
      require("config.markdown_paragraphs").detach_window()
    end
  end,
})

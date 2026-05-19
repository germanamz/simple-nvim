local opt = vim.opt

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
  trail = "·",
  extends = "›",
  precedes = "‹",
  nbsp = "␣",
}
opt.fillchars = { eob = " " }

-- Indentation
opt.expandtab = true
opt.shiftwidth = 2
opt.tabstop = 2
opt.softtabstop = 2
opt.smartindent = true

-- Search
opt.ignorecase = true
opt.smartcase = true
opt.hlsearch = true
opt.incsearch = true

-- Misc quality-of-life
opt.termguicolors = true
opt.mouse = "a"
opt.clipboard = "unnamedplus"

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
opt.laststatus = 2
opt.wrap = true
opt.linebreak = true -- wrap at word boundaries, not mid-word
opt.breakindent = true -- wrapped lines keep indent
opt.showbreak = "↪ "

-- Force wrap inside diff mode (vim disables it by default, diffview inherits)
vim.api.nvim_create_autocmd({ "OptionSet" }, {
  pattern = "diff",
  callback = function()
    if vim.v.option_new == "1" then
      vim.opt_local.wrap = true
      vim.opt_local.linebreak = true
    end
  end,
})
vim.api.nvim_create_autocmd({ "FileType" }, {
  pattern = { "DiffviewFiles", "DiffviewFileHistory" },
  callback = function()
    vim.opt_local.wrap = true
    vim.opt_local.linebreak = true
  end,
})

-- Writing-friendly markdown: paragraph numbering in gutter, thin ruler line at
-- column 80, hard-wrap before the word that would push past textwidth.
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown", "mdx" },
  callback = function(args)
    vim.opt_local.textwidth = 80
    vim.opt_local.formatoptions:append("t") -- auto-wrap text using textwidth
    vim.keymap.set("n", "<leader>w", function()
      -- LSP attach sets formatexpr to vim.lsp.formatexpr, which doesn't honor
      -- textwidth. Drop it for the duration of gq so vim's internal formatter
      -- runs and reflows to textwidth=80. Save/restore cursor so the user
      -- isn't dumped at the last formatted line. Skip past YAML frontmatter
      -- so wrapping never breaks `key: value` lines into invalid YAML, and
      -- skip table blocks (lines starting with `|`) since gq has no concept
      -- of markdown tables and would rewrap row cells into prose.
      local saved_fe = vim.bo.formatexpr
      local pos = vim.api.nvim_win_get_cursor(0)
      vim.bo.formatexpr = ""

      local fm_end = require("config.markdown_paragraphs").frontmatter_end(0)
      local start_line = math.max(pos[1], fm_end + 1)
      local last_line = vim.api.nvim_buf_line_count(0)
      if start_line <= last_line then
        local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, last_line, false)
        local ranges = {}
        local chunk_from = nil
        for i, line in ipairs(lines) do
          local lnum = start_line + i - 1
          if line:match("^%s*|") then
            if chunk_from then
              table.insert(ranges, { chunk_from, lnum - 1 })
              chunk_from = nil
            end
          elseif not chunk_from then
            chunk_from = lnum
          end
        end
        if chunk_from then
          table.insert(ranges, { chunk_from, last_line })
        end
        -- Reverse order so line-count shifts from formatting an earlier chunk
        -- don't invalidate later chunk boundaries.
        for i = #ranges, 1, -1 do
          local r = ranges[i]
          pcall(vim.api.nvim_win_set_cursor, 0, { r[1], 0 })
          vim.cmd(string.format("silent! keepjumps normal! V%dGgq", r[2]))
        end
      end

      vim.bo.formatexpr = saved_fe
      pcall(vim.api.nvim_win_set_cursor, 0, pos)
    end, {
      buffer = args.buf,
      desc = "Rewrap from cursor to end of file",
    })
    require("config.markdown_paragraphs").attach(args.buf)
  end,
})

vim.api.nvim_create_autocmd("BufWinEnter", {
  callback = function(args)
    local ft = vim.bo[args.buf].filetype
    local mp = require("config.markdown_paragraphs")
    if ft == "markdown" or ft == "mdx" then
      mp.apply_window()
    else
      mp.detach_window()
    end
  end,
})

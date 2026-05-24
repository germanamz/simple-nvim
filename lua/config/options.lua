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

-- Force wrap inside diff mode (vim disables it by default)
vim.api.nvim_create_autocmd({ "OptionSet" }, {
  pattern = "diff",
  callback = function()
    if vim.v.option_new == "1" then
      vim.opt_local.wrap = true
      vim.opt_local.linebreak = true
    end
  end,
})

-- Markdown fenced code blocks are dispatched to per-language formatters via
-- the shared config in lua/config/formatters.lua. Unknown tags / missing
-- binaries / non-zero exits leave the block untouched.

local function format_code_block(block)
  local cmd = require("config.formatters").resolve_fence_argv(block.lang)
  if not cmd or block.from > block.to then
    return
  end
  local content = vim.api.nvim_buf_get_lines(0, block.from - 1, block.to, false)
  local indent = block.indent or ""
  if indent ~= "" then
    for i, line in ipairs(content) do
      if line:sub(1, #indent) == indent then
        content[i] = line:sub(#indent + 1)
      end
    end
  end
  local stdin = table.concat(content, "\n") .. "\n"
  local ok, res = pcall(function()
    return vim.system(cmd, { stdin = stdin, text = true }):wait(5000)
  end)
  if not ok or not res or res.code ~= 0 or not res.stdout or res.stdout == "" then
    return
  end
  local out = res.stdout
  if out:sub(-1) == "\n" then
    out = out:sub(1, -2)
  end
  local new_lines = vim.split(out, "\n", { plain = true })
  if indent ~= "" then
    for i, line in ipairs(new_lines) do
      if line ~= "" then
        new_lines[i] = indent .. line
      end
    end
  end
  vim.api.nvim_buf_set_lines(0, block.from - 1, block.to, false, new_lines)
end

local function parse_fence(line)
  local indent, fc, lang = line:match("^(%s*)(```+)%s*([%w_.+-]*)")
  if fc then
    return indent, fc, lang
  end
  indent, fc, lang = line:match("^(%s*)(~~~+)%s*([%w_.+-]*)")
  if fc then
    return indent, fc, lang
  end
  return nil
end

-- Writing-friendly markdown: paragraph numbering in gutter, thin ruler line at
-- column 80, hard-wrap before the word that would push past textwidth.
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown", "mdx" },
  callback = function(args)
    vim.opt_local.textwidth = 80
    vim.opt_local.formatoptions:append("t") -- auto-wrap text using textwidth
    vim.opt_local.wrap = false -- prose is hard-wrapped; long table rows scroll horizontally instead of soft-wrapping ugly
    vim.keymap.set("n", "<leader>w", function()
      -- LSP attach sets formatexpr to vim.lsp.formatexpr, which doesn't honor
      -- textwidth. Drop it for the duration of gq so vim's internal formatter
      -- runs and reflows to textwidth=80. Save/restore cursor so the user
      -- isn't dumped at the last formatted line. Skip past YAML frontmatter
      -- so wrapping never breaks `key: value` lines into invalid YAML, skip
      -- table blocks (lines starting with `|`) since gq has no concept of
      -- markdown tables, and isolate fenced code blocks: their fence lines
      -- are excluded from prose ranges and their contents are dispatched to
      -- a language-specific formatter (see FORMATTERS) instead of gq.
      local saved_fe = vim.bo.formatexpr
      local pos = vim.api.nvim_win_get_cursor(0)
      vim.bo.formatexpr = ""

      local fm_end = require("config.markdown_paragraphs").frontmatter_end(0)
      local start_line = math.max(pos[1], fm_end + 1)
      local last_line = vim.api.nvim_buf_line_count(0)
      if start_line <= last_line then
        local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, last_line, false)
        local actions = {}
        local chunk_from = nil
        local code_open = nil -- { content_from, lang, indent, fence_char, fence_len }
        for i, line in ipairs(lines) do
          local lnum = start_line + i - 1
          if code_open then
            local _, fc = parse_fence(line)
            if fc and fc:sub(1, 1) == code_open.fence_char and #fc >= code_open.fence_len then
              table.insert(actions, {
                kind = "code",
                from = code_open.content_from,
                to = lnum - 1,
                lang = code_open.lang,
                indent = code_open.indent,
              })
              code_open = nil
            end
          else
            local indent, fc, lang = parse_fence(line)
            if fc then
              if chunk_from then
                table.insert(actions, { kind = "prose", from = chunk_from, to = lnum - 1 })
                chunk_from = nil
              end
              code_open = {
                content_from = lnum + 1,
                lang = lang,
                indent = indent,
                fence_char = fc:sub(1, 1),
                fence_len = #fc,
              }
            elseif line:match("^%s*|") then
              if chunk_from then
                table.insert(actions, { kind = "prose", from = chunk_from, to = lnum - 1 })
                chunk_from = nil
              end
            elseif not chunk_from then
              chunk_from = lnum
            end
          end
        end
        if chunk_from then
          table.insert(actions, { kind = "prose", from = chunk_from, to = last_line })
        end
        -- An unterminated fence at EOF: best-effort, format what's there.
        if code_open and code_open.content_from <= last_line then
          table.insert(actions, {
            kind = "code",
            from = code_open.content_from,
            to = last_line,
            lang = code_open.lang,
            indent = code_open.indent,
          })
        end

        table.sort(actions, function(a, b)
          return a.from < b.from
        end)
        -- Reverse order so line-count shifts from formatting an earlier action
        -- don't invalidate later action boundaries.
        for i = #actions, 1, -1 do
          local a = actions[i]
          if a.kind == "prose" then
            pcall(vim.api.nvim_win_set_cursor, 0, { a.from, 0 })
            vim.cmd(string.format("silent! keepjumps normal! V%dGgq", a.to))
          else
            format_code_block(a)
          end
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

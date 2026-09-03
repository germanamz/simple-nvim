-- Comment continuation and reflow.
--
-- Three things a doc comment needs that the runtime does not give every
-- filetype:
--
--   • Enter continues the comment. That is 'formatoptions' flag `r`, which the
--     bundled ftplugins for lua/c/typescript/sh add and the ones for go, python
--     and fga do not (go.vim only removes `t`). `apply` normalises every code
--     buffer after its ftplugin ran: `r` on, `o` off (a normal-mode `o` gives a
--     plain line everywhere, not a leader in some languages), `t` off so a
--     project's editorconfig 'textwidth' wraps comments (`c`) but never code.
--   • Enter on the leader Neovim just inserted ends the comment. `cr` backs the
--     insert-mode <CR> map: on a line that is only the leader plus the trailing
--     space the `r` flag copies, it clears the line back to its indent instead
--     of stacking another leader. A bare `//` you typed yourself has no trailing
--     space and keeps continuing — it is Go's paragraph separator.
--   • `gqc` reflows the comment block under the cursor. `gq` alone cannot: conform
--     owns 'formatexpr' and runs the project formatter, and gofmt never rewraps
--     a comment. `block` finds the run of comment-only lines with one leader
--     (`//` and `///` are different blocks, `//go:build` is a boundary), and
--     `reflow` formats exactly those lines with Neovim's internal formatter,
--     which knows 'comments'. `formatexpr` is the same idea for a range you
--     chose: comment-only → internal formatter, anything else → conform.
--
-- No default 'textwidth' is set. Wrapping while typing happens only where a
-- project's editorconfig sets max_line_length; `gqc` without one wraps at 79,
-- the internal formatter's own cap, pinned so a narrow split does not change it.
local M = {}

local ft_util = require("util.ft")

-- Filetypes whose ftplugin keeps `t` on purpose: prose, where wrapping the text
-- itself is the point. The markdown family has its own handler in options.lua.
M.PROSE_FT = { text = true, gitcommit = true, mail = true }

-- Width for `gqc` when 'textwidth' is 0: the internal formatter's cap.
M.FALLBACK_WIDTH = 79

-- The default 'formatlistpat' (numbered items) plus `-`/`*`/`+` bullets, so the
-- `n` flag keeps gofmt-style `//   - item` lists apart instead of merging them.
M.FORMATLISTPAT = [[^\s*\d\+[\]:.)}\t ]\s*\|^\s*[-*+]\s\+]]

local function termcodes(s)
  return vim.api.nvim_replace_termcodes(s, true, false, true)
end

function M.is_code_buffer(buf)
  if vim.bo[buf].buftype ~= "" then
    return false
  end
  local ft = vim.bo[buf].filetype
  return ft ~= "" and not ft_util.is_markdown(ft) and not M.PROSE_FT[ft]
end

-- The 'formatoptions' policy for one code buffer. Runs from a FileType autocmd,
-- i.e. after the runtime ftplugin, so it can undo what that set.
function M.apply(buf)
  if not M.is_code_buffer(buf) then
    return
  end
  local fo = vim.bo[buf].formatoptions:gsub("[to]", "")
  for flag in ("rjln"):gmatch(".") do
    if not fo:find(flag, 1, true) then
      fo = fo .. flag
    end
  end
  vim.bo[buf].formatoptions = fo
  vim.bo[buf].formatlistpat = M.FORMATLISTPAT
end

-- The line-comment leader from 'commentstring': "// %s" → "//". nil when the
-- buffer has none or it is a block form ("/* %s */", "<!-- %s -->"), where
-- the runtime's `r` continuation inserts a middle piece, not this prefix.
function M.leader(buf)
  local prefix = vim.bo[buf].commentstring:match("^%s*(.-)%s*%%s%s*$")
  if not prefix or prefix == "" then
    return nil
  end
  return prefix
end

-- Is `body` a leader and nothing else? It may repeat the prefix's own
-- characters (`///`, `---`) but add nothing (`//!` is text).
local function only_leader(body, prefix)
  if not body or body:sub(1, #prefix) ~= prefix then
    return false
  end
  local set = {}
  for ch in prefix:gmatch(".") do
    set[ch] = true
  end
  for ch in body:gmatch(".") do
    if not set[ch] then
      return false
    end
  end
  return true
end

-- Is `line` only a comment leader with trailing whitespace — the shape the `r`
-- flag leaves behind (`// `, `\t--- `)?
function M.is_fresh_leader(line, prefix)
  return only_leader(line:match("^%s*(%S+)%s+$"), prefix)
end

-- Is `line` only a bare leader (`//`)? That is a paragraph separator the user
-- typed, not something `r` produces.
function M.is_bare_leader(line, prefix)
  return only_leader(line:match("^%s*(%S+)$"), prefix)
end

local function newline()
  -- mini.pairs owns <CR> between a registered pair (`{|}` → open the pair out).
  -- It installs its own <CR> map only when none exists, and ours does, so
  -- delegate; it returns plain <CR> keys when no pair is involved.
  if _G.MiniPairs and MiniPairs.cr then
    return MiniPairs.cr()
  end
  return termcodes("<CR>")
end

-- Body of the insert-mode <CR> expr map. Returns keys, never edits the buffer:
-- blink's fallback and multicursor's redo replay both need a key-returning map.
function M.cr()
  if not vim.bo.formatoptions:find("r", 1, true) then
    return newline()
  end
  local prefix = M.leader(0)
  if not prefix then
    return newline()
  end
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  if col ~= #line then
    return newline()
  end
  if M.is_fresh_leader(line, prefix) then
    -- <C-w> takes the trailing space and then the leader as one word and stops
    -- at the indent, so the code line that is left sits where the comment did.
    -- (<C-u> would delete only the characters typed since insert started,
    -- which after a bare-leader continuation is just the space below.)
    return termcodes("<C-w>")
  end
  if M.is_bare_leader(line, prefix) then
    -- Neovim copies a bare leader bare (`//` → `//`); the space makes the new
    -- line the same fresh leader every other Enter leaves. One caveat: a
    -- second <CR> already queued behind these keys (a macro, a pasted burst)
    -- is resolved while the space is still in typeahead and sees the bare
    -- leader again, so it continues instead of ending the comment.
    return newline() .. " "
  end
  return newline()
end

-- Grammars spell it `comment`, `line_comment`, `block_comment`, … (the same
-- predicate config.decl_rules uses).
local function is_comment(node_type)
  return node_type:find("comment", 1, true) ~= nil
end

local function tree_root(buf)
  if require("util.largefile").is_large(buf) then
    return nil -- a fresh whole-buffer parse would stall; use the leader fallback
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
  if not ok or not parser then
    return nil
  end
  local trees = parser:parse()
  return trees and trees[1] and trees[1]:root() or nil
end

-- The leader as written on this row: the run of punctuation the text starts
-- with, so `//`, `///`, `//!`, `---@` and `#!` all differ.
local function row_leader(text)
  return text:match("^(%p+)")
end

-- `//go:build`, `//nolint`, `#!/bin/sh`, `---@param`: a leader glued to a word.
-- Never prose, never reflowed, and a boundary for the block around it.
local function is_directive(text, leader)
  if not leader then
    return false
  end
  local next_ch = text:sub(#leader + 1, #leader + 1)
  return next_ch ~= "" and not next_ch:match("%s")
end

-- What `row` is: nil for a blank, code or trailing-comment row; `{ span = {s, e} }`
-- for a row of a comment node covering several rows; `{ leader, text }` for a
-- row that is one line comment.
local function classify(buf, row, root, prefix)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  if not line then
    return nil
  end
  local indent, text = line:match("^(%s*)(.*)$")
  if text == "" then
    return nil
  end
  if root then
    local col = #indent
    local node = root:named_descendant_for_range(row, col, row, col + 1)
    while node and not is_comment(node:type()) do
      node = node:parent()
    end
    if not node then
      return nil
    end
    local s, sc, e, ec = node:range()
    if ec == 0 and e > s then
      e = e - 1
    end
    if s ~= row or sc ~= col then
      -- inside a multi-row comment, or a comment that starts after code
      if s < row and row <= e then
        return { span = { s, e } }
      end
      return nil
    end
    if e > s then
      return { span = { s, e } }
    end
    return { leader = row_leader(text), text = text }
  end
  if prefix and text:sub(1, #prefix) == prefix then
    return { leader = row_leader(text), text = text }
  end
  return nil
end

local function same_block(here, other)
  return other ~= nil
    and other.span == nil
    and other.leader == here.leader
    and not is_directive(other.text, other.leader)
end

-- The comment block containing `row` (0-indexed): `{ first, last }`, inclusive,
-- or nil when `row` is not a comment-only line. A block is one multi-row comment
-- node, or a run of consecutive line comments sharing a leader, broken by blank
-- lines, code, a leader change or a directive. Bare-leader lines (`//`) belong
-- to the run: they are paragraph separators the internal formatter leaves alone.
function M.block(buf, row)
  local root, prefix = tree_root(buf), M.leader(buf)
  local here = classify(buf, row, root, prefix)
  if not here then
    return nil
  end
  if here.span then
    return { here.span[1], here.span[2] }
  end
  if is_directive(here.text, here.leader) then
    return nil
  end
  local first, last = row, row
  while first > 0 and same_block(here, classify(buf, first - 1, root, prefix)) do
    first = first - 1
  end
  local count = vim.api.nvim_buf_line_count(buf)
  while last < count - 1 and same_block(here, classify(buf, last + 1, root, prefix)) do
    last = last + 1
  end
  return { first, last }
end

-- Are rows `first..last` (0-indexed, inclusive) all comment-only?
function M.all_comment_rows(buf, first, last)
  local root, prefix = tree_root(buf), M.leader(buf)
  for row = first, last do
    if not classify(buf, row, root, prefix) then
      return false
    end
  end
  return true
end

-- 'formatexpr' for every buffer (conform's spec points both of its formatexpr
-- sites here). A comment-only range returns 1, which makes Neovim use its
-- internal, 'comments'-aware formatter; anything else is conform's to format.
-- Insert-mode auto-wrap lands here too and takes the comment branch.
function M.formatexpr()
  local first = vim.v.lnum - 1
  if M.all_comment_rows(0, first, first + vim.v.count - 1) then
    return 1
  end
  local ok, conform = pcall(require, "conform")
  if not ok then
    return 1
  end
  return conform.formatexpr()
end

-- `gqc`: reflow the comment block under the cursor with the internal formatter.
-- 'textwidth' 0 is pinned to FALLBACK_WIDTH for the duration so the result
-- does not depend on the window's width.
function M.reflow()
  local buf = vim.api.nvim_get_current_buf()
  local range = M.block(buf, vim.api.nvim_win_get_cursor(0)[1] - 1)
  if not range then
    vim.notify("No comment under the cursor", vim.log.levels.INFO)
    return
  end
  local view = vim.fn.winsaveview()
  local tw = vim.bo[buf].textwidth
  if tw == 0 then
    vim.bo[buf].textwidth = M.FALLBACK_WIDTH
  end
  vim.api.nvim_win_set_cursor(0, { range[1] + 1, 0 })
  local ok, err = pcall(vim.cmd, ("normal! %dgww"):format(range[2] - range[1] + 1))
  if tw == 0 then
    vim.bo[buf].textwidth = 0
  end
  vim.fn.winrestview(view)
  if not ok then
    error(err)
  end
end

return M

-- A hairline rule above every top-level declaration.
--
-- The companion to config.syntax_emphasis: once comments recede and declaration
-- names go bold, the last thing missing when scanning a Go file is a boundary —
-- where does one `func` (with its doc block) end and the next begin. This draws
-- one, as a faint full-width underline on the line directly above each top-level
-- declaration group.
--
-- Rendering notes, both learned the hard way:
--
--   • It's an UNDERLINE (line_hl_group + sp), not a virtual line, so it costs no
--     screen rows and the code never reflows. Same mechanism as gitsigns'
--     deletion underdash, which already renders here.
--   • The extmarks are PERSISTENT, not the ephemeral decoration-provider marks
--     config.block_guides uses. An ephemeral extmark silently ignores
--     line_hl_group — it is accepted and simply never paints. Persistent marks
--     also suit the data: the rules depend on the buffer's text, not the cursor,
--     so recomputing them per redraw would be pure waste. They ride along with
--     edits for free, since extmarks shift with the text.
--
-- What counts as a declaration is deliberately language-agnostic: any named
-- child of the tree ROOT. In Go that's exactly package_clause /
-- import_declaration / const / var / type / func / method; in Lua, TypeScript
-- and the rest it lands on the same top-level statements. No per-language node
-- table to keep in sync, and nothing to add when a new parser is pinned.
local M = {}

local hl = require("util.hl")

local ns = vim.api.nvim_create_namespace("decl_rules")
local HL = "DeclRule"

-- Filetypes whose top-level children are prose, not declarations — every
-- section or paragraph would otherwise get a rule. Mirrors block_guides'
-- exclusion list, for the same reason.
local EXCLUDED_FT = {
  [""] = true,
  markdown = true,
  mdx = true,
  help = true,
  text = true,
  gitcommit = true,
}

local enabled = true
-- [buf] = "<changedtick>:<filetype>" the current marks were painted from. The
-- filetype is part of the key because `:set filetype=` swaps the treesitter
-- parser WITHOUT bumping the tick — a tick-only key would keep the old
-- language's rules until the next edit (the same trap block_guides documents).
local painted = {}

-- Grammars spell it `comment`, `line_comment`, `block_comment`, … — all of them
-- contain "comment", and no non-comment top-level node type does.
function M.is_comment(node_type)
  return node_type:find("comment", 1, true) ~= nil
end

-- Rows to underline, given the tree root's named children in document order as
-- { type = <node type>, s = <start row>, e = <end row> } (0-indexed, inclusive).
-- Returns sorted, deduped 0-indexed rows.
--
-- A declaration's group starts at its doc block: the run of consecutive comments
-- ending on the line DIRECTLY above it. A comment separated from the
-- declaration by a blank line is free-standing prose and stays outside the
-- group, so the rule lands above the comment only when the comment belongs to
-- the declaration.
--
-- Single-line declarations with no doc block get no rule — otherwise a run of
-- `import "fmt"` lines or a stack of one-line consts would be ruled to death.
function M.rule_rows(children)
  local rows, seen = {}, {}
  local run_first, run_last -- extent of the comment run immediately behind us
  local prev_end -- last row occupied by the previous sibling, comment or not
  for _, c in ipairs(children) do
    if M.is_comment(c.type) then
      -- A TRAILING comment — `} // end Alpha`, `const N = 3 // per attempt` —
      -- parses as a root-level sibling starting on a row the previous node
      -- already occupies. It belongs to the line it trails, not to whatever
      -- comes next, so it must not seed or extend a doc run: doing so dragged
      -- the following declaration's group start back onto the `}` row and
      -- painted the rule inside the previous function's body.
      if prev_end and c.s == prev_end then
        run_first, run_last = nil, nil
      elseif run_last and c.s == run_last + 1 then
        run_last = c.e -- contiguous with the run so far
      else
        run_first, run_last = c.s, c.e -- a blank line broke it; start over
      end
    else
      local start = c.s
      if run_last and run_last + 1 == c.s then
        start = run_first
      end
      local worth_ruling = c.e > c.s or start < c.s
      if worth_ruling and start > 0 and not seen[start - 1] then
        seen[start - 1] = true
        rows[#rows + 1] = start - 1
      end
      run_first, run_last = nil, nil
    end
    prev_end = c.e
  end
  table.sort(rows)
  return rows
end

-- rule_rows over `buf`'s parsed tree. Never creates a parser: callers gate on an
-- active highlighter, which means one already exists.
function M.rows_for(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return {}
  end
  local trees = parser:parse()
  if not trees or not trees[1] then
    return {}
  end
  local children = {}
  for node in trees[1]:root():iter_children() do
    if node:named() then
      local s, _, e, e_col = node:range()
      -- A node ending at column 0 really ends on the row before (same
      -- correction block_guides applies to fold ranges).
      if e_col == 0 and e > s then
        e = e - 1
      end
      children[#children + 1] = { type = node:type(), s = s, e = e }
    end
  end
  return M.rule_rows(children)
end

-- Hairline, not a divider. Derived from the live Comment colour and washed
-- another 55% toward the background, so it tracks the theme and always sits a
-- tier below the (already dimmed) comments it separates. `sp` keeps it a thin
-- coloured underline where the terminal supports one and degrades to a plain
-- underline where it doesn't. Deliberately NOT `default = true`: this is
-- re-derived on every ColorScheme, and a default set would refuse to update it.
local function ensure_highlights()
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  if comment.fg and normal.bg then
    vim.api.nvim_set_hl(0, HL, { underline = true, sp = hl.blend(comment.fg, normal.bg, 0.45) })
  else
    vim.api.nvim_set_hl(0, HL, { underline = true })
  end
end

local function eligible(buf)
  if not enabled or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if EXCLUDED_FT[vim.bo[buf].filetype] then
    return false
  end
  -- Also the large-file guard, transitively: the treesitter highlight autocmd
  -- skips oversized buffers, so no highlighter means no rules and no parse.
  return vim.treesitter.highlighter.active[buf] ~= nil
end

-- Identity of what a paint was computed from; see `painted`.
local function paint_key(buf)
  return vim.api.nvim_buf_get_changedtick(buf) .. ":" .. vim.bo[buf].filetype
end

function M.paint(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  painted[buf] = nil
  if not eligible(buf) then
    return
  end
  for _, row in ipairs(M.rows_for(buf)) do
    -- pcall: a row can fall off the end if the buffer changed between the parse
    -- and this loop (an autocmd firing mid-schedule).
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, { line_hl_group = HL })
  end
  painted[buf] = paint_key(buf)
end

-- Repaint `buf` on the next tick, unless neither its text nor its filetype has
-- changed since the marks were painted. Scheduled because the FileType handler
-- that starts treesitter is registered later than ours (lazy loads plugins after
-- init.lua's eager requires), so at event time the highlighter isn't attached
-- yet.
local function schedule_paint(buf)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if painted[buf] == paint_key(buf) then
      return
    end
    M.paint(buf)
  end)
end

function M.is_enabled()
  return enabled
end

function M.toggle()
  enabled = not enabled
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.paint(buf)
    end
  end
  vim.notify("Declaration rules " .. (enabled and "on" or "off"))
end

function M.setup()
  -- Idempotent: a second call would otherwise stack a second copy of every
  -- handler, including the per-edit repaint.
  if M._did_setup then
    return
  end
  M._did_setup = true
  local group = vim.api.nvim_create_augroup("decl_rules", { clear = true })

  ensure_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = ensure_highlights })

  -- TextChanged (normal mode) and InsertLeave, not TextChangedI: a full-buffer
  -- reparse per keystroke buys nothing, and the existing marks shift with the
  -- text as you type, so only added/removed declarations lag — until you leave
  -- insert, which is immediately.
  vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter", "TextChanged", "InsertLeave" }, {
    group = group,
    callback = function(args)
      schedule_paint(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(args)
      painted[args.buf] = nil
    end,
  })

  vim.keymap.set("n", "<leader>ur", M.toggle, { desc = "Toggle declaration rules" })
end

return M

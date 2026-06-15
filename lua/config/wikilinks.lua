-- Follow wiki-style links to their target file.
--
-- Wikilinks here are project-scoped: `[[a/b/c]]` resolves to
-- `<project root>/a/b/c.md`, where the root is found by walking up from the
-- current file for a `.git` / `.marksman.toml` / `tusk.toml` / `.tusk` marker
-- (e.g. an agent-brain vault). `[[target|alias]]` and `[[target#heading]]` are
-- supported -- the alias and heading are ignored for resolution, and `.md` is
-- appended when the target has no extension.
--
-- Bound to `gd` (buffer-local) in markdown/mdx buffers as a "smart go-to": it
-- follows the wikilink under the cursor, falling back to LSP go-to-definition
-- when the cursor isn't on one. See setup() and the LspAttach branch in
-- lua/plugins/lsp.lua.

local M = {}

local ROOT_MARKERS = { ".git", ".marksman.toml", "tusk.toml", ".tusk" }

-- Return the inner text of the `[[...]]` wikilink covering 1-based column `col`
-- on `line`, or nil if the column isn't inside one.
local function wikilink_at(line, col)
  local init = 1
  while true do
    local s, e, inner = line:find("%[%[(.-)%]%]", init)
    if not s then
      return nil
    end
    if col >= s and col <= e then
      return inner
    end
    init = e + 1
  end
end
M._wikilink_at = wikilink_at

-- Reduce a wikilink's inner text to a project-root-relative file path: drop a
-- `|alias` and a `#heading`, trim, and append `.md` when there is no extension.
local function normalize_target(inner)
  local target = inner:gsub("|.*$", ""):gsub("#.*$", "")
  target = vim.trim(target)
  if target == "" then
    return nil
  end
  if not target:match("%.%w+$") then
    target = target .. ".md"
  end
  return target
end
M._normalize_target = normalize_target

-- Project root for `source` (a file path); defaults to the current buffer/cwd.
local function project_root(source)
  if not source or source == "" then
    local name = vim.api.nvim_buf_get_name(0)
    source = name ~= "" and name or vim.fn.getcwd()
  end
  return vim.fs.root(source, ROOT_MARKERS) or vim.fn.getcwd()
end

-- Open a project-relative target in the current window. Returns false (and
-- notifies) if the resolved file doesn't exist.
local function open_target(target, root)
  local path = root .. "/" .. target
  if vim.fn.filereadable(path) == 0 then
    vim.notify("Wikilink target not found:\n" .. path, vim.log.levels.WARN, { title = "wikilinks" })
    return false
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
  return true
end

-- Try to follow the wikilink under the cursor. Returns true when the cursor was
-- on a wikilink (whether the target opened or was reported missing), false when
-- there was nothing to follow -- so the caller can fall back to LSP.
local function try_follow()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local inner = wikilink_at(line, col)
  if not inner then
    return false
  end
  local target = normalize_target(inner)
  if not target then
    return false
  end
  open_target(target, project_root())
  return true
end
M._try_follow = try_follow

-- Smart `gd`: follow a wikilink if the cursor is on one, else LSP definition.
function M.goto_definition()
  if try_follow() then
    return
  end
  vim.lsp.buf.definition()
end

-- The rendered display text glow shows for a wikilink: the alias when present,
-- otherwise the raw inner (e.g. "lola/product"). This is what appears verbatim
-- in the preview, so it's what we match the cursor against.
local function display_text(inner)
  local pipe = inner:find("|", 1, true)
  return vim.trim(pipe and inner:sub(pipe + 1) or inner)
end

-- Ordered { display, target } for every wikilink in `lines`, skipping fenced
-- code (which glow renders raw, so there's no rendered link to match).
local function links_in_lines(lines)
  local out, in_fence = {}, false
  for _, line in ipairs(lines) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      in_fence = not in_fence
    elseif not in_fence then
      local init = 1
      while true do
        local s, e, inner = line:find("%[%[(.-)%]%]", init)
        if not s then
          break
        end
        local display, target = display_text(inner), normalize_target(inner)
        if display ~= "" and target then
          out[#out + 1] = { display = display, target = target }
        end
        init = e + 1
      end
    end
  end
  return out
end
M._links_in_lines = links_in_lines

-- Among `links`, the distinct targets whose display text covers 1-based column
-- `col` in `line`. Longer (more specific) displays win on overlap.
local function match_at(links, line, col)
  local hits = {}
  for _, lk in ipairs(links) do
    local init = 1
    while true do
      local s, e = line:find(lk.display, init, true)
      if not s then
        break
      end
      if col >= s and col <= e then
        hits[#hits + 1] = lk
      end
      init = e + 1
    end
  end
  table.sort(hits, function(a, b)
    return #a.display > #b.display
  end)
  local seen, uniq = {}, {}
  for _, h in ipairs(hits) do
    if not seen[h.target] then
      seen[h.target] = true
      uniq[#uniq + 1] = h
    end
  end
  return uniq
end
M._match_at = match_at

-- Follow the wikilink under the cursor in the (reflowed, target-less) preview by
-- matching the rendered link text against `src`'s wikilinks. Opens in the source
-- window; prompts when a display name maps to more than one target.
function M.follow_in_preview(src)
  if not (src and vim.api.nvim_buf_is_valid(src)) then
    return
  end
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local matches = match_at(links_in_lines(vim.api.nvim_buf_get_lines(src, 0, -1, false)), line, col)
  if #matches == 0 then
    vim.notify("No wikilink under the cursor", vim.log.levels.INFO, { title = "wikilinks" })
    return
  end
  local root = project_root(vim.api.nvim_buf_get_name(src))
  local src_win = vim.fn.bufwinid(src)
  local function go(target)
    if src_win ~= -1 and vim.api.nvim_win_is_valid(src_win) then
      vim.api.nvim_set_current_win(src_win)
    end
    open_target(target, root)
  end
  if #matches == 1 then
    go(matches[1].target)
  else
    vim.ui.select(matches, {
      prompt = "Follow wikilink:",
      format_item = function(m)
        return m.display .. "  →  " .. m.target
      end,
    }, function(choice)
      if choice then
        go(choice.target)
      end
    end)
  end
end

local function set_keymap(buf)
  vim.keymap.set("n", "gd", M.goto_definition, {
    buffer = buf,
    desc = "Goto wikilink / definition",
  })
end

function M.setup()
  if M._did_setup then
    return
  end
  M._did_setup = true

  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("wikilinks_setup", { clear = true }),
    pattern = { "markdown", "mdx" },
    callback = function(args)
      set_keymap(args.buf)
    end,
  })

  -- Backfill any markdown buffers already open when setup() runs.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local ft = vim.bo[buf].filetype
      if ft == "markdown" or ft == "mdx" then
        set_keymap(buf)
      end
    end
  end
end

return M

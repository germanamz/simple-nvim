-- Follow markdown links to their target -- wiki-style and standard alike.
--
-- Wikilinks here are project-scoped: `[[a/b/c]]` resolves to
-- `<project root>/a/b/c.md`, where the root is found by walking up from the
-- current file for a `.git` / `.marksman.toml` / `tusk.toml` / `.tusk` marker
-- (e.g. an agent-brain vault). `[[target|alias]]` and `[[target#heading]]` are
-- supported -- the alias and heading are ignored for resolution, and `.md` is
-- appended when the target has no extension.
--
-- Standard `[text](dest)` links are followed by their destination: a relative or
-- absolute file path opens the file (resolved against the source file's own
-- directory, CommonMark-style); an external URL (`http(s):`, `mailto:`, ...)
-- opens via the system handler; an in-document `#anchor` is left to LSP.
--
-- Bound to `gd` (buffer-local) in markdown/mdx buffers as a "smart go-to": it
-- follows the link under the cursor, falling back to LSP go-to-definition when
-- the cursor isn't on one. The same logic backs the read-only preview's `gd`
-- (config.markdown_preview), which matches the rendered text back to the source
-- since glow's output drops link destinations. See setup() and the LspAttach
-- branch in lua/plugins/lsp.lua.

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

-- Classify a standard `[text](dest)` link's destination: an explicit URI scheme
-- (`http://`, `mailto:`, ...) is a "url" (opened by the system handler), a
-- leading `#` is an in-document "anchor" (not followable here), and anything
-- else is a local "file" path.
local function classify_dest(dest)
  if dest:sub(1, 1) == "#" then
    return "anchor"
  elseif dest:match("^%a[%w+.-]*:") then
    return "url"
  end
  return "file"
end
M._classify_dest = classify_dest

-- The standard markdown link `[text](dest)` covering 1-based column `col` on
-- `line`, returned as { text, dest }, or nil. Images (`![alt](src)`) are skipped.
local function standard_link_at(line, col)
  local init = 1
  while true do
    local s, e, text, dest = line:find("%[([^%]]*)%]%(([^%)]*)%)", init)
    if not s then
      return nil
    end
    local is_image = s > 1 and line:sub(s - 1, s - 1) == "!"
    if not is_image and col >= s and col <= e then
      return { text = text, dest = dest }
    end
    init = e + 1
  end
end
M._standard_link_at = standard_link_at

-- Resolve a local-file link destination to an absolute path, relative to the
-- source file's directory (CommonMark semantics). Drops a trailing `#fragment`,
-- keeps an absolute (or `~`) dest, and collapses `.`/`..` segments.
local function resolve_file(dest, src_dir)
  dest = dest:gsub("#.*$", "")
  if dest == "" then
    return nil
  end
  local first = dest:sub(1, 1)
  local path = (first == "/" or first == "~") and dest or (src_dir .. "/" .. dest)
  return vim.fs.normalize(path)
end
M._resolve_file = resolve_file

-- Project root for `source` (a file path); defaults to the current buffer/cwd.
local function project_root(source)
  if not source or source == "" then
    local name = vim.api.nvim_buf_get_name(0)
    source = name ~= "" and name or vim.fn.getcwd()
  end
  return vim.fs.root(source, ROOT_MARKERS) or vim.fn.getcwd()
end

-- Open an absolute path in the current window. Returns false (and notifies) if
-- the file doesn't exist. Standard `[text](dest)` file links route through this
-- and stay fail-fast -- a broken path there is a typo to fix, not a file to
-- conjure (only wikilinks create; see open_or_create).
local function open_path(path)
  if vim.fn.filereadable(path) == 0 then
    vim.notify("Link target not found:\n" .. path, vim.log.levels.WARN, { title = "wikilinks" })
    return false
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
  return true
end

-- The blocking y/n prompt, behind an indirection so headless tests can stub it
-- (vim.fn.confirm needs a UI to answer) and the resolution logic stays testable
-- without it. Defaults to "No" (button 2) so a stray <cr> never creates a file.
M._confirm = vim.fn.confirm

-- Open an absolute path, offering to create it when missing. Backs wikilink
-- following only: following `[[new-note]]` to a file that doesn't exist yet
-- prompts, then spawns it (parent dirs and all) -- Obsidian/zk-style forward
-- references, where you link a note into being before writing it.
local function open_or_create(path)
  if vim.fn.filereadable(path) == 1 then
    vim.cmd.edit(vim.fn.fnameescape(path))
    return true
  end
  if M._confirm("Create " .. path .. "?", "&Yes\n&No", 2) ~= 1 then
    return false
  end
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.cmd.edit(vim.fn.fnameescape(path))
  return true
end

-- Open a project-relative wikilink target in the current window, creating it on
-- confirmation when it doesn't exist yet (see open_or_create).
local function open_target(target, root)
  return open_or_create(root .. "/" .. target)
end

-- Open an external URL with the system handler (browser, mail client, ...).
local function open_url(url)
  local _, err = vim.ui.open(url)
  if err then
    vim.notify("Could not open URL:\n" .. url, vim.log.levels.WARN, { title = "wikilinks" })
  end
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

-- Try to follow the standard `[text](dest)` link under the cursor in the raw
-- source buffer (where the real dest is present). Returns true when the cursor
-- was on a followable link -- a file opens, a URL opens externally -- and false
-- otherwise (including in-document anchors), so the caller can fall back to LSP.
local function try_follow_standard()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local link = standard_link_at(line, col)
  if not link then
    return false
  end
  local kind = classify_dest(link.dest)
  if kind == "url" then
    open_url(link.dest)
    return true
  elseif kind == "file" then
    local name = vim.api.nvim_buf_get_name(0)
    local src_dir = name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
    local path = resolve_file(link.dest, src_dir)
    if path then
      open_path(path)
    end
    return true
  end
  return false
end

-- Smart `gd`: follow a wiki or standard link if the cursor is on one, else LSP.
function M.goto_definition()
  if try_follow() or try_follow_standard() then
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

-- The next non-image standard `[text](dest)` link at/after `init` on `line`,
-- as (s, e, text, dest), or nil. Images (`![alt](src)`) are skipped.
local function next_standard(line, init)
  while true do
    local s, e, text, dest = line:find("%[([^%]]*)%]%(([^%)]*)%)", init)
    if not s then
      return nil
    end
    if not (s > 1 and line:sub(s - 1, s - 1) == "!") then
      return s, e, text, dest
    end
    init = e + 1
  end
end

-- Ordered { display, kind, target } for every followable link in `lines` (wiki
-- and standard, in document order), skipping fenced code (which glow renders
-- raw, so there's no rendered link to match), images, and in-doc `#anchor`
-- links. For wikilinks `target` is the project-relative path; for standard links
-- it is the raw destination (a file path or a URL), resolved at follow time.
local function links_in_lines(lines)
  local out, in_fence = {}, false
  for _, line in ipairs(lines) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      in_fence = not in_fence
    elseif not in_fence then
      local init = 1
      while init <= #line do
        local ws, we, inner = line:find("%[%[(.-)%]%]", init)
        local ss, se, text, dest = next_standard(line, init)
        if ws and (not ss or ws <= ss) then
          local display, target = display_text(inner), normalize_target(inner)
          if display ~= "" and target then
            out[#out + 1] = { display = display, kind = "wiki", target = target }
          end
          init = we + 1
        elseif ss then
          local kind = classify_dest(dest)
          if kind ~= "anchor" and text ~= "" then
            out[#out + 1] = { display = text, kind = kind, target = dest }
          end
          init = se + 1
        else
          break
        end
      end
    end
  end
  return out
end
M._links_in_lines = links_in_lines

-- Among `links`, the distinct links whose display text covers 1-based column
-- `col` in `line`. Longer (more specific) displays win on overlap; dedup is by
-- kind+target so a file and a like-named wikilink aren't collapsed.
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
    local key = (h.kind or "") .. "\1" .. h.target
    if not seen[key] then
      seen[key] = true
      uniq[#uniq + 1] = h
    end
  end
  return uniq
end
M._match_at = match_at

-- Follow the link under the cursor in the (reflowed, target-less) preview by
-- matching the rendered link text against `src`'s links. Files and wikilinks open
-- in the source window, URLs open externally; prompts when a display name maps to
-- more than one target.
function M.follow_in_preview(src)
  if not (src and vim.api.nvim_buf_is_valid(src)) then
    return
  end
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local matches = match_at(links_in_lines(vim.api.nvim_buf_get_lines(src, 0, -1, false)), line, col)
  if #matches == 0 then
    vim.notify("No link under the cursor", vim.log.levels.INFO, { title = "wikilinks" })
    return
  end
  local name = vim.api.nvim_buf_get_name(src)
  local root = project_root(name)
  local src_dir = name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
  local src_win = vim.fn.bufwinid(src)
  local function go(match)
    if match.kind == "url" then
      open_url(match.target)
      return
    end
    if src_win ~= -1 and vim.api.nvim_win_is_valid(src_win) then
      vim.api.nvim_set_current_win(src_win)
    end
    if match.kind == "file" then
      local path = resolve_file(match.target, src_dir)
      if path then
        open_path(path)
      end
    else
      open_target(match.target, root)
    end
  end
  if #matches == 1 then
    go(matches[1])
  else
    vim.ui.select(matches, {
      prompt = "Follow link:",
      format_item = function(m)
        return m.display .. "  →  " .. m.target
      end,
    }, function(choice)
      if choice then
        go(choice)
      end
    end)
  end
end

-- Install the buffer-local smart `gd` (follow link, else LSP go-to). Called from
-- config.options' single markdown FileType autocmd (the one entry point for the
-- markdown family), not from a FileType autocmd here.
function M.set_keymap(buf)
  vim.keymap.set("n", "gd", M.goto_definition, {
    buffer = buf,
    desc = "Goto wikilink / definition",
  })
end

-- Kept callable (init.lua calls it) and idempotent, but a no-op now: keymap
-- registration moved to config.options' markdown FileType autocmd, so this no
-- longer registers a duplicate FileType handler or backfills open buffers.
function M.setup()
  if M._did_setup then
    return
  end
  M._did_setup = true
end

return M

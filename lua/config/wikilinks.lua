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
-- the cursor isn't on one. The raw source buffer is the only place this runs:
-- the `<leader>mp` preview (config.markdown_preview) is a cmux panel, a pane of
-- the surrounding terminal rather than a Neovim buffer, so it has no cursor of
-- ours to read and no keymap of ours to bind. See M.set_keymap, called from
-- config.options' markdown FileType autocmd, and the LspAttach branch in
-- lua/plugins/lsp.lua.

local M = {}

-- A wiki vault is rooted by ANY of these, not just .git — so a note directory
-- with no repo still resolves. This is deliberately NOT routed through
-- util.git.root: that resolver is git-toplevel-only (rev-parse) and would return
-- nil for a non-git vault. The two answer different questions (vault root vs git
-- toplevel) and only coincide on the .git marker, so they stay separate rather
-- than forcing a shared resolver around a marker-set parameter neither wants.
local WIKI_MARKERS = { ".git", ".marksman.toml", "tusk.toml", ".tusk" }

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

-- The next non-image standard `[text](dest)` link at/after `init` on `line`,
-- as (s, e, text, dest), or nil. Images (`![alt](src)`) are skipped rather than
-- returned, so the cursor lookup below walks a line link by link without ever
-- re-testing for a leading `!`. It stays a function of its own despite having a
-- single caller because a line is scanned past for two unrelated reasons -- the
-- match is an image, or the link doesn't cover the cursor -- and one loop per
-- reason leaves the lookup below testing nothing but the column.
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

-- The standard markdown link `[text](dest)` covering 1-based column `col` on
-- `line`, returned as { text, dest }, or nil.
local function standard_link_at(line, col)
  local init = 1
  while true do
    local s, e, text, dest = next_standard(line, init)
    if not s then
      return nil
    end
    if col >= s and col <= e then
      return { text = text, dest = dest }
    end
    init = e + 1
  end
end
M._standard_link_at = standard_link_at

-- Resolve a local-file link destination to an absolute path, relative to the
-- source file's directory (CommonMark semantics). Drops a trailing `#fragment`,
-- decodes percent-escapes, keeps an absolute (or `~`) dest, and collapses
-- `.`/`..` segments.
--
-- A link destination is percent-encoded, so `[Note](My%20Note.md)` names the
-- file "My Note.md" on disk -- without decoding, every link to a file with a
-- space (or any other escaped character) in its name resolves to a path that
-- doesn't exist and is reported as a broken link. The decode runs *after* the
-- fragment split, which is the order the encoding implies: the `#` that starts
-- a fragment is raw, while a `#` belonging to the filename arrives as `%23` and
-- must survive the split to be decoded here. vim.uri_decode leaves a lone `%`
-- (`100% done.md`) alone and doesn't read `+` as a space, both of which are
-- what a path wants.
local function resolve_file(dest, src_dir)
  dest = dest:gsub("#.*$", "")
  if dest == "" then
    return nil
  end
  dest = vim.uri_decode(dest)
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
  return vim.fs.root(source, WIKI_MARKERS) or vim.fn.getcwd()
end
M._project_root = project_root

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
local function try_follow(origin)
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
  -- Record the definition-stack frame only once the file is actually open:
  -- open_or_create returns false for a declined "Create?" prompt, and pushing
  -- before the jump would leave `<C-t>` pointing at a hop that never happened.
  if open_target(target, project_root()) then
    require("config.tagstack").push(origin, "link")
  end
  return true
end

-- Try to follow the standard `[text](dest)` link under the cursor. Returns true
-- when the cursor was on a followable link -- a file opens, a URL opens
-- externally -- and false otherwise (including in-document anchors), so the
-- caller can fall back to LSP.
local function try_follow_standard(origin)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local link = standard_link_at(line, col)
  if not link then
    return false
  end
  local kind = classify_dest(link.dest)
  if kind == "url" then
    -- Hands off to the system handler; the cursor never leaves this buffer, so
    -- there is nothing to come back from.
    open_url(link.dest)
    return true
  elseif kind == "file" then
    local name = vim.api.nvim_buf_get_name(0)
    local src_dir = name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
    local path = resolve_file(link.dest, src_dir)
    -- open_path returns false (and notifies) for an unreadable target, so the
    -- frame goes in only when the jump happened.
    if path and open_path(path) then
      require("config.tagstack").push(origin, "link")
    end
    return true
  end
  return false
end

-- Smart `gd`: follow a wiki or standard link if the cursor is on one, else LSP.
function M.goto_definition()
  local tagstack = require("config.tagstack")
  -- Captured once, up front, and threaded through every branch: whichever one
  -- fires, the frame has to record where the cursor was when `gd` was pressed.
  local origin = tagstack.capture()
  if try_follow(origin) or try_follow_standard(origin) then
    return
  end
  tagstack.definition(origin)
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

return M

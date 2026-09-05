-- Yank a `path:line` reference for the current buffer into the clipboard, so a
-- spot in the code can be pasted into a chat, a commit message, a ticket or an
-- AI prompt and still resolve for whoever reads it.
--
-- The path is relative to the project root, never absolute: an absolute path
-- carries a home directory nobody else has, and a bare file name is ambiguous
-- across a repo. `path:line` (not GitHub's `#L42`) because that is the form
-- terminals, editors and CLI agents already turn into a jump.
local M = {}

local git = require("util.git")
local path = require("util.path")

-- Is `child` inside (or equal to) `dir`? util.path.relative hands back a
-- relative tail when it is and an absolute path when it is not, so the leading
-- slash is the answer — and it is prefix-safe, so /repo-other is not "inside"
-- /repo. (Comparing the result against `child` instead would misfire: relative
-- normalizes with `:p`, which appends a trailing slash to a real directory.)
local function inside(child, dir)
  return path.relative(child, dir):sub(1, 1) ~= "/"
end

--- The directory a reference for `abs` should be expressed relative to.
---
--- The buffer's own work tree is the project root, with one exception: in a
--- superproject the buffer's toplevel is the *submodule*, and a reader handed
--- `file.lua:42` cannot tell which of 200 submodules it means. When the work
--- tree we are sitting in (cwd's toplevel) contains that submodule, the outer
--- tree wins and the reference reads `sub/file.lua:42`. Note this keys off
--- cwd's *toplevel*, not cwd itself: with nvim opened at $HOME the git root
--- still wins, because $HOME is no project.
---
--- Pure (all four inputs passed in) so the ladder is unit-testable without a
--- repo on disk.
---@param abs string absolute path of the file
---@param buf_root string|nil git toplevel of the buffer, nil outside a work tree
---@param cwd string
---@param cwd_root string|nil git toplevel containing the cwd
---@return string|nil base directory, nil when the path has to stay absolute
function M.base(abs, buf_root, cwd, cwd_root)
  if buf_root then
    if cwd_root and inside(buf_root, cwd_root) then
      return cwd_root
    end
    return buf_root
  end
  -- Outside any work tree the cwd is the best stand-in for a project root, but
  -- only for files that actually live under it.
  if inside(abs, cwd) then
    return cwd
  end
  return nil
end

local function real(dir)
  return dir and vim.fn.resolve(dir) or nil
end

--- The path a reference for `buf` should use: relative to the project root that
--- M.base picks, or absolute when the file lives outside both the cwd and any
--- work tree. nil for a buffer with no file.
---
--- Split out of M.reference so callers that need a different spelling of the
--- reference (the agent payload wants `@path#L39-41`) share this ladder rather
--- than reimplementing it.
---@param buf integer
---@return string|nil
function M.relpath(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  -- Resolve both sides before comparing: a buffer name keeps whatever symlinked
  -- path was opened (/tmp, a symlinked checkout) while git prints the physical
  -- toplevel, and a prefix test across the two silently misses — degrading the
  -- reference to an absolute path.
  local abs = vim.fn.resolve(vim.fn.fnamemodify(name, ":p"))
  local cwd = vim.fn.resolve(vim.fn.getcwd())
  local base = M.base(abs, real(git.buf_root(buf)), cwd, real(git.root(cwd)))
  return base and path.relative(abs, base) or abs
end

--- The reference string for `buf` at line `first` (through `last`, when a
--- visual selection spans more than one line). nil for a buffer with no file.
---@param buf integer
---@param first integer 1-indexed line
---@param last integer|nil 1-indexed line, when the reference covers a range
---@return string|nil
function M.reference(buf, first, last)
  local rel = M.relpath(buf)
  if not rel then
    return nil
  end
  if last and last > first then
    return string.format("%s:%d-%d", rel, first, last)
  end
  return string.format("%s:%d", rel, first)
end

--- Copy the reference for the cursor line — or for the visual selection's line
--- span — to the system clipboard.
function M.yank()
  local first, last
  if vim.fn.mode():match("^[vV\22]") then
    -- Still in visual mode inside a keymap callback (they run like <Cmd>), so
    -- '< / '> are stale; `v` is the anchor and `.` the cursor end.
    first, last = vim.fn.line("v"), vim.fn.line(".")
    if first > last then
      first, last = last, first
    end
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "n", false)
  else
    first = vim.api.nvim_win_get_cursor(0)[1]
  end

  local ref = M.reference(vim.api.nvim_get_current_buf(), first, last)
  if not ref then
    vim.notify("No file behind this buffer", vim.log.levels.WARN)
    return
  end
  -- `+` only: clipboard=unnamedplus already makes it the unnamed register, so
  -- `p` pastes it too.
  vim.fn.setreg("+", ref)
  vim.notify("Copied " .. ref)
end

return M

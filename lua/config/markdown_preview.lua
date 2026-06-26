-- Live, read-only markdown preview rendered through `glow`.
--
-- The wrap-vs-table tension in-buffer is unsolvable (`wrap` is window-wide, so
-- you can't soft-wrap prose while leaving wide tables unwrapped). Instead of
-- fighting it, this hands layout to a real renderer: a side split shows the
-- current buffer rendered by `glow -w <panewidth>`, which reflows prose AND keeps
-- wide tables structurally intact (very wide cells are truncated, not shattered).
--
-- glow only emits color to a real TTY (piping it yields bold/italic but no
-- color, and driving a captured pty hangs on glow's terminal-capability
-- queries). So we render glow inside a Neovim **terminal buffer** — Neovim's own
-- terminal emulator answers those queries and carries the full color. The cost
-- is that each refresh re-runs glow, so we refresh on save / leaving insert /
-- (debounced) normal-mode edits rather than on every keystroke, to limit the
-- redraw flicker.
--
-- Live updates without saving your file: each refresh writes the *buffer* lines
-- to a private temp file and renders that, never your file on disk. Editing
-- stays in the raw source buffer; this side pane is the reading view (it replaces
-- the former in-buffer render-markdown.nvim decoration).
--
-- Links get a destination tail glow would render: wiki-style links (`[[target]]`)
-- aren't CommonMark so glow prints them raw; standard `[text](dest)` links show
-- their dest (a noisy absolute temp path for a sibling doc, the full URL for an
-- external link). All are rewritten to anchor-destination links so glow shows
-- just the link-styled text (no tail); the links stay usable via the preview's
-- `gd`, which matches the text back to the source. See transform_links.
--
-- Trigger: buffer-local `<leader>mp` in markdown/mdx buffers (see setup()).
-- `glow` is an external binary; if it is missing the toggle notifies once with
-- an install hint and no-ops, so the config still loads on a fresh machine.

local M = {}

-- src bufnr -> {
--   src, preview_win, preview_buf, src_win,
--   tmpfile, timer, job, gen, life_group, win_group, fm_lines
-- }
--
-- The preview belongs to its file as a group: a state persists for as long as
-- the preview is *enabled* for `src` (you toggled it on), independent of whether
-- the preview window currently exists. A state is in one of two sub-states:
--   * shown  -- preview_win is a valid window (the file is on screen)
--   * hidden -- preview_win is nil (the file left view); auto-restores when the
--               file returns to a window.
-- `life_group` (the lifecycle augroup) watches the file's visibility and lives
-- until a real close; `win_group` holds the refresh/scroll/WinClosed handlers and
-- is recreated on each show, torn down on each hide. See show/hide.
local states = {}
local notified = false
local ft_util = require("util.ft")

local notify_missing, set_keymap, schedule_refresh, refresh, sync_scroll
local setup_win_autocmds, ensure_lifecycle, ensure_state, show, hide

local DEBOUNCE_MS = 300

local function glow_style()
  return vim.o.background == "light" and "light" or "dark"
end

-- Number of leading YAML-frontmatter lines (0 if none) for a list of buffer
-- lines, counting both `---` fences. glow strips frontmatter from its output, so
-- the preview's first line corresponds to the first source line after it; the
-- scroll sync offsets by this so the % mapping stays aligned.
local function frontmatter_lines(lines)
  if lines[1] ~= "---" then
    return 0
  end
  for i = 2, #lines do
    if lines[i] == "---" then
      return i
    end
  end
  return 0
end
M._frontmatter_lines = frontmatter_lines

-- glow renders both wiki-style and standard links in ways that need rewriting
-- before it sees them:
--
--   * Wiki-style `[[target]]` / `[[target|alias]]` links aren't CommonMark, so
--     glow prints them literally.
--   * For a standard `[text](dest)` link, glow appends `dest` as a visible tail
--     -- a noisy absolute temp path for a relative sibling-doc link (resolved
--     against the temp file's dir), or the full URL for an external link.
--
-- Rewrite both so glow shows just the link-styled text: wikilinks and every
-- non-image standard link become `[text](#)` -- a bare fragment, so glow leaves
-- no tail. The links stay followable: the preview's `gd` matches the rendered
-- text back to the source (see config.wikilinks.follow_in_preview). Inline code
-- spans are protected; fenced code blocks are skipped by the caller.

local function convert_links(text)
  -- Protect inline code spans (`...`, ``...``) from rewriting.
  local spans = {}
  text = text:gsub("(`+)(.-)%1", function(ticks, body)
    spans[#spans + 1] = ticks .. body .. ticks
    return "\1" .. #spans .. "\2"
  end)
  -- [[target|alias]] -> [alias](#)  (show the alias)
  text = text:gsub("%[%[[^%]|]+|([^%]]+)%]%]", function(alias)
    return "[" .. alias .. "](#)"
  end)
  -- [[target]] -> [target](#)  (show the target text)
  text = text:gsub("%[%[([^%]|]+)%]%]", function(target)
    return "[" .. target .. "](#)"
  end)
  -- [text](dest) -> [text](#)  (drop the tail glow would append, for local paths
  -- and external URLs alike). The leading `.?` captures the char before `[` so an
  -- image (`![alt](src)`) is detected and left untouched.
  text = text:gsub("(.?)(%[[^%]]*%])%([^%)]*%)", function(prefix, label)
    if prefix == "!" then
      return nil
    end
    return prefix .. label .. "(#)"
  end)
  -- Restore protected code spans.
  text = text:gsub("\1(%d+)\2", function(i)
    return spans[tonumber(i)]
  end)
  return text
end

-- Apply convert_links line by line, leaving fenced code blocks untouched.
local function transform_links(lines)
  local out, in_fence = {}, false
  for _, line in ipairs(lines) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      in_fence = not in_fence
      out[#out + 1] = line
    elseif in_fence then
      out[#out + 1] = line
    else
      out[#out + 1] = convert_links(line)
    end
  end
  return out
end
M._transform_links = transform_links

notify_missing = function()
  if notified then
    return
  end
  notified = true
  vim.notify(
    "markdown preview: `glow` not found on PATH.\n"
      .. "Install it with `brew install glow` "
      .. "(or `go install github.com/charmbracelet/glow@latest`).",
    vim.log.levels.WARN,
    { title = "markdown_preview" }
  )
end

-- Approximate scroll sync: place the preview at the same fraction through its
-- (reflowed) line count as the source cursor. glow reflows, so exact source
-- line -> rendered line mapping is impossible; percentage is the best we can do.
sync_scroll = function(state)
  local pw, pb = state.preview_win, state.preview_buf
  if not (pw and vim.api.nvim_win_is_valid(pw)) then
    return
  end
  if not (pb and vim.api.nvim_buf_is_valid(pb)) then
    return
  end
  if not vim.api.nvim_buf_is_valid(state.src) then
    return
  end
  local src_win = vim.fn.bufwinid(state.src)
  if src_win == -1 then
    return
  end
  -- glow drops YAML frontmatter, so the preview starts at the first source line
  -- after it; offset the source position by the frontmatter length so the cursor
  -- maps to the right fraction of the (frontmatter-less) preview.
  local first = (state.fm_lines or 0) + 1
  local src_total = vim.api.nvim_buf_line_count(state.src)
  local src_line = vim.api.nvim_win_get_cursor(src_win)[1]
  local denom = src_total - first
  local pct = denom > 0 and (src_line - first) / denom or 0
  pct = math.max(0, math.min(1, pct))
  local p_total = vim.api.nvim_buf_line_count(pb)
  local target = math.max(1, math.min(p_total, math.floor(pct * (p_total - 1)) + 1))
  vim.api.nvim_win_call(pw, function()
    pcall(vim.api.nvim_win_set_cursor, pw, { target, 0 })
    vim.cmd("normal! zz")
  end)
end

refresh = function(src)
  local state = states[src]
  if not state then
    return
  end
  if not (state.preview_win and vim.api.nvim_win_is_valid(state.preview_win)) then
    return
  end
  if not vim.api.nvim_buf_is_valid(src) then
    return
  end

  -- Render the live (possibly unsaved) buffer via a private temp file, rewriting
  -- wiki-style and local-file links so glow renders them without a temp-path tail.
  -- Record the frontmatter length (glow strips it) for the scroll sync.
  local raw = vim.api.nvim_buf_get_lines(src, 0, -1, false)
  state.fm_lines = frontmatter_lines(raw)
  vim.fn.writefile(transform_links(raw), state.tmpfile)

  -- glow lays out to roughly `-w` + a left margin (~6 cols); target the pane
  -- width minus that so the rendered frame doesn't overflow horizontally.
  local width = math.max(20, vim.api.nvim_win_get_width(state.preview_win) - 6)

  local tbuf = vim.api.nvim_create_buf(false, true)
  -- `gd` in the preview follows the wikilink under the cursor (matched back to
  -- the source, since glow's output is reflowed and target-less).
  vim.keymap.set("n", "gd", function()
    require("config.wikilinks").follow_in_preview(src)
  end, { buffer = tbuf, silent = true, desc = "Follow wikilink (preview)" })
  -- `<leader>mp` only lives on the source buffer, so once focus is in the preview
  -- window it can't toggle the pane shut. Mirror it here (closing the source's
  -- preview) so the same key dismisses it from either side.
  vim.keymap.set("n", "<leader>mp", function()
    M.close(src)
  end, { buffer = tbuf, silent = true, desc = "Toggle markdown preview" })
  local old_buf = state.preview_buf
  state.gen = state.gen + 1
  local gen = state.gen
  local cmd = { "glow", "-s", glow_style(), "-w", tostring(width), state.tmpfile }

  -- Run glow in a terminal buffer hosted by the preview window (so Neovim's
  -- terminal emulator answers glow's queries and sizes it), without stealing
  -- focus from the source buffer.
  vim.api.nvim_win_call(state.preview_win, function()
    vim.api.nvim_set_current_buf(tbuf)
    state.job = vim.fn.jobstart(cmd, {
      term = true,
      on_exit = function()
        vim.schedule(function()
          local s = states[src]
          if not s or s.gen ~= gen then
            return
          end
          if not (s.preview_buf == tbuf and vim.api.nvim_buf_is_valid(tbuf)) then
            return
          end
          -- Drop Neovim's trailing "[Process exited N]" terminal line.
          local n = vim.api.nvim_buf_line_count(tbuf)
          local last = vim.api.nvim_buf_get_lines(tbuf, math.max(0, n - 1), n, false)[1] or ""
          if last:match("%[Process exited") then
            vim.bo[tbuf].modifiable = true
            vim.api.nvim_buf_set_lines(tbuf, n - 1, n, false, {})
            vim.bo[tbuf].modifiable = false
          end
          sync_scroll(s)
        end)
      end,
    })
  end)

  state.preview_buf = tbuf
  if old_buf and old_buf ~= tbuf and vim.api.nvim_buf_is_valid(old_buf) then
    pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
  end
end

schedule_refresh = function(state)
  if not state.timer then
    state.timer = vim.uv.new_timer()
  end
  state.timer:stop()
  state.timer:start(
    DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      refresh(state.src)
    end)
  )
end

-- Window-scoped autocmds: live only while the preview pane is shown, recreated on
-- each show() and torn down on each hide(). They drive the rendered output and
-- handle the user closing the pane directly.
setup_win_autocmds = function(state)
  local grp = vim.api.nvim_create_augroup("markdown_preview_win_" .. state.src, { clear = true })
  state.win_group = grp

  -- Refresh on save, on leaving insert, and on debounced normal-mode edits --
  -- deliberately NOT TextChangedI, so it doesn't flicker on every keystroke.
  vim.api.nvim_create_autocmd({ "BufWritePost", "InsertLeave", "TextChanged" }, {
    group = grp,
    buffer = state.src,
    callback = function()
      schedule_refresh(state)
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = grp,
    callback = function()
      schedule_refresh(state)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = grp,
    buffer = state.src,
    callback = function()
      sync_scroll(state)
    end,
  })
  -- Closing the preview window directly (`:q` in the pane) is a real disable, not
  -- a hide -- the file is no longer in the preview group.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = grp,
    callback = function(ev)
      if tonumber(ev.match) == state.preview_win then
        M.close(state.src)
      end
    end,
  })
end

-- Lifecycle autocmds: created once when the preview is first enabled, removed only
-- on a real close. They tie the pane's existence to the file's visibility so the
-- two move as a group.
ensure_lifecycle = function(state)
  local grp = vim.api.nvim_create_augroup("markdown_preview_life_" .. state.src, { clear = true })
  state.life_group = grp

  -- File left a window -> hide the pane, but only once the file is gone from
  -- *every* window (closing one split of a file shown in two keeps the preview).
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = grp,
    buffer = state.src,
    callback = function()
      local src = state.src
      vim.schedule(function()
        if states[src] and vim.fn.bufwinid(src) == -1 then
          hide(src)
        end
      end)
    end,
  })
  -- File came back to a window -> restore the pane next to it.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = grp,
    buffer = state.src,
    callback = function()
      local src = state.src
      vim.schedule(function()
        if states[src] then
          show(src, vim.fn.bufwinid(src))
        end
      end)
    end,
  })
  -- The file itself is gone -> tear the whole group down.
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = grp,
    buffer = state.src,
    callback = function()
      M.close(state.src)
    end,
  })
end

-- Create (once) the persistent state for an enabled preview, along with the
-- lifecycle autocmds. Does not open any window -- that's show()'s job.
ensure_state = function(src)
  local state = states[src]
  if state then
    return state
  end
  state = {
    src = src,
    preview_win = nil,
    preview_buf = nil,
    src_win = nil,
    tmpfile = vim.fn.tempname() .. ".md",
    gen = 0,
    fm_lines = 0,
  }
  states[src] = state
  ensure_lifecycle(state)
  return state
end

-- Open the preview pane for an already-enabled file in a split to the right of
-- `target_win` (the window showing the file). No-op if already shown.
show = function(src, target_win)
  local state = states[src]
  if not state then
    return
  end
  if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
    return
  end
  if not vim.api.nvim_buf_is_valid(src) then
    return
  end
  if not (target_win and target_win ~= -1 and vim.api.nvim_win_is_valid(target_win)) then
    return
  end

  -- Placeholder buffer to create the split; replaced by the terminal on refresh.
  local placeholder = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(placeholder, false, { win = target_win, split = "right" })

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].colorcolumn = ""
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = false
  vim.wo[win].list = false
  vim.wo[win].wrap = false -- glow already wraps to the target width
  vim.wo[win].spell = false
  vim.wo[win].winfixwidth = true

  state.preview_win = win
  state.preview_buf = placeholder
  state.src_win = target_win
  setup_win_autocmds(state)
  refresh(src)
end

-- Tear down the preview pane while keeping the file enabled (state + lifecycle
-- survive, so it auto-restores when the file is back on screen).
hide = function(src)
  local state = states[src]
  if not state then
    return
  end
  -- Drop the window-scoped autocmds FIRST so closing the pane doesn't trip
  -- WinClosed -> M.close, which would forget the file was enabled.
  if state.win_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.win_group)
    state.win_group = nil
  end
  if state.timer then
    state.timer:stop()
  end
  if state.job then
    pcall(vim.fn.jobstop, state.job)
    state.job = nil
  end
  if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
    pcall(vim.api.nvim_win_close, state.preview_win, true)
  end
  if state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf) then
    pcall(vim.api.nvim_buf_delete, state.preview_buf, { force = true })
  end
  state.preview_win = nil
  state.preview_buf = nil
end

function M.open(src)
  if vim.fn.executable("glow") ~= 1 then
    notify_missing()
    return
  end
  src = src or vim.api.nvim_get_current_buf()
  ensure_state(src)
  show(src, vim.api.nvim_get_current_win())
end

function M.close(src)
  src = src or vim.api.nvim_get_current_buf()
  local state = states[src]
  if not state then
    return
  end
  -- Delete the augroups first so closing the window doesn't re-enter via
  -- WinClosed and tearing the file down doesn't re-enter via the lifecycle group.
  if state.life_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.life_group)
  end
  if state.win_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.win_group)
  end
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  if state.job then
    pcall(vim.fn.jobstop, state.job)
  end
  if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
    pcall(vim.api.nvim_win_close, state.preview_win, true)
  end
  if state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf) then
    pcall(vim.api.nvim_buf_delete, state.preview_buf, { force = true })
  end
  if state.tmpfile then
    pcall(vim.fn.delete, state.tmpfile)
  end
  states[src] = nil
end

function M.toggle()
  local src = vim.api.nvim_get_current_buf()
  local state = states[src]
  if state and state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
    M.close(src)
  else
    M.open(src)
  end
end

set_keymap = function(buf)
  vim.keymap.set("n", "<leader>mp", M.toggle, {
    buffer = buf,
    desc = "Toggle markdown preview",
  })
end

function M.setup()
  if M._did_setup then
    return
  end
  M._did_setup = true

  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("markdown_preview_setup", { clear = true }),
    pattern = ft_util.markdown,
    callback = function(args)
      set_keymap(args.buf)
    end,
  })

  -- Backfill any markdown buffers already open when setup() runs.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local ft = vim.bo[buf].filetype
      if ft_util.is_markdown(ft) then
        set_keymap(buf)
      end
    end
  end
end

return M

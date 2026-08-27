-- Locating the cmux CLI, shared by everything in this config that talks to the
-- terminal Neovim is running inside.
--
-- cmux is a Ghostty-based terminal that hosts panes, browser surfaces and
-- markdown panels, driven over ~/.local/state/cmux/cmux.sock. The socket is
-- authed by CMUX_SOCKET_CAPABILITY, which Neovim inherits from the pane it was
-- launched in, so callers need no auth handling of their own -- they only need
-- to know whether there is a CLI to call at all.
--
-- Two consumers so far: config.open_url (docs into a browser pane) and
-- config.markdown_preview (markdown into a rendered panel). The detector lives
-- here so the "is this a cmux session" rule is stated once.
local M = {}

--- Path to the cmux CLI, or nil when this is not a cmux session.
---
--- Detection keys on CMUX_SURFACE_ID rather than TERM_PROGRAM: cmux embeds
--- Ghostty, so TERM_PROGRAM reads "ghostty" and would also match a plain
--- Ghostty window, which has none of the panes we would be opening into.
---@return string|nil
function M.bin()
  if not vim.env.CMUX_SURFACE_ID then
    return nil
  end
  if vim.fn.executable("cmux") == 1 then
    return "cmux"
  end
  -- PATH can be trimmed by a `:terminal` or a session restore even though the
  -- surface is still a cmux one; the app exports its own CLI path for that.
  local bundled = vim.env.CMUX_BUNDLED_CLI_PATH
  if bundled and vim.uv.fs_stat(bundled) then
    return bundled
  end
  return nil
end

return M

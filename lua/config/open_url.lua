-- Route a URL to the best viewer available, preferring one that keeps you in
-- the same app.
--
-- This Neovim runs inside cmux, a Ghostty-based terminal that hosts a built-in
-- WKWebView browser. Its CLI talks to ~/.local/state/cmux/cmux.sock, authed by
-- CMUX_SOCKET_CAPABILITY, which Neovim inherits from the pane it was launched
-- in — so `vim.system({ "cmux", ... })` needs no auth handling of its own.
-- Opening docs in a cmux pane beats `vim.ui.open` here: the page lands in a
-- split of the *same* workspace instead of raising a separate browser app over
-- the terminal.
--
-- Everything is async. A URL open must never block the keypress that asked for
-- it, and the cmux CLI is a socket round-trip.
--
-- Elsewhere (a plain terminal, cmux's browser disabled, a non-http URI) this
-- degrades to `vim.ui.open` with no behavior change.

local M = {}

-- surface_id (a UUID) of the pane docs were last opened in, so repeated lookups
-- re-navigate one pane instead of stacking a new split per press.
--
-- Deliberately the UUID and NOT the `surface:N` ref: refs are positional and
-- renumber as surfaces come and go (opening a tab moved a live surface from
-- surface:11 to surface:12 in testing). The UUID from `--json` is stable.
local docs_surface = nil

-- Set once cmux has told us its browser is unavailable (e.g. `cmux
-- disable-browser`). Without this every subsequent open would pay a failed
-- socket round-trip before falling back.
local browser_unavailable = false

-- The `vim.ui.open` we wrapped, so the wrapper can delegate everything it does
-- not handle (file:// URIs, paths) rather than reimplementing it.
local inner_ui_open = nil

--- Path to the cmux CLI, or nil when this is not a cmux session. Shared with
--- config.markdown_preview, which opens rendered markdown panels the same way,
--- so the "is this a cmux session" rule is stated once (see util.cmux).
---@type fun(): string|nil
local cmux_bin = require("util.cmux").bin

--- Hand `url` to core's opener.
---
--- Calls the *pre-wrap* `vim.ui.open` when M.setup() has wrapped it. The
--- wrapper would delegate here anyway (both of its guards are false by the time
--- we fall back), but relying on that would make the no-recursion argument
--- depend on state set elsewhere.
---@param url string
local function fallback(url)
  local open = inner_ui_open or vim.ui.open
  vim.schedule(function()
    local ok, err = pcall(open, url)
    if not ok then
      vim.notify("open_url: " .. tostring(err), vim.log.levels.WARN)
    end
  end)
end

--- Open `url` in a new cmux browser split and remember the surface.
---@param bin string
---@param url string
local function cmux_open_new(bin, url)
  -- --focus false is already the default for `browser open`, but say it: the
  -- point of opening docs from Neovim is to keep the cursor in Neovim, and a
  -- default is a weaker guarantee than an argument.
  -- `--id-format both` is load-bearing, not cosmetic: cmux's JSON carries only
  -- the positional `surface_ref` by default, and the whole point of tracking a
  -- pane across calls is to hold the UUID that refs renumber out from under.
  local cmd = { bin, "--json", "--id-format", "both", "browser", "open", url, "--focus", "false" }
  vim.system(cmd, { text = true }, function(res)
    if res.code ~= 0 then
      -- The browser can be switched off wholesale (`cmux disable-browser`).
      -- We cannot tell that apart from a transient failure here, so stop
      -- trying for this session rather than paying the round-trip forever.
      browser_unavailable = true
      fallback(url)
      return
    end
    local ok, decoded = pcall(vim.json.decode, res.stdout)
    if ok and type(decoded) == "table" then
      docs_surface = decoded.surface_id
    end
    -- A missing surface_id is not a failure: the page did open, we just cannot
    -- reuse the pane, so the next call opens another split.
  end)
end

--- Send `url` to cmux's built-in browser, reusing the docs pane when there is
--- one, and falling back to `vim.ui.open` when cmux cannot take it.
---@param bin string
---@param url string
local function cmux_open(bin, url)
  if not docs_surface then
    return cmux_open_new(bin, url)
  end
  -- Re-navigate the pane we already own. A dead surface (the user closed the
  -- split) exits 1 with "invalid_params: Browser operation failed", which is
  -- the signal to open a fresh one.
  vim.system(
    { bin, "browser", "--surface", docs_surface, "goto", url },
    { text = true },
    function(res)
      if res.code ~= 0 then
        docs_surface = nil
        cmux_open_new(bin, url)
      end
    end
  )
end

--- Open a URL, preferring cmux's in-app browser.
---
--- `file://` is accepted alongside http(s) because rust-analyzer answers
--- `experimental/externalDocs` with a path into rustup's generated HTML when
--- the docs are on disk. cmux's browser renders those (verified), so they reuse
--- the same docs pane instead of being handed to the system browser.
---
--- Other URI schemes and non-cmux sessions go straight to `vim.ui.open`.
---@param url string
function M.open(url)
  if type(url) ~= "string" or url == "" then
    return
  end
  local browsable = url:match("^https?://") or url:match("^file://")
  local bin = (not browser_unavailable) and browsable and cmux_bin()
  if bin then
    cmux_open(bin, url)
  else
    fallback(url)
  end
end

--- Make `gx`, LSP handlers, and anything else that opens a web URL go through
--- the cmux pane too, by wrapping `vim.ui.open`.
---
--- Only http(s) is intercepted; file paths and other URIs keep core's behavior,
--- which is what actually knows about `open`/`xdg-open`/wslview per platform.
--- The wrapper returns `nil, nil` for the intercepted case — callers such as
--- `gx` only read the second value to report an error, and there is no error to
--- report yet at the point this returns (the open is still in flight).
function M.setup()
  if inner_ui_open then
    return
  end
  inner_ui_open = vim.ui.open
  vim.ui.open = function(path, opts)
    local bin = type(path) == "string"
      and path:match("^https?://")
      and not browser_unavailable
      and cmux_bin()
    if bin then
      cmux_open(bin, path)
      return nil, nil
    end
    return inner_ui_open(path, opts)
  end
end

--- Test seam: forget the remembered pane and any cached unavailability.
function M._reset()
  docs_surface = nil
  browser_unavailable = false
end

--- Test seam: the surface_id docs are currently pinned to, if any.
---@return string|nil
function M._surface()
  return docs_surface
end

return M

-- Minimal floating-window handle that owns its (win, buf) lifetime. Extracted
-- because the valid-guarded close/teardown was byte-identical in review_base and
-- telescope_smart. Only the teardown + open-tracking are shared; each caller
-- builds its own buffer contents and computes its own window config (a centered
-- bordered badge vs a borderless results-anchored strip), so those stay local.
local Overlay = {}
Overlay.__index = Overlay

function Overlay.new()
  return setmetatable({ win = nil, buf = nil }, Overlay)
end

-- Close the window and delete the buffer if either is still valid, then reset.
function Overlay:close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
  self.win, self.buf = nil, nil
end

-- Open `win_config` over the already-populated `buf`, replacing any existing
-- overlay first, and track both so :close() can tear them down. Returns the win.
function Overlay:mount(buf, win_config)
  self:close()
  self.buf = buf
  self.win = vim.api.nvim_open_win(buf, false, win_config)
  return self.win
end

return Overlay

-- Count LSP references to the symbol under the cursor within the current buffer
-- and expose the result as a statusline segment (`_G.lsp_refs_status`).

local M = {}

-- state[bufnr] = { row, col, count } — last resolved result for that buffer.
local state = {}

local function has_refs_client(bufnr)
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if c.server_capabilities and c.server_capabilities.referencesProvider then
      return c
    end
  end
  return nil
end

local function cursor_rc()
  local pos = vim.api.nvim_win_get_cursor(0)
  return pos[1] - 1, pos[2]
end

local function request(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if bufnr ~= vim.api.nvim_get_current_buf() then return end

  local client = has_refs_client(bufnr)
  if not client then
    state[bufnr] = nil
    return
  end

  local row, col = cursor_rc()
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.context = { includeDeclaration = true }

  local buf_uri = vim.uri_from_bufnr(bufnr)

  local ok = pcall(vim.lsp.buf_request, bufnr, "textDocument/references", params,
    function(err, result)
      if err or not result then return end
      if not vim.api.nvim_buf_is_valid(bufnr) then return end

      -- Drop stale responses: cursor moved off the position we queried.
      local cur_row, cur_col = cursor_rc()
      if cur_row ~= row or cur_col ~= col then return end
      if vim.api.nvim_get_current_buf() ~= bufnr then return end

      local seen = {}
      local count = 0
      for _, loc in ipairs(result) do
        if loc.uri == buf_uri then
          local s = loc.range.start
          local key = s.line .. ":" .. s.character
          if not seen[key] then
            seen[key] = true
            count = count + 1
          end
        end
      end

      state[bufnr] = { row = row, col = col, count = count }
      vim.cmd("redrawstatus")
    end)

  if not ok then state[bufnr] = nil end
end

local function invalidate_on_move()
  local bufnr = vim.api.nvim_get_current_buf()
  local s = state[bufnr]
  if not s then return end
  local row, col = cursor_rc()
  if s.row ~= row or s.col ~= col then
    state[bufnr] = nil
    vim.cmd("redrawstatus")
  end
end

function M.status()
  local bufnr = vim.api.nvim_get_current_buf()
  local s = state[bufnr]
  if not s or s.count <= 0 then return "" end
  local row, col = cursor_rc()
  if s.row ~= row or s.col ~= col then return "" end
  return string.format(" ⇄%d ", s.count)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("lsp_refs_status", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
    group = group,
    callback = function(args) request(args.buf) end,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = invalidate_on_move,
  })

  vim.api.nvim_create_autocmd({ "BufLeave", "BufWipeout" }, {
    group = group,
    callback = function(args) state[args.buf] = nil end,
  })

  _G.lsp_refs_status = M.status
end

return M

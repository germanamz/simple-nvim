local nvim_env = require("helpers.nvim_env")

local function fresh_buffer_with_lines(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function ns_id()
  return vim.api.nvim_create_namespace("lsp_refs_status")
end

describe("config.lsp_refs", function()
  local env_root, M
  local orig_get_clients, orig_buf_request, orig_make_params

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
    package.loaded["config.lsp_refs"] = nil
    M = require("config.lsp_refs")
    M.setup()

    orig_get_clients = vim.lsp.get_clients
    orig_buf_request = vim.lsp.buf_request
    orig_make_params = vim.lsp.util.make_position_params
  end)

  after_each(function()
    if orig_get_clients then
      vim.lsp.get_clients = orig_get_clients
      orig_get_clients = nil
    end
    if orig_buf_request then
      vim.lsp.buf_request = orig_buf_request
      orig_buf_request = nil
    end
    if orig_make_params then
      vim.lsp.util.make_position_params = orig_make_params
      orig_make_params = nil
    end
    pcall(vim.api.nvim_clear_autocmds, { group = "lsp_refs_status" })
    nvim_env.teardown(env_root)
  end)

  describe("M.status", function()
    it("returns empty string when no state for current buffer", function()
      fresh_buffer_with_lines({ "x x x" })
      assert.are.equal("", M.status())
    end)
  end)

  describe("M.next / M.prev", function()
    local function seed_marks(buf)
      local ns = ns_id()
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_row = 0, end_col = 1 })
      vim.api.nvim_buf_set_extmark(buf, ns, 1, 2, { end_row = 1, end_col = 3 })
      vim.api.nvim_buf_set_extmark(buf, ns, 2, 0, { end_row = 2, end_col = 1 })
    end

    it("forward: cursor before all marks jumps to first mark", function()
      local buf = fresh_buffer_with_lines({ "a a a", "b b b", "c c c", "d d d" })
      seed_marks(buf)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      M.next()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      assert.are.equal(2, row)
      assert.are.equal(2, col)
    end)

    it("forward wrap: cursor past last mark wraps to first", function()
      local buf = fresh_buffer_with_lines({ "a a a", "b b b", "c c c", "d d d" })
      seed_marks(buf)
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      M.next()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      assert.are.equal(1, row)
      assert.are.equal(0, col)
    end)

    it("backward: cursor after all marks jumps to last mark", function()
      local buf = fresh_buffer_with_lines({ "a a a", "b b b", "c c c", "d d d" })
      seed_marks(buf)
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      M.prev()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      assert.are.equal(3, row)
      assert.are.equal(0, col)
    end)

    it("backward wrap: cursor before all marks wraps to last", function()
      local buf = fresh_buffer_with_lines({ "a a a", "b b b", "c c c", "d d d" })
      seed_marks(buf)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      M.prev()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      assert.are.equal(3, row)
      assert.are.equal(0, col)
    end)

    it("on mark: M.next jumps past current mark", function()
      local buf = fresh_buffer_with_lines({ "a a a", "b b b", "c c c", "d d d" })
      seed_marks(buf)
      vim.api.nvim_win_set_cursor(0, { 2, 2 })
      M.next()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      assert.are.equal(3, row)
      assert.are.equal(0, col)
    end)
  end)

  describe("reference request callback", function()
    local function install_lsp_stubs(buf)
      local fake_client = {
        server_capabilities = { referencesProvider = true },
        offset_encoding = "utf-16",
      }
      vim.lsp.get_clients = function(_)
        return { fake_client }
      end
      vim.lsp.util.make_position_params = function(_, _)
        return {
          textDocument = { uri = vim.uri_from_bufnr(buf) },
          position = { line = 0, character = 0 },
        }
      end

      local captured = {}
      vim.lsp.buf_request = function(_, _, _, handler)
        captured.handler = handler
        return true
      end
      return captured
    end

    it("places extmarks for 3 same-buffer references and reports count", function()
      local buf = fresh_buffer_with_lines({ "x x x", "x x x", "x x x" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local captured = install_lsp_stubs(buf)

      vim.api.nvim_exec_autocmds("CursorHold", { group = "lsp_refs_status", buffer = buf })
      assert.is_function(captured.handler)

      local uri = vim.uri_from_bufnr(buf)
      captured.handler(nil, {
        {
          uri = uri,
          range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } },
        },
        {
          uri = uri,
          range = { start = { line = 1, character = 2 }, ["end"] = { line = 1, character = 3 } },
        },
        {
          uri = uri,
          range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 1 } },
        },
      })

      local marks = vim.api.nvim_buf_get_extmarks(buf, ns_id(), 0, -1, {})
      assert.are.equal(3, #marks)
      assert.are.equal(" ⇄3 ", M.status())
    end)

    it("places no extmarks when count is below 2", function()
      local buf = fresh_buffer_with_lines({ "x x x", "x x x" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local captured = install_lsp_stubs(buf)

      vim.api.nvim_exec_autocmds("CursorHold", { group = "lsp_refs_status", buffer = buf })
      assert.is_function(captured.handler)

      local uri = vim.uri_from_bufnr(buf)
      captured.handler(nil, {
        {
          uri = uri,
          range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } },
        },
      })

      local marks = vim.api.nvim_buf_get_extmarks(buf, ns_id(), 0, -1, {})
      assert.are.equal(0, #marks)
    end)

    it("dedupes references with the same line:character start", function()
      local buf = fresh_buffer_with_lines({ "x x x", "x x x", "x x x" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local captured = install_lsp_stubs(buf)

      vim.api.nvim_exec_autocmds("CursorHold", { group = "lsp_refs_status", buffer = buf })
      assert.is_function(captured.handler)

      local uri = vim.uri_from_bufnr(buf)
      captured.handler(nil, {
        {
          uri = uri,
          range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } },
        },
        {
          uri = uri,
          range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } },
        },
        {
          uri = uri,
          range = { start = { line = 1, character = 2 }, ["end"] = { line = 1, character = 3 } },
        },
      })

      assert.are.equal(" ⇄2 ", M.status())
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns_id(), 0, -1, {})
      assert.are.equal(2, #marks)
    end)

    it("drops stale responses when cursor moved before handler fires", function()
      local buf = fresh_buffer_with_lines({ "x x x", "x x x", "x x x" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local captured = install_lsp_stubs(buf)

      vim.api.nvim_exec_autocmds("CursorHold", { group = "lsp_refs_status", buffer = buf })
      assert.is_function(captured.handler)

      vim.api.nvim_win_set_cursor(0, { 2, 1 })

      local uri = vim.uri_from_bufnr(buf)
      captured.handler(nil, {
        {
          uri = uri,
          range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } },
        },
        {
          uri = uri,
          range = { start = { line = 1, character = 2 }, ["end"] = { line = 1, character = 3 } },
        },
        {
          uri = uri,
          range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 1 } },
        },
      })

      local marks = vim.api.nvim_buf_get_extmarks(buf, ns_id(), 0, -1, {})
      assert.are.equal(0, #marks)
      assert.are.equal("", M.status())
    end)

    it("returns empty status after the cursor moves off the recorded position", function()
      local buf = fresh_buffer_with_lines({ "x x x", "x x x", "x x x" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local captured = install_lsp_stubs(buf)

      vim.api.nvim_exec_autocmds("CursorHold", { group = "lsp_refs_status", buffer = buf })
      assert.is_function(captured.handler)

      local uri = vim.uri_from_bufnr(buf)
      captured.handler(nil, {
        {
          uri = uri,
          range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } },
        },
        {
          uri = uri,
          range = { start = { line = 1, character = 2 }, ["end"] = { line = 1, character = 3 } },
        },
      })

      assert.are.equal(" ⇄2 ", M.status())
      vim.api.nvim_win_set_cursor(0, { 3, 4 })
      assert.are.equal("", M.status())
    end)
  end)
end)

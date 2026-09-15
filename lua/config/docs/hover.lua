-- `K` for C, C++ and Python: core's LSP hover, plus a documentation excerpt
-- when the server's hover has none.
--
-- clangd hovers libc and libc++ symbols with a signature and nothing else (the
-- macOS SDK headers carry no doc comments), and pyright does the same for the
-- builtins implemented in C (typeshed stubs carry no docstrings). The text
-- exists — cppreference, the POSIX man pages, the Python library reference —
-- and config.docs.devdocs keeps it on disk. This module decides when to reach
-- for it and puts it in the same float.
--
-- The split of labor:
--   * config.docs.brief.<lang> NAMES the symbol by asking its server
--     (clangd symbolInfo, pyright declaration) — no bundle reads.
--   * config.docs.devdocs finds the name in a bundle and cuts the excerpt.
--   * this module requests the hover, decides whether the server already said
--     enough, and opens ONE float, so nothing jumps as results arrive.
--
-- Two promises hold everywhere below. `K` never touches the network — bundles
-- arrive only through `:DocsInstall`. And `K` never shows less than core's
-- hover: every failure on the excerpt side degrades to the plain hover.
--
-- Why not reuse vim.lsp.buf.hover: its float is built and sized inside one
-- callback with no seam to add lines to, so the choices were to edit a window
-- core owns after the fact (the float jumps, and conceal/highlighting were
-- computed for the old contents) or to wrap client.request (which would feed
-- every other hover consumer, including the `gK` URL resolver, rewritten
-- responses). Owning the ~60 lines of request-and-render is the smaller cost.

local M = {}

--- How long `K` waits for an excerpt before opening the hover without one. The
--- excerpt still lands in the cache, so the next press has it.
M.DEADLINE_MS = 1500

-- filetype -> provider module under config.docs.brief. Static, like BY_FT in
-- config.docs, so a buffer of another filetype never loads a provider.
local PROVIDERS = {
  c = "c",
  cpp = "c",
  python = "python",
}

---@param ft string
---@return boolean
function M.has_provider(ft)
  return PROVIDERS[ft] ~= nil
end

---@param ft string
---@return table|nil
local function provider_for(ft)
  local name = PROVIDERS[ft]
  if not name then
    return nil
  end
  local ok, mod = pcall(require, "config.docs.brief." .. name)
  return ok and mod or nil
end

-- Lines a server's hover template always produces, per server. What survives
-- these (outside code fences) is documentation.
local STRUCTURE = {
  clangd = {
    "^###? ",
    "^provided by ",
    "^→ ",
    "^Parameters:$",
    "^Template parameters:$",
    "^%- ",
    "^Type: ",
    "^Value = ",
    "^Size: ",
    "^Offset: ",
    "^Padding: ",
    "^Passed ",
  },
  pyright = {},
}

--- Does a hover already carry documentation?
---
--- An unknown server always counts as having some, so a hover this cannot read
--- is left exactly as the server sent it.
---@param client_name string
---@param lines string[]
---@return boolean
function M._has_prose(client_name, lines)
  local patterns = STRUCTURE[client_name]
  if not patterns then
    return true
  end
  local in_fence = false
  for _, raw in ipairs(lines) do
    local line = vim.trim(raw)
    if line:match("^```") then
      in_fence = not in_fence
    elseif not in_fence and line ~= "" and line ~= "---" then
      local structural = false
      for _, pattern in ipairs(patterns) do
        if line:match(pattern) then
          structural = true
          break
        end
      end
      if not structural then
        return true
      end
    end
  end
  return false
end

---@class DocsBrief
---@field label string|nil
---@field lines string[]|nil
---@field truncated boolean|nil
---@field hint string|nil

--- A hover's lines with the brief appended.
---@param hover_lines string[]
---@param brief DocsBrief|nil
---@return string[]
function M._compose(hover_lines, brief)
  local out = vim.list_extend({}, hover_lines)
  if not brief then
    return out
  end
  out[#out + 1] = "---"
  if brief.hint then
    out[#out + 1] = "*" .. brief.hint .. "*"
    return out
  end
  out[#out + 1] = "*" .. brief.label .. "*"
  out[#out + 1] = ""
  vim.list_extend(out, brief.lines)
  if brief.truncated then
    out[#out + 1] = ""
    out[#out + 1] = "*gK: full page*"
  end
  return out
end

local warned = false

--- Test seam.
function M._reset()
  warned = false
end

---@param err any
local function warn(err)
  if warned then
    return
  end
  warned = true
  vim.notify("docs: hover excerpt failed: " .. tostring(err), vim.log.levels.WARN)
end

--- Walk a provider's candidates to the first excerpt an installed bundle has.
---
--- A candidate whose bundle is not installed is remembered rather than skipped
--- silently: if nothing installed answers, the float says which bundles would
--- have, instead of leaving the gap unexplained.
---@param provider table
---@param ctx table
---@param cb fun(brief: DocsBrief|nil)
function M._brief(provider, ctx, cb)
  local finished = false
  local function done(value)
    if not finished then
      finished = true
      cb(value)
    end
  end

  local ok, err = pcall(provider.candidates, ctx, function(candidates)
    local walked, result = pcall(function()
      if type(candidates) ~= "table" then
        return nil
      end
      local devdocs = require("config.docs.devdocs")
      local missing, seen = {}, {}
      for _, candidate in ipairs(candidates) do
        if devdocs.installed(candidate.slug) then
          local entry = devdocs.lookup(candidate.slug, candidate.name, candidate.hint)
          local excerpt = entry and devdocs.excerpt(candidate.slug, entry)
          if excerpt and #excerpt.lines > 0 then
            return {
              label = devdocs.label(candidate.slug, entry),
              lines = excerpt.lines,
              truncated = excerpt.truncated,
            }
          end
        elseif not seen[candidate.slug] then
          seen[candidate.slug] = true
          missing[#missing + 1] = candidate.slug
        end
      end
      if #missing > 0 then
        return { hint = "No docs installed — :DocsInstall " .. table.concat(missing, " ") }
      end
      return nil
    end)
    if not walked then
      warn(result)
      return done(nil)
    end
    done(result)
  end)
  if not ok then
    warn(err)
    done(nil)
  end
end

--- A hover result's contents as markdown lines.
---@param contents any
---@return string[]
local function markdown_lines(contents)
  if type(contents) == "table" and contents.kind == "plaintext" then
    local lines = { "```" }
    vim.list_extend(lines, vim.split(contents.value or "", "\n", { trimempty = true }))
    lines[#lines + 1] = "```"
    return lines
  end
  return vim.lsp.util.convert_input_to_markdown_lines(contents)
end

--- Valid hover results, in client-id order, filtered the way core filters them.
---@param results table<integer, { err: table|nil, result: table|nil }>
---@return { client: vim.lsp.Client, result: table }[] items
---@return boolean empty  -- some server answered, but with nothing
function M._collect(results)
  local items, empty = {}, false
  local ids = vim.tbl_keys(results)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local resp = results[id]
    if resp.err then
      vim.lsp.log.error(resp.err.code, resp.err.message)
    elseif resp.result and resp.result.contents then
      local contents = resp.result.contents
      local value = type(contents) == "string" and contents
        or vim.tbl_get(contents, "value")
        or vim.tbl_get(contents, 1, "value")
        or contents[1]
        or ""
      local client = vim.lsp.get_client_by_id(id)
      if type(value) == "string" and #value > 0 and client then
        items[#items + 1] = { client = client, result = resp.result }
      else
        empty = true
      end
    end
  end
  return items, empty
end

local hover_ns = vim.api.nvim_create_namespace("config.docs.hover_range")

---@param bufnr integer
---@param pos { line: integer, character: integer }
---@param encoding string
---@return integer
local function byte_col(bufnr, pos, encoding)
  local line = vim.api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1] or ""
  local ok, col = pcall(vim.str_byteindex, line, encoding, pos.character, false)
  return ok and col or pos.character
end

--- Open the float, as core's hover does: one section per client, a rule
--- between them, the hovered range highlighted until the float closes.
---@param bufnr integer
---@param items { client: vim.lsp.Client, result: table }[]
---@param target table|nil
---@param brief DocsBrief|nil
---@return integer|nil winid
function M._open(bufnr, items, target, brief)
  local contents = {}
  for i, item in ipairs(items) do
    if #items > 1 then
      contents[#contents + 1] = "# " .. item.client.name
    end
    local lines = markdown_lines(item.result.contents)
    if item == target then
      lines = M._compose(lines, brief)
    end
    vim.list_extend(contents, lines)
    if i < #items then
      contents[#contents + 1] = "---"
    end

    local range = item.result.range
    if range then
      local encoding = item.client.offset_encoding
      vim.hl.range(
        bufnr,
        hover_ns,
        "LspReferenceTarget",
        { range.start.line, byte_col(bufnr, range.start, encoding) },
        { range["end"].line, byte_col(bufnr, range["end"], encoding) },
        { priority = vim.hl.priorities.user }
      )
    end
  end

  local _, winid = vim.lsp.util.open_floating_preview(contents, "markdown", {
    focus_id = "textDocument/hover",
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(winid),
    once = true,
    callback = function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, hover_ns, 0, -1)
      end
      return true
    end,
  })
  return winid
end

--- Where `K` was pressed, and a check that the user is still there.
---@return { bufnr: integer, win: integer, cursor: integer[], tick: integer }
local function snapshot()
  local win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  return {
    bufnr = bufnr,
    win = win,
    cursor = vim.api.nvim_win_get_cursor(win),
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
  }
end

---@param at { bufnr: integer, win: integer, cursor: integer[], tick: integer }
---@return boolean
local function still_at(at)
  return vim.api.nvim_buf_is_valid(at.bufnr)
    and vim.api.nvim_win_is_valid(at.win)
    and vim.api.nvim_get_current_win() == at.win
    and vim.api.nvim_get_current_buf() == at.bufnr
    and vim.api.nvim_buf_get_changedtick(at.bufnr) == at.tick
    and vim.deep_equal(vim.api.nvim_win_get_cursor(at.win), at.cursor)
end

--- The provider's client on a buffer, and the position params for it taken
--- from the press. Params are built once per client at press time, so every
--- request in this press asks about the same position.
---@param at table
---@param provider table
---@return vim.lsp.Client|nil, table|nil
local function provider_client(at, provider)
  local client = vim.lsp.get_clients({ bufnr = at.bufnr, name = provider.server })[1]
  if not client then
    return nil, nil
  end
  return client, vim.lsp.util.make_position_params(at.win, client.offset_encoding)
end

--- `K`.
function M.hover()
  local at = snapshot()
  local word = vim.fn.expand("<cword>")
  local dotted = require("config.docs")._dotted_word()
  local params = {}

  vim.lsp.buf_request_all(at.bufnr, "textDocument/hover", function(client)
    params[client.id] = params[client.id]
      or vim.lsp.util.make_position_params(at.win, client.offset_encoding)
    return params[client.id]
  end, function(results)
    if not still_at(at) then
      return
    end
    local items, empty = M._collect(results)
    if #items == 0 then
      vim.notify(
        empty and "Empty hover response" or "No information available",
        vim.log.levels.INFO
      )
      return
    end

    local provider = provider_for(vim.bo[at.bufnr].filetype)
    local target = nil
    for _, item in ipairs(provider and items or {}) do
      if item.client.name == provider.server then
        target = item
        break
      end
    end

    local function open(brief)
      if still_at(at) then
        M._open(at.bufnr, items, target, brief)
      end
    end

    if not target or M._has_prose(target.client.name, markdown_lines(target.result.contents)) then
      return open(nil)
    end

    local settled = false
    local timer = assert(vim.uv.new_timer())
    local function settle(brief)
      if settled then
        return
      end
      settled = true
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      open(brief)
    end
    timer:start(
      M.DEADLINE_MS,
      0,
      vim.schedule_wrap(function()
        settle(nil)
      end)
    )

    M._brief(provider, {
      bufnr = at.bufnr,
      client = target.client,
      params = params[target.client.id],
      word = word,
      dotted = dotted,
    }, function(brief)
      vim.schedule(function()
        settle(brief)
      end)
    end)
  end)
end

--- `gK`'s last-but-one resort: the hosted page for the symbol under the
--- cursor, found through the same provider and installed bundles as `K`.
---@param bufnr integer
---@param cb fun(url: string|nil)
function M.docs_url(bufnr, cb)
  local provider = provider_for(vim.bo[bufnr].filetype)
  if not provider or bufnr ~= vim.api.nvim_get_current_buf() then
    return cb(nil)
  end
  local at = snapshot()
  local client, params = provider_client(at, provider)
  if not client then
    return cb(nil)
  end

  local finished = false
  local function done(url)
    if not finished then
      finished = true
      cb(url)
    end
  end
  local ok, err = pcall(provider.candidates, {
    bufnr = bufnr,
    client = client,
    params = params,
    word = vim.fn.expand("<cword>"),
    dotted = require("config.docs")._dotted_word(),
  }, function(candidates)
    local devdocs = require("config.docs.devdocs")
    for _, candidate in ipairs(type(candidates) == "table" and candidates or {}) do
      if devdocs.installed(candidate.slug) then
        local entry = devdocs.lookup(candidate.slug, candidate.name, candidate.hint)
        local url = entry and devdocs.url(candidate.slug, entry)
        if url then
          return done(url)
        end
      end
    end
    done(nil)
  end)
  if not ok then
    warn(err)
    done(nil)
  end
end

return M

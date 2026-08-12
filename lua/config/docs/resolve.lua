-- The language-blind half of dependency docs: ask the servers that are already
-- running where the documentation lives.
--
-- Three LSP mechanisms carry most of the coverage, with no per-language code:
--
--   experimental/externalDocs  rust-analyzer only, and mandatory there — it is
--                              the only thing that resolves re-exports
--                              (serde::Serialize lives in serde_core) and that
--                              honors a crate's #![doc(html_root_url)]. Those
--                              URLs are not reconstructable from Cargo.toml.
--   textDocument/hover         gopls appends a version-pinned, symbol-anchored
--                              pkg.go.dev link to every symbol hover; lua_ls
--                              links the Lua manual; HLS links Hackage; and
--                              ts_ls surfaces the ~4.9k MDN links baked into
--                              lib.dom.d.ts.
--   textDocument/documentLink  gopls turns each go.mod require line into
--                              pkg.go.dev/mod/<module>@<version> — the only
--                              versioned manifest source found in any
--                              ecosystem. clangd maps #include to the SDK
--                              header on disk.
--
-- Every request here is async and fired at a server that is already warm. The
-- keypress path must never block, and must never touch the network: we build a
-- URL and let the browser discover a 404, because half the doc hosts (javadoc.io,
-- cppreference, npmjs.com, jsr.io) reject scripted clients anyway.

local M = {}

--- Flatten the several shapes `hover.contents` is allowed to take (a bare
--- string, a MarkupContent, or a legacy array of either) into one string.
---@param contents any
---@return string
local function contents_to_string(contents)
  if type(contents) == "string" then
    return contents
  end
  if type(contents) ~= "table" then
    return ""
  end
  if type(contents.value) == "string" then
    return contents.value
  end
  local parts = {}
  for _, chunk in ipairs(contents) do
    parts[#parts + 1] = type(chunk) == "string" and chunk
      or (type(chunk) == "table" and chunk.value or "")
  end
  return table.concat(parts, "\n")
end

--- Pull the documentation URL out of a hover payload's markdown.
---
--- Two passes, because servers disagree about the shape. gopls, lua_ls and HLS
--- emit a real markdown link; ts_ls renders a JSDoc `@see https://...` as a
--- bare URL with no brackets around it.
---
--- Among markdown links we take the LAST one, because gopls appends its doc
--- link as the final line of an otherwise link-free hover — but first we drop
--- any link labelled "Source", since HLS emits `[Documentation]` followed by
--- `[Source]` and the last link there is the one we don't want.
---@param markdown string
---@return string|nil
function M.extract_url(markdown)
  if type(markdown) ~= "string" or markdown == "" then
    return nil
  end
  local best = nil
  for label, url in markdown:gmatch("%[([^%]]*)%]%((https?://[^%s%)]+)%)") do
    if not label:match("^%s*[Ss]ource%s*$") then
      best = url
    end
  end
  if best then
    return best
  end
  -- Bare-URL pass. Anchored on whitespace or start-of-line so we don't slice a
  -- URL out of the middle of a markdown link we already declined above.
  return markdown:match("^(https?://[^%s]+)") or markdown:match("%s(https?://[^%s]+)")
end

--- Clients attached to `bufnr` that advertise experimental/externalDocs.
---
--- The capability lives under `experimental`, which servers are free to shape
--- however they like, so every access is guarded.
---@param bufnr integer
---@return vim.lsp.Client[]
local function external_docs_clients(bufnr)
  local out = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    local exp = client.server_capabilities and client.server_capabilities.experimental
    if type(exp) == "table" and exp.externalDocs then
      out[#out + 1] = client
    end
  end
  return out
end

--- Ask a server for the canonical docs URL of the symbol under the cursor.
---
--- The response is either a bare string (older rust-analyzer) or
--- `{ web = ..., local = ... }`. `local` is a Lua keyword, so it can only be
--- read with bracket syntax — and it may name a file that was never generated
--- (no `cargo doc` run), so it is stat'd before being preferred.
---
--- A `{ web = nil, local = nil }` result is NOT an error: rust-analyzer returns
--- it while it is still indexing. Treated as "no answer", so the caller falls
--- through to the next mechanism instead of reporting a failure.
---@param bufnr integer
---@param cb fun(url: string|nil)
function M.external_docs(bufnr, cb)
  local clients = external_docs_clients(bufnr)
  local client = clients[1]
  if not client then
    return cb(nil)
  end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request("experimental/externalDocs", params, function(err, result)
    if err or not result then
      return cb(nil)
    end
    if type(result) == "string" then
      return cb(result)
    end
    if type(result) ~= "table" then
      return cb(nil)
    end
    local localdoc = result["local"]
    if type(localdoc) == "string" and localdoc ~= "" then
      local path = vim.uri_to_fname(localdoc)
      if vim.uv.fs_stat(path) then
        return cb(localdoc)
      end
    end
    cb(type(result.web) == "string" and result.web or nil)
  end, bufnr)
end

--- Hover the symbol under the cursor and scrape a documentation URL out of it.
---@param bufnr integer
---@param cb fun(url: string|nil)
function M.hover_url(bufnr, cb)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/hover" })
  local client = clients[1]
  if not client then
    return cb(nil)
  end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request("textDocument/hover", params, function(err, result)
    if err or not result or not result.contents then
      return cb(nil)
    end
    cb(M.extract_url(contents_to_string(result.contents)))
  end, bufnr)
end

--- Is a 0-indexed (row, col) inside an LSP range?
---@param range table
---@param row integer
---@param col integer
---@return boolean
local function in_range(range, row, col)
  local s, e = range.start, range["end"]
  if row < s.line or row > e.line then
    return false
  end
  if row == s.line and col < s.character then
    return false
  end
  if row == e.line and col > e.character then
    return false
  end
  return true
end

--- Resolve the document link the cursor sits on, if any.
---
--- Deliberately does not use `vim.ui._get_urls()`: it is private, landed only
--- in 0.12, and does a synchronous whole-document buf_request_sync on every
--- press. `file://` targets (clangd pointing at an SDK header) are handed back
--- as paths, which the caller opens as a buffer rather than a URL.
---@param bufnr integer
---@param cb fun(target: string|nil)
function M.document_link(bufnr, cb)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/documentLink" })
  local client = clients[1]
  if not client then
    return cb(nil)
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  client:request("textDocument/documentLink", params, function(err, result)
    if err or type(result) ~= "table" then
      return cb(nil)
    end
    for _, link in ipairs(result) do
      if link.target and link.range and in_range(link.range, row, col) then
        return cb(link.target)
      end
    end
    cb(nil)
  end, bufnr)
end

return M

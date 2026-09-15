-- Name a C or C++ symbol for config.docs.hover: which DevDocs bundle documents
-- it, and under what index name.
--
-- clangd's `textDocument/symbolInfo` (a clangd extension, answered by no other
-- server) carries exactly what is needed: the name, the qualified container
-- (`std::vector::`, already without libc++'s inline `__1`), and where the
-- declaration lives. Hover markdown would need parsing to recover the same.
--
-- The lookup order per name is the c bundle (ISO C, from cppreference), then
-- the man bundle, preferring the POSIX `3p` page — standard behavior rather
-- than Linux-specific wording, which matters on a Mac — over the Linux `2`
-- (syscalls) and `3` (library) pages. `read`, `write`, `tcsetattr` and `ioctl`
-- are in no C standard, so the c bundle alone would miss exactly what systems
-- C reaches for.
local M = {}

--- The server whose hover this provider completes.
M.server = "clangd"

---@param info table
---@return string
local function container_of(info)
  local container = type(info.containerName) == "string" and info.containerName or ""
  return (container:gsub("__[%w_]+::", ""))
end

--- Put the entry named like the word under the cursor first.
---
--- The fortified `memcpy` answers as `__builtin___memcpy_chk` AND the macro
--- `memcpy`, builtin first. The macro is the name anyone looks up.
---@param infos table[]
---@param word string
---@return table[]
function M._order(infos, word)
  local first, rest = {}, {}
  for _, info in ipairs(infos) do
    table.insert(info.name == word and first or rest, info)
  end
  return vim.list_extend(first, rest)
end

--- Is any of these symbols declared under `root`?
---
--- A symbol the project declares is the project's own, however its name
--- collides with libc: a kilo-style editor's `abAppend`, or a local `open`.
--- Offering POSIX text for those would be confidently wrong.
---@param infos table[]
---@param root string|nil
---@return boolean
function M._declared_in(infos, root)
  if not root then
    return false
  end
  local prefix = vim.fs.normalize(root) .. "/"
  for _, info in ipairs(infos) do
    local uri = vim.tbl_get(info, "declarationRange", "uri")
    if
      type(uri) == "string" and vim.startswith(vim.fs.normalize(vim.uri_to_fname(uri)), prefix)
    then
      return true
    end
  end
  return false
end

--- The declaring header's basename without its extension: libc++'s
--- `__vector/vector.h` gives `vector`, `<string>` gives `string`. DevDocs'
--- cppreference paths are grouped by the same names, which is what lets
--- devdocs.pick tell the three `std::to_string` pages apart.
---@param info table
---@return string|nil
function M._header_hint(info)
  local uri = vim.tbl_get(info, "declarationRange", "uri")
  if type(uri) ~= "string" then
    return nil
  end
  return (vim.fs.basename(vim.uri_to_fname(uri)):gsub("%.[^.]*$", ""))
end

---@param out table[]
---@param seen table<string, boolean>
---@param candidate { slug: string, name: string, hint: string|nil }
local function add(out, seen, candidate)
  local key = candidate.slug .. "\0" .. candidate.name
  if not seen[key] then
    seen[key] = true
    out[#out + 1] = candidate
  end
end

---@param out table[]
---@param seen table<string, boolean>
---@param name string
local function c_names(out, seen, name)
  add(out, seen, { slug = "c", name = name })
  for _, section in ipairs({ "3p", "2", "3" }) do
    add(out, seen, { slug = "man", name = ("%s (%s)"):format(name, section) })
  end
end

--- Candidates from a symbolInfo result.
---@param ft string
---@param infos table[]|nil
---@param word string
---@param root string|nil
---@return { slug: string, name: string, hint: string|nil }[]|nil
function M._from_symbols(ft, infos, word, root)
  if type(infos) ~= "table" or #infos == 0 or M._declared_in(infos, root) then
    return nil
  end
  local out, seen = {}, {}
  for _, info in ipairs(M._order(infos, word)) do
    local name = type(info.name) == "string" and info.name or ""
    -- `__`-prefixed names are the implementation's own (`__builtin___memcpy_chk`)
    -- and are documented nowhere.
    if name:match("^[%a_][%w_]*$") and not name:match("^__") then
      local container = container_of(info)
      if ft == "cpp" then
        local hint = M._header_hint(info)
        if container:match("^std::") then
          add(out, seen, { slug = "cpp", name = container .. name, hint = hint })
        elseif container == "" then
          add(out, seen, { slug = "cpp", name = "std::" .. name, hint = hint })
          c_names(out, seen, name)
        end
      elseif container == "" then
        c_names(out, seen, name)
      end
    end
  end
  return #out > 0 and out or nil
end

--- Where the project starts, for the "declared by the project" gate. A file
--- outside any repository still has its own directory as the project.
---@param bufnr integer
---@return string|nil
function M._root(bufnr)
  local git = vim.fs.root(bufnr, ".git")
  if git then
    return git
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fs.dirname(name) or nil
end

---@param ctx { bufnr: integer, client: vim.lsp.Client, params: table, word: string }
---@param cb fun(candidates: table[]|nil)
function M.candidates(ctx, cb)
  local ft = vim.bo[ctx.bufnr].filetype
  local sent = ctx.client:request("textDocument/symbolInfo", ctx.params, function(err, result)
    if err or type(result) ~= "table" then
      return cb(nil)
    end
    cb(M._from_symbols(ft, result, ctx.word, M._root(ctx.bufnr)))
  end, ctx.bufnr)
  if not sent then
    cb(nil)
  end
end

return M

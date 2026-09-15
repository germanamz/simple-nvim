-- Offline DevDocs bundles: the documentation `K` appends when a language
-- server's hover has none.
--
-- Why DevDocs
-- -----------
-- clangd has nothing to say about libc or libc++ (the macOS SDK headers carry
-- no doc comments), and pyright has nothing for the builtins implemented in C
-- (typeshed stubs carry no docstrings). DevDocs publishes cppreference, the
-- Linux and POSIX man pages, and the Python library reference as one JSON index
-- plus one JSON blob of cleaned HTML per documentation set. That index is the
-- symbol -> page table cppreference's own URLs never let us compute.
--
-- The layout on disk
-- ------------------
--   <stdpath("data")>/devdocs/<slug>/index.json   { entries = { {name, path, type} } }
--   <stdpath("data")>/devdocs/<slug>/pages/<path>.html
--   <stdpath("data")>/devdocs/<slug>/meta.json    { slug, installed_at }
--
-- `db.json` is split into one file per page at install time, in a separate
-- process. The man bundle's db.json is 143 MB: decoding it on a keypress, or
-- even once per session in the editor, is not an option, while reading one
-- page file is a few milliseconds.
--
-- Nothing here touches the network except `install`, which only ever runs from
-- `:DocsInstall`.

local M = {}

local state = require("util.state")

--- Test seam: point the store at a fixture directory.
---@type string|nil
M._root = nil

---@class DevdocsEntry
---@field name string   -- the index name: `std::vector::push_back`, `read (3p)`, `str.split()`
---@field path string   -- page path, with `#anchor` for Sphinx entries
---@field type string   -- the index's own grouping, unused here

---@return string
function M.root()
  return M._root or vim.fs.joinpath(vim.fn.stdpath("data"), "devdocs")
end

---@param slug string
---@return string
function M.dir(slug)
  return vim.fs.joinpath(M.root(), slug)
end

---@param slug string
---@return boolean
function M.installed(slug)
  return vim.uv.fs_stat(vim.fs.joinpath(M.dir(slug), "index.json")) ~= nil
end

--- Every installed bundle, sorted.
---
--- An install stages into `<slug>.tmp` and moves the previous bundle aside as
--- `<slug>.old` while it swaps, so neither suffix is ever a bundle.
---@return string[]
function M.installed_slugs()
  local out = {}
  local root = M.root()
  if not vim.uv.fs_stat(root) then
    return out
  end
  for name, kind in vim.fs.dir(root) do
    if kind == "directory" and not name:match("%.tmp$") and not name:match("%.old$") then
      if M.installed(name) then
        out[#out + 1] = name
      end
    end
  end
  table.sort(out)
  return out
end

-- slug -> name -> entries, or false when the index could not be read. The
-- failure is memoized too: a corrupt index would otherwise be re-read and
-- re-failed on every `K`.
---@type table<string, table<string, DevdocsEntry[]>|false>
local indexes = {}

-- slug .. "\0" .. path .. "\0" .. MAX_LINES -> excerpt, or false for a page that
-- yields none.
---@type table<string, table|false>
local excerpts = {}

function M._reset()
  indexes = {}
  excerpts = {}
end

---@param slug string
---@return table<string, DevdocsEntry[]>|nil
local function index(slug)
  if indexes[slug] == nil then
    indexes[slug] = false
    local raw = state.read_file(vim.fs.joinpath(M.dir(slug), "index.json"))
    local ok, decoded = pcall(vim.json.decode, raw or "")
    if ok and type(decoded) == "table" and type(decoded.entries) == "table" then
      local by_name = {}
      for _, entry in ipairs(decoded.entries) do
        if type(entry.name) == "string" and type(entry.path) == "string" then
          by_name[entry.name] = by_name[entry.name] or {}
          table.insert(by_name[entry.name], entry)
        end
      end
      indexes[slug] = by_name
    end
  end
  return indexes[slug] or nil
end

--- Choose among entries that share a name.
---
--- cppreference files `std::to_string` three times: once under
--- string/basic_string for the <string> overloads, twice under utility/ for
--- <stacktrace>. The caller passes the basename of the header clangd says the
--- symbol was declared in, and a path segment equal to it wins. With no hint,
--- or no segment matching, the index's own order stands.
---@param entries DevdocsEntry[]
---@param hint string|nil
---@return DevdocsEntry
function M.pick(entries, hint)
  if hint then
    for _, entry in ipairs(entries) do
      for segment in entry.path:gmatch("[^/#]+") do
        if segment == hint then
          return entry
        end
      end
    end
  end
  return entries[1]
end

---@param slug string
---@param name string
---@param hint string|nil
---@return DevdocsEntry|nil
function M.lookup(slug, name, hint)
  local by_name = index(slug)
  local entries = by_name and by_name[name]
  if not entries or #entries == 0 then
    return nil
  end
  return M.pick(entries, hint)
end

--- The family of markup a bundle's pages are written in.
---@param slug string
---@return "cppreference"|"man"|"sphinx"|nil
function M._family(slug)
  if slug == "c" or slug == "cpp" then
    return "cppreference"
  elseif slug == "man" then
    return "man"
  elseif slug:match("^python~%d+%.%d+$") then
    return "sphinx"
  end
  return nil
end

--- The hosted page for an entry, for `gK`.
---@param slug string
---@param entry DevdocsEntry
---@return string|nil
function M.url(slug, entry)
  local page, anchor = entry.path:match("^([^#]*)#?(.*)$")
  if slug == "cpp" or slug == "c" then
    return "https://en.cppreference.com/w/" .. slug .. "/" .. entry.path
  elseif slug == "man" then
    return "https://man7.org/linux/man-pages/" .. page .. ".html"
  end
  local version = slug:match("^python~(%d+%.%d+)$")
  if version then
    return "https://docs.python.org/"
      .. version
      .. "/"
      .. page
      .. ".html"
      .. (anchor ~= "" and ("#" .. anchor) or "")
  end
  return nil
end

--- What the excerpt is headed with in the float.
---@param slug string
---@param entry DevdocsEntry
---@return string
function M.label(slug, entry)
  local family = M._family(slug)
  if family == "cppreference" then
    return "cppreference · " .. entry.name
  elseif family == "man" then
    return "man · " .. (entry.name:gsub(" %(", "("))
  elseif family == "sphinx" then
    return "python " .. slug:match("^python~(.*)$") .. " · " .. entry.name
  end
  return slug .. " · " .. entry.name
end

-- ---------------------------------------------------------------------------
-- HTML -> markdown
--
-- A converter for exactly the markup these bundles use, not a general one.
-- DevDocs has already stripped the sites' navigation, scripts and styling, so
-- what remains is paragraphs, code, headings, definition lists and a few
-- tables. Anything unrecognized is reduced to its text, which is always the
-- safe failure for a hover: slightly flatter, never wrong.
-- ---------------------------------------------------------------------------

--- The column excerpts wrap at. Paragraphs in these pages are single long
--- lines, and the float sizes itself to its longest line, so an unwrapped
--- excerpt would stretch the hover across the whole editor.
M.WIDTH = 80

local ENTITIES = {
  amp = "&",
  lt = "<",
  gt = ">",
  quot = '"',
  apos = "'",
  nbsp = " ",
  mdash = "—",
  ndash = "–",
  hellip = "…",
  lsquo = "‘",
  rsquo = "’",
  ldquo = "“",
  rdquo = "”",
  times = "×",
  minus = "−",
}

---@param s string
---@return string
function M._decode(s)
  return (
    s:gsub("&(#?[xX]?)(%w+);", function(prefix, body)
      if prefix == "" then
        return ENTITIES[body]
      end
      local code = prefix == "#" and tonumber(body) or tonumber(body, 16)
      if code then
        local ok, char = pcall(vim.fn.nr2char, code, true)
        return ok and char or nil
      end
      return nil
    end)
  )
end

---@param text string
---@param width integer
---@return string[]
function M._wrap(text, width)
  local lines, current = {}, ""
  for word in text:gmatch("%S+") do
    if current == "" then
      current = word
    elseif vim.api.nvim_strwidth(current) + 1 + vim.api.nvim_strwidth(word) <= width then
      current = current .. " " .. word
    else
      lines[#lines + 1] = current
      current = word
    end
  end
  if current ~= "" then
    lines[#lines + 1] = current
  end
  return lines
end

--- Strip the common leading indent and the blank lines at either end.
---@param lines string[]
---@return string[]
local function dedent(lines)
  while #lines > 0 and vim.trim(lines[1]) == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  local common
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      local indent = #line:match("^ *")
      common = common and math.min(common, indent) or indent
    end
  end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line:sub((common or 0) + 1)
  end
  return out
end

-- Tags that end the paragraph being built. Table cells deliberately are not:
-- a parameter row's name and description belong on one line.
local BLOCK = {
  p = true,
  div = true,
  br = true,
  table = true,
  tr = true,
  dl = true,
  dt = true,
  dd = true,
  ul = true,
  ol = true,
  li = true,
  blockquote = true,
}

---@class DevdocsBlock
---@field kind "para"|"heading"|"code"
---@field text string|nil
---@field lang string|nil
---@field lines string[]|nil

--- Convert HTML into a flat list of blocks.
---@param html string
---@param lang string|nil  -- fence language for <pre>; defaults to the page's data-language
---@return DevdocsBlock[]
function M._blocks(html, lang)
  -- DevDocs' syntax highlighter emits `unsigned char` as two adjacent keyword
  -- spans with the space between them gone.
  html = html:gsub('</span>(<span class="kt">)', "</span> %1")
  local blocks = {}
  local inline = {}
  local heading = false
  local in_code = false
  local pre = nil ---@type { lang: string|nil, parts: string[] }|nil

  local function flush()
    local text = table.concat(inline):gsub("%s+", " ")
    text = vim.trim(text:gsub("``", ""))
    inline = {}
    if text ~= "" and text ~= "-" then
      blocks[#blocks + 1] = { kind = heading and "heading" or "para", text = text }
    end
    heading = false
  end

  local pos = 1
  while pos <= #html do
    local s, e = html:find("<[^>]*>", pos)
    local text = html:sub(pos, (s or #html + 1) - 1)
    if text ~= "" then
      if pre then
        pre.parts[#pre.parts + 1] = text
      else
        inline[#inline + 1] = M._decode(text)
      end
    end
    if not s then
      break
    end

    local tag = html:sub(s, e)
    local closing, name = tag:match("^<(/?)(%w+)")
    name = name and name:lower()
    pos = e + 1

    if pre then
      -- Inside <pre> every tag but its own close is markup around code text
      -- (<b>, <span>, <a>), so only the text between tags is kept.
      if name == "pre" and closing == "/" then
        local body = M._decode(table.concat(pre.parts))
        local lines = dedent(vim.split(body, "\n", { plain = true }))
        if #lines > 0 then
          blocks[#blocks + 1] = { kind = "code", lang = pre.lang, lines = lines }
        end
        pre = nil
      end
    elseif not name then
      -- A comment or a doctype: nothing to show.
    elseif name == "pre" and closing == "" then
      flush()
      pre = { lang = lang or tag:match('data%-language="([^"]*)"'), parts = {} }
    elseif name:match("^h%d$") then
      flush()
      heading = closing == ""
    elseif BLOCK[name] then
      flush()
      if name == "li" and closing == "" then
        inline[1] = "- "
      end
    elseif name == "span" and closing == "" and tag:find('class="t-li"', 1, true) then
      -- cppreference's inline list marker: `<span class="t-li">2)</span>`.
      flush()
    elseif name == "code" then
      in_code = closing == ""
      inline[#inline + 1] = "`"
    elseif (name == "b" or name == "strong") and not in_code then
      inline[#inline + 1] = "**"
    elseif (name == "i" or name == "em") and not in_code then
      inline[#inline + 1] = "*"
    elseif name == "td" or name == "th" then
      inline[#inline + 1] = " "
    end
  end
  flush()
  return blocks
end

--- Lay blocks out as markdown lines, capped at `max_lines`.
---
--- The cut lands on a block boundary so an excerpt never ends mid-sentence.
--- The one exception is a first block that is longer than the cap on its own,
--- which is hard-cut, since stopping before it would show nothing at all; a
--- code fence cut that way is closed so the rest of the float is not swallowed
--- into it. A cut that would leave a heading as the last thing shown drops the
--- heading too, since "**Return value**" with nothing under it reads as a bug.
---@param blocks DevdocsBlock[]
---@param max_lines integer
---@return string[] lines
---@return boolean truncated
function M._render(blocks, max_lines)
  local out = {}
  local heading_at = nil -- where the last block started, if it was a heading
  for _, block in ipairs(blocks) do
    local lines
    if block.kind == "code" then
      lines = { "```" .. (block.lang or "") }
      vim.list_extend(lines, block.lines)
      lines[#lines + 1] = "```"
    elseif block.kind == "heading" then
      lines = { "**" .. block.text .. "**" }
    else
      lines = M._wrap(block.text, M.WIDTH)
    end

    local needed = #lines + (#out > 0 and 1 or 0)
    if #out + needed > max_lines then
      if #out == 0 then
        for j = 1, max_lines do
          out[j] = lines[j]
        end
        if block.kind == "code" then
          out[max_lines] = "```"
        end
      elseif heading_at then
        for j = #out, heading_at, -1 do
          out[j] = nil
        end
      end
      return out, true
    end
    if #out > 0 then
      out[#out + 1] = ""
    end
    heading_at = block.kind == "heading" and #out or nil
    vim.list_extend(out, lines)
  end
  return out, false
end

-- ---------------------------------------------------------------------------
-- Excerpts
--
-- A hover is not the page. Each family below picks the part of a page that
-- answers "what does this do": the hover already carries the signature, and
-- `gK` is one key away for everything else.
-- ---------------------------------------------------------------------------

--- Lines of excerpt body, not counting the hover, label or footer.
M.MAX_LINES = 25

--- The slice of `html` from the `<tag` at `start` to its balanced close.
---@param html string
---@param start integer
---@param tag string
---@return string|nil inner  -- between the opening tag's `>` and the matching close
local function balanced(html, start, tag)
  local open_end = html:find(">", start, true)
  if not open_end then
    return nil
  end
  local depth, pos = 1, open_end + 1
  local open_pat, close_pat = "<" .. tag .. "[%s>]", "</" .. tag .. ">"
  while true do
    local o = html:find(open_pat, pos)
    local c = html:find(close_pat, pos, true)
    if not c then
      return nil
    end
    if o and o < c then
      depth = depth + 1
      pos = o + 1
    else
      depth = depth - 1
      if depth == 0 then
        return html:sub(open_end + 1, c - 1)
      end
      pos = c + #close_pat
    end
  end
end

---@param html string
---@return string
local function strip_tags(html)
  return vim.trim(M._decode(html:gsub("<[^>]*>", "")):gsub("%s+", " "))
end

--- cppreference (the `c` and `cpp` bundles).
---
--- Every page opens with the declaration table (`t-dcl-begin`), which also
--- carries "Defined in header <...>"; the hover already shows the signature, so
--- it goes. The lead paragraphs before the first <h3> are the description, and
--- of the sections after it only Parameters and Return value are about calling
--- the thing. Complexity, Exceptions, Notes, Example and See also are page
--- material.
---@param html string
---@param slug string
---@return DevdocsBlock[]
local function cppreference(html, slug)
  html = html:gsub("<h1.-</h1>", "")
  html = html:gsub('<table class="t%-dcl%-begin">.-</table>', "")
  -- A parameter row is three cells: the name, a lone dash, the description.
  html = html:gsub(
    '<tr class="t%-par">%s*<td>(.-)</td>%s*<td>.-</td>%s*<td>(.-)</td>%s*</tr>',
    function(name, desc)
      return "<p><code>" .. strip_tags(name) .. "</code> — " .. desc .. "</p>"
    end
  )

  local lang = slug == "cpp" and "cpp" or "c"
  local first = html:find("<h3", 1, true)
  local blocks = M._blocks(first and html:sub(1, first - 1) or html, lang)
  if not first then
    return blocks
  end

  local pos = first
  while pos do
    local _, head_end, title = html:find("<h3[^>]*>(.-)</h3>", pos)
    if not head_end then
      break
    end
    local next_h3 = html:find("<h3", head_end, true)
    title = strip_tags(title)
    if title == "Parameters" or title == "Return value" then
      blocks[#blocks + 1] = { kind = "heading", text = title }
      vim.list_extend(blocks, M._blocks(html:sub(head_end + 1, (next_h3 or #html + 1) - 1), lang))
    end
    pos = next_h3
  end
  return blocks
end

--- Sphinx (the `python~X.Y` bundles).
---
--- An entry's path carries an anchor into a long page (`library/stdtypes`
--- holds every method of every builtin type), and the anchor sits on the
--- entry's <dt>. Its body is the <dd> that follows, which must be matched for
--- balance: a class's <dd> contains the <dl> of each of its methods.
---@param html string
---@param anchor string
---@return DevdocsBlock[]
local function sphinx(html, anchor)
  if anchor == "" then
    return M._blocks((html:gsub("<h1.-</h1>", "")), "python")
  end
  local dt = html:find('<dt id="' .. anchor .. '"', 1, true)
  local dd = dt and html:find("<dd[%s>]", dt)
  local inner = dd and balanced(html, dd, "dd")
  return inner and M._blocks(inner, "python") or {}
end

--- A man section's <pre> body as paragraphs and code, with its subsections.
---
--- man renders the body at one indent, subsection titles to the left of it,
--- and code examples to the right. The body indent is found as the most
--- common one rather than assumed, because the two man-page sources in the
--- bundle disagree: the Linux man-pages indent by 7 with titles at 3, while
--- POSIX pages have no subsections at all.
---@param pre string
---@return { title: string|nil, blocks: DevdocsBlock[] }[]
local function man_section(pre)
  pre = pre:gsub("<a[^>]*>", ""):gsub("</a>", "")
  -- Whitespace inside a bold or italic run is hoisted outside the markers:
  -- `<b>malloc </b>or` must become `**malloc** or`, since `**malloc **` does
  -- not render as bold.
  for tag, mark in pairs({ b = "**", i = "*" }) do
    pre = pre:gsub("<" .. tag .. ">(%s*)(.-)(%s*)</" .. tag .. ">", function(lead, body, trail)
      return body == "" and (lead .. trail) or (lead .. mark .. body .. mark .. trail)
    end)
  end
  pre = M._decode(pre:gsub("<[^>]*>", ""))

  local lines = vim.split(pre, "\n", { plain = true })
  local counts = {}
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      local indent = #line:match("^ *")
      counts[indent] = (counts[indent] or 0) + 1
    end
  end
  local body_indent, best = 0, -1
  for indent, n in pairs(counts) do
    if n > best or (n == best and indent < body_indent) then
      body_indent, best = indent, n
    end
  end

  local sections = { { title = nil, blocks = {} } }
  local para = {}
  local function flush()
    if #para == 0 then
      return
    end
    local deeper = true
    for _, line in ipairs(para) do
      if #line:match("^ *") <= body_indent then
        deeper = false
        break
      end
    end
    local blocks = sections[#sections].blocks
    if deeper then
      blocks[#blocks + 1] = { kind = "code", lang = "c", lines = dedent(para) }
    else
      local text = table.concat(vim.tbl_map(vim.trim, para), " ")
      blocks[#blocks + 1] = { kind = "para", text = text }
    end
    para = {}
  end

  for _, line in ipairs(lines) do
    if vim.trim(line) == "" then
      flush()
    elseif #line:match("^ *") < body_indent then
      flush()
      sections[#sections + 1] = { title = vim.trim(line), blocks = {} }
    else
      para[#para + 1] = line
    end
  end
  flush()
  return sections
end

--- Does a man paragraph mention `name()`?
---@param block DevdocsBlock
---@param name string
---@return boolean
local function mentions(block, name)
  local plain = (block.text or table.concat(block.lines or {}, " ")):gsub("%*", "")
  return plain:find("%f[%w_]" .. vim.pesc(name) .. "%(%)") ~= nil
end

--- The blocks of `sections` that are about `name`, most specific first: its
--- own subsection, else the paragraphs mentioning it, else everything.
---@param sections { title: string|nil, blocks: DevdocsBlock[] }[]
---@param name string
---@return DevdocsBlock[]
local function about(sections, name)
  for _, section in ipairs(sections) do
    if section.title and section.title:gsub("%*", "") == name .. "()" then
      return section.blocks
    end
  end
  local all, hits = {}, {}
  for _, section in ipairs(sections) do
    for _, block in ipairs(section.blocks) do
      all[#all + 1] = block
      if block.kind == "para" and mentions(block, name) then
        hits[#hits + 1] = block
      end
    end
  end
  return #hits > 0 and hits or all
end

--- man (Linux man-pages and the POSIX `3p` pages).
---
--- A man page often documents a family: malloc(3) holds malloc, free, calloc,
--- realloc and reallocarray. The NAME line says what the family is for, and
--- the rest is narrowed to the one function asked about.
---@param html string
---@param name string
---@return DevdocsBlock[]
local function man(html, name)
  local by_title = {}
  for title, pre in html:gmatch("<h2>%s*(.-)%s*</h2>%s*<pre>(.-)</pre>") do
    by_title[vim.trim(title)] = man_section(pre)
  end

  local blocks = {}
  for _, section in ipairs(by_title["NAME"] or {}) do
    vim.list_extend(blocks, section.blocks)
  end
  if by_title["DESCRIPTION"] then
    vim.list_extend(blocks, about(by_title["DESCRIPTION"], name))
  end
  if by_title["RETURN VALUE"] then
    blocks[#blocks + 1] = { kind = "heading", text = "Return value" }
    vim.list_extend(blocks, about(by_title["RETURN VALUE"], name))
  end
  return blocks
end

--- The excerpt for an entry, or nil when there is nothing to show.
---@param slug string
---@param entry DevdocsEntry|nil
---@return { lines: string[], truncated: boolean }|nil
function M.excerpt(slug, entry)
  if not entry then
    return nil
  end
  local key = slug .. "\0" .. entry.path .. "\0" .. M.MAX_LINES
  if excerpts[key] ~= nil then
    return excerpts[key] or nil
  end
  excerpts[key] = false

  local family = M._family(slug)
  local page, anchor = entry.path:match("^([^#]*)#?(.*)$")
  local html = family and state.read_file(vim.fs.joinpath(M.dir(slug), "pages", page .. ".html"))
  if not html then
    return nil
  end

  local blocks
  if family == "cppreference" then
    blocks = cppreference(html, slug)
  elseif family == "sphinx" then
    blocks = sphinx(html, anchor)
  else
    blocks = man(html, entry.name:match("^(.-) %(") or entry.name)
  end
  if #blocks == 0 then
    return nil
  end

  local lines, truncated = M._render(blocks, M.MAX_LINES)
  excerpts[key] = { lines = lines, truncated = truncated }
  return excerpts[key]
end

-- ---------------------------------------------------------------------------
-- :DocsInstall
-- ---------------------------------------------------------------------------

--- Test seam: tests point this at a file:// fixture directory.
M._base_url = "https://documents.devdocs.io/"

--- Test seam: curl's --retry count. A GET against documents.devdocs.io once
--- stalled with zero bytes and succeeded on the retry, so the default retries;
--- tests set 0 so a deliberate miss does not sit through the backoff.
M._retries = 3

--- What `:DocsInstall` completes. Any valid slug is accepted.
M.SLUGS = { "c", "cpp", "man" }
for minor = 8, 14 do
  M.SLUGS[#M.SLUGS + 1] = "python~3." .. minor
end

local SPLIT_SCRIPT =
  vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "devdocs_split.lua")

--- A slug names a directory under the store, so it must be one safe segment.
---@param slug any
---@return boolean
function M.valid_slug(slug)
  return type(slug) == "string" and slug:match("^[%w_.~]+$") ~= nil and slug ~= "." and slug ~= ".."
end

---@param cmd string[]
---@param cb fun(res: { code: integer, stdout: string, stderr: string })
local function run(cmd, cb)
  local ok, err = pcall(vim.system, cmd, { text = true }, function(res)
    vim.schedule(function()
      cb(res)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb({ code = -1, stdout = "", stderr = tostring(err) })
    end)
  end
end

--- The last few lines of a failed command's output, for the error message.
---@param res { stdout: string|nil, stderr: string|nil }
---@return string
local function tail(res)
  local text = vim.trim(res.stderr or "")
  if text == "" then
    text = vim.trim(res.stdout or "")
  end
  -- A Lua error from the split script ends in a traceback; the message is what
  -- comes before it.
  text = vim.trim((text:gsub("\n%s*stack traceback:.*$", "")))
  local lines = vim.split(text, "\n", { plain = true })
  return table.concat(vim.list_slice(lines, math.max(1, #lines - 2)), "\n")
end

--- Download a bundle and swap it into place.
---
--- Staged in `<slug>.tmp` and moved over the live bundle only once every step
--- has succeeded, so a failed or interrupted install never leaves a half-written
--- bundle that `installed()` would report as usable, and never costs the one
--- that was already there.
---@param slug string
---@param on_done fun(ok: boolean, err: string|nil)|nil
function M.install(slug, on_done)
  local function finish(ok, err)
    if ok then
      vim.notify("devdocs: installed " .. slug, vim.log.levels.INFO)
    else
      vim.notify(
        ("devdocs: installing %s failed: %s"):format(tostring(slug), tostring(err)),
        vim.log.levels.ERROR
      )
    end
    if on_done then
      on_done(ok, err)
    end
  end

  if not M.valid_slug(slug) then
    return finish(false, "invalid slug")
  end

  local final = M.dir(slug)
  local tmp = final .. ".tmp"
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(vim.fs.joinpath(tmp, "pages"), "p")

  local function fail(err)
    vim.fn.delete(tmp, "rf")
    finish(false, err)
  end

  local function curl(file)
    return {
      "curl",
      "-fsSL",
      "--retry",
      tostring(M._retries),
      "--retry-all-errors",
      "-o",
      vim.fs.joinpath(tmp, file),
      M._base_url .. slug .. "/" .. file,
    }
  end

  vim.notify("devdocs: downloading " .. slug .. "…", vim.log.levels.INFO)
  run(curl("index.json"), function(index_res)
    if index_res.code ~= 0 then
      return fail("index.json: " .. tail(index_res))
    end
    run(curl("db.json"), function(db_res)
      if db_res.code ~= 0 then
        return fail("db.json: " .. tail(db_res))
      end
      local db = vim.fs.joinpath(tmp, "db.json")
      local split =
        { vim.v.progpath, "--clean", "-l", SPLIT_SCRIPT, db, vim.fs.joinpath(tmp, "pages") }
      run(split, function(split_res)
        if split_res.code ~= 0 then
          return fail(tail(split_res))
        end
        os.remove(db)

        local meta = vim.json.encode({ slug = slug, installed_at = os.date("!%Y-%m-%dT%H:%M:%SZ") })
        if not pcall(vim.fn.writefile, { meta }, vim.fs.joinpath(tmp, "meta.json")) then
          return fail("could not write meta.json")
        end

        local old = final .. ".old"
        vim.fn.delete(old, "rf")
        local had = vim.uv.fs_stat(final) ~= nil
        if had then
          local moved, err = vim.uv.fs_rename(final, old)
          if not moved then
            return fail(err)
          end
        end
        local placed, err = vim.uv.fs_rename(tmp, final)
        if not placed then
          if had then
            vim.uv.fs_rename(old, final)
          end
          return fail(err)
        end
        vim.fn.delete(old, "rf")
        -- The memoized index and excerpts describe the bundle just replaced.
        M._reset()
        finish(true)
      end)
    end)
  end)
end

--- One line per installed bundle, for `:DocsInstall` with no argument.
---@return string[]
function M.list_installed()
  local out = {}
  for _, slug in ipairs(M.installed_slugs()) do
    local raw = state.read_file(vim.fs.joinpath(M.dir(slug), "meta.json"))
    local ok, meta = pcall(vim.json.decode, raw or "")
    local date = ok and type(meta) == "table" and meta.installed_at or "?"
    out[#out + 1] = ("%s  installed %s"):format(slug, tostring(date):sub(1, 10))
  end
  return out
end

return M

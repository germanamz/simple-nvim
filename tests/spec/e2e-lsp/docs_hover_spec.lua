local nvim_env = require("tests.helpers.nvim_env")

-- `K` against the real servers, reading the trimmed fixture bundles so nothing
-- touches the network. Slow lane (`make test-lsp`), and self-skipping per
-- server like its siblings: mason's bin dir is not on the shell PATH by
-- default.
--
-- What only real servers can prove: that clangd's hover for a libc/libc++
-- symbol really is template-only (the prose check says "no docs"), that its
-- symbolInfo names the symbol the way the DevDocs index spells it, and that
-- pyright's declaration for a builtin lands in typeshed's stdlib stub. The fake
-- server in tests/spec/e2e/docs_hover_spec.lua replays those shapes; this is
-- where they are checked against the source.
--
-- One example, one isolated env: a second setup_isolated_env() in the same
-- headless child leaves the LSP log path stale (see lsp_restart_spec), so the
-- three servers are exercised inside a single `it`, each skipping on its own.
-- Files are loaded with bufadd/bufload rather than built with nvim_create_buf:
-- the LSP plugin lazy-loads on BufReadPre, which only a real read fires.

local FIXTURES = vim.fs.joinpath(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"),
  "fixtures",
  "devdocs"
)

local function floats()
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      out[#out + 1] = win
    end
  end
  return out
end

local function close_floats()
  for _, win in ipairs(floats()) do
    pcall(vim.api.nvim_win_close, win, true)
  end
end

local function float_text()
  local win = floats()[1]
  if not win then
    return nil
  end
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
end

describe("e2e-lsp: K documentation excerpts", function()
  local root, devdocs, hover, saved_root, notify

  before_each(function()
    root = nvim_env.setup_isolated_env()
    devdocs = require("config.docs.devdocs")
    hover = require("config.docs.hover")
    saved_root = devdocs._root
    devdocs._root = FIXTURES
    devdocs._reset()
    -- A server still indexing answers "No information available"; the retry
    -- loop below expects that and should not spam the message area.
    notify = vim.notify
    vim.notify = function() end
  end)

  after_each(function()
    close_floats()
    vim.notify = notify
    for _, client in ipairs(vim.lsp.get_clients()) do
      client:stop(true)
    end
    vim.wait(3000, function()
      return #vim.lsp.get_clients() == 0
    end, 50)
    devdocs._root = saved_root
    devdocs._reset()
    vim.cmd("silent! %bwipeout!")
    nvim_env.teardown(root)
  end)

  --- Write `lines` to `name` under the env, load it as a buffer with
  --- `filetype` (which is what makes vim.lsp.enable attach), and put the cursor
  --- on `symbol`.
  ---@return integer bufnr
  local function open(name, filetype, lines, symbol)
    local dir = vim.uv.fs_realpath(root) or root
    local path = dir .. "/" .. name
    vim.fn.writefile(lines, path)
    vim.fn.chdir(dir)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = filetype
    for row, line in ipairs(lines) do
      local col = line:find(symbol, 1, true)
      if col then
        vim.api.nvim_win_set_cursor(0, { row, col })
        break
      end
    end
    return buf
  end

  --- Press K until the float carries `needle`; a server that is still indexing
  --- answers with nothing, or with a hover that has not resolved the symbol yet.
  ---@param server string
  ---@param buf integer
  ---@param needle string
  local function hover_until(server, buf, needle)
    assert(
      vim.wait(30000, function()
        return #vim.lsp.get_clients({ bufnr = buf, name = server }) > 0
      end, 100),
      server .. " never attached"
    )
    local text
    local found = vim.wait(45000, function()
      close_floats()
      hover.hover()
      vim.wait(1500, function()
        text = float_text()
        return text ~= nil and text:find(needle, 1, true) ~= nil
      end, 50)
      return text ~= nil and text:find(needle, 1, true) ~= nil
    end, 10)
    assert(found, ("no float with %q; last float:\n%s"):format(needle, tostring(text)))
    return text
  end

  it("clangd and pyright hovers for library symbols carry the excerpt", function()
    local ran = 0
    if vim.fn.executable("clangd") == 1 then
      local c = open("a.c", "c", {
        "#include <stdlib.h>",
        "int main(void) { char *p = realloc(0, 4); return p == 0; }",
      }, "realloc")
      local text = hover_until("clangd", c, "Reallocates the given area of memory")
      assert.truthy(text:find("cppreference · realloc", 1, true), text)
      close_floats()

      local cpp = open("b.cpp", "cpp", {
        "#include <vector>",
        "int main() { std::vector<int> v; v.push_back(1); return 0; }",
      }, "push_back")
      hover_until("clangd", cpp, "Appends the given element")
      close_floats()
      ran = ran + 1
    end

    if vim.fn.executable("pyright-langserver") == 1 then
      local py = open("a.py", "python", { "x = len([1])", "print(x)" }, "len")
      local text = hover_until("pyright", py, "Return the length")
      assert.truthy(text:find("python 3.10 · len()", 1, true), text)
      ran = ran + 1
    end

    if ran == 0 then
      pending("neither clangd nor pyright-langserver on PATH")
    end
  end)
end)

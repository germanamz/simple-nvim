local nvim_env = require("tests.helpers.nvim_env")
local keymap_probe = require("tests.helpers.keymap_probe")

-- `K` end to end against an in-process fake language server named `clangd`,
-- with the DevDocs store pointed at the trimmed fixture bundles. The fake
-- answers with the payloads real clangd returned on 2026-09-15, so what runs
-- here is the real request flow, the real float, and the real LspAttach wiring
-- — only the server process is missing.
--
-- The buffer's filetype is set with :noautocmd. /usr/bin/clangd is on PATH on
-- macOS, and a FileType event would have vim.lsp.enable start it next to the
-- fake.

local FIXTURES = vim.fs.joinpath(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"),
  "fixtures",
  "devdocs"
)
local SDK =
  "file:///Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include"

local PUSH_BACK_HOVER = table.concat({
  "### instance-method `push_back`",
  "",
  "provided by `<vector>`",
  "",
  "---",
  "→ `void`",
  "",
  "Parameters:",
  "",
  "- `value_type && __x (aka int &&)`",
  "",
  "---",
  "```cpp",
  "// In vector<int>",
  "public: void push_back(value_type &&__x)",
  "```",
}, "\n")

local DOCUMENTED_HOVER = table.concat({
  "### function `push_back`",
  "",
  "Appends to our own vector.",
  "",
  "---",
  "```cpp",
  "void push_back(int x)",
  "```",
}, "\n")

--- An in-process server. `opts.hover` is the markdown to answer with;
--- `opts.hover_delay` defers the hover reply by that many ms.
---@return fun(dispatchers: table): table
local function fake_clangd(opts)
  return function(dispatchers)
    local closing, next_id = false, 0
    local server = {}
    function server.request(method, _, callback, notify_reply)
      next_id = next_id + 1
      local id = next_id
      local function reply(err, result)
        callback(err, result)
        if notify_reply then
          notify_reply(id)
        end
      end
      if method == "initialize" then
        reply(nil, { capabilities = { hoverProvider = true } })
      elseif method == "shutdown" then
        reply(nil, nil)
      elseif method == "textDocument/hover" then
        local result = { contents = { kind = "markdown", value = opts.hover } }
        if opts.hover_delay then
          vim.defer_fn(function()
            reply(nil, result)
          end, opts.hover_delay)
        else
          reply(nil, result)
        end
      elseif method == "textDocument/symbolInfo" then
        reply(nil, {
          {
            name = "push_back",
            containerName = "std::vector::",
            declarationRange = { uri = SDK .. "/c%2B%2B/v1/__vector/vector.h" },
          },
        })
      else
        reply({ code = -32601, message = "unsupported: " .. method }, nil)
      end
      return true, id
    end
    function server.notify(method)
      if method == "exit" then
        dispatchers.on_exit(0, 15)
      end
      return true
    end
    function server.is_closing()
      return closing
    end
    function server.terminate()
      closing = true
    end
    return server
  end
end

local function floats()
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      out[#out + 1] = win
    end
  end
  return out
end

local function float_text()
  for _, win in ipairs(floats()) do
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    return table.concat(lines, "\n"), win
  end
  return nil
end

describe("e2e: K with documentation excerpts", function()
  local root, devdocs, hover, saved_root

  before_each(function()
    root = nvim_env.setup_isolated_env()
    devdocs = require("config.docs.devdocs")
    hover = require("config.docs.hover")
    saved_root = devdocs._root
    devdocs._root = FIXTURES
    devdocs._reset()
  end)

  after_each(function()
    for _, win in ipairs(floats()) do
      pcall(vim.api.nvim_win_close, win, true)
    end
    for _, client in ipairs(vim.lsp.get_clients()) do
      client:stop(true)
    end
    vim.wait(2000, function()
      return #vim.lsp.get_clients() == 0
    end, 20)
    devdocs._root = saved_root
    devdocs._reset()
    vim.cmd("silent! %bwipeout!")
    nvim_env.teardown(root)
  end)

  --- A cpp buffer on disk-less path with the fake clangd attached and the
  --- cursor on `push_back`.
  ---@return integer bufnr
  local function cpp_buffer(opts, ft)
    ft = ft or "cpp"
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, root .. "/src/main." .. (ft == "go" and "go" or "cpp"))
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "int main() {",
      "  std::vector<int> v; v.push_back(1);",
      "}",
    })
    vim.cmd("noautocmd setlocal filetype=" .. ft)
    local id = vim.lsp.start({
      name = ft == "go" and "gopls" or "clangd",
      cmd = fake_clangd(opts),
      root_dir = root,
    }, { bufnr = buf })
    assert.truthy(id, "fake server did not start")
    assert(
      vim.wait(5000, function()
        return vim.lsp.buf_is_attached(buf, id)
      end, 20),
      "fake server never attached"
    )
    vim.api.nvim_win_set_cursor(0, { 2, vim.fn.getline(2):find("push_back", 1, true) + 1 })
    return buf
  end

  local function wait_float()
    assert(
      vim.wait(5000, function()
        return float_text() ~= nil
      end, 20),
      "no hover float opened"
    )
    return float_text()
  end

  it("maps K to the excerpting hover in C++ and leaves other filetypes to core", function()
    cpp_buffer({ hover = PUSH_BACK_HOVER })
    local k = keymap_probe.resolve("n", "K")
    assert.is_not_nil(k)
    assert.equals(hover.hover, k.callback)

    cpp_buffer({ hover = PUSH_BACK_HOVER }, "go")
    local go_k = keymap_probe.resolve("n", "K")
    assert.is_true(go_k == nil or go_k.callback ~= hover.hover)
  end)

  it("appends the cppreference excerpt under the hover", function()
    cpp_buffer({ hover = PUSH_BACK_HOVER })
    hover.hover()
    local text = wait_float()
    assert.truthy(text:find("push_back", 1, true), text)
    assert.truthy(text:find("cppreference · std::vector::push_back", 1, true), text)
    assert.truthy(text:find("Appends the given element", 1, true), text)
  end)

  it("focuses the float on a second K, as core's hover does", function()
    cpp_buffer({ hover = PUSH_BACK_HOVER })
    hover.hover()
    wait_float()
    local _, win = float_text()
    hover.hover()
    assert(
      vim.wait(5000, function()
        return vim.api.nvim_get_current_win() == win
      end, 20),
      "second K did not focus the hover float"
    )
  end)

  it("leaves a hover that already has documentation alone", function()
    cpp_buffer({ hover = DOCUMENTED_HOVER })
    hover.hover()
    local text = wait_float()
    assert.truthy(text:find("Appends to our own vector.", 1, true), text)
    assert.is_nil(text:find("cppreference", 1, true), text)
  end)

  it("says which bundle to install when none is on disk", function()
    devdocs._root = root .. "/empty-store"
    cpp_buffer({ hover = PUSH_BACK_HOVER })
    hover.hover()
    local text = wait_float()
    assert.truthy(text:find(":DocsInstall cpp", 1, true), text)
  end)

  it("opens nothing when the cursor moved before the server answered", function()
    cpp_buffer({ hover = PUSH_BACK_HOVER, hover_delay = 200 })
    hover.hover()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.wait(600)
    assert.equals(0, #floats())
  end)

  it("gK opens the cppreference page when nothing better resolves", function()
    cpp_buffer({ hover = PUSH_BACK_HOVER })
    local open_url = require("config.open_url")
    local saved_open = open_url.open
    local opened
    open_url.open = function(url)
      opened = url
    end
    local ok, err = pcall(function()
      require("config.docs").open_at_cursor()
      assert(
        vim.wait(5000, function()
          return opened ~= nil
        end, 20),
        "gK opened nothing"
      )
    end)
    open_url.open = saved_open
    require("config.docs.viewer").close()
    assert(ok, err)
    assert.equals("https://en.cppreference.com/w/cpp/container/vector/push_back", opened)
  end)
end)

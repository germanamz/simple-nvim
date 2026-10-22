-- The Python type server: which one, and the per-root wiring that keeps it
-- pointed at the project on screen. See docs/python-navigation.md.
--
-- Why basedpyright and not pyright
-- --------------------------------
-- Plain pyright answers no textDocument/implementation request at all (it
-- replies -32601), so `gri` was dead in Python, and `gd` on a call made through
-- an ABC or a Protocol can only ever land on the abstract method — which is
-- what go-to-definition means in every editor. basedpyright is pyright with the
-- open-source half of Pylance put back: implementation lookup (subclass
-- overrides, and classes that satisfy a Protocol without inheriting from it),
-- semantic tokens and inlay hints. Same engine, same import resolution, same
-- pyrightconfig.json — so everything config.pyright_rules does carries over.
--
-- The name lives here, in one place, so trying another server is a one-line
-- change for everything keyed on it (pyright_rules, the docs hover, the
-- statusline). Only the settings layout is pyright-family specific.
--
-- What this module adds on top of the server
-- -------------------------------------------
-- The same `gd` used to land in different places depending on how Neovim was
-- started. Three causes, three answers:
--   * the interpreter: before_init hands the server the project's own
--     (config.python_env) as python.pythonPath, instead of leaving it to
--     whatever `python` Neovim inherited;
--   * the root: config.python_root roots a workspace member at the workspace;
--   * staleness: with didChangeWatchedFiles off (lua/plugins/lsp.lua), the
--     server never hears about a branch switch or a `uv sync`, so both restart
--     it (on_head_changed / check_envs).
-- And the interpreter it settled on is in the statusline, so a wrong one is
-- something you can see rather than something you infer from a strange jump.
local M = {}

local python_env = require("config.python_env")

--- The lspconfig name of the Python type server.
M.server = "basedpyright"

--- The workspace/configuration section its analysis settings live under
--- (`basedpyright.analysis.*`). basedpyright reads `python.analysis` only when
--- there is no basedpyright section at all, and lspconfig always contributes
--- one — so anything written under python.analysis is silently ignored.
M.section = "basedpyright"

--- Merged over lspconfig's defaults in lua/plugins/lsp.lua.
---
--- typeCheckingMode: basedpyright defaults to "recommended", which turns on a
--- long list of rules plain pyright leaves off. "standard" is pyright's default
--- (and Zed's choice for basedpyright), so switching servers changes navigation,
--- not how loud a project is. A project's own config file still wins.
---
--- inlayHints: still off until `<leader>uh`; these pick what the toggle shows.
--- Return types and call-argument names say something the code does not;
--- a type on every assignment and the generic arguments are noise.
M.settings = {
  basedpyright = {
    analysis = {
      typeCheckingMode = "standard",
      inlayHints = { variableTypes = false, genericTypes = false },
    },
  },
}

-- realpath'd root -> what before_init resolved for it:
--   { exe, venv, kind, top, sp, sp_mtime }
-- Survives a client restart on purpose: the restart's own before_init
-- overwrites it, and until then the label keeps naming what is running.
local envs = {}

---@param root string|nil
---@return string|nil
local function normalize(root)
  return root and (vim.uv.fs_realpath(root) or root) or nil
end

--- Is `path` `dir` or below it, on a "/" boundary (so /repo-backup is not taken
--- for a child of /repo)?
---@param path string|nil
---@param dir string|nil
---@return boolean
local function under(path, dir)
  path, dir = normalize(path), normalize(dir)
  if not path or not dir then
    return false
  end
  return path == dir or vim.startswith(path, dir == "/" and "/" or dir .. "/")
end

-- A directory's mtime as one comparable string. Nanoseconds as well as
-- seconds: an install can land inside the same second as the start that
-- recorded the old value.
---@param path string|nil
---@return string|nil
local function mtime(path)
  local st = path and vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. "." .. (st.mtime.nsec or 0)) or nil
end

---@param client vim.lsp.Client|table
---@return string|nil
local function client_root(client)
  return client.root_dir or (client.config and client.config.root_dir)
end

--- vim.lsp before_init hook: point the server at the project's interpreter,
--- then fold in the per-project rule severities (config.pyright_rules).
---
--- MUTATES config.settings — see config.pyright_rules' header for why a
--- reassignment would silently never reach the server. A nil settings table
--- has nothing aliased to client.settings, so there is nothing to write into.
---
--- pythonPath is left unset when python_env finds nothing, so the server's own
--- fallback (`./.venv`, then `python` on PATH) still runs; the statusline says
--- PATH in that case.
---@param params table initialize params
---@param config table the resolved client config
function M.before_init(params, config)
  local root = config and config.root_dir
  if root then
    local top = vim.fs.root(root, { ".git" })
    local env = python_env.resolve(root, top)
    local settings = config.settings
    if env and settings then
      settings.python = settings.python or {}
      settings.python.pythonPath = env.exe
    end
    local sp = env and env.venv and python_env.site_packages(env.venv) or nil
    envs[normalize(root)] = {
      exe = env and env.exe,
      venv = env and env.venv,
      kind = env and env.kind,
      top = top,
      sp = sp,
      sp_mtime = mtime(sp),
    }
  end
  require("config.pyright_rules").before_init(params, config)
end

--- What before_init resolved for `root`, or nil when no server started there.
---@param root string|nil
---@return table|nil
function M.env(root)
  return envs[normalize(root)]
end

--- The statusline text for the server rooted at `root`: the venv's path
--- relative to the root (`.venv`), the pyenv version, or PATH when the server
--- was left to find python itself.
---@param root string|nil
---@return string
function M.label(root)
  local env = M.env(root)
  if not env then
    return ""
  end
  local name
  if env.kind == "venv" then
    name = vim.fs.relpath(normalize(root), env.venv) or vim.fn.fnamemodify(env.venv, ":~")
  elseif env.kind == "pyenv" then
    name = "pyenv " .. vim.fs.basename(vim.fs.dirname(vim.fs.dirname(env.exe)))
  else
    name = "PATH"
  end
  return " py:" .. name .. " "
end

--- Statusline segment for `bufnr`: the label of the Python type server serving
--- it, or "" when none is.
---@param bufnr integer|nil
---@param clients table[]|nil defaults to the server's clients on the buffer
---@return string
function M.status(bufnr, clients)
  clients = clients or vim.lsp.get_clients({ bufnr = bufnr or 0, name = M.server })
  local client = clients[1]
  if not client then
    return ""
  end
  return M.label(client_root(client))
end

--- Restart `clients` and say why. A seam for the spec; the restart itself is
--- config.lsp_picker's, which re-reads the buffers so the new server is handed
--- what is on disk now.
---@param clients vim.lsp.Client[]
---@param reason string
function M._restart(clients, reason)
  require("config.lsp_picker").restart_clients(clients)
  vim.notify(("%s restarted: %s"):format(M.server, reason), vim.log.levels.INFO)
end

---@param clients table[]|nil
---@return table[]
local function live(clients)
  return clients or vim.lsp.get_clients({ name = M.server })
end

--- A checkout moved HEAD in the repository at `root`: every file the servers
--- inside it analysed may have changed underneath them.
---@param root string
---@param clients table[]|nil defaults to every running Python type server
function M.on_head_changed(root, clients)
  local stale = vim.tbl_filter(function(c)
    return under(client_root(c), root)
  end, live(clients))
  if #stale > 0 then
    M._restart(stale, "branch changed")
  end
end

--- Restart the servers whose interpreter changed under them: packages
--- installed into (or removed from) the venv they started with, or a venv
--- created where there was none. Both are what `uv sync` does, and neither
--- reaches a server that is not watching files.
---@param clients table[]|nil defaults to every running Python type server
function M.check_envs(clients)
  local by_reason = {}
  for _, c in ipairs(live(clients)) do
    local root = client_root(c)
    local env = M.env(root)
    local reason
    if env and env.sp then
      if mtime(env.sp) ~= env.sp_mtime then
        reason = "packages changed"
      end
    elseif env and not env.venv and python_env.venv_dir(root, env.top) then
      reason = "venv appeared"
    end
    if reason then
      by_reason[reason] = by_reason[reason] or {}
      table.insert(by_reason[reason], c)
    end
  end
  for reason, stale in pairs(by_reason) do
    M._restart(stale, reason)
  end
end

--- Wire the refresh triggers and the statusline segment. Idempotent: the
--- augroup is cleared on every call.
function M.setup()
  local group = vim.api.nvim_create_augroup("python_lsp", { clear = true })
  -- config.git_head broadcasts HeadChanged for every repo it watches, which is
  -- every repo with a buffer open (the statusline starts the watchers).
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "HeadChanged",
    callback = function(args)
      if args.data and args.data.root then
        M.on_head_changed(args.data.root)
      end
    end,
  })
  -- Coming back from the terminal the install ran in. Only stats a directory
  -- per running server, so it is cheap enough for every focus change.
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      M.check_envs()
    end,
  })
  _G.python_env_status = function()
    return M.status(0)
  end
end

-- Forget every resolved env. For tests.
function M._reset()
  envs = {}
end

return M

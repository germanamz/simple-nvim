-- How loud basedpyright is in a project that carries its own type-checker
-- config, and the two ways out. See docs/python-diagnostics.md.
--
-- The editor asks for typeCheckingMode = "standard" (config.python_lsp), which
-- keeps basedpyright as quiet as plain pyright was. But once a project has a
-- pyrightconfig.json, or a pyproject.toml with [tool.pyright] /
-- [tool.basedpyright], the server drops the editor's settings wholesale (the
-- precedence config.pyright_rules' `shadowed` describes) and starts that config
-- from basedpyright's OWN default, "recommended". No editor setting reaches
-- past that. Measured on a 150-file package: 175 diagnostics under standard,
-- 4,683 under recommended, nearly all from rules plain pyright does not have
-- (reportDeprecated, reportAny, reportUnannotatedClassAttribute...).
--
-- So the fix has to live in a config file, and this module offers both:
--   * M.warn, once per project whose config leaves the mode unset, names the
--     one line to add to that file. Setting "standard" there changes nothing for
--     plain pyright, Pylance or CI, whose default it already is.
--   * :PythonQuiet (M.quiet) is for a repo you do not own. basedpyright reads
--     no config file name but pyrightconfig.json and pyproject.toml, and
--     pyrightconfig.json wins, so an untracked pyrightconfig.json that extends
--     the project's pyproject.toml and sets "standard" keeps every project
--     setting except the mode. It goes in .git/info/exclude, never .gitignore,
--     so the repo itself is left untouched.
local M = {}

local python_lsp = require("config.python_lsp")

--- Modes at or below pyright's own default. Asked to quiet a project already
--- at one of these, :PythonQuiet has nothing to do.
M.QUIET = { off = true, basic = true, standard = true }

local OVERRIDE = table.concat({
  "{",
  "  // Local only, listed in .git/info/exclude: keeps basedpyright at",
  '  // pyright\'s "standard" level. Delete this file to undo.',
  '  "extends": "./pyproject.toml",',
  '  "typeCheckingMode": "standard"',
  "}",
  "",
}, "\n")

-- Test seam so specs can capture the message without a real UI (same contract
-- as config.pyright_rules' M._notify).
M._notify = nil

local function notify(msg, level)
  local send = M._notify or vim.notify
  send(msg, level or vim.log.levels.INFO)
end

---@param path string
---@return string|nil
local function read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local body = f:read("*a")
  f:close()
  return body
end

---@param path string
---@return boolean
local function is_toml(path)
  return path:match("%.toml$") ~= nil
end

--- The two keys this module cares about, straight from the type checker's
--- table in a pyproject.toml. Keys under a subtable or an array of tables
--- ([[tool.pyright.executionEnvironments]]) do not count: typeCheckingMode is
--- only read at the top of the section.
---@param body string
---@return table<string, string>
local function toml_keys(body)
  local keys, inside = {}, false
  for line in vim.gsplit(body, "\n", { plain = true }) do
    local header = line:match("^%s*%[(.-)%]%s*$") or line:match("^%s*%[(.-)%]%s*#")
    if header then
      header = vim.trim(header)
      inside = header == "tool.pyright" or header == "tool.basedpyright"
    elseif inside then
      local key, value = line:match("^%s*([%w_]+)%s*=%s*[\"']([^\"']*)[\"']")
      if key then
        keys[key] = value
      end
    end
  end
  return keys
end

--- The same two keys from a pyrightconfig.json. basedpyright parses it as
--- JSONC, so a plain decode would fail on the comments it allows; the keys are
--- matched instead, with comment lines dropped first.
---@param body string
---@return table<string, string>
local function json_keys(body)
  local lines = vim.tbl_filter(function(line)
    return not line:match("^%s*//")
  end, vim.split(body, "\n", { plain = true }))
  local text = table.concat(lines, "\n")
  return {
    typeCheckingMode = text:match('"typeCheckingMode"%s*:%s*"([^"]*)"'),
    extends = text:match('"extends"%s*:%s*"([^"]*)"'),
  }
end

--- The typeCheckingMode in force for config file `path`, following its
--- `extends` chain the way the server does: the extending file wins, so the
--- first file in the chain that sets a mode decides. nil when none does, which
--- means basedpyright's "recommended".
---@param path string
---@return string|nil
function M.mode(path)
  local seen = {}
  while path and not seen[path] do
    seen[path] = true
    local body = read(path)
    if not body then
      return nil
    end
    local keys = is_toml(path) and toml_keys(body) or json_keys(body)
    if keys.typeCheckingMode then
      return keys.typeCheckingMode
    end
    local base = keys.extends
    if base and not vim.startswith(base, "/") then
      base = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(path), base))
    end
    path = base
  end
  return nil
end

--- The config file basedpyright reads in `root` when it leaves the mode unset,
--- or nil when there is no config file or it sets one. Judged on the file that
--- actually wins: pyrightconfig.json outranks pyproject.toml.
---@param root string|nil
---@return string|nil
function M.implicit(root)
  local path = require("config.pyright_rules").shadowed(root)
  if path and not M.mode(path) then
    return path
  end
  return nil
end

--- The line to add to `path`, in that file's own syntax.
---@param path string
---@return string
local function fix_for(path)
  return is_toml(path) and 'typeCheckingMode = "standard"' or '"typeCheckingMode": "standard"'
end

-- One warning per root: a project has many buffers and the fact is a property
-- of the project, not of the file you happened to open.
local warned = {}

--- Warn once that `root`'s own config has put basedpyright in "recommended"
--- mode. Silent for a project with no config (the editor's "standard" applies)
--- and for one that chose a mode: that is the project's call.
---@param root string|nil
function M.warn(root)
  local key = root and (vim.uv.fs_realpath(root) or root)
  if not key or warned[key] then
    return
  end
  local path = M.implicit(key)
  if not path then
    return
  end
  warned[key] = true
  local rel = vim.fn.fnamemodify(path, ":~:.")
  local msg = ('%s sets no typeCheckingMode, so %s checks this project in its "recommended" mode, which reports far more than pyright. Add %s to it'):format(
    rel,
    python_lsp.server,
    fix_for(path)
  )
  if is_toml(path) then
    msg = msg .. ", or run :PythonQuiet for a local, git-excluded override"
  end
  notify(msg .. " (docs/python-diagnostics.md).", vim.log.levels.WARN)
end

--- Add `/<path of name relative to the repository top>` to the
--- .git/info/exclude of the repository holding `root`, once. Asks git for both
--- paths, so a worktree or a submodule (whose git dir lives elsewhere) gets its
--- own exclude file.
---@param root string
---@param name string file name inside root
---@return string|nil pattern added (or already there), nil outside a repository
function M._exclude(root, name)
  local res = vim
    .system({
      "git",
      "-C",
      root,
      "rev-parse",
      "--path-format=absolute",
      "--show-toplevel",
      "--git-path",
      "info/exclude",
    }, { text = true })
    :wait()
  if res.code ~= 0 then
    return nil
  end
  local top, exclude = unpack(vim.split(vim.trim(res.stdout), "\n", { plain = true }))
  local rel = vim.fs.relpath(top, vim.fs.joinpath(vim.uv.fs_realpath(root) or root, name))
  if not rel or not exclude then
    return nil
  end
  local pattern = "/" .. rel
  local body = read(exclude) or ""
  for line in vim.gsplit(body, "\n", { plain = true }) do
    if line == pattern then
      return pattern
    end
  end
  vim.fn.mkdir(vim.fs.dirname(exclude), "p")
  local f = io.open(exclude, "a")
  if not f then
    return nil
  end
  f:write((body ~= "" and not vim.endswith(body, "\n") and "\n" or "") .. pattern .. "\n")
  f:close()
  return pattern
end

---@param client table
---@return string|nil
local function client_root(client)
  local root = client.root_dir or (client.config and client.config.root_dir)
  return root and (vim.uv.fs_realpath(root) or root)
end

--- :PythonQuiet. Hold the project served on `bufnr` at "standard" with an
--- untracked pyrightconfig.json, then restart its server so the file is read
--- (file watching is off, so the server would never notice on its own).
---@param bufnr integer
---@param clients table[]|nil the type server on the buffer; defaults to the live one
---@param all table[]|nil servers to consider for the restart; defaults to every live one
function M.quiet(bufnr, clients, all)
  local root = require("config.pyright_rules").resolve_root(bufnr, clients)
  if not root then
    notify(
      ("No %s client on this buffer — open a Python file in the project first"):format(
        python_lsp.server
      ),
      vim.log.levels.WARN
    )
    return
  end

  local path = require("config.pyright_rules").shadowed(root)
  if not path then
    notify(
      ('%s has no type-checker config, so the editor\'s "standard" mode already applies.'):format(
        vim.fs.basename(root)
      )
    )
    return
  end
  local rel = vim.fn.fnamemodify(path, ":~:.")
  local mode = M.mode(path)
  if mode and M.QUIET[mode] then
    notify(('%s already sets typeCheckingMode = "%s".'):format(rel, mode))
    return
  end
  if not is_toml(path) then
    -- The override would have to be this very file.
    notify(
      ("%s is the config basedpyright reads here, so a local override cannot sit beside it. Add %s to it instead."):format(
        rel,
        fix_for(path)
      ),
      vim.log.levels.WARN
    )
    return
  end

  local target = vim.fs.joinpath(root, "pyrightconfig.json")
  local f = io.open(target, "w")
  if not f then
    notify("Could not write " .. target, vim.log.levels.ERROR)
    return
  end
  f:write(OVERRIDE)
  f:close()

  local excluded = M._exclude(root, "pyrightconfig.json")
  local reason = ('pyrightconfig.json holds %s at "standard" (%s; delete the file to undo)'):format(
    vim.fs.basename(root),
    excluded and ("git-excluded as " .. excluded) or "not a git repository, so not excluded"
  )
  local stale = vim.tbl_filter(function(c)
    return client_root(c) == root
  end, all or vim.lsp.get_clients({ name = python_lsp.server }))
  if #stale > 0 then
    python_lsp._restart(stale, reason)
  else
    notify("Wrote " .. reason)
  end
end

-- Forget which projects were warned about. For tests.
function M._clear()
  warned = {}
end

return M

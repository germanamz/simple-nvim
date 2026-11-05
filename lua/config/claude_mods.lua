-- Install the Claude Code mods kept in claude-mods/ into one project, behind
-- :ClaudeModInstall and :ClaudeModUninstall. Today that is nvim-review, which
-- pulls the <leader>ac queue into Claude's prompt (docs/agent-review-comments.md).
--
-- claude-mods/ is a plugin marketplace on disk. A plugin installed from a folder
-- marketplace is read in place, never copied, so an edit there reaches a Claude
-- session at its next start or /reload-plugins with no reinstall, and
-- `--marketplace <folder>` adds the marketplace on a first install by itself.
--
-- The scope is `local`: the project's .claude/settings.local.json, never the
-- committed settings.json, because the marketplace path exists only on this
-- machine and a team project's shared settings must not name it. Claude
-- resolves the project itself, so running in a subdirectory installs into the
-- repo's root.
local M = {}

M.marketplace = "simple-nvim"

-- This file is lua/config/claude_mods.lua: the repo is three levels up.
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
M.dir = vim.fs.joinpath(repo, "claude-mods")

--- The mods the marketplace lists, for completion and the default.
---@return string[]
function M.names()
  local ok, lines =
    pcall(vim.fn.readfile, vim.fs.joinpath(M.dir, ".claude-plugin", "marketplace.json"))
  if not ok then
    return {}
  end
  local decoded, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded or type(data) ~= "table" or type(data.plugins) ~= "table" then
    return {}
  end
  local out = {}
  for _, plugin in ipairs(data.plugins) do
    out[#out + 1] = plugin.name
  end
  return out
end

--- The CLI's own words for a run: the message of its JSON line, else the last
--- line it printed. A failure is plain text even under --json.
---@param r vim.SystemCompleted
---@return string
local function said(r)
  local last
  for _, stream in ipairs({ r.stdout or "", r.stderr or "" }) do
    for line in vim.gsplit(stream, "\n", { trimempty = true }) do
      local ok, data = pcall(vim.json.decode, line)
      if ok and type(data) == "table" and type(data.message) == "string" then
        return data.message
      end
      last = line
    end
  end
  return last or string.format("claude exited %d", r.code)
end

---@param args string[]
---@param hint string|nil appended to a success the CLI did not already explain
local function run(args, hint)
  if vim.fn.executable("claude") ~= 1 then
    vim.notify("claude is not on PATH", vim.log.levels.ERROR)
    return
  end
  vim.system(
    args,
    { cwd = vim.fn.getcwd(), text = true },
    vim.schedule_wrap(function(r)
      local msg = said(r)
      if r.code ~= 0 then
        vim.notify(msg, vim.log.levels.ERROR)
        return
      end
      if hint and not msg:find("/reload-plugins", 1, true) then
        msg = msg .. "\n" .. hint
      end
      vim.notify(msg)
    end)
  )
end

---@param name string|nil
---@return string|nil
local function pick(name)
  if name and name ~= "" then
    return name
  end
  return M.names()[1]
end

---@param name string|nil the mod; the marketplace's first when absent
function M.install(name)
  name = pick(name)
  if not name then
    vim.notify("No Claude Code mods in " .. M.dir, vim.log.levels.ERROR)
    return
  end
  run(
    { "claude", "plugin", "install", name, "--marketplace", M.dir, "--scope", "local", "--json" },
    "Start a Claude session here, or run /reload-plugins in one."
  )
end

---@param name string|nil the mod; the marketplace's first when absent
function M.uninstall(name)
  name = pick(name)
  if not name then
    vim.notify("No Claude Code mods in " .. M.dir, vim.log.levels.ERROR)
    return
  end
  run({
    "claude",
    "plugin",
    "uninstall",
    name .. "@" .. M.marketplace,
    "--scope",
    "local",
    "--json",
  })
end

--- Completion for the two commands: the marketplace's mods matching `lead`.
---@param lead string
---@return string[]
function M.complete(lead)
  return vim.tbl_filter(function(n)
    return vim.startswith(n, lead)
  end, M.names())
end

return M

-- Where a batch of review comments goes.
--
-- One entry per agent transport. `cmux` types the payload into the terminal
-- surface the agent is running in -- the only channel that reaches an agent
-- living OUTSIDE Neovim and can carry the comment prose along with the file
-- reference. `clipboard` is the fallback when this is not a cmux session, so a
-- batch is never lost, only relocated.
--
-- Why not Claude's own IDE websocket: its complete set of IDE->Claude
-- notifications is at_mentioned / selection_changed / log_event, and
-- at_mentioned takes strictly {filePath, lineStart, lineEnd}. There is no field
-- for a comment. MCP's unsolicited path (notifications/claude/channel) would
-- carry one, but is gated off. See docs/agent-review-comments.md.
local cmux = require("util.cmux")

local M = {}

--- Test seam: when set, replaces every cmux invocation. Called synchronously.
---@type nil|fun(args: string[], on_done: fun(code: integer, stdout: string))
M._run = nil

local function run(bin, args, on_done)
  if M._run then
    return M._run(args, on_done)
  end
  local cmd = { bin }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(res)
    -- vim.system's callback lands in a luv context; hop to the main loop so
    -- handlers can notify and touch the editor freely.
    vim.schedule(function()
      on_done(res.code, res.stdout or "")
    end)
  end)
end

---@return table|nil
local function decode(stdout)
  local ok, value = pcall(vim.json.decode, stdout)
  if ok and type(value) == "table" then
    return value
  end
  return nil
end

--- The sink to use with no configuration: cmux when we are inside it.
---@return string
function M.choose()
  return cmux.bin() and "cmux" or "clipboard"
end

local sinks = {}

function sinks.clipboard(text, _opts, on_done)
  vim.fn.setreg("+", text)
  on_done(true, nil)
end

--- Deliver `text` through the named sink.
---@param name string
---@param text string
---@param opts table `{ submit = boolean }`
---@param on_done fun(ok: boolean, err: string|nil)
function M.send(name, text, opts, on_done)
  local sink = sinks[name]
  if not sink then
    return on_done(false, "no such sink: " .. tostring(name))
  end
  sink(text, opts or {}, on_done)
end

--- Test seam: the sink table, so a spec can reach one directly.
function M._sinks()
  return sinks
end

return M

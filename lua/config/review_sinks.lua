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

-- The agent's surface, resolved once per session. Dropped whenever a send
-- fails, since "the pane is gone" is the failure that matters and re-resolving
-- is cheaper than making the user care.
local surface = nil

--- Every terminal surface in the caller's workspace except our own.
---
--- Workspace-scoped, not window-scoped: `nvim .` and the agent share one pane
--- in one workspace, and a second workspace holding an unrelated agent must not
--- become a candidate. Self-identification comes from the response's `caller`
--- rather than CMUX_SURFACE_ID, which a :terminal or a session restore can trim.
---@param t table decoded `cmux tree` output
---@return table[] `{ ref = string, title = string }`
local function candidates(t)
  local caller = t.caller or {}
  local out = {}
  for _, window in ipairs(t.windows or {}) do
    for _, workspace in ipairs(window.workspaces or {}) do
      if workspace.id == caller.workspace_id then
        for _, pane in ipairs(workspace.panes or {}) do
          for _, s in ipairs(pane.surfaces or {}) do
            if s.type == "terminal" and s.id ~= caller.surface_id then
              out[#out + 1] = { ref = s.ref, title = s.title or s.ref }
            end
          end
        end
      end
    end
  end
  return out
end

--- Resolve the agent's surface, asking the user only when it is ambiguous.
---@param bin string
---@param on_done fun(ref: string|nil, err: string|nil)
local function resolve_surface(bin, on_done)
  if surface then
    return on_done(surface, nil)
  end
  run(bin, { "--json", "--id-format", "both", "tree" }, function(code, stdout)
    local t = code == 0 and decode(stdout) or nil
    if not t then
      return on_done(nil, "cmux tree failed")
    end
    local found = candidates(t)
    if #found == 0 then
      return on_done(nil, "no agent surface in this workspace")
    end
    if #found == 1 then
      surface = found[1].ref
      return on_done(surface, nil)
    end
    vim.ui.select(found, {
      prompt = "Send review comments to:",
      format_item = function(item)
        return item.title
      end,
    }, function(choice)
      if not choice then
        return on_done(nil, "cancelled")
      end
      surface = choice.ref
      on_done(surface, nil)
    end)
  end)
end

--- The payload as `cmux send` will not misread it.
---
--- `cmux send` treats part of its text argument as keystrokes: a real newline
--- or carriage return, and the two-character sequences `\n` and `\r`, all
--- arrive as Enter, and `\t` (real or escaped) as Tab. Left alone, a batch --
--- which is always multi-line, and whose prose is whatever the reviewer typed
--- -- submits itself piece by piece into the agent's prompt, destroying the
--- draft-not-submit guarantee that `<leader>as` exists for, and fires Tabs into
--- the agent's TUI. Escaping does not help: cmux has no escape for a backslash,
--- so `\\n` still ends in an Enter (verified against cmux 0.64.22). The only
--- neutralizer is to break the pair, so a zero-width space is parted between
--- the backslash and its letter: invisible in the prompt, and it carries no
--- meaning into the text the agent reads.
---@param text string
---@return string
local function flatten(text)
  local line = text:gsub("%s*[\r\n]%s*", "  "):gsub("\t", " ")
  return (line:gsub("\\([nrt])", "\\\226\128\139%1"))
end

--- Type `text` into the agent's surface.
---
--- Two calls, never one: `send` writes the payload and `send-key enter` submits
--- it. Submitting is opt-in because injected input goes wherever focus is -- a
--- permission dialog or a picker in that pane would swallow a blind submit --
--- so the default leaves the text sitting there for the user to send.
function sinks.cmux(text, opts, on_done)
  local bin = cmux.bin()
  if not bin then
    return on_done(false, "not a cmux session")
  end
  local retried = false
  local attempt
  attempt = function()
    resolve_surface(bin, function(ref, err)
      if not ref then
        return on_done(false, err)
      end
      run(bin, { "send", "--surface", ref, "--", flatten(text) }, function(code)
        if code ~= 0 then
          -- The surface is gone. Forget it and resolve again, once.
          surface = nil
          if not retried then
            retried = true
            return attempt()
          end
          return on_done(false, "cmux send failed")
        end
        if not opts.submit then
          return on_done(true, nil)
        end
        run(bin, { "send-key", "--surface", ref, "enter" }, function(enter_code)
          on_done(enter_code == 0, enter_code == 0 and nil or "cmux send-key failed")
        end)
      end)
    end)
  end
  attempt()
end

--- Test seam: forget the resolved surface between specs.
function M._reset_surface()
  surface = nil
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

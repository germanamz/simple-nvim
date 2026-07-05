-- Runtime state for the local-Ollama AI autocomplete (minuet virtual text +
-- blink.cmp). The plugin spec (lua/plugins/minuet.lua) stays declarative; every
-- moving part that has to change at runtime lives here so no plugin knowledge
-- leaks into the spec:
--   * a global on/off toggle (V1),
--   * the blink ghost-text swap that couples to it (V2),
--   * a live model switch + cross-session persistence (V3),
--   * an Ollama-availability gate: start disabled when ollama isn't installed.
-- The browse/install/delete/pick model-management modal lives in
-- lua/config/ai_models.lua (v2); its <CR> routes back into M.set_model here.
--
-- V1 — global toggle. minuet's only per-buffer gate is the buffer variable
-- `vim.b.minuet_virtual_text_auto_trigger` (confirmed in minuet-ai.nvim
-- lua/minuet/virtualtext.lua: should_auto_trigger() reads exactly this, and
-- enable/disable/toggle_auto_trigger just write it). With auto_trigger_ft="*"
-- minuet sets it true on every buffer's FileType, so a real global switch is a
-- session flag (M.enabled) plus our own augroup that re-asserts the flag =
-- M.enabled on BufEnter/InsertEnter/FileType (registered AFTER minuet.setup so
-- it wins the ordering), plus an immediate sweep of open buffers on toggle. This
-- is the design's V1 mechanism and Report A's recommended approach.
--
-- V2 — ghost-text swap. blink's renderer reads
-- require("blink.cmp.config").completion.ghost_text.enabled live on every
-- draw_preview (confirmed in blink.cmp completion/windows/ghost_text/init.lua),
-- so mutating that leaf flips blink's inline preview at runtime. AI-on ⇒ blink
-- ghost text OFF (minuet owns inline); AI-off ⇒ blink ghost text back ON.
--
-- V3 — live model switch. `:Minuet change_model provider:model` splits on the
-- FIRST colon (confirmed in minuet init.lua), so a tag that itself contains a
-- colon (qwen2.5-coder:3b-base) parses correctly, and the FIM backend re-reads
-- the model from config on the next request — no re-setup needed.
--
-- Startup safety: requiring this module touches no network and creates no
-- autocmds; the only Ollama/HTTP call here lives inside set_model (the live
-- :Minuet switch), and load_persisted_model degrades to the default when its
-- state file is absent.
local M = {}

local state_util = require("util.state")

-- The single home for the default completion model. config.ai_models reads
-- this export for its "nothing installed yet" hint, so the two modules can
-- never disagree on the fallback. Exported from THIS side of the dependency
-- (ai_models already requires config.ai) so no require cycle appears.
M.DEFAULT_MODEL = "qwen2.5-coder:7b-base"

local GATE_AUGROUP = "ai_completions_gate"

-- Common Ollama install locations, checked in addition to PATH so a GUI Neovim
-- launched from Finder — which doesn't inherit the shell PATH — still detects an
-- installed Ollama (Homebrew arm64 / Intel, and the Linux default).
local OLLAMA_BIN_PATHS = {
  "/opt/homebrew/bin/ollama",
  "/usr/local/bin/ollama",
  "/usr/bin/ollama",
}

-- Global enable flag, per-session (starts enabled). Read live by the gate
-- autocmd below, so flipping it and re-entering a buffer is enough to change
-- behavior there; M.apply() handles the buffers already open.
M.enabled = true

-- Filetypes where AI autocomplete should never fire even when globally enabled.
-- Special buffers (buftype ~= "") are excluded wholesale by is_eligible below;
-- this list adds *normal* buffers that are non-editing contexts. Extend to taste
-- (e.g. add "markdown"/"text" to spare prose from constant local inference).
local IGNORE_FT = {
  gitcommit = true,
  gitrebase = true,
}

-- A buffer is eligible for AI autocomplete only if it is a real editable buffer
-- (not a prompt/terminal/nofile/help buftype) and not an ignored filetype. This
-- is what makes auto_trigger_ft="*" safe: without it, typing in a Telescope
-- prompt, an nvim-tree rename, or a git commit message would each kick off a
-- local FIM inference against that throwaway text.
local function is_eligible(buf)
  return vim.bo[buf].buftype == "" and not IGNORE_FT[vim.bo[buf].filetype]
end

-- Persisted-model file lives under stdpath("state") (resolved per call so the
-- test harness's XDG swap is honored, mirroring config.review_base).
function M.model_path()
  return vim.fn.stdpath("state") .. "/minuet-model"
end

-- Read the persisted model, or the default when the file is absent/empty. Must
-- never error (it runs from minuet.setup at config-time): a missing file just
-- yields the default.
function M.load_persisted_model()
  local model = vim.trim(state_util.read_file(M.model_path()) or "")
  if model == "" then
    return M.DEFAULT_MODEL
  end
  return model
end

-- Atomic write via util.state (shared with ai_models' library cache and
-- review_base's store) so a crashed write never leaves a half-written file.
local function write_persisted_model(model)
  state_util.write_atomic(M.model_path(), model)
end

-- The gate: keep every buffer's minuet auto-trigger flag in lockstep with the
-- global M.enabled. minuet's own FileType autocmd (auto_trigger_ft="*") sets the
-- flag true on new buffers, so when AI is OFF this re-asserts false; when AI is
-- back ON it restores true. Named augroup with clear=true, so re-running it (or a
-- test package.loaded reset) replaces rather than stacks.
local function ensure_gate()
  local g = vim.api.nvim_create_augroup(GATE_AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "InsertEnter", "FileType" }, {
    group = g,
    callback = function(args)
      if vim.api.nvim_buf_is_valid(args.buf) then
        vim.b[args.buf].minuet_virtual_text_auto_trigger = M.enabled and is_eligible(args.buf)
      end
    end,
  })
end

-- Sweep every open buffer's flag to `on` immediately (the gate only fires on
-- future buffer/insert events). On disable, also dismiss the suggestion already
-- painted so it vanishes at once instead of lingering until the next schedule
-- the flag now suppresses.
local function set_minuet_trigger(on)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.b[buf].minuet_virtual_text_auto_trigger = on and is_eligible(buf)
    end
  end
  if not on then
    pcall(function()
      require("minuet.virtualtext").action.dismiss()
    end)
  end
end

-- Ollama is "available" when its binary is installed — on PATH, or at a known
-- install location for PATH-less GUI launches. Cheap and synchronous (no network
-- probe), so it never blocks and can't be fooled by the daemon merely being
-- stopped; it answers "is ollama on this computer" only. If it isn't installed,
-- AI completions are pointless (every FIM request would just fail), so we don't
-- run them.
function M.available()
  if vim.fn.executable("ollama") == 1 then
    return true
  end
  for _, p in ipairs(OLLAMA_BIN_PATHS) do
    if vim.uv.fs_stat(p) then
      return true
    end
  end
  return false
end

-- Apply the current M.enabled state to both layers: minuet auto-trigger (V1) and
-- the blink ghost-text swap (V2). Guarded so it is safe before either plugin has
-- loaded (blink loads as an LSP dependency; minuet on InsertEnter).
function M.apply()
  ensure_gate()
  set_minuet_trigger(M.enabled)

  local ok, cfg = pcall(require, "blink.cmp.config")
  if ok then
    -- Mutate ONLY the leaf (Report B): blink's renderer captured the ghost_text
    -- table by reference and reads .enabled live, so reassigning a parent would
    -- diverge from what it reads. This overwrites blink's mode-dispatch function
    -- (the per-mode cmdline/term ghost-text selector) with a plain boolean —
    -- intentional and harmless here, as we only rely on insert-mode ghost text.
    cfg.completion.ghost_text.enabled = not M.enabled
    if M.enabled then
      -- AI owns inline now — clear any blink ghost text still on screen.
      pcall(function()
        require("blink.cmp.completion.windows.ghost_text").clear_preview()
      end)
    end
  end
end

function M.toggle()
  -- Refuse to enable when Ollama isn't installed (re-checked here, so installing
  -- it and toggling again just works). Disabling is always allowed.
  if not M.enabled and not M.available() then
    vim.notify(
      "Ollama not found — install it (https://ollama.com) to enable AI completions",
      vim.log.levels.WARN
    )
    return
  end
  M.enabled = not M.enabled
  M.apply()
  vim.notify("AI completions " .. (M.enabled and "enabled" or "disabled"))
end

-- Called once when minuet loads (from lua/plugins/minuet.lua). If Ollama isn't
-- installed, start disabled — and say so once — so a machine without Ollama never
-- fires failing FIM requests or steals the inline slot from blink's LSP ghost
-- text. Then apply the resolved state (installs the gate + ghost-text swap).
function M.bootstrap()
  if not M.available() then
    M.enabled = false
    vim.notify(
      "Ollama not found — AI completions disabled (install ollama to enable)",
      vim.log.levels.WARN
    )
  end
  M.apply()
end

-- Live-switch the active model + persist the choice. Prefer the :Minuet
-- change_model Ex command (V3 primary — it mutates the live config in place, and
-- the FIM backend re-reads it next request); fall back to mutating the config
-- table directly if the command isn't registered yet (design V3 fallback). The
-- persist write happens first, so even if the live switch is a no-op (minuet not
-- yet set up) the next session's minuet.setup reads the new model back.
function M.set_model(model)
  if not model or model == "" then
    return
  end
  write_persisted_model(model)
  local ok = pcall(vim.cmd, "Minuet change_model openai_fim_compatible:" .. model)
  if not ok then
    pcall(function()
      require("minuet").config.provider_options.openai_fim_compatible.model = model
    end)
  end
  vim.notify("AI model set to " .. model)
end

-- The model picker (browse/install/delete/set-active) moved to
-- lua/config/ai_models.lua as the v2 model-management modal; is_preferred /
-- sort_models / fetch_models / pick_model went with it. It calls back into
-- M.set_model above, keeping this module free of telescope/plenary knowledge.

return M

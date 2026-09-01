-- Local-Ollama, Copilot-style AI autocomplete via minuet-ai.nvim, running in
-- virtual-text mode (true multi-line inline ghost text with its own
-- accept/dismiss) against a local Ollama FIM endpoint. Deliberately NOT wired as
-- a blink source, so sources.default / sources.per_filetype (and their
-- per-filetype-replaces-default gotcha) are left untouched — the only blink
-- change is the ghost-text swap in lua/plugins/completion.lua.
--
-- Prereqs (all local, no cloud, no API key):
--   * Ollama running:  ollama serve
--   * Base code model: ollama pull qwen2.5-coder:7b-base   (base tag = clean FIM)
-- The default model above is overridable live via <leader>am / :AIModel, and the
-- choice persists across sessions (see lua/config/ai.lua).
--
-- MLX: nothing to configure here. Ollama's MLX preview is automatic on 32GB+
-- Apple Silicon but only for a small supported set (Qwen3.5/Gemma-4); the
-- qwen2.5-coder base models run on llama.cpp regardless, and FIM is prefill-bound
-- (MLX's weak spot pre-M5). The FIM path is unaffected — recorded so it is not
-- re-litigated.
--
-- Runtime behavior (toggle, ghost-text swap, live model switch, picker) lives in
-- lua/config/ai.lua; this spec stays declarative. Lazy on InsertEnter (zero
-- startup cost) and additionally on the AI keys/command so those trigger the
-- setup that populates minuet.config before we mutate it.

-- Sentinel tokens that a *base* FIM model (qwen2.5-coder:*-base) occasionally
-- emits into a completion and that must never reach the ghost text:
--   * Editor "cursor" sentinels — the base model echoes / hallucinates these when
--     the surrounding buffer is marker-heavy (this very config, FIM docs, etc.).
--     The reported symptom was a stray `<|Cursor|>` landing in accepted
--     suggestions; reproduced against the local model — 5/5 completions carried
--     `<|Cursor|>` with a marker in context, 0/5 once these are set as stops.
--   * Qwen2.5-Coder structural / repo-FIM tokens — after finishing the "middle" a
--     base model can spill `<|file_sep|>` / `<|repo_name|>` and start hallucinating
--     the *next* file; stopping there keeps that garbage out of the buffer.
-- minuet sends no `stop` list by default and the Ollama Modelfile for the base
-- tag defines none, so without this the tokens pass straight through. Ollama's
-- /v1/completions honors `stop` server-side (the matched sequence is not emitted
-- and generation halts), so this behaves identically on the streamed and
-- non-streamed paths. These tokens never occur in ordinary code, so real
-- suggestions are untouched — the one exception is editing a file that literally
-- discusses FIM tokens (this config, minuet's own source, FIM docs), where a
-- legitimate completion of e.g. `<|fim_suffix|>` is cut short rather than garbled.
-- That narrow trade keeps the sentinels out of every other buffer; matching is a
-- case-sensitive literal substring, so add a variant here if a new casing shows.
local FIM_STOP = {
  "<|Cursor|>",
  "<|cursor|>",
  "<|user_cursor_is_here|>",
  "<CURSOR>",
  "<cursor>",
  "<|fim_prefix|>",
  "<|fim_suffix|>",
  "<|fim_middle|>",
  "<|fim_pad|>",
  "<|repo_name|>",
  "<|file_sep|>",
  "<|endoftext|>",
}

return {
  "milanglacier/minuet-ai.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  event = "InsertEnter",
  cmd = "AIModel",
  keys = {
    {
      "<leader>am",
      function()
        require("config.ai_models").open()
      end,
      desc = "AI model picker",
    },
    {
      "<leader>ua",
      function()
        require("config.ai").toggle()
      end,
      desc = "Toggle AI completions",
    },
  },
  config = function()
    require("minuet").setup({
      provider = "openai_fim_compatible",
      -- One suggestion, small context: FIM autocomplete is prefill-bound, so a
      -- tight window keeps latency low (tunable up given 32GB).
      n_completions = 1,
      context_window = 512,
      -- Pacing. minuet's defaults (throttle 1000, debounce 400) are sized as
      -- cost/rate-limit controls for paid cloud APIs; upstream's own "local model"
      -- preset uses 400/100. Against localhost they are actively harmful, because
      -- `schedule()` (virtualtext.lua:288-292) early-returns while throttled
      -- BEFORE re-arming the debounce — keystrokes inside the window are dropped,
      -- not deferred, and `on_cursor_hold_i` (:499) is dead code that is never
      -- registered, so nothing rescues them. Stop typing mid-window and no
      -- corrective request is ever issued: measured 18 of 40 keystrokes dropped,
      -- and a misaligned suggestion left on screen for 7.1s.
      --
      -- throttle = 0 restores the trailing edge (measured: zero keystrokes
      -- dropped). It is not literally "off" — :309-312 has no `> 0` short-circuit,
      -- unlike blink.lua:49 — but one event-loop tick is the intent here.
      -- debounce = 150 measured 5 requests / 0 misaligned over a 40-key run; 75
      -- (copilot's value) measured 29 requests with 22 SIGTERM cancellations for
      -- no accuracy gain. Raising the debounce back toward the round-trip median
      -- (433ms) is what re-opens the stale window, so keep it well under.
      --
      -- Safe against this Ollama despite the higher rate: common.terminate_all_jobs
      -- runs at the head of every FIM request, so at most one job is in flight, and
      -- SIGTERM frees the `-np 1` slot cleanly (next TTFB measured back at 0.17s).
      -- Put the defaults back if this provider is ever pointed at a paid endpoint.
      throttle = 0,
      debounce = 150,
      provider_options = {
        openai_fim_compatible = {
          -- api_key is an env-var NAME (minuet resolves it via utils.get_api_key);
          -- Ollama ignores auth, so point at TERM, which is always set.
          api_key = "TERM",
          name = "Ollama",
          -- FIM (/completions) endpoint, NOT the chat one.
          end_point = "http://localhost:11434/v1/completions",
          model = require("config.ai").load_persisted_model(),
          optional = {
            max_tokens = 56,
            -- top_p is a pass-through here, not a documented default field
            -- (Report A): minuet merges `optional` verbatim into the request
            -- body, so any Ollama-accepted param can ride along.
            top_p = 0.9,
            -- Halt (and drop) editor/repo sentinel tokens the base model spills
            -- into FIM output — e.g. the stray `<|Cursor|>` that was landing in
            -- suggestions. See FIM_STOP above for the full rationale.
            stop = FIM_STOP,
          },
        },
      },
      virtualtext = {
        -- Copilot-style: auto-trigger everywhere. The "*" pattern is baked into
        -- minuet's FileType autocmd at setup, which is what config.ai's global
        -- toggle rides on top of.
        auto_trigger_ft = { "*" },
        keymap = {
          -- accept stays unset — the smart <Tab> in lua/plugins/completion.lua
          -- owns whole-suggestion accept (AI-first, then snippet tabstop jump,
          -- then blink menu, then Tab).
          -- next/prev/accept_n_lines unused (n_completions = 1).
          accept = nil,
          accept_line = "<C-l>",
          dismiss = "<C-]>",
        },
        -- Keep the AI ghost text visible even when blink's menu auto-shows.
        show_on_completion_menu = true,
      },
    })

    -- :AIModel mirrors <leader>am (the picker), for people who reach for commands.
    vim.api.nvim_create_user_command("AIModel", function()
      require("config.ai_models").open()
    end, { desc = "Pick the Ollama model for AI completions" })

    -- Second half of the stale-ghost-text fix: throttle = 0 above restores the
    -- trailing edge (so a wrong suggestion gets CORRECTED), but on its own it
    -- still lets one land — minuet paints a response without checking the buffer
    -- moved under it, measured at 4 misaligned renders out of 7 even with the
    -- throttle gone. The guard drops those. Both halves are required: the guard
    -- alone would trade wrong ghost text for missing ghost text. Full rationale
    -- and the upstream line numbers live in lua/config/minuet_guard.lua.
    --
    -- Warn rather than fail silently: this wraps a plugin internal upstream makes
    -- no promises about, so a rename would otherwise just quietly restore the bug.
    if not require("config.minuet_guard").install() then
      vim.notify(
        "minuet stale-guard did not attach — completions may render against a stale buffer",
        vim.log.levels.WARN
      )
    end

    -- Multiple cursors: minuet's accept writes the suggestion with
    -- nvim_buf_set_text, and an API edit never enters the redo record, which is
    -- exactly what multicursor replays at the other cursors. Without this the
    -- suggestion lands at the main cursor only and <Esc> never catches the rest
    -- up. Re-expresses that one insertion as nvim_paste while cursors are
    -- alive; the single-cursor path is untouched. Full rationale, and why
    -- keymap.accept above must stay nil, in lua/config/minuet_multicursor.lua.
    if not require("config.minuet_multicursor").install() then
      vim.notify(
        "minuet multicursor accept did not attach — AI accepts will land at one cursor only",
        vim.log.levels.WARN
      )
    end

    -- Establish the initial state now that minuet is up. bootstrap() first checks
    -- that Ollama is installed: if not, it starts disabled (blink keeps its own LSP
    -- ghost text) and says so once; otherwise default-on means blink's inline ghost
    -- text goes OFF (minuet owns it) and the global gate autocmd is installed.
    -- pcall so a hiccup here never aborts minuet's load.
    pcall(require("config.ai").bootstrap)
  end,
}

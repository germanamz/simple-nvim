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
          -- owns whole-suggestion accept (AI-first, then blink menu, then Tab).
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

    -- Establish the initial state now that minuet is up. bootstrap() first checks
    -- that Ollama is installed: if not, it starts disabled (blink keeps its own LSP
    -- ghost text) and says so once; otherwise default-on means blink's inline ghost
    -- text goes OFF (minuet owns it) and the global gate autocmd is installed.
    -- pcall so a hiccup here never aborts minuet's load.
    pcall(require("config.ai").bootstrap)
  end,
}

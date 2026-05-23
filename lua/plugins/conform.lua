-- conform.nvim drives buffer-level formatting on real files. The per-filetype
-- formatter list comes from lua/config/formatters.lua (shared with the
-- markdown fence dispatch in lua/config/options.lua).
--
-- Behavior:
--   • formatexpr is set globally to conform's so `gq` reflows via the
--     configured formatter. Neovim 0.11's default LspAttach also sets
--     formatexpr per-buffer; for filetypes we have a conform formatter for,
--     re-override after attach so conform wins. lsp_format = "fallback" means
--     conform.format() falls back to LSP for filetypes without a conform
--     entry.
--   • <leader>F formats the current buffer (or visual selection) on demand.
--   • No format-on-save: this matches the explicit-trigger workflow (<leader>w
--     for markdown, <leader>F here). Add `format_on_save = { ... }` if you
--     change your mind.
return {
  "stevearc/conform.nvim",
  event = { "BufReadPre", "BufNewFile" },
  cmd = { "ConformInfo" },
  config = function()
    local formatters = require("config.formatters")
    require("conform").setup({
      formatters_by_ft = formatters.by_ft,
      default_format_opts = { lsp_format = "fallback" },
      notify_on_error = true,
    })

    vim.o.formatexpr = "v:lua.require'conform'.formatexpr()"

    vim.api.nvim_create_autocmd("LspAttach", {
      group = vim.api.nvim_create_augroup("conform_formatexpr", { clear = true }),
      callback = function(args)
        local ft = vim.bo[args.buf].filetype
        if formatters.by_ft[ft] then
          vim.bo[args.buf].formatexpr = "v:lua.require'conform'.formatexpr()"
        end
      end,
    })

    vim.keymap.set({ "n", "x" }, "<leader>F", function()
      require("conform").format({ async = false, lsp_format = "fallback" })
    end, { desc = "Format buffer / selection" })
  end,
}

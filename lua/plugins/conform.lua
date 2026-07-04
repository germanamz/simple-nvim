-- conform.nvim drives buffer-level formatting on real files. The per-filetype
-- formatter list comes from lua/config/formatters.lua (its `by_ft` map).
--
-- Behavior:
--   • formatexpr is set globally to conform's so `gq` reflows via the
--     configured formatter. Neovim 0.11's default LspAttach also sets
--     formatexpr per-buffer; for filetypes we have a conform formatter for,
--     re-override after attach so conform wins. lsp_format = "fallback" means
--     conform.format() falls back to LSP for filetypes without a conform
--     entry.
--   • <leader>F formats the current buffer (or visual selection) on demand.
--   • Format-on-save: BufWritePre runs conform synchronously (1000ms cap —
--     black needs ~150ms warm, more cold — then the write proceeds anyway).
--     Skipped on large files (util.largefile): prettier on a big generated
--     json/yaml/markdown artifact would hit the 1s cap and stall every save —
--     the same files skip treesitter and gitsigns painting. <leader>F still
--     formats them on demand.
return {
  "stevearc/conform.nvim",
  event = { "BufReadPre", "BufNewFile" },
  cmd = { "ConformInfo" },
  config = function()
    local formatters = require("config.formatters")
    require("conform").setup({
      -- default_format_opts merges into EVERY conform.format() call (and gq via
      -- formatexpr), so lsp_format policy lives here once — restating it at the
      -- call sites would silently override a change made here.
      formatters_by_ft = formatters.by_ft,
      default_format_opts = { lsp_format = "fallback" },
      notify_on_error = true,
      format_on_save = function(buf)
        if require("util.largefile").is_large(buf) then
          return nil
        end
        return { timeout_ms = 1000 }
      end,
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

    -- The python formatter choice (black vs ruff_format) is memoized per dir in
    -- formatters.lua. Saving a pyproject.toml is the one in-session event that
    -- can flip a [tool.black] decision, so drop the cache on that write and the
    -- next python save re-reads the freshly-edited config.
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = vim.api.nvim_create_augroup("conform_pyproject_cache", { clear = true }),
      pattern = "pyproject.toml",
      callback = function()
        require("config.formatters")._clear_python_cache()
      end,
    })

    -- On-demand format. Unlike on-save (capped at 1000ms and skipped entirely
    -- on large files), <leader>F is an explicit ask, so give it a generous
    -- 10s budget — a multi-MB file genuinely takes a few seconds to format and
    -- the default 1s cap would silently no-op on exactly the files we skip on
    -- save and expect <leader>F to handle.
    vim.keymap.set({ "n", "x" }, "<leader>F", function()
      require("conform").format({ async = false, timeout_ms = 10000 })
    end, { desc = "Format buffer / selection" })
  end,
}

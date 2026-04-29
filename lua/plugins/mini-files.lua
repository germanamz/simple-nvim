return {
  "echasnovski/mini.files",
  version = false,
  keys = {
    {
      "<leader>e",
      function()
        local buf_name = vim.api.nvim_buf_get_name(0)
        local path = buf_name ~= "" and buf_name or vim.fn.getcwd()
        require("mini.files").open(path)
      end,
      desc = "File explorer (current file)",
    },
    {
      "<leader>E",
      function()
        require("mini.files").open(vim.fn.getcwd())
      end,
      desc = "File explorer (cwd)",
    },
  },
  opts = {
    windows = {
      preview = true,
      width_focus = 30,
      width_preview = 50,
    },
    options = {
      use_as_default_explorer = true,
    },
  },
  config = function(_, opts)
    require("mini.files").setup(opts)

    vim.api.nvim_create_autocmd("User", {
      pattern = "MiniFilesBufferCreate",
      callback = function(args)
        vim.keymap.set("n", "q", function()
          require("mini.files").close()
        end, { buffer = args.data.buf_id, desc = "Close mini.files" })
      end,
    })
  end,
}

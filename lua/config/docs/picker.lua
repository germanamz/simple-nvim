-- Telescope picker over the packages this project declares (<leader>kd).
--
-- The counterpart to `gK`: that key answers "what is this symbol", this one
-- answers "what do I depend on, and where are its docs". Rows come from
-- config.docs.deps, which reads manifests off disk — so opening this picker
-- costs no subprocess and no network, and it works on a plane.
--
-- Opens in normal mode like every other picker in this config; press `i` to
-- filter. `<CR>` opens the row's documentation through config.open_url, which
-- puts it in a cmux pane beside Neovim rather than raising a browser app.

local deps = require("config.docs.deps")

local M = {}

--- The coordinate and context a row stands for.
---
--- Rows are package coordinates with no symbol, which is exactly the shape
--- adapters take — no special-casing needed per language. `version` is carried
--- through because the manifest already stated it: this is the free half of
--- version pinning, with no lockfile parsing and no resolution.
---@param row table
---@return DocCoord, DocCtx
function M.coord_for(row)
  return { pkg = row.name, version = row.version, stdlib = row.kind == "stdlib" }, {
    bufnr = 0,
    root = row.root,
    word = row.name or "",
    line = "",
    col = 0,
  }
end

local function make_finder(rows)
  local finders = require("telescope.finders")
  return finders.new_table({
    results = rows,
    entry_maker = function(row)
      local line = deps.format(row)
      return { value = row, display = line, ordinal = line }
    end,
  })
end

function M.open()
  local bufnr = vim.api.nvim_get_current_buf()
  local rows = deps.collect(bufnr)
  if #rows == 0 then
    vim.notify("docs: no dependency manifest found for this project", vim.log.levels.INFO)
    return
  end

  local pickers = require("telescope.pickers")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "Dependency docs",
      finder = make_finder(rows),
      sorter = conf.generic_sorter({}),
      initial_mode = "normal",
      attach_mappings = function(prompt_bufnr, map)
        local function open_selected()
          local entry = action_state.get_selected_entry()
          local row = entry and entry.value
          if not row then
            return
          end
          actions.close(prompt_bufnr)
          if not row.adapter then
            vim.notify("docs: no adapter for " .. (row.name or "?"), vim.log.levels.INFO)
            return
          end
          -- Routed through the driver rather than straight to a URL so this key
          -- keeps the same local-first promise gK makes: `go doc` and `pydoc`
          -- render in the two-pane viewer, and the hosted page is one `o` away.
          local coord, ctx = M.coord_for(row)
          require("config.docs").open_coord(row.adapter, coord, ctx)
        end

        map({ "i", "n" }, "<CR>", open_selected)
        return true
      end,
    })
    :find()
end

return M

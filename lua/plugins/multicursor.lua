-- Multiple cursors: edit every occurrence of a symbol, or the same column down
-- a block of lines, in one pass.
--   • `<C-n>` is the Sublime/VS Code muscle memory — add a cursor at the next
--     match of the word under the cursor (or of the visual selection), then
--     just use Vim normally (`ciw`, `A`, `~`) and every cursor does it.
--   • `<S-Down>` / `<S-Up>` stack cursors down/up a column. macOS binds
--     `<C-Up>`/`<C-Down>` to Mission Control and App Exposé system-wide, so
--     those never reach the terminal; Shift+arrows do, and only shadow the
--     `<C-b>`/`<C-f>` page-scroll aliases.
--   • The remaining verbs hang off a `<leader>c` prefix ("cursors") — `<leader>m`
--     is already the markdown group.
--
-- Highlights are deliberately not configured: the plugin registers
-- MultiCursorCursor/Visual/Sign with `default = true` links to Visual, Search
-- and SignColumn, so they follow github-theme instead of hardcoding colors.
--
-- branch = "1.0" is upstream's stable branch (the repo ships no semver tags),
-- matching the readme's own lazy.nvim example; the exact commit is pinned in
-- lazy-lock.json.
return {
  "jake-stewart/multicursor.nvim",
  branch = "1.0",
  -- Same lazy-load shape as mini.surround: these entries are stubs that load
  -- the plugin and re-feed the key, and the real mappings below take over. The
  -- descs are what which-key shows before the plugin has loaded, so every
  -- trigger carries one (pinned by tests/spec/smoke/which_key_spec.lua).
  keys = {
    { "<C-n>", mode = { "n", "x" }, desc = "Cursor at next match" },
    { "<S-Down>", mode = { "n", "x" }, desc = "Cursor on line below" },
    { "<S-Up>", mode = { "n", "x" }, desc = "Cursor on line above" },
    { "<leader>cN", mode = { "n", "x" }, desc = "Cursor at previous match" },
    { "<leader>cs", mode = { "n", "x" }, desc = "Skip match forward" },
    { "<leader>cS", mode = { "n", "x" }, desc = "Skip match backward" },
    { "<leader>cA", mode = { "n", "x" }, desc = "Cursor at every match" },
    { "<leader>ca", mode = { "n", "x" }, desc = "Cursor per line over motion" },
    { "<leader>cr", desc = "Restore cleared cursors" },
  },
  config = function()
    local mc = require("multicursor-nvim")
    mc.setup()

    local set = vim.keymap.set

    -- Add / skip by matching the word under the cursor or the visual selection.
    -- Skip is the necessary companion to add: without it a false positive in
    -- the middle of a run forces you to start over.
    set({ "n", "x" }, "<C-n>", function()
      mc.matchAddCursor(1)
    end, { desc = "Cursor at next match" })
    set({ "n", "x" }, "<leader>cN", function()
      mc.matchAddCursor(-1)
    end, { desc = "Cursor at previous match" })
    set({ "n", "x" }, "<leader>cs", function()
      mc.matchSkipCursor(1)
    end, { desc = "Skip match forward" })
    set({ "n", "x" }, "<leader>cS", function()
      mc.matchSkipCursor(-1)
    end, { desc = "Skip match backward" })

    -- Column editing: stack cursors down or up from the main one.
    set({ "n", "x" }, "<S-Down>", function()
      mc.lineAddCursor(1)
    end, { desc = "Cursor on line below" })
    set({ "n", "x" }, "<S-Up>", function()
      mc.lineAddCursor(-1)
    end, { desc = "Cursor on line above" })

    set({ "n", "x" }, "<leader>cA", mc.matchAllAddCursors, { desc = "Cursor at every match" })
    -- Operator: `<leader>caip` puts a cursor on every line of a paragraph, and
    -- over a visual selection it does the same for the selected lines.
    set({ "n", "x" }, "<leader>ca", mc.addCursorOperator, { desc = "Cursor per line over motion" })
    set("n", "<leader>cr", mc.restoreCursors, { desc = "Restore cleared cursors" })

    -- Mappings that only exist while there are multiple cursors. The layer sets
    -- them buffer-locally and deletes them when the cursors collapse, so
    -- `<Esc>` goes back to its usual job (clearing search highlight, see
    -- lua/config/options.lua) the moment you are down to one cursor again.
    mc.addKeymapLayer(function(layerSet)
      layerSet({ "n", "x" }, "<Left>", mc.prevCursor, { desc = "Previous cursor" })
      layerSet({ "n", "x" }, "<Right>", mc.nextCursor, { desc = "Next cursor" })
      layerSet({ "n", "x" }, "<leader>cx", mc.deleteCursor, { desc = "Delete this cursor" })
      layerSet("n", "<Esc>", function()
        if not mc.cursorsEnabled() then
          mc.enableCursors()
        else
          mc.clearCursors()
        end
      end, { desc = "Collapse to one cursor" })

      -- Auto-pairs and multiple cursors do not mix. multicursor replays an
      -- insert at the other cursors from `getreg(".")` (the last-inserted-text
      -- register), and mini.pairs adds the closing half through an `expr`
      -- mapping that returns the pair plus a cursor-moving `<C-g>U<Left>`. A
      -- single-line `{` still replays fine, but the moment a `<CR>` lands
      -- inside the pair the register stops holding the whole insert, and the
      -- other cursors receive a truncated replay: the brackets vanish and the
      -- remaining text is dropped at the wrong column.
      --
      -- Mapping the openers to themselves (buffer-locally, for as long as the
      -- cursors live) shadows mini.pairs' global expr mappings, so typing `{`
      -- inserts one literal `{` at every cursor. You close the pair yourself
      -- while multi-cursor editing; normal single-cursor editing is untouched.
      for _, opener in ipairs({ "(", "[", "{", '"', "'", "`" }) do
        layerSet("i", opener, opener, { desc = "Literal " .. opener })
      end
    end)
  end,
}

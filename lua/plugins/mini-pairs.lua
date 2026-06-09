-- Auto-close pairs as you type: when "(", "[", "{", a quote or backtick is
-- typed explicitly, the matching closing symbol is inserted after the cursor.
--   • Lightweight: each trigger key maps to a small function that inspects the
--     neighbouring characters — no rule engine or treesitter queries.
--   • <BS> between an empty pair deletes both characters; <CR> is left alone.
--   • Completion never auto-appends brackets (blink's auto_brackets is off in
--     lua/plugins/completion.lua) — pairs come only from keys you type.
return {
  "echasnovski/mini.pairs",
  version = false,
  event = "InsertEnter",
  opts = {},
}

-- Add / change / delete surroundings (quotes, brackets, tags, custom pairs).
--   • gs-prefixed mappings so they never shadow the native `s`/`S`
--     (substitute char / line) — mini.surround's own default `sa`/`sd`/… would.
--   • Great for wrapping prose (**bold**, [text](link)) and editing code
--     quotes/brackets without retyping the delimiters.
--   • Lazy on first use: the keys below load the plugin, then opts.mappings
--     wires the real surround actions.
-- version = false matches mini.pairs — the mini.* modules ship from a monorepo
-- without semver tags, so pin to the default (latest) branch.
return {
  "echasnovski/mini.surround",
  version = false,
  keys = {
    { "gsa", mode = { "n", "x" }, desc = "Surround add" },
    { "gsd", desc = "Surround delete" },
    { "gsr", desc = "Surround replace" },
    { "gsf", desc = "Surround find" },
    { "gsF", desc = "Surround find left" },
    { "gsh", desc = "Surround highlight" },
    { "gsn", desc = "Surround update n_lines" },
  },
  opts = {
    mappings = {
      add = "gsa",
      delete = "gsd",
      replace = "gsr",
      find = "gsf",
      find_left = "gsF",
      highlight = "gsh",
      update_n_lines = "gsn",
    },
  },
}

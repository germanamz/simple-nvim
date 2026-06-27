-- Single source for the "list every file under the cwd" command shared by the
-- two file pickers (telescope_smart's list_all and telescope's find_files).
-- rg/fd honor each (sub)repo's .gitignore; the `find` fallback honors nothing,
-- so it gets explicit excludes for the heavy dirs a polyglot superproject is
-- full of — a bare find would otherwise walk every node_modules / target /
-- .venv across every submodule.
--
-- Two callers, two small dialect differences, expressed as opts:
--   opts.hidden      — emit `--hidden` (telescope_smart's list_all lists
--                      dotfiles itself rather than leaning on telescope).
--   opts.color_never — emit `--color never` (telescope's find_files lets
--                      telescope append --hidden / --no-ignore from picker opts,
--                      so it only needs rg/fd output kept plain).
-- The `find` branch ignores both: it has no color output and already walks
-- hidden files, so the heavy-dir excludes are all it needs.
local M = {}

-- Returns a FRESH command table on every call: telescope's find_files mutates
-- the command in place to append --hidden / --no-ignore from opts, so a shared
-- table would accumulate them across opens.
function M.list_files_cmd(opts)
  opts = opts or {}
  if vim.fn.executable("rg") == 1 then
    local cmd = { "rg", "--files" }
    if opts.hidden then
      table.insert(cmd, "--hidden")
    end
    if opts.color_never then
      table.insert(cmd, "--color")
      table.insert(cmd, "never")
    end
    vim.list_extend(cmd, { "--glob", "!.git" })
    return cmd
  elseif vim.fn.executable("fd") == 1 then
    local cmd = { "fd", "--type", "f" }
    if opts.hidden then
      table.insert(cmd, "--hidden")
    end
    if opts.color_never then
      table.insert(cmd, "--color")
      table.insert(cmd, "never")
    end
    vim.list_extend(cmd, { "--exclude", ".git" })
    return cmd
  end
  return {
    "find",
    ".",
    "-type",
    "f",
    "-not",
    "-path",
    "*/.git/*",
    "-not",
    "-path",
    "*/node_modules/*",
    "-not",
    "-path",
    "*/.venv/*",
    "-not",
    "-path",
    "*/target/*",
    "-not",
    "-path",
    "*/build/*",
    "-not",
    "-path",
    "*/dist/*",
  }
end

return M

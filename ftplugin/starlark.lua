-- Starlark (`.star`, and Tiltfiles via ftplugin/tiltfile.lua). The runtime
-- ships no ftplugin for either filetype, so without this `gcc` has no comment
-- string and buffers get the config's global 2-space indent. Starlark is a
-- Python dialect: `#` comments, and 4-space indent — what buildifier emits and
-- what the runtime's python ftplugin gives python buffers here.
if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = 1

vim.bo.commentstring = "# %s"
vim.bo.comments = "b:#"
vim.bo.expandtab = true
vim.bo.shiftwidth = 4
vim.bo.softtabstop = 4

vim.b.undo_ftplugin = "setlocal commentstring< comments< expandtab< shiftwidth< softtabstop<"

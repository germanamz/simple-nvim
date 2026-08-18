-- Tiltfiles are Starlark: same comment string and indent. Core detects the
-- filetype (Tiltfile, Tiltfile.local, *.tiltfile) but has no ftplugin for it.
vim.cmd.runtime("ftplugin/starlark.lua")

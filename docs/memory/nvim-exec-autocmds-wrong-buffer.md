---
type: memory
title: "Nvim_exec_autocmds fires on the wrong buffer"
kind: reference
description: "nvim_exec_autocmds({buffer=b}) sets <abuf> but never makes b current, so ftplugins setlocal onto the buffer you are standing in; wrap in nvim_buf_call."
---

# Nvim_exec_autocmds fires on the wrong buffer

`vim.api.nvim_exec_autocmds("FileType", { buffer = b })` fires the handlers with
`<abuf>` / `args.buf` set to `b`, but it does **not** switch the current buffer
(unlike `:doautoall`). Handlers that read the current buffer instead of the event
buffer therefore act on whatever you are standing in. `$VIMRUNTIME/ftplugin/lua.lua`
is the canonical case: it calls `vim.treesitter.start()` with no bufnr, so a
FileType fire aimed at a hidden lua buffer tries to start a lua parser on the
current buffer and errors `Parser not found for buffer 1: language could not be
determined`. Every `setlocal` in a runtime ftplugin has the same aim problem —
firing FileType for a python buffer while in a lua buffer applies python's
options to the lua one.

Fix: `vim.api.nvim_buf_call(b, function() vim.api.nvim_exec_autocmds(...) end)`.
`nvim_buf_call` uses the autocmd window, so it works on a buffer in no window.

Found re-attaching LSP clients (`config.lsp_picker`'s restart cycle re-fires
FileType because that is the hook `vim.lsp.enable` installs). `vim.lsp.enable`'s
own handler reads `args.buf` and so never noticed the bug — only the ftplugins
did. Surfaced as *test output noise*, not a failure, which is why "output must be
pristine" is worth enforcing: the error was printed by a passing spec.

Related: [[nvim-hidden-buffer-edit-traps]], [[nvim-headless-window-height]].

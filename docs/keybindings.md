# Keybindings & Navigation Cheatsheet

A flat, searchable reference for this config plus the Neovim built-ins that
are easy to forget. Use `Ctrl-F` (or `/` inside Neovim) to jump to a section.

Leader = `<Space>` · Local leader = `\`

> **Jumping to a section:** put the cursor on a TOC entry and press `gd`
> (marksman LSP follows the markdown link), or just type `/## N` where `N`
> is the section number (e.g. `/## 13` → Telescope). `]]` / `[[` step
> between headings; `gg` returns to the top.

## Table of contents

1. [Forget-me-not: top 20](#1-forget-me-not-top-20)
2. [Discover keymaps live](#2-discover-keymaps-live)
3. [Moving inside a buffer](#3-moving-inside-a-buffer)
4. [Windows (splits)](#4-windows-splits)
5. [Buffers](#5-buffers)
6. [Tabs](#6-tabs)
7. [Marks & jumps](#7-marks--jumps)
8. [Search & replace](#8-search--replace)
9. [Editing](#9-editing)
10. [Visual mode & text objects](#10-visual-mode--text-objects)
11. [Registers (yank / paste)](#11-registers-yank--paste)
12. [Folds](#12-folds)
13. [Telescope (find)](#13-telescope-find)
14. [LSP](#14-lsp)
15. [Diagnostics](#15-diagnostics)
16. [Git: gitsigns hunks](#16-git-gitsigns-hunks)
17. [Git: review base](#17-git-review-base)
18. [Markdown / MDX](#18-markdown--mdx)
19. [Formatting](#19-formatting)
20. [Treesitter context](#20-treesitter-context)
21. [Command-line tricks](#21-command-line-tricks)
22. [Sessions](#22-sessions)
23. [Known conflicts](#23-known-conflicts)

---

## 1. Forget-me-not: top 20

| Keys              | Action                                                |
| ----------------- | ----------------------------------------------------- |
| `<Space><Space>`  | Files picker (changed-first ordering)                 |
| `<Space>ff`       | Find files                                            |
| `<Space>fg`       | Live grep (from project/git root)                     |
| `<Space>fb`       | Buffer list                                           |
| `<Space>f/`       | Fuzzy find inside current buffer                      |
| `<Space>?`        | Telescope keymaps (searchable list of *everything*)   |
| `<Space>K`        | which-key popup (live, grouped)                       |
| `<Space>k?`       | Open *this* cheatsheet                                |
| `<Space>e`        | nvim-tree file tree (reveals current file)            |
| `<Space>E`        | Open netrw file tree in current window                |
| `gd`              | Go to definition (LSP)                                |
| `K`               | Hover docs (LSP default)                              |
| `]c` / `[c`       | Next / previous git hunk                              |
| `]d` / `[d`       | Next / previous diagnostic (Nvim 0.11 default)        |
| `]r` / `[r`       | Next / previous LSP reference in current buffer       |
| `<Space>gB`       | Pick a review base branch                             |
| `<Space>F`        | Format buffer (or selection)                          |
| `<C-w>` then `hjkl` | Move between split windows                          |
| `:q` / `:wq` / `ZZ` | Close / save+close / save+close                     |

---

## 2. Discover keymaps live

Use these when you forget anything else in this doc.

| Keys           | Action                                                        |
| -------------- | ------------------------------------------------------------- |
| `<Space>?`     | Telescope `keymaps` — fuzzy-searchable list of every binding  |
| `<Space>k?`    | Open `docs/keybindings.md` (this file) from anywhere          |
| `<Space>K`     | which-key global popup (browse by prefix)                     |
| `<Space>fc`    | Telescope `commands` — all `:Ex` commands                     |
| `<Space>fh`    | Telescope `help_tags` — fuzzy across `:help`                  |
| `:map`         | Raw list of every mapping (no filter)                         |
| `:verbose map <lhs>` | Show *where* a mapping was defined                      |
| `:WhichKey`    | which-key for current prefix                                  |

Inside which-key: just keep typing the prefix; pause and the menu appears.
`<BS>` goes back one level.

---

## 3. Moving inside a buffer

### Per-character

| Keys        | Action                                  |
| ----------- | --------------------------------------- |
| `h j k l`   | left / down / up / right                |
| `0`         | first column                            |
| `^`         | first non-blank                         |
| `$`         | end of line                             |
| `g_`        | last non-blank                          |

### Per-word

| Keys        | Action                                  |
| ----------- | --------------------------------------- |
| `w` / `W`   | next word start (small / WORD)          |
| `e` / `E`   | next word end                           |
| `b` / `B`   | previous word start                     |
| `ge` / `gE` | previous word end                       |

(`W/E/B` use whitespace-only boundaries — useful for paths, URLs.)

### Per-line / find-char

| Keys           | Action                                       |
| -------------- | -------------------------------------------- |
| `f{c}` / `F{c}`| jump to next/prev `{c}` on this line         |
| `t{c}` / `T{c}`| jump *before* next/prev `{c}` on this line   |
| `;` / `,`      | repeat last `fFtT` forward / backward        |

### Per-paragraph / section

| Keys      | Action                                  |
| --------- | --------------------------------------- |
| `{` / `}` | previous / next blank-line paragraph    |
| `[[` `]]` | previous / next section (lang-aware)    |
| `%`       | matching bracket `(` `[` `{`            |

### Per-screen / per-file

| Keys              | Action                                  |
| ----------------- | --------------------------------------- |
| `<C-d>` / `<C-u>` | half-page down / up                     |
| `<C-f>` / `<C-b>` | full-page forward / back                |
| `<C-e>` / `<C-y>` | scroll view down / up by one line       |
| `H` / `M` / `L`   | top / middle / bottom of visible window |
| `zz` / `zt` / `zb`| recenter view (cursor middle/top/bot)   |
| `gg` / `G`        | first / last line                       |
| `{N}gg` / `:{N}`  | jump to line N                          |
| `%`               | (in normal) percent-of-file → see `:h N%` |

### Scrolloff

`scrolloff = 8` and `sidescrolloff = 8` — the cursor never reaches the
last 8 lines / columns. Adjust with `:set scrolloff=0` if you want.

---

## 4. Windows (splits)

All window commands start with `<C-w>` (Ctrl-W). `splitbelow` and
`splitright` are on, so new splits open below / to the right.

### Create

| Keys              | Action                       |
| ----------------- | ---------------------------- |
| `:split`  / `<C-w>s` | horizontal split          |
| `:vsplit` / `<C-w>v` | vertical split            |
| `:new`    / `<C-w>n` | new horizontal empty buf  |
| `:vnew`              | new vertical empty buf    |

### Move focus

| Keys             | Action                              |
| ---------------- | ----------------------------------- |
| `<C-w>h/j/k/l`   | move to left / down / up / right    |
| `<C-w>w`         | cycle to next window                |
| `<C-w>p`         | go to previous (last-focused)       |
| `<C-w>t` / `<C-w>b` | top-left / bottom-right window   |

### Move / resize

| Keys              | Action                                 |
| ----------------- | -------------------------------------- |
| `<C-w>H/J/K/L`    | move window to far left/bottom/top/right |
| `<C-w>r` / `<C-w>R` | rotate windows                       |
| `<C-w>x`          | swap with next                         |
| `<C-w>=`          | equalize sizes                         |
| `<C-w>_`          | maximize height                        |
| `<C-w>|`          | maximize width                         |
| `<C-w>+` / `<C-w>-` | grow / shrink height                 |
| `<C-w>>` / `<C-w><` | grow / shrink width                  |
| `<C-w>o`          | close all *other* windows (only-one)   |
| `<C-w>c` / `:close` | close current window                 |
| `<C-w>q` / `:q`   | quit window (last → quit Nvim)         |

---

## 5. Buffers

`clipboard=unnamedplus` — yanks go to the system clipboard automatically.

| Keys / cmd                     | Action                                |
| ------------------------------ | ------------------------------------- |
| `<Space>fb`                    | Telescope buffer list                 |
| `:bn` / `:bp`                  | next / previous buffer                |
| `:b {n}` or `:b name<Tab>`     | jump to buffer by number / fuzzy name |
| `<C-^>` (`<C-6>`)              | swap with alternate (last) buffer     |
| `:bd`                          | close (delete) current buffer         |
| `:bd!`                         | force close, discard changes          |
| `:bufdo {cmd}`                 | run cmd in every loaded buffer        |
| `:ls`                          | list buffers                          |

Tip: `<Space>fb` is faster than `:ls` and lets you `<C-d>` in insert mode to
delete the buffer under the cursor.

`<Space>e` opens nvim-tree and reveals the current file, expanding the whole
ancestry from the project root down to it (and tracking the focused buffer as
you switch). Press `<Space>e` again to close it. Inside the tree: `<CR>` opens
a file / toggles a folder, `a` creates a file (type `foo/bar.lua` to make the
intermediate dirs too; trailing `/` makes a directory), `d` deletes, `r`
renames, `H` toggles dotfiles, `I` toggles gitignored files, `g?` shows all
mappings.

`<Space>E` opens netrw (`:Explore`) in the current window using the tree
listing style (`g:netrw_liststyle = 3`) with the banner hidden. The previous
buffer stays loaded — `<C-^>` or `:b#` returns to it. Inside netrw: `<CR>` on
a folder expands/collapses it in place, `<CR>` on a file opens it, `-` goes
up, `D` deletes, `R` renames, `%` creates a file, `d` makes a directory.

---

## 6. Tabs

Tabs in Vim are *layout pages*, not browser tabs. Use sparingly.

| Cmd                | Action                       |
| ------------------ | ---------------------------- |
| `:tabnew {file}`   | new tab                      |
| `:tabclose`        | close current tab            |
| `:tabonly`         | close all other tabs         |
| `gt` / `gT`        | next / previous tab          |
| `{N}gt`            | jump to tab N                |
| `:tabs`            | list tabs                    |

---

## 7. Marks & jumps

### Marks

| Keys           | Action                                              |
| -------------- | --------------------------------------------------- |
| `m{a-z}`       | set buffer-local mark `a`–`z`                       |
| `m{A-Z}`       | set global mark (persists across files / restarts)  |
| `` `{mark} ``  | jump to mark (exact row+col)                        |
| `'{mark}`      | jump to start of mark's line                        |
| `:marks`       | list all marks                                      |
| `:delmarks a b`| delete specific marks                               |

Useful auto-marks: `` `. `` = last edit, `` `^ `` = last insert, `` `[ `` /
`` `] `` = start/end of last change or yank.

### Jump list (file-position history)

| Keys     | Action                                  |
| -------- | --------------------------------------- |
| `<C-o>`  | jump *back* in jumplist                 |
| `<C-i>`  | jump *forward* (same as `<Tab>`)        |
| `:jumps` | list                                    |

### Change list

| Keys   | Action                            |
| ------ | --------------------------------- |
| `g;`   | older change                      |
| `g,`   | newer change                      |

---

## 8. Search & replace

`ignorecase` + `smartcase`: lowercase pattern = case-insensitive; any
uppercase = case-sensitive. `incsearch` + `hlsearch` are on.

### Search

| Keys             | Action                                       |
| ---------------- | -------------------------------------------- |
| `/pattern`       | search forward                               |
| `?pattern`       | search backward                              |
| `n` / `N`        | next / previous match                        |
| `*` / `#`        | search word under cursor forward / backward  |
| `g*` / `g#`      | …without word boundaries                     |
| `:noh`           | clear current highlight                      |
| `<Esc>`          | clear search highlight + pattern (normal mode) |
| `<Space>fs`      | Telescope grep-string of word under cursor   |
| `<Space>fg`      | Telescope live grep across project           |
| `<Space>f/`      | Fuzzy find within current buffer             |

### Replace

| Cmd                          | Action                                       |
| ---------------------------- | -------------------------------------------- |
| `:s/old/new/`                | replace first on current line                |
| `:s/old/new/g`               | replace all on current line                  |
| `:%s/old/new/g`              | replace all in buffer                        |
| `:%s/old/new/gc`             | …with confirm                                |
| `:%s/\<word\>/new/g`         | whole-word only                              |
| `:'<,'>s/old/new/g`          | in visual selection                          |
| `:cdo s/old/new/g | update`  | replace across quickfix entries              |
| `:argdo %s/old/new/ge | up`  | replace across `:args` files                 |

---

## 9. Editing

`smartindent` is on; indent = 2 spaces; tabs become spaces.

### Entering insert

| Keys        | Action                                |
| ----------- | ------------------------------------- |
| `i` / `a`   | insert before / after cursor          |
| `I` / `A`   | insert at line start (non-blank) / end|
| `o` / `O`   | new line below / above                |
| `s` / `S`   | delete char / line then insert        |
| `c{motion}` | change over motion (e.g. `ciw`, `c$`) |
| `C`         | change to end of line                 |
| `R`         | replace mode                          |
| `gi`        | insert at last insert position        |

### Deleting

| Keys       | Action                            |
| ---------- | --------------------------------- |
| `x` / `X`  | delete char under / before cursor |
| `d{motion}`| delete over motion                |
| `dd`       | delete line                       |
| `D`        | delete to end of line             |

### Misc

| Keys          | Action                                            |
| ------------- | ------------------------------------------------- |
| `u` / `<C-r>` | undo / redo                                       |
| `.`           | repeat last change                                |
| `J`           | join line below into current                      |
| `gJ`          | join without inserting a space                    |
| `~`           | toggle case of char under cursor                  |
| `g~{motion}`  | toggle case over motion                           |
| `gu` / `gU`   | lowercase / uppercase over motion                 |
| `>>` / `<<`   | indent / dedent line                              |
| `==`          | re-indent line                                    |
| `gq{motion}`  | reformat (uses formatexpr → conform / LSP / `gq`) |
| `<Space>F`    | format buffer or visual selection (conform)       |

In insert mode: `<C-w>` deletes last word, `<C-u>` deletes to start of line,
`<C-h>` is backspace, `<C-o>` runs one normal-mode command then returns.

### Surround (mini.surround)

`mini.surround` adds / changes / removes the brackets, quotes, or tags *around*
a text object. All maps share the `gs` prefix so they don't shadow the built-in
`s` (substitute) or any single-key motion.

| Keys          | Action                                            |
| ------------- | ------------------------------------------------- |
| `gsa` (n / x) | add surround around a motion / selection          |
| `gsd`         | delete the surrounding pair                       |
| `gsr`         | replace the surrounding pair                      |
| `gsf` / `gsF` | find next / previous surround                     |
| `gsh`         | highlight the surrounding pair                    |
| `gsn`         | update the `n_lines` search range                 |

---

## 10. Visual mode & text objects

### Enter visual

| Keys      | Action                  |
| --------- | ----------------------- |
| `v`       | char-wise               |
| `V`       | line-wise               |
| `<C-v>`   | block-wise              |
| `gv`      | re-select last visual   |

### Operations on selection

| Keys     | Action                                     |
| -------- | ------------------------------------------ |
| `d` / `x`| delete                                     |
| `y`      | yank                                       |
| `c`      | change                                     |
| `>` / `<`| indent / dedent                            |
| `=`      | re-indent                                  |
| `u` / `U`| lowercase / uppercase                      |
| `~`      | toggle case                                |
| `o`      | move to other end of selection             |
| `:`      | run an Ex command on the selection         |

### Text objects (use after `d`, `c`, `y`, `v`)

`i` = inner (no surrounding chars), `a` = around (with chars).

| Object | Examples                                  |
| ------ | ----------------------------------------- |
| `iw` / `aw` | word                                 |
| `iW` / `aW` | WORD (whitespace-delimited)          |
| `is` / `as` | sentence                             |
| `ip` / `ap` | paragraph                            |
| `i"` / `a"` | inside / around double quotes        |
| `i'` `a'` `` i` `` `` a` `` | quotes / backticks   |
| `i(` `i)` `ib` | inside parentheses                |
| `i{` `i}` `iB` | inside braces                     |
| `i[` `i]`      | inside brackets                   |
| `it` / `at`    | inside / around xml/html tag      |

### Block-wise tricks (`<C-v>`)

- `<C-v>` then `j` to select column → `I{text}<Esc>` inserts on every line.
- `<C-v>` → `$A{text}<Esc>` appends at end of every selected line.
- `<C-v>` then `c` to replace, `<Esc>` propagates the change.

---

## 11. Registers (yank / paste)

`clipboard=unnamedplus` means default yank/paste uses `+` (system).

| Keys             | Action                                        |
| ---------------- | --------------------------------------------- |
| `y{motion}` `yy` | yank                                          |
| `p` / `P`        | paste after / before cursor                   |
| `"{r}y` / `"{r}p`| use register `r`                              |
| `"0p`            | paste from yank register (not from delete)    |
| `"+y` / `"+p`    | system clipboard explicitly                   |
| `"*y` / `"*p`    | primary selection (X11)                       |
| `"_d`            | "black hole" delete — does not pollute reg    |
| `:reg` / `:reg a`| list registers / show register `a`            |
| (insert) `<C-r>{r}` | paste register `r` while in insert mode    |

OSC52: in containers / SSH sessions the config installs an OSC52 clipboard
provider so `"+y` works through your terminal.

---

## 12. Folds

Treesitter-driven folds (`foldmethod=expr`, `foldexpr=v:lua.vim.treesitter.foldexpr()`).
File opens fully unfolded (`foldlevelstart=99`). `foldcolumn=1` shows fold markers.

| Keys      | Action                                  |
| --------- | --------------------------------------- |
| `za`      | toggle fold under cursor                |
| `zA`      | toggle fold recursively                 |
| `zo` / `zc` | open / close fold                     |
| `zO` / `zC` | open / close recursively              |
| `zR` / `zM` | open all / close all                  |
| `zj` / `zk` | jump to next / previous fold start    |

---

## 13. Telescope (find)

All under `<Space>f` (group: "find").

| Keys           | Action                                          |
| -------------- | ----------------------------------------------- |
| `<Space><Space>` | Smart files picker — changed-first ordering   |
| `<Space>ff`    | Find files (respects `.gitignore`)              |
| `<Space>fi`    | Find files *including* gitignored / hidden      |
| `<Space>fg`    | Live grep (from project/git root)               |
| `<Space>fs`    | Grep word under cursor (from project/git root)  |
| `<Space>fb`    | Buffers                                         |
| `<Space>fr`    | Recent files (`oldfiles`)                       |
| `<Space>fR`    | Resume last picker                              |
| `<Space>fh`    | Help tags                                       |
| `<Space>fd`    | Diagnostics across project                      |
| `<Space>fo`    | Document symbols (LSP)                          |
| `<Space>fS`    | Workspace symbols (LSP)                         |
| `<Space>?`     | Keymaps                                         |
| `<Space>fc`    | Commands                                        |
| `<Space>f/`    | Fuzzy find inside current buffer                |

### Inside the picker (insert mode)

| Keys           | Action                              |
| -------------- | ----------------------------------- |
| `<C-j>` / `<C-k>` | next / previous selection        |
| `<C-n>` / `<C-p>` | next / previous **history**      |
| `<C-u>` / `<C-d>` | scroll preview up / down         |
| `<C-/>`           | show available picker mappings   |
| `<Tab>` / `<S-Tab>` | toggle multi-select            |
| `<C-q>`           | send selection to quickfix       |
| `<CR>`            | open in current window           |
| `<C-x>` / `<C-v>` / `<C-t>` | open in split / vsplit / tab |
| `<Esc>`           | close picker (single-press)      |

---

## 14. LSP

Buffer-local — these only exist in buffers with an attached LSP client.

| Keys         | Action                                                  |
| ------------ | ------------------------------------------------------- |
| `gd`         | go to definition (ts_ls: source via `_typescript.goToSourceDefinition`) |
| `gD`         | go to **declaration** (Nvim 0.11 default)               |
| `grr`        | references (Nvim 0.11 default — opens loclist)          |
| `gri`        | implementations (Nvim 0.11 default)                     |
| `grn`        | rename symbol (Nvim 0.11 default)                       |
| `gra`        | code action (Nvim 0.11 default)                         |
| `K`          | hover docs (Nvim 0.11 default)                          |
| `<C-s>` (insert) | signature help (Nvim 0.11 default)                  |
| `]r` / `[r`  | next / previous LSP **reference** in this buffer        |
| `]d` / `[d`  | next / previous **diagnostic** (Nvim 0.11 default)      |
| `<C-w>d`     | show diagnostic float (Nvim 0.11 default)               |
| `<Space>uh`  | Toggle inlay hints (off; only when server supports them)|

Statusline shows `⇄N` when the cursor is on a symbol with `N` references in
the current buffer.

Inlay hints are off by default; `<Space>uh` toggles them per buffer and is only
mapped when the attached server advertises `textDocument/inlayHint`.

### Servers configured

ts_ls, pyright, gopls, rust_analyzer, lua_ls, bashls, jsonls, yamlls, taplo,
html, cssls, marksman, mdx_analyzer. Each attaches only on its `filetypes`.

### Useful commands

| Cmd                | Purpose                                |
| ------------------ | -------------------------------------- |
| `:LspInfo`         | which clients are attached & their state |
| `:LspLog`          | tail the LSP log                       |
| `:LspRestart`      | restart attached clients               |
| `:Mason`           | manage server binaries                 |
| `:checkhealth lsp` | diagnose attach problems               |

---

## 15. Diagnostics

| Keys          | Action                                  |
| ------------- | --------------------------------------- |
| `]d` / `[d`   | next / previous diagnostic              |
| `<C-w>d`      | show diagnostic float at cursor          |
| `<Space>fd`   | Telescope: all diagnostics              |
| `:diagnostic` | core API; see also `vim.diagnostic.*`    |

Gutter signs are themed nerd-font glyphs keyed by severity (error / warn / info
/ hint), with the highest severity winning a shared line. Inline virtual text
stays off on purpose — the full message surfaces in a float when the cursor
rests on a diagnostic (after `updatetime`), keeping the UI quiet.

---

## 16. Git: gitsigns hunks

Active on every loaded buffer. Word-level inline diff is rendered with
background highlights (no sign column — `signcolumn=false`).

| Keys         | Action                                       |
| ------------ | -------------------------------------------- |
| `]c` / `[c`  | next / previous hunk                         |
| `<Space>hp`  | preview hunk (popup)                         |
| `<Space>hi`  | preview hunk **inline**                      |
| `<Space>hs`  | stage hunk                                   |
| `<Space>hr`  | reset hunk                                   |
| `<Space>hb`  | full blame for current line                  |
| `<Space>hB`  | toggle the always-on line blame virtual text |
| `<Space>hd`  | diff against index                           |
| `<Space>ht`  | toggle deleted-lines display                 |
| `<Space>gR`  | refresh git hunks & status (manual)          |

All git displays auto-refresh when nvim regains focus (so an external
commit/stage shows up on return): gitsigns hunks, the statusline branch/base
and hunk counts, and the file-tree's git decorations. `<Space>gR` forces the
same refresh for terminals that don't forward focus events.

Statusline: ` +A ~C -D ↑above ↓below ` summary.

---

## 17. Git: review base

Per-repo "review base" ref: gitsigns diffs against it (instead of HEAD), and
the smart files picker surfaces files changed since it.

| Keys         | Action                                              |
| ------------ | --------------------------------------------------- |
| `<Space>gB`  | pick a base branch (auto-opens Telescope files)     |
| `<Space>gX`  | clear the review base                               |

Stored per repo on disk; auto-applies on buffer attach.

### Git pickers (Telescope)

Telescope-backed git pickers (also under `<Space>g`):

| Keys         | Action                                              |
| ------------ | --------------------------------------------------- |
| `<Space>gc`  | Git commits (repo log)                              |
| `<Space>gC`  | Git commits for the current file                    |
| `<Space>gt`  | Git status (changed files)                          |
| `<Space>gv`  | Diff changed files vs the review base               |

---

## 18. Markdown / MDX

Active in `markdown` and `mdx` buffers. Prose is never auto-hard-wrapped
(`formatoptions` has `t` removed), and long lines scroll horizontally rather than
soft-wrapping. The gutter shows section / paragraph numbers (see below).

Spellcheck is on by default in these buffers (`spelllang=en`, `spelloptions=camel`
so CamelCase identifiers split into checkable words). Move between misspellings
with `]s` / `[s`, and `z=` lists suggestions for the word under the cursor.

| Keys         | Action                                                  |
| ------------ | ------------------------------------------------------- |
| `gq{motion}` | reflow one motion's worth (via `formatexpr`)            |
| `<Space>F`   | run conform's markdown formatter                        |
| `<Space>mp`  | toggle live `glow` preview (read-only side pane)        |
| `gd`         | follow wiki/standard link under cursor (else LSP definition) |

`<Space>mp` opens a read-only, **full-color** preview split on the right that
renders the buffer through [`glow`](https://github.com/charmbracelet/glow) inside a
terminal buffer. It reflows prose *and* keeps wide tables aligned (cells wider than
the pane are truncated with `…`, not shattered) — so it sidesteps the wrap-vs-table
problem that plain soft-wrap can't. Every link renders as just its styled text:
wiki-style links (`[[note]]`, `[[note|alias]]`) are rewritten so glow renders them
(it doesn't grok them natively), and standard `[text](dest)` links have their URL
tail stripped (glow would otherwise print the full path/URL after the text). The
links stay usable — press `gd` on one in the preview to follow it (see below).
It renders the **live buffer** (written to a
private temp file, so you never have to save your document) and refreshes on save,
when you leave insert mode, and after normal-mode edits (debounced) — not on every
keystroke, to limit the redraw flicker from re-running glow. Scroll approximately
syncs to the source cursor (glow reflows, so the match is by % through the
document, not line-for-line). Toggle again to close. Requires the `glow` binary
(`brew install glow`); without it the keymap notifies once and does nothing.

`gd` follows the link under the cursor — wiki or standard — falling back to LSP
go-to-definition when the cursor isn't on one. It works the same in the source
buffer and in the `glow` preview (where the rendered text is matched back to the
source, since glow drops link destinations). Wikilinks are project-scoped:
`[[a/b/c]]` opens `<project root>/a/b/c.md`, where the root is found by walking up
for a `.git` / `.marksman.toml` / `tusk.toml` / `.tusk` marker. `[[target|alias]]`
and `[[target#heading]]` work too (alias/heading are ignored for resolution).
Standard `[text](dest)` links follow their destination: a relative or absolute
file path opens the file (resolved against the current file's directory), and an
external URL (`http(s):`, `mailto:`, …) opens via the system handler. `<C-^>`
returns to the previous file.

The gutter shows section / paragraph numbers (`§1.2¶3` style). Headings
H2–H6 form the dotted path; H1 is ignored. Scratchpad blockquotes
(`> Mental Note`, `> TODO`, `> Note to self`, `> Draft note`) and HTML
comments are not numbered.

---

## 19. Formatting

`conform.nvim` drives formatting. `formatexpr` is set to conform's globally,
so `gq{motion}` uses the configured formatter. Falls back to LSP for
filetypes without a conform entry.

| Keys         | Action                                          |
| ------------ | ----------------------------------------------- |
| `<Space>F`   | format buffer (or visual selection) on demand   |
| `gq{motion}` | format one motion's worth via `formatexpr`      |
| `:ConformInfo` | which formatter applies to current buffer     |

Format-on-save is on: `BufWritePre` runs conform synchronously (1000 ms cap, LSP
fallback), skipped on very large files (see `lua/util/largefile.lua`). `<Space>F`
and `gq{motion}` remain the on-demand paths.

---

## 20. Treesitter context

Sticky scope headers at the top of the window (function / class / heading).

| Keys         | Action                       |
| ------------ | ---------------------------- |
| `<Space>ut`  | toggle treesitter context    |

---

## 21. Command-line tricks

In `:` command-line mode:

| Keys                | Action                                       |
| ------------------- | -------------------------------------------- |
| `<Tab>` / `<S-Tab>` | complete next / previous                     |
| `<C-d>`             | list all completions                         |
| `<C-r>{r}`          | insert register `r` (e.g. `<C-r>"` = yank)   |
| `<C-r><C-w>`        | insert word under cursor                     |
| `<C-f>`             | open command-line window (full editor)       |
| `q:` (normal)       | open command history window                  |
| `q/` `q?` (normal)  | open search history window                   |

In the command-line window: `<CR>` runs the line; `:q` to close.

Other helpful Ex bits:

| Cmd                       | Action                                  |
| ------------------------- | --------------------------------------- |
| `:%y+`                    | yank whole buffer into system clipboard |
| `:g/pattern/d`            | delete every line matching              |
| `:g!/pattern/d` / `:v/p/d`| delete every *non*-matching line        |
| `:sort` / `:sort u`       | sort buffer (unique)                    |
| `:earlier 5m` / `:later`  | time-travel undo                        |

---

## 22. Sessions

`persistence.nvim` auto-saves a session per working directory (window layout,
open buffers, cwd). Nothing is restored automatically — pick a restore on demand.

| Keys         | Action                          |
| ------------ | ------------------------------- |
| `<Space>ql`  | restore the session for the cwd |
| `<Space>qL`  | restore the last saved session  |

---

## 23. Known conflicts

### `gd` — depends on filetype

- **LSP buffers (non-ts_ls):** `vim.lsp.buf.definition`.
- **TypeScript buffers (ts_ls):** custom "go to source definition" that
  follows imports through, falling back to standard `definition` if the
  command returns nothing.
- **Markdown / MDX buffers:** follows the link under the cursor — a
  `[[wikilink]]` (project-root path), or a standard `[text](dest)` link (file
  opened relative to the current file, external URL opened via the system
  handler) — falling back to `vim.lsp.buf.definition` when the cursor isn't on a
  link.

### `<Esc>` in Telescope

Single press closes the picker (not "go to normal mode inside the picker").

---

## See also

- `:help quickref` — Vim's own one-page cheatsheet.
- `:help index` — every default mapping by mode.
- `:help lua-guide` — Nvim Lua API.
- `lua/plugins/*.lua` — source of truth for plugin keymaps in this config.
- `lua/config/options.lua` — editor options & markdown autocommands.

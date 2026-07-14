-- Smart file pickers with git-status-aware prefixes.
--
-- After `M.setup()` runs, telescope's `make_entry.gen_from_file` is wrapped
-- so the same prefixes appear in every file-listing picker (find_files,
-- oldfiles, the smart pickers, etc.). Codes are cached per-cwd for ~500ms
-- so successive picker opens don't re-shell out to git.
--
-- Prefix scheme (single dominant letter + color):
--     A   added       (green)
--     M   modified    (blue)
--     D   deleted     (gray)
--     R   renamed     (teal)
--     ?   untracked   (brown)
--
-- A trailing '*' marks the file as having unstaged worktree changes.
-- Absence of '*' means the change is fully staged:
--     A     staged add
--     M     staged modification
--     M*    worktree modification (unstaged or staged+further edits)
--     D     staged delete
--     D*    worktree delete
--     ?*    untracked (always shown with '*')
--     R     staged rename
--
-- When a review base is set (see config.review_base), files that differ
-- from the base in committed history but have no current worktree change
-- get a leading 'b' (purple), with the type letter retaining its color:
--     bA   added in a commit since base
--     bM   modified in a commit since base
--     bD   deleted in a commit since base
--     bR   renamed in a commit since base

local M = {}

local review_base = require("config.review_base")
local git = require("util.git")
local git_status_codes = require("config.git_status_codes")
local Overlay = require("util.overlay")
local picker_legend = require("util.picker_legend")
local path_util = require("util.path")
local palette = require("config.palette")
local fs = require("util.fs")
local pool = require("util.pool")

-- ===================== helpers =====================

local function parse_status_path(raw)
  local arrow = raw:find(" %-> ")
  if arrow then
    raw = raw:sub(arrow + 4)
  end
  return (raw:gsub('^"(.*)"$', "%1"))
end

-- ===================== git status / counts =====================

M._parse_status_path = parse_status_path
M._format_prefix = git_status_codes.code_to_display

-- Apply `git status --porcelain` lines to per-path XY codes and worktree counts.
-- Pure (no shellout) so the sync and async fetch paths share it. `prefix` (for
-- the submodule recursion) is prepended to each path key so a submodule's files
-- merge into the superproject-relative codes as "childA/<path>"; "" for the
-- outer repo.
local function apply_worktree_lines(lines, codes, counts, prefix)
  prefix = prefix or ""
  for _, line in ipairs(lines) do
    if #line >= 4 then
      local x = line:sub(1, 1)
      local y = line:sub(2, 2)
      codes[prefix .. parse_status_path(line:sub(4))] = x .. y

      local cat = git_status_codes.category(git_status_codes.dominant_letter(x, y))
      if cat then
        counts[cat] = counts[cat] + 1
      end
      if x ~= " " and x ~= "?" then
        counts.staged = counts.staged + 1
      end
      if y ~= " " and y ~= "?" then
        counts.unstaged = counts.unstaged + 1
      end
      if x == "?" and y == "?" then
        counts.unstaged = counts.unstaged + 1
      end
    end
  end
end

-- Sync fetch + parse of `git status --porcelain`.
-- --untracked-files=all lists each untracked file individually; without it git
-- collapses a fully-untracked directory to a single "dir/" entry, which would
-- show (and try to open) the directory instead of the new file.
-- --ignore-submodules=all matches git_changes_async: the sync path has no
-- submodule recursion, so a dirty-gitlink row would surface as a bogus file
-- entry (see the e2e contract in telescope_smart_spec).
local function parse_worktree_status(root, codes, counts)
  local lines, ok = git.run(
    { "status", "--porcelain", "--untracked-files=all", "--ignore-submodules=all" },
    { cwd = root }
  )
  if not ok then
    return
  end
  apply_worktree_lines(lines, codes, counts)
end

-- Apply `git diff --name-status base...HEAD` lines to base-only 'b<letter>'
-- codes (only for paths not already changed in the worktree) and base counts.
-- Pure (no shellout) so the sync and async fetch paths share it.
local function apply_committed_lines(lines, codes, counts)
  for _, line in ipairs(lines) do
    if line ~= "" then
      local status_char = line:sub(1, 1)
      local rest = line:sub(2):match("^%s*(.*)$") or ""
      local path
      if status_char == "R" or status_char == "C" then
        path = rest:match("\t[^\t]+\t(.+)$") or rest:match("%s+%S+%s+(.+)$")
      else
        path = rest:match("^(.+)$")
      end
      if path and path ~= "" then
        counts.committed = counts.committed + 1
        -- The base count must match the visible b<letter> rows: a path also
        -- changed in the worktree keeps its worktree code (no b row), so only
        -- bump the base category when this path actually receives a b code.
        if not codes[path] then
          codes[path] = "b" .. status_char
          local cat = git_status_codes.category(status_char)
          if cat and counts.base[cat] ~= nil then
            counts.base[cat] = counts.base[cat] + 1
          end
        end
      end
    end
  end
end

local function parse_committed_history(root, base, codes, counts)
  -- Three-dot (base...HEAD) diffs against the merge-base of base and HEAD, not
  -- base's current tip: it shows what changed on my branch since it forked off
  -- base — the "changed since base" intent — and matches the `git log base..HEAD`
  -- preview semantics. (base advancing upstream doesn't masquerade as my work.)
  local lines, ok = git.run(
    { "diff", "--name-status", "--ignore-submodules=all", base .. "...HEAD" },
    { cwd = root }
  )
  if not ok then
    return
  end
  apply_committed_lines(lines, codes, counts)
end

local function fresh_counts()
  return {
    added = 0,
    modified = 0,
    deleted = 0,
    renamed = 0,
    untracked = 0,
    staged = 0,
    unstaged = 0,
    committed = 0,
    base = { added = 0, modified = 0, deleted = 0, renamed = 0 },
  }
end

function M._git_changes(root, base)
  local codes = {}
  local counts = fresh_counts()

  parse_worktree_status(root, codes, counts)
  if base and git.resolve(root, base) then
    parse_committed_history(root, base, codes, counts)
  end

  return codes, counts
end

local function split_lines(s)
  return vim.split(s or "", "\n", { trimempty = true })
end

-- ===================== submodule recursion =====================

-- Extract the value column from `git config --get-regexp` output lines
-- ("submodule.<name>.path <value>" -> "<value>"). The git-side regex already
-- restricts these to submodule path entries, so each value is a submodule path.
-- Values may contain spaces, so capture everything after the first key token.
local function parse_config_values(lines)
  local vals = {}
  for _, line in ipairs(lines) do
    local v = line:match("^%S+%s+(.+)$")
    if v and v ~= "" then
      vals[#vals + 1] = v
    end
  end
  return vals
end
M._parse_config_values = parse_config_values

-- Cheap gate for the recursion: a repo has submodules only if a .gitmodules sits
-- at its toplevel. One fs_stat and zero git spawns, so the common single-repo
-- case never pays for submodule discovery.
local function has_submodules(root)
  return root ~= nil and vim.uv.fs_stat(root .. "/.gitmodules") ~= nil
end
M._has_submodules = has_submodules

-- Bounded fan-out over the submodule statuses, via the shared util.pool
-- (config.ignore_filter's oracle drains through the same pool and bound).
-- Thin re-exports keep the existing unit-spec seams stable.
local SUBMODULE_CONCURRENCY = pool.GIT_CONCURRENCY
M._SUBMODULE_CONCURRENCY = SUBMODULE_CONCURRENCY

local run_pool = pool.run
M._run_pool = run_pool

-- Matches util.git's TIMEOUT_MS: one bound for how long any single git call may
-- run. A hung/slow submodule status is killed at the bound (its res.code != 0 →
-- that submodule contributes nothing) so the pool always completes.
local GIT_TIMEOUT_MS = 2000

-- The outer whole-superproject status/diff get a larger bound than the
-- per-submodule calls: they cover the entire tree, and killing a legitimate
-- cold-cache status would blank every label. The bound still guarantees the
-- pipeline completes — without one, a single hung spawn wedges refreshing[cwd]
-- forever and silently disables every future refresh for that cwd.
local BULK_GIT_TIMEOUT_MS = 5 * GIT_TIMEOUT_MS

-- The full-tree file walker (rg/fd/find) gets the same whole-tree bound as the
-- bulk git calls: without one, a wedged walker lingers forever and its callback
-- never fires, so the picker never opens.
local WALKER_TIMEOUT_MS = 10000

-- Async sibling of _git_changes: fetch `git status` (and, when a base is set,
-- `git diff`) via vim.system so the UI never blocks on git over a large
-- superproject tree. vim.system callbacks run in a fast context where most of
-- the API is off-limits, so all parsing is vim.schedule'd back onto the main
-- loop. Calls cb(codes, counts).
local function git_changes_async(root, base, cb)
  local function finish(wt_lines, df_lines)
    local codes, counts = {}, fresh_counts()
    apply_worktree_lines(wt_lines, codes, counts)
    if df_lines then
      apply_committed_lines(df_lines, codes, counts)
    end
    cb(codes, counts)
  end
  vim.system(
    -- --ignore-submodules=all: the recursion path resolves per-file status
    -- INSIDE each submodule itself, so the outer status must not collapse a
    -- dirty submodule to a single gitlink row (which would show as a bogus
    -- "childA" file). No-op for a plain repo with no submodules.
    {
      "git",
      "-C",
      root,
      "status",
      "--porcelain",
      "--untracked-files=all",
      "--ignore-submodules=all",
    },
    { text = true, timeout = BULK_GIT_TIMEOUT_MS },
    function(wt)
      local wt_lines = wt.code == 0 and split_lines(wt.stdout) or {}
      vim.schedule(function()
        -- `git status` and `git diff` run SERIALLY (diff spawned only after the
        -- status process has exited), never concurrently. Both commands
        -- opportunistically take `.git/index.lock` to refresh the index stat
        -- cache, so two overlapping git processes in the same repo intermittently
        -- collide on the lock: one exits nonzero and its output is dropped — a
        -- lost `git diff` means the b<letter> base labels silently vanish. Serial
        -- is marginally slower on a huge tree but correct; a "parallel join"
        -- traded that correctness for an unproven latency win.
        --
        -- No synchronous `git rev-parse --verify` guard here: that would block
        -- the main loop on every async refresh. An invalid base just makes the
        -- diff below exit nonzero (df_lines = {}), which degrades to no committed
        -- history — the same outcome the guard produced.
        if base then
          vim.system(
            -- Three-dot base...HEAD: diff against the merge-base of base and HEAD
            -- (see parse_committed_history) — "changed on my branch since base".
            {
              "git",
              "-C",
              root,
              "diff",
              "--name-status",
              "--ignore-submodules=all",
              base .. "...HEAD",
            },
            { text = true, timeout = BULK_GIT_TIMEOUT_MS },
            function(df)
              local df_lines = df.code == 0 and split_lines(df.stdout) or {}
              vim.schedule(function()
                finish(wt_lines, df_lines)
              end)
            end
          )
        else
          finish(wt_lines, nil)
        end
      end)
    end
  )
end

-- Direct (one level) submodule paths declared in `dir`/.gitmodules, async.
-- Reads ONLY .gitmodules via `git config` (no index/tree walk), so it stays
-- cheap even under a 20k-file superproject. cb runs on the main loop with the
-- declared path list (empty on missing file / read failure / timeout).
local function direct_submodule_paths_async(dir, cb)
  vim.system(
    { "git", "config", "--file", dir .. "/.gitmodules", "--get-regexp", "^submodule\\..*\\.path$" },
    { text = true, timeout = GIT_TIMEOUT_MS },
    function(res)
      local paths = res.code == 0 and parse_config_values(split_lines(res.stdout)) or {}
      vim.schedule(function()
        cb(paths)
      end)
    end
  )
end

-- Checked-out submodule worktree paths under `root`, superproject-relative and
-- nested as "child/grand", resolved fresh each call. Replaces the pathologically
-- slow `git submodule status --recursive` (~7 s at 200 submodules — it spawns a
-- subprocess per submodule to resolve a SHA/describe we discard) with cheap
-- per-directory .gitmodules reads gated by fs_stat, bounded by
-- SUBMODULE_CONCURRENCY so a deeply nested tree can't fork-bomb:
--   * fs_stat(sub/.git)        -> skip uninitialized submodules (no worktree)
--   * fs_stat(sub/.gitmodules) -> recurse ONLY into submodules that themselves
--                                 contain submodules (near-zero cost when flat)
local function submodule_paths_async(root, cb)
  local result = {}
  local queue = { { dir = root, prefix = "" } }
  local head, active, finished = 1, 0, false

  local function done_if_idle()
    if not finished and active == 0 and head > #queue then
      finished = true
      cb(result)
    end
  end

  local function pump()
    while active < SUBMODULE_CONCURRENCY and head <= #queue do
      local item = queue[head]
      head = head + 1
      active = active + 1
      direct_submodule_paths_async(item.dir, function(paths)
        for _, p in ipairs(paths) do
          local subdir = item.dir .. "/" .. p
          if vim.uv.fs_stat(subdir .. "/.git") then
            result[#result + 1] = item.prefix .. p
            if vim.uv.fs_stat(subdir .. "/.gitmodules") then
              queue[#queue + 1] = { dir = subdir, prefix = item.prefix .. p .. "/" }
            end
          end
        end
        active = active - 1
        pump()
        done_if_idle()
      end)
    end
    done_if_idle()
  end

  pump()
end
M._submodule_paths_async = submodule_paths_async

-- git_changes_async plus, for a superproject, each submodule's per-file worktree
-- status merged under its "subpath/" prefix — so A/M/D/?* appear on files INSIDE
-- submodules, which the outer --ignore-submodules=all status collapses away.
-- Discovery (submodule status) and the outer status stay serial to avoid the
-- root's index.lock; the per-submodule statuses then run through a bounded pool
-- — they live in distinct repos with distinct locks, and --ignore-submodules=all
-- keeps a parent from descending into (and racing on the index.lock of) its
-- nested child. The base...HEAD diff is scoped to the OUTER repo only this stage:
-- review_base is keyed by the outer toplevel, so a submodule's "changed since
-- base" is ill-defined; submodules contribute worktree codes, not bX.
local function recursive_changes_async(root, base, cb)
  if not has_submodules(root) then
    return git_changes_async(root, base, cb)
  end
  submodule_paths_async(root, function(paths)
    git_changes_async(root, base, function(codes, counts)
      run_pool(paths, SUBMODULE_CONCURRENCY, function(subpath, done)
        vim.system({
          "git",
          "-C",
          root .. "/" .. subpath,
          "status",
          "--porcelain",
          "--untracked-files=all",
          "--ignore-submodules=all",
        }, { text = true, timeout = GIT_TIMEOUT_MS }, function(res)
          local sub_lines = res.code == 0 and split_lines(res.stdout) or {}
          vim.schedule(function()
            apply_worktree_lines(sub_lines, codes, counts, subpath .. "/")
            done()
          end)
        end)
      end, function()
        cb(codes, counts)
      end)
    end)
  end)
end
M._recursive_changes_async = recursive_changes_async

-- The command that lists every file from the cwd, shared with find_files via
-- util.fs (which carries the rg/fd/find dialects and the heavy-dir excludes the
-- find fallback needs for a polyglot superproject). list_all hardcodes --hidden
-- because it lists dotfiles itself rather than leaning on telescope to append it.
local function list_all_cmd()
  return fs.list_files_cmd({ hidden = true })
end

function M._list_all()
  return vim.fn.systemlist(list_all_cmd())
end

-- Async sibling of _list_all: stream the file list off the main thread so a big
-- superproject doesn't freeze the editor while a picker is opening.
function M._list_all_async(cwd, cb)
  vim.system(list_all_cmd(), { cwd = cwd, text = true, timeout = WALKER_TIMEOUT_MS }, function(out)
    -- Keep whatever the walker printed regardless of exit code: rg exits 2 on
    -- a partial-error walk (one unreadable directory) while still emitting the
    -- full valid listing, and the sync sibling (vim.fn.systemlist) likewise
    -- ignores exit codes. split_lines maps nil/empty stdout to {}. A timed-out
    -- (code 124) or signal-killed walker is different: its truncated listing is
    -- not the tree, so it degrades to {} like the git spawns' failures.
    local timed_out = out.code == 124 or (out.signal or 0) ~= 0
    local files = timed_out and {} or split_lines(out.stdout)
    vim.schedule(function()
      cb(files)
    end)
  end)
end

function M._merge_results(codes, all_files)
  local seen, results = {}, {}
  local function add(f)
    if not seen[f] then
      seen[f] = true
      table.insert(results, f)
    end
  end
  -- Emit the changed-files cluster in sorted order so this picker matches its
  -- sibling smart_files_changed (which table.sorts): pairs() order is otherwise
  -- nondeterministic, which would shuffle the leading rows between the two.
  local changed = {}
  for f in pairs(codes) do
    table.insert(changed, f)
  end
  table.sort(changed)
  for _, f in ipairs(changed) do
    add(f)
  end
  for _, f in ipairs(all_files) do
    f = f:gsub("^%./", "")
    add(f)
  end
  return results
end

-- ===================== codes cache (per-cwd, short TTL) =====================

local cache = { codes = {}, counts = nil, base = nil, root = nil, cwd = nil, time = 0 }

local function ms_now()
  return vim.uv.hrtime() / 1e6
end

-- Canonical cache key: "cwd" and "cwd/" must converge on one cache/refreshing
-- entry (a trailing-slash cwd once produced a divergent key — the
-- SmartCodesRefreshed bug). The "(.)/$" pattern keeps the filesystem root "/"
-- from collapsing to "".
local function canonical_cwd(cwd)
  return (cwd:gsub("(.)/$", "%1"))
end
M._canonical_cwd = canonical_cwd

-- Async core: resolve root, fetch git changes (worktree status across the repo
-- AND its submodules) off the main thread, rewrite the per-path keys relative to
-- cwd, store them in the cache, then hand them to cb.
local function refresh_codes_async(cwd, cb)
  cwd = canonical_cwd(cwd or vim.fn.getcwd())
  local root = git.root(cwd)
  if not root then
    cache = { codes = {}, counts = nil, base = nil, root = nil, cwd = cwd, time = ms_now() }
    if cb then
      cb({}, nil, nil, nil)
    end
    return
  end
  local base = review_base.get(root)
  recursive_changes_async(root, base, function(raw_codes, counts)
    local codes = {}
    for p, c in pairs(raw_codes) do
      codes[path_util.relative(root .. "/" .. p, cwd)] = c
    end
    cache = { codes = codes, counts = counts, base = base, root = root, cwd = cwd, time = ms_now() }
    if cb then
      cb(codes, counts, base, root)
    end
  end)
end
M._refresh_async = refresh_codes_async

-- Non-blocking read of the codes cache. On a fresh hit it returns immediately;
-- otherwise it kicks a deduped async refresh and returns whatever is cached now
-- (possibly empty, or for a prior cwd). Consumers that need the fresh result
-- listen for `User SmartCodesRefreshed`. Nothing here shells out synchronously
-- for git status — that synchronous call was the picker/tree open-time freeze.
local refreshing = {}

local function refresh_codes(cwd)
  cwd = canonical_cwd(cwd or vim.fn.getcwd())
  local now = ms_now()
  if cache.cwd == cwd and (now - cache.time) < 500 then
    return cache.codes, cache.counts, cache.base, cache.root
  end
  if not refreshing[cwd] then
    refreshing[cwd] = true
    refresh_codes_async(cwd, function()
      refreshing[cwd] = nil
      vim.api.nvim_exec_autocmds("User", { pattern = "SmartCodesRefreshed", data = { cwd = cwd } })
    end)
  end
  if cache.cwd == cwd then
    return cache.codes, cache.counts, cache.base, cache.root
  end
  local root = git.root(cwd)
  local base = root and review_base.get(root) or nil
  return {}, nil, base, root
end

function M._refresh(cwd)
  return refresh_codes(cwd)
end

-- ===================== highlights & legend =====================

local function set_legend_highlights()
  git_status_codes.define_highlights()
  vim.api.nvim_set_hl(0, "SmartFilesLegend", { fg = palette.muted, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesLegendCount", { fg = "#768390", bold = true, default = true })
end

local legend = Overlay.new()

local function close_legend()
  legend:close()
end

-- Pure: turn the counts table into the two legend rows (worktree + base),
-- dropping zero-count entries and appending a "vs <base>" trailer when a base
-- is set and has any nonzero category. Exposed for unit testing.
local function build_legend_segments(counts, base)
  local function b_icon(letter, type_hl)
    return {
      icon = "b" .. letter,
      icon_hls = { { 0, 1, "SmartFilesBase" }, { 1, 2, type_hl } },
    }
  end
  local function nonzero(segs)
    local out = {}
    for _, s in ipairs(segs) do
      if (s.count or 0) > 0 then
        table.insert(out, s)
      end
    end
    return out
  end

  local worktree = nonzero({
    { icon = "A", icon_hl = "SmartFilesAdded", count = counts.added, label = "added" },
    { icon = "M", icon_hl = "SmartFilesModified", count = counts.modified, label = "modified" },
    { icon = "D", icon_hl = "SmartFilesDeleted", count = counts.deleted, label = "deleted" },
    { icon = "R", icon_hl = "SmartFilesRenamed", count = counts.renamed, label = "renamed" },
    { icon = "?*", icon_hl = "SmartFilesUntracked", count = counts.untracked, label = "untracked" },
    { icon = "*", icon_hl = "SmartFilesUnstaged", count = counts.unstaged, label = "unstaged" },
  })

  local base_list = {}
  if base then
    local b = counts.base or {}
    base_list = nonzero({
      vim.tbl_extend("force", b_icon("A", "SmartFilesAdded"), { count = b.added, label = "added" }),
      vim.tbl_extend(
        "force",
        b_icon("M", "SmartFilesModified"),
        { count = b.modified, label = "modified" }
      ),
      vim.tbl_extend(
        "force",
        b_icon("D", "SmartFilesDeleted"),
        { count = b.deleted, label = "deleted" }
      ),
      vim.tbl_extend(
        "force",
        b_icon("R", "SmartFilesRenamed"),
        { count = b.renamed, label = "renamed" }
      ),
    })
    if #base_list > 0 then
      table.insert(base_list, { label = "vs " .. base })
    end
  end

  return { worktree = worktree, base_list = base_list }
end
M._build_legend_segments = build_legend_segments

-- Render the segment rows into padded statuscolumn lines + their highlights.
local function render_legend_lines(groups, width)
  local lines, ranges_by_line = {}, {}
  for _, segs in ipairs({ groups.worktree, groups.base_list }) do
    if #segs > 0 then
      local text, ranges = picker_legend.render_segments(segs, {
        separator = "   ",
        default_hl = "SmartFilesLegend",
        count_hl = "SmartFilesLegendCount",
      })
      text, ranges = picker_legend.fit_line(text, ranges, width)
      table.insert(lines, text)
      table.insert(ranges_by_line, ranges)
    end
  end
  return lines, ranges_by_line
end

local function open_legend(prompt_bufnr, counts, base)
  close_legend()
  set_legend_highlights()
  if not counts then
    return
  end
  local results_win = picker_legend.results_win(prompt_bufnr)
  if not results_win then
    return
  end

  local groups = build_legend_segments(counts, base)
  if #groups.worktree == 0 and #groups.base_list == 0 then
    return
  end

  local width = vim.api.nvim_win_get_width(results_win)
  local lines, ranges_by_line = render_legend_lines(groups, width)
  if #lines == 0 then
    return
  end
  picker_legend.mount(legend, results_win, "smart_files_legend", lines, ranges_by_line)
end

-- ===================== picker core =====================

local function open_picker(opts)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local make_entry = require("telescope.make_entry")

  set_legend_highlights()

  pickers
    .new({}, {
      prompt_title = opts.title,
      finder = finders.new_table({
        results = opts.results,
        entry_maker = make_entry.gen_from_file({ cwd = opts.cwd }),
      }),
      sorter = conf.file_sorter({}),
      previewer = conf.file_previewer({}),
      attach_mappings = function(prompt_bufnr, _)
        picker_legend.attach(prompt_bufnr, function()
          open_legend(prompt_bufnr, opts.counts, opts.base)
        end, close_legend)
        return true
      end,
    })
    :find()
end

-- ===================== loading float =====================

-- A debounced "Loading changes…" badge shown while smart_files() prepares
-- (git status + the rg walk). P1 made the picker open fast; this only makes the
-- residual wait (cold cache, very large submodule counts, slow FS) visible so it
-- never reads as a freeze. Below the debounce the float never shows — intended.

-- Pure race decisions for the debounced float, as a function of this press's
-- generation vs the live generation and whether the picker has opened:
--   * mount   -> the debounce should show the float (still current, not yet open)
--   * dismiss -> a resolving callback should close it (still current). A stale
--                press (my_gen ~= live_gen) must never touch the shared overlay.
local function load_guard(my_gen, live_gen, opened)
  local current = my_gen == live_gen
  return { mount = current and not opened, dismiss = current }
end
M._load_guard = load_guard

-- Module state for the debounced float. Overlay.new() is a plain table (no OS
-- handle), so it's safe at module scope like `legend`. The debounce timer is
-- created LAZILY (loading_timer) so merely requiring the module allocates no
-- libuv handle — and the test harness's per-test module reloads don't strand one.
local loading = Overlay.new() -- OWN instance; sharing `legend` would make the two evict each other.
local load_timer = nil -- the ONE reused debounce timer; created on first arm, never per-call.
local load_gen = 0 -- generation token; bumped each smart_files() press so a stale press is a no-op.
local LOAD_DEBOUNCE_MS = 150 -- flash-free on ~120 ms git; appears promptly on genuinely slow repos.

-- Lazily create (once) and return the shared debounce timer. One handle for the
-- module's lifetime, reused via stop/start — never a fresh per-call timer, and
-- never :close()d on dismiss (that would make the next :start() throw). Lazy so
-- requiring the module (and the test harness's reloads) allocates no handle.
local function loading_timer()
  if not load_timer then
    load_timer = vim.uv.new_timer()
  end
  return load_timer
end

-- Build the one-line badge buffer and mount it on the `loading` overlay:
-- borderless, non-entering, bottom-center — mirrors review_base's "active base"
-- badge (review_base.lua:247). Overlay:mount self-closes any prior mount.
local function mount_loading_float()
  local text = "  Loading changes…  "
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  local width = vim.api.nvim_strwidth(text)
  loading:mount(buf, {
    relative = "editor",
    row = vim.o.lines - 4,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = 1,
    style = "minimal",
    border = "none",
    focusable = false,
    noautocmd = true,
    zindex = 250,
  })
end
M._mount_loading = mount_loading_float

-- Arm (or re-arm) the shared debounce timer for this press. Reuses the ONE
-- module-local timer (stop-then-start) — never allocates a per-press handle, and
-- never :close()s it (that would make the next :start() throw). `is_opened` is
-- read at fire time so a picker that opened before the debounce elapsed cancels
-- the mount; the generation guard cancels a superseded press's mount.
local function arm_loading(my_gen, is_opened)
  local t = loading_timer()
  t:stop()
  t:start(
    LOAD_DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      if load_guard(my_gen, load_gen, is_opened()).mount then
        mount_loading_float()
      end
    end)
  )
end
M._arm_loading = arm_loading
M._loading = loading
M._loading_timer = loading_timer

-- Both pickers fetch git status (and the file list) asynchronously and open in
-- the callback: the editor never blocks while git/rg run over the superproject,
-- and by the time open_picker builds its entries the cache is fresh, so the
-- status prefixes (via the patched gen_from_file) are correct on first render.
function M.smart_files()
  local cwd = vim.fn.getcwd()
  local codes_res, files_res
  local function maybe_open()
    if not (codes_res and files_res) then
      return
    end
    local base = codes_res.base
    open_picker({
      title = base and ("Files (base: " .. base .. ")") or "Files",
      results = M._merge_results(codes_res.codes, files_res),
      cwd = cwd,
      counts = codes_res.counts,
      base = base,
    })
  end
  refresh_codes_async(cwd, function(codes, counts, base)
    codes_res = { codes = codes, counts = counts, base = base }
    maybe_open()
  end)
  M._list_all_async(cwd, function(files)
    files_res = files or {}
    maybe_open()
  end)
end

function M.smart_files_changed()
  local cwd = vim.fn.getcwd()
  refresh_codes_async(cwd, function(codes, counts, base, root)
    if not root then
      vim.notify(review_base.MSG_NOT_A_REPO, vim.log.levels.WARN)
      return
    end
    local results = {}
    for f in pairs(codes) do
      table.insert(results, f)
    end
    table.sort(results)
    if #results == 0 then
      vim.notify("No changes vs " .. (base or "index"), vim.log.levels.INFO)
      return
    end
    open_picker({
      title = base and ("Changed files (base: " .. base .. ")") or "Changed files",
      results = results,
      cwd = cwd,
      counts = counts,
      base = base,
    })
  end)
end

-- ===================== telescope integration =====================

local patched = false

function M.setup()
  if patched then
    return
  end
  set_legend_highlights()
  local ok, make_entry = pcall(require, "telescope.make_entry")
  if not ok then
    return
  end
  local original = make_entry.gen_from_file
  make_entry.gen_from_file = function(opts)
    opts = opts or {}
    local cwd = opts.cwd or vim.fn.getcwd()
    local codes = refresh_codes(cwd)
    local base_maker = original(opts)
    return function(line)
      local e = base_maker(line)
      if not e then
        return nil
      end
      local path = e.value
      if type(path) == "string" then
        path = path:gsub("^%./", "")
      end
      local code = codes[path]
      local prefix_text, prefix_hls = git_status_codes.code_to_display(code)
      local pad = prefix_text .. " "
      local plen = #pad
      local base_display = e.display
      e.display = function(entry)
        local d, base_hl
        if type(base_display) == "function" then
          d, base_hl = base_display(entry)
        else
          d = base_display or entry.value
        end
        local text = pad .. (d or "")
        local hls = {}
        for _, ph in ipairs(prefix_hls) do
          table.insert(hls, ph)
        end
        if base_hl then
          for _, h in ipairs(base_hl) do
            table.insert(hls, { { h[1][1] + plen, h[1][2] + plen }, h[2] })
          end
        end
        return text, hls
      end
      return e
    end
  end
  patched = true
end

return M

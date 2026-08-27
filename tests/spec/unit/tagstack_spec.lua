local nvim_env = require("helpers.nvim_env")

-- A real file on disk per frame: the tagstack stores buffer numbers, and `:pop`
-- reopens by name, so scratch buffers would not survive the round trip.
local function write_file(root, name, lines)
  local path = root .. "/" .. name
  vim.fn.writefile(lines, path)
  return path
end

local function clear_stack()
  vim.fn.settagstack(vim.api.nvim_get_current_win(), { items = {} }, "r")
end

local function stack()
  return vim.fn.gettagstack(vim.api.nvim_get_current_win())
end

describe("config.tagstack", function()
  local env_root, M, root

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
    package.loaded["config.tagstack"] = nil
    M = require("config.tagstack")
    M._reset_kinds()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    -- On macOS $TMPDIR lives under /var, which is a symlink to /private/var.
    -- Buffer names come back resolved, so resolve the root too or every path
    -- assertion compares the two spellings of the same file.
    root = vim.fn.resolve(root)
    clear_stack()
  end)

  after_each(function()
    clear_stack()
    pcall(vim.fn.delete, root, "rf")
    nvim_env.teardown(env_root)
  end)

  describe("M.capture", function()
    it("records the cursor with a 1-based column, matching tagstack `from`", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha beta", "gamma" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      local origin = M.capture()
      assert.are.equal(buf, origin.bufnr)
      assert.are.equal(2, origin.lnum)
      -- nvim_win_get_cursor is 0-based on the column; `from` wants col('.').
      assert.are.equal(1, origin.col)
      assert.are.equal(vim.api.nvim_get_current_win(), origin.winid)
      assert.are.equal("gamma", origin.tagname)
    end)
  end)

  describe("M.push", function()
    it("pushes a frame carrying the captured position", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      local origin = M.capture()

      -- Move away, exactly as an async response callback would find things.
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      assert.is_true(M.push(origin, "gd"))

      local st = stack()
      assert.are.equal(1, st.length)
      -- The frame must record where the cursor WAS, not where it drifted to.
      assert.are.equal(3, st.items[1].from[2])
      assert.are.equal("three", st.items[1].tagname)
    end)

    it("refuses a nil origin and one whose window is gone", function()
      assert.is_false(M.push(nil, "gd"))
      assert.is_false(M.push({ winid = 99999, bufnr = 1, lnum = 1, col = 1 }, "gd"))
      assert.are.equal(0, stack().length)
    end)
  end)

  describe("M.frames", function()
    local function push_three()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "aa", "bb", "cc", "dd" })
      for _, lnum in ipairs({ 1, 2, 3 }) do
        vim.api.nvim_win_set_cursor(0, { lnum, 0 })
        M.push(M.capture(), "gd")
      end
      return buf
    end

    it("returns rows newest first with their stack index", function()
      push_three()
      local rows, curidx, length = M.frames()

      assert.are.equal(3, #rows)
      assert.are.equal(3, length)
      -- Nothing popped yet, so curidx sits one past the end.
      assert.are.equal(4, curidx)

      assert.are.equal(3, rows[1].lnum) -- newest
      assert.are.equal(3, rows[1].stack_idx)
      assert.are.equal(1, rows[3].lnum) -- oldest
      assert.are.equal(1, rows[3].stack_idx)
    end)

    it("marks no row current while curidx is past the end", function()
      push_three()
      for _, row in ipairs(M.frames()) do
        assert.is_false(row.current)
      end
    end)

    it("carries the kind for frames it pushed and nil for frames it did not", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha", "beta" })

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      M.push(M.capture(), "grr")

      -- A frame pushed by core or a plugin, bypassing this module entirely.
      vim.fn.settagstack(vim.api.nvim_get_current_win(), {
        items = { { tagname = "beta", from = { buf, 2, 1, 0 } } },
      }, "a")

      local rows = M.frames()
      assert.is_nil(rows[1].kind) -- the foreign frame: blank, not guessed
      assert.are.equal("grr", rows[2].kind)
    end)
  end)

  describe("M.pop", function()
    it("reports an empty stack instead of raising E73", function()
      local notified
      local orig = vim.notify
      vim.notify = function(msg)
        notified = msg
      end
      local ok = M.pop(1)
      vim.notify = orig

      assert.is_false(ok)
      assert.are.equal("definition stack empty", notified)
    end)

    it("returns to the recorded position", function()
      local a = write_file(root, "a.txt", { "a1", "a2", "a3" })
      local b = write_file(root, "b.txt", { "b1", "b2" })

      vim.cmd.edit(vim.fn.fnameescape(a))
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      M.push(M.capture(), "gd")
      vim.cmd.edit(vim.fn.fnameescape(b))

      assert.is_true(M.pop(1))
      assert.are.equal(a, vim.api.nvim_buf_get_name(0))
      assert.are.equal(3, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("unwinds several hops with a count", function()
      local a = write_file(root, "a.txt", { "a1", "a2" })
      local b = write_file(root, "b.txt", { "b1", "b2" })
      local c = write_file(root, "c.txt", { "c1", "c2" })

      vim.cmd.edit(vim.fn.fnameescape(a))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      M.push(M.capture(), "gd")
      vim.cmd.edit(vim.fn.fnameescape(b))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      M.push(M.capture(), "gd")
      vim.cmd.edit(vim.fn.fnameescape(c))

      -- One press past both hops, back to where the chain started.
      assert.is_true(M.pop(2))
      assert.are.equal(a, vim.api.nvim_buf_get_name(0))
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
    end)
  end)

  describe("M.goto_frame", function()
    local function three_files()
      local paths = {}
      for i, name in ipairs({ "a.txt", "b.txt", "c.txt" }) do
        paths[i] = write_file(root, name, { name .. "1", name .. "2", name .. "3" })
      end
      vim.cmd.edit(vim.fn.fnameescape(paths[1]))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      M.push(M.capture(), "gd")
      vim.cmd.edit(vim.fn.fnameescape(paths[2]))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      M.push(M.capture(), "gd")
      vim.cmd.edit(vim.fn.fnameescape(paths[3]))
      return paths
    end

    it("reaches the oldest frame in one step", function()
      local paths = three_files()
      assert.is_true(M.goto_frame(nil, 1))
      assert.are.equal(paths[1], vim.api.nvim_buf_get_name(0))
      assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])
      assert.are.equal(1, stack().curidx)
    end)

    it("reaches a frame ABOVE the current position, which :tag cannot", function()
      -- `:tag` re-resolves the tagname through a tags file, so with none on disk
      -- it is E433 for every LSP-pushed frame. Setting curidx and popping once
      -- has to work in both directions.
      local paths = three_files()
      M.goto_frame(nil, 1) -- walk to the bottom first
      assert.are.equal(1, stack().curidx)

      assert.is_true(M.goto_frame(nil, 2))
      assert.are.equal(paths[2], vim.api.nvim_buf_get_name(0))
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("refuses an out-of-range index", function()
      three_files()
      assert.is_false(M.goto_frame(nil, 0))
      assert.is_false(M.goto_frame(nil, 99))
    end)
  end)

  describe("M.drop_frame", function()
    local function push_at(buf, lnum, name)
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      local origin = M.capture()
      origin.tagname = name
      M.push(origin, "gd")
    end

    local function seeded()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "l1", "l2", "l3", "l4" })
      push_at(buf, 1, "A")
      push_at(buf, 2, "B")
      push_at(buf, 3, "C")
      return buf
    end

    it("removes the frame and keeps the rest in order", function()
      seeded()
      assert.is_true(M.drop_frame(nil, 1)) -- drop the oldest

      local st = stack()
      assert.are.equal(2, st.length)
      assert.are.equal("B", st.items[1].tagname)
      assert.are.equal("C", st.items[2].tagname)
    end)

    it("keeps curidx pointing at the same frame after dropping below it", function()
      -- settagstack forces curidx to one-past-the-length whenever `items` is
      -- present, so a naive single write silently moves the position. Dropping
      -- the oldest of three while sitting at curidx 3 must leave curidx at 2 --
      -- still the same logical frame -- not snap it to the top.
      seeded()
      vim.fn.settagstack(vim.api.nvim_get_current_win(), { curidx = 3 }, "r")
      assert.are.equal(3, stack().curidx)

      assert.is_true(M.drop_frame(nil, 1))
      assert.are.equal(2, stack().curidx)
    end)

    it("leaves curidx alone when dropping above it", function()
      seeded()
      vim.fn.settagstack(vim.api.nvim_get_current_win(), { curidx = 1 }, "r")

      assert.is_true(M.drop_frame(nil, 3))
      assert.are.equal(1, stack().curidx)
      assert.are.equal(2, stack().length)
    end)

    it("clears the marker when you drop the frame you are standing at", function()
      -- Holding curidx would put the ● on whichever frame slid into that slot --
      -- a position the user has never visited. One-past-the-end is the same
      -- "not positioned within the stack" state a fresh push leaves.
      seeded()
      vim.fn.settagstack(vim.api.nvim_get_current_win(), { curidx = 2 }, "r")

      assert.is_true(M.drop_frame(nil, 2))
      assert.are.equal(2, stack().length)
      assert.are.equal(3, stack().curidx)
      for _, row in ipairs(M.frames()) do
        assert.is_false(row.current)
      end
    end)

    it("refuses an out-of-range index", function()
      seeded()
      assert.is_false(M.drop_frame(nil, 0))
      assert.is_false(M.drop_frame(nil, 99))
      assert.are.equal(3, stack().length)
    end)
  end)

  describe("M.locations", function()
    local function request_returning(items)
      return function(opts)
        opts.on_list({ title = "test", items = items })
      end
    end

    it("pushes exactly one frame for a single result", function()
      local dest = write_file(root, "dest.txt", { "d1", "d2", "d3" })
      local src = write_file(root, "src.txt", { "s1", "s2" })
      vim.cmd.edit(vim.fn.fnameescape(src))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      M.locations(request_returning({ { filename = dest, lnum = 3, col = 1 } }), "gd", "definition")

      assert.are.equal(dest, vim.api.nvim_buf_get_name(0))
      assert.are.equal(3, vim.api.nvim_win_get_cursor(0)[1])

      local st = stack()
      assert.are.equal(1, st.length)
      assert.are.equal(2, st.items[1].from[2])
    end)

    it("pushes nothing when the server returns no locations", function()
      local notified
      local orig = vim.notify
      vim.notify = function(msg)
        notified = msg
      end
      M.locations(request_returning({}), "gd", "definition")
      vim.notify = orig

      assert.are.equal("no definition found", notified)
      assert.are.equal(0, stack().length)
    end)

    it("records exactly one frame for a multi-result list", function()
      -- Deferring the push to the quickfix <CR> was tried and fails both ways:
      -- browsing N entries pushed N identical frames (evicting real hops at the
      -- 20-frame cap), while ]q / :cnext / :cc bypassed the mapping entirely.
      -- One frame per invocation is the unit.
      local dest = write_file(root, "dest.txt", { "d1", "d2", "d3" })
      local src = write_file(root, "src.txt", { "s1", "s2" })
      vim.cmd.edit(vim.fn.fnameescape(src))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      M.locations(
        request_returning({
          { filename = dest, lnum = 1, col = 1 },
          { filename = dest, lnum = 3, col = 1 },
        }),
        "gd",
        "definition"
      )

      local st = stack()
      assert.are.equal(1, st.length)
      assert.are.equal(2, st.items[1].from[2])
      assert.are.equal("quickfix", vim.bo.buftype)
      pcall(vim.cmd, "cclose")
    end)

    it("still records one frame when the list is walked with :cnext", function()
      -- ]q / [q are Neovim 0.11+ defaults for :cnext / :cprev and never touch a
      -- buffer-local quickfix mapping, so this route used to push nothing at all.
      local dest = write_file(root, "dest.txt", { "d1", "d2", "d3" })
      local src = write_file(root, "src.txt", { "s1", "s2" })
      vim.cmd.edit(vim.fn.fnameescape(src))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      M.locations(
        request_returning({
          { filename = dest, lnum = 1, col = 1 },
          { filename = dest, lnum = 3, col = 1 },
        }),
        "gd",
        "definition"
      )
      pcall(vim.cmd, "cclose")
      pcall(vim.cmd, "cnext")
      pcall(vim.cmd, "cnext")

      -- Walking the whole list must not add frames on top of the one already in.
      assert.are.equal(1, stack().length)
      assert.is_true(M.pop(1))
      assert.are.equal(src, vim.api.nvim_buf_get_name(0))
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("keeps references on the list path even for a lone result", function()
      -- Core never single-jumps for references, and with includeDeclaration a
      -- symbol used nowhere returns exactly one location: the declaration under
      -- the cursor. Single-jumping that is a `grr` that appears to do nothing.
      local src = write_file(root, "src.txt", { "s1", "s2" })
      vim.cmd.edit(vim.fn.fnameescape(src))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      M.locations(
        request_returning({ { filename = src, lnum = 2, col = 1 } }),
        "grr",
        "references",
        nil,
        { always_list = true }
      )

      assert.are.equal("quickfix", vim.bo.buftype)
      pcall(vim.cmd, "cclose")
    end)
  end)

  describe("M.jump", function()
    it("still records a frame when the origin window has been closed", function()
      -- The frame used to be silently dropped: M.jump fell back to the current
      -- window to navigate but M.push re-checked the dead origin.winid and bailed,
      -- so a successful jump left <C-t> unarmed.
      local dest = write_file(root, "dest.txt", { "d1", "d2" })
      local src = write_file(root, "src.txt", { "s1", "s2" })
      vim.cmd.edit(vim.fn.fnameescape(src))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      vim.cmd("split")
      local doomed = vim.api.nvim_get_current_win()
      local origin = M.capture()
      assert.are.equal(doomed, origin.winid)
      vim.api.nvim_win_close(doomed, true)

      assert.is_true(M.jump(origin, { filename = dest, lnum = 1, col = 1 }, "gd"))
      assert.are.equal(1, stack().length)
    end)

    it("clamps an out-of-range destination line instead of reporting a bogus jump", function()
      local dest = write_file(root, "dest.txt", { "d1", "d2" })
      local src = write_file(root, "src.txt", { "s1" })
      vim.cmd.edit(vim.fn.fnameescape(src))
      local origin = M.capture()

      assert.is_true(M.jump(origin, { filename = dest, lnum = 999, col = 1 }, "gd"))
      assert.are.equal(dest, vim.api.nvim_buf_get_name(0))
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("does not push when there is nothing to jump to", function()
      local src = write_file(root, "src.txt", { "s1" })
      vim.cmd.edit(vim.fn.fnameescape(src))
      local origin = M.capture()

      assert.is_false(M.jump(origin, nil, "gd"))
      assert.is_false(M.jump(origin, { lnum = 1, col = 1 }, "gd")) -- no filename
      assert.are.equal(0, stack().length)
    end)
  end)
end)

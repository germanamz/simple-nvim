local emphasis = require("config.syntax_emphasis")
local palette = require("config.palette")

-- Relative luminance, so "is this dimmer?" can be asserted without pinning a hex
-- (docs/superpowers/theme.md: no spec asserts a colour value).
local function luminance(rgb)
  local function channel(c)
    c = c / 255
    return c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
  end
  local r = channel(math.floor(rgb / 0x10000) % 0x100)
  local g = channel(math.floor(rgb / 0x100) % 0x100)
  local b = channel(rgb % 0x100)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

local function get(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

describe("config.syntax_emphasis", function()
  before_each(function()
    -- A miniature light theme: apply() reads these and derives everything else.
    -- Normal needs a real bg or util.hl.define_dim can't blend and falls back to
    -- a NonText link.
    vim.api.nvim_set_hl(0, "Normal", { fg = 0x010409, bg = 0xffffff })
    vim.api.nvim_set_hl(0, "Function", { fg = 0x512598 })
    vim.api.nvim_set_hl(0, "@function", { link = "Function" })
    vim.api.nvim_set_hl(0, "@function.method", { fg = 0x512598 })
    vim.api.nvim_set_hl(0, "@type", { fg = 0x702c00 })
    vim.api.nvim_set_hl(0, "@type.definition", { fg = 0x702c00 })
    vim.api.nvim_set_hl(0, "Comment", { fg = 0x4b535d })
    vim.api.nvim_set_hl(0, "@comment.documentation", { fg = 0x4b535d })
    vim.api.nvim_set_hl(0, "@lsp.type.comment", { link = "@comment" })
    -- @function.call and @function.method.call are deliberately NOT defined:
    -- github-theme leaves both commented out, and they are the only EMPHASIS
    -- `use` captures that are hierarchy children of their own `decl`. Defining
    -- them here would remove the only condition under which the pinning matters,
    -- and the spec would pass with the pinning deleted.
    --
    -- The two link shapes that leak the bold in the real world:
    vim.api.nvim_set_hl(0, "@lsp.type.class", { link = "@function" }) -- github-theme
    vim.api.nvim_set_hl(0, "@lsp.type.typeParameter", { link = "@type.definition" }) -- Nvim default
    -- Stands in for any OTHER group a colorscheme happens to point at a bolded
    -- capture (github-theme really does this to @string.special.symbol in
    -- Makefiles). Unlike the two above it is not named in EMPHASIS, so only the
    -- discovery scan can save it.
    vim.api.nvim_set_hl(0, "@lsp.type.decorator", { link = "@function" })
    -- Defined-but-empty on purpose, which blocks the @-hierarchy. Must be left
    -- alone rather than repainted with the family colour.
    vim.api.nvim_set_hl(0, "@function.builtin", {})
    emphasis.apply()
  end)

  describe("comments", function()
    it("dims Comment to the shared muted grey", function()
      assert.are.equal(palette.muted, string.format("#%06x", get("Comment").fg))
    end)

    it("puts doc comments in a dimmer tier than ordinary comments", function()
      local doc = get("@comment.documentation")
      assert.is_not_nil(doc.fg)
      -- Light background: dimmer means closer to white, so higher luminance.
      assert.is_true(luminance(doc.fg) > luminance(get("Comment").fg))
    end)

    it("clears the LSP comment token so the two tiers survive", function()
      -- gopls paints @lsp.type.comment across a whole doc comment at a higher
      -- priority than treesitter; a defined-but-empty group contributes nothing.
      assert.are.same({}, get("@lsp.type.comment"))
    end)
  end)

  describe("declarations", function()
    it("bolds every declaration capture", function()
      for _, e in ipairs(emphasis.EMPHASIS) do
        assert.is_true(get(e.decl).bold, e.decl .. " should be bold")
      end
    end)

    it("keeps the declaration's colour rather than collapsing to a bare bold", function()
      -- @function is a LINK in the fixture; re-asserting it with bold must
      -- resolve through the link instead of dropping Function's foreground.
      assert.are.equal(0x512598, get("@function").fg)
    end)

    it("leaves call sites unbolded", function()
      for _, e in ipairs(emphasis.EMPHASIS) do
        assert.is_not_true(get(e.use).bold, e.use .. " should not be bold")
      end
    end)

    it("pins the LSP type token to the plain use weight", function()
      -- The semantic-token layer paints this on declarations AND call sites, so
      -- inheriting the bold here would bold every call.
      for _, e in ipairs(emphasis.EMPHASIS) do
        local lsp = get("@lsp.type." .. e.lsp)
        assert.is_not_true(lsp.bold, "@lsp.type." .. e.lsp .. " should not be bold")
        assert.are.equal(get(e.use).fg, lsp.fg)
      end
    end)

    it("re-bolds only the occurrences carrying a defining modifier", function()
      for _, e in ipairs(emphasis.EMPHASIS) do
        for _, mod in ipairs(emphasis.DEFINING_MODIFIERS) do
          local group = "@lsp.typemod." .. e.lsp .. "." .. mod
          assert.are.equal(e.decl, vim.api.nvim_get_hl(0, { name = group }).link)
          assert.is_true(get(group).bold, group .. " should resolve to bold")
        end
      end
    end)
  end)

  describe("bold containment", function()
    -- Bolding a capture is not local to it: other groups reach it by an explicit
    -- link or by the @-hierarchy and inherit the bold on EVERY occurrence. Each
    -- of these was a real regression caught in review.

    it("does not bold a group the theme links into a bolded capture", function()
      -- The theme's link is the leak vector; the discovery scan is the only
      -- thing that catches a group EMPHASIS does not name.
      local dec = get("@lsp.type.decorator")
      assert.is_not_true(dec.bold)
      assert.are.equal(0x512598, dec.fg, "should still read as a function")
    end)

    it("routes the class token to the type family, plain", function()
      -- github-theme points @lsp.type.class at @function, so ts_ls's `class`
      -- token bolded `new Foo()` and `let x: Foo` and painted them as functions.
      -- EMPHASIS claims `class` for the type pair instead: treesitter already
      -- captures a TS class name as @type, so this makes the two layers agree.
      local cls = get("@lsp.type.class")
      assert.is_not_true(cls.bold)
      assert.are.equal(get("@type").fg, cls.fg)
    end)

    it("does not bold a group Neovim's defaults link into a bolded capture", function()
      -- @lsp.type.typeParameter defaults to @type.definition; gopls emits it for
      -- every T/U in a generic signature AND body, so all of them went bold.
      local tp = get("@lsp.type.typeParameter")
      assert.is_not_true(tp.bold)
      assert.are.equal(0x702c00, tp.fg)
    end)

    it("does not bold an undefined family member that falls through", function()
      -- @function.macro is undefined by github-theme and lands on macro USE
      -- sites (`println!`, `vec!`), so it inherited @function's bold.
      local macro = get("@function.macro")
      assert.is_not_true(macro.bold)
      assert.are.equal(0x512598, macro.fg, "should inherit the plain family colour")
    end)

    it("leaves a defined-but-empty family member empty", function()
      -- The theme blocks the hierarchy here deliberately; repainting it with the
      -- family colour would be its own regression.
      assert.are.same({}, get("@function.builtin"))
    end)

    it("keeps the undefined use captures plain", function()
      -- The load-bearing case: these are undefined, so without pinning they
      -- resolve up the hierarchy straight into the bolded declaration group.
      for _, group in ipairs({ "@function.call", "@function.method.call" }) do
        local h = get(group)
        assert.is_not_true(h.bold, group .. " should not be bold")
        assert.are.equal(0x512598, h.fg, group .. " should keep the family colour")
      end
    end)
  end)

  it("is idempotent — a second apply() does not re-read its own output", function()
    local before = get("@function.call")
    emphasis.apply()
    emphasis.apply()
    assert.is_not_true(get("@function.call").bold)
    assert.are.equal(before.fg, get("@function.call").fg)
    assert.is_true(get("@function").bold)
  end)
end)

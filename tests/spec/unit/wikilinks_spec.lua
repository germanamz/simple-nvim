local wl = require("config.wikilinks")

describe("config.wikilinks", function()
  describe("_wikilink_at", function()
    -- "see [[a/b]] end"  -> [[a/b]] spans columns 5..11
    local line = "see [[a/b]] end"

    it("returns the inner target when the column is inside the link", function()
      assert.are.equal("a/b", wl._wikilink_at(line, 6))
    end)

    it("matches on the opening and closing brackets", function()
      assert.are.equal("a/b", wl._wikilink_at(line, 5))
      assert.are.equal("a/b", wl._wikilink_at(line, 11))
    end)

    it("returns nil when the column is outside any link", function()
      assert.is_nil(wl._wikilink_at(line, 1))
      assert.is_nil(wl._wikilink_at(line, 13))
    end)

    it("picks the link under the cursor when there are several", function()
      local l = "[[one]] and [[two]]"
      assert.are.equal("one", wl._wikilink_at(l, 3))
      assert.are.equal("two", wl._wikilink_at(l, 15))
    end)

    it("returns nil when the line has no wikilink", function()
      assert.is_nil(wl._wikilink_at("just [a](b) text", 7))
    end)
  end)

  describe("_normalize_target", function()
    it("appends .md to a bare path target", function()
      assert.are.equal("tickets/spcx-watch.md", wl._normalize_target("tickets/spcx-watch"))
    end)

    it("drops the alias", function()
      assert.are.equal(
        "food/meals/chicken-salad.md",
        wl._normalize_target("food/meals/chicken-salad|Chicken salad")
      )
    end)

    it("drops a heading anchor", function()
      assert.are.equal("notes/x.md", wl._normalize_target("notes/x#some-heading"))
    end)

    it("drops both heading and alias", function()
      assert.are.equal("notes/x.md", wl._normalize_target("notes/x#heading|Alias"))
    end)

    it("keeps an explicit extension as-is", function()
      assert.are.equal("assets/diagram.png", wl._normalize_target("assets/diagram.png"))
    end)

    it("returns nil for an empty target", function()
      assert.is_nil(wl._normalize_target("|just an alias"))
    end)
  end)

  -- Classify a standard link's destination: a URI scheme is external (opened in
  -- the browser/mail client), a leading `#` is an in-document anchor (not
  -- followable here), everything else is a local file path.
  describe("_classify_dest", function()
    it("classifies an http(s) URL as a url", function()
      assert.are.equal("url", wl._classify_dest("https://example.com"))
      assert.are.equal("url", wl._classify_dest("http://example.com"))
    end)

    it("classifies a mailto: destination as a url", function()
      assert.are.equal("url", wl._classify_dest("mailto:a@b.com"))
    end)

    it("classifies a relative path as a file", function()
      assert.are.equal("file", wl._classify_dest("PRODUCT.md"))
      assert.are.equal("file", wl._classify_dest("../docs/cli.md"))
    end)

    it("classifies an absolute path as a file", function()
      assert.are.equal("file", wl._classify_dest("/var/x/PRODUCT.md"))
    end)

    it("classifies a leading-# destination as an anchor", function()
      assert.are.equal("anchor", wl._classify_dest("#heading"))
    end)
  end)

  -- The standard markdown link `[text](dest)` covering the cursor column: what
  -- `gd` follows in a markdown buffer, routed by its destination (file, URL, or
  -- in-document anchor). Images (`![alt](src)`) are skipped, so `gd` on one
  -- falls through to LSP instead of opening the image path.
  describe("_standard_link_at", function()
    -- "see [spec](PRODUCT.md) end" -> [spec](PRODUCT.md) spans columns 5..22
    local line = "see [spec](PRODUCT.md) end"

    it("returns the text and dest when the column is inside the link", function()
      assert.are.same({ text = "spec", dest = "PRODUCT.md" }, wl._standard_link_at(line, 7))
    end)

    it("matches on the opening bracket and closing paren", function()
      assert.are.same({ text = "spec", dest = "PRODUCT.md" }, wl._standard_link_at(line, 5))
      assert.are.same({ text = "spec", dest = "PRODUCT.md" }, wl._standard_link_at(line, 22))
    end)

    it("returns nil when the column is outside any link", function()
      assert.is_nil(wl._standard_link_at(line, 1))
      assert.is_nil(wl._standard_link_at(line, 24))
    end)

    it("skips images", function()
      assert.is_nil(wl._standard_link_at("pre ![alt](img.png) post", 8))
    end)

    it("picks the link under the cursor when there are several", function()
      local l = "[a](x.md) and [b](y.md)"
      assert.are.same({ text = "a", dest = "x.md" }, wl._standard_link_at(l, 2))
      assert.are.same({ text = "b", dest = "y.md" }, wl._standard_link_at(l, 16))
    end)

    it("returns nil on a wikilink (not a standard link)", function()
      assert.is_nil(wl._standard_link_at("[[a/b]]", 3))
    end)
  end)

  -- Resolve a local-file link's destination to an absolute path: relative to the
  -- source file's directory (standard markdown semantics), with any `#fragment`
  -- dropped, percent-escapes decoded, and `.`/`..` segments collapsed. Absolute
  -- destinations are kept.
  describe("_resolve_file", function()
    it("resolves a relative destination against the source dir", function()
      assert.are.equal("/home/u/notes/PRODUCT.md", wl._resolve_file("PRODUCT.md", "/home/u/notes"))
    end)

    it("collapses ../ against the source dir", function()
      assert.are.equal("/home/u/notes/sib.md", wl._resolve_file("../sib.md", "/home/u/notes/sub"))
    end)

    it("keeps an absolute destination as-is", function()
      assert.are.equal("/abs/x.md", wl._resolve_file("/abs/x.md", "/home/u"))
    end)

    it("drops a trailing #fragment before resolving", function()
      assert.are.equal("/home/u/doc.md", wl._resolve_file("doc.md#sec", "/home/u"))
    end)

    -- CommonMark spells a space in a link destination as %20, so the on-disk
    -- name only appears after decoding -- without it every link to a file with
    -- a space in its name is reported as missing.
    it("decodes percent-escaped spaces", function()
      assert.are.equal("/home/u/sub/My Note.md", wl._resolve_file("sub/My%20Note.md", "/home/u"))
    end)

    it("decodes multi-byte percent escapes", function()
      assert.are.equal("/home/u/café.md", wl._resolve_file("caf%C3%A9.md", "/home/u"))
    end)

    -- The fragment split runs on the still-encoded dest (the separating `#` is
    -- raw), so an encoded `#` in the filename survives it and decodes after.
    it("decodes an escaped # instead of treating it as a fragment", function()
      assert.are.equal("/home/u/a#b.md", wl._resolve_file("a%23b.md", "/home/u"))
    end)

    it("decodes the path but not the dropped fragment", function()
      assert.are.equal("/home/u/My Note.md", wl._resolve_file("My%20Note.md#a%20b", "/home/u"))
    end)

    it("leaves a lone % that is not a valid escape", function()
      assert.are.equal("/home/u/100% done.md", wl._resolve_file("100% done.md", "/home/u"))
      assert.are.equal("/home/u/%zz.md", wl._resolve_file("%zz.md", "/home/u"))
    end)

    -- `+` means a space in a query string, never in a path -- a file called
    -- "a+b.md" must not resolve to "a b.md".
    it("does not treat + as a space", function()
      assert.are.equal("/home/u/a+b.md", wl._resolve_file("a+b.md", "/home/u"))
    end)
  end)

  describe("_project_root", function()
    it("resolves a non-git vault by its marker, where git.root could not", function()
      -- The deliberate non-merge with util.git: a wiki vault is rooted by any of
      -- WIKI_MARKERS (.marksman.toml here), not just .git, so a plain note
      -- directory with no repo still resolves. git.root (rev-parse) would return
      -- nil for this, which is why the two resolvers stay separate.
      local vault = vim.fn.tempname()
      vim.fn.mkdir(vault .. "/notes", "p")
      assert(io.open(vault .. "/.marksman.toml", "w")):close()
      assert.are.equal(
        vim.fn.resolve(vault),
        vim.fn.resolve(wl._project_root(vault .. "/notes/x.md"))
      )
      vim.fn.delete(vault, "rf")
    end)
  end)
end)

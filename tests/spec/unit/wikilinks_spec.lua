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

  -- The standard markdown link `[text](dest)` covering the cursor column, used to
  -- follow links directly in the raw source buffer (where the real dest is still
  -- present). Images (`![alt](src)`) are skipped.
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
  -- dropped and `.`/`..` segments collapsed. Absolute destinations are kept.
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
  end)

  describe("_links_in_lines", function()
    it("extracts wiki, file, and url links with their kind and target", function()
      local got = wl._links_in_lines({
        "see [[lola/product]] and [[food/x|Tasty]] here",
        "spec [the spec](PRODUCT.md) and site [Home](https://ex.com)",
      })
      assert.are.same({
        { display = "lola/product", kind = "wiki", target = "lola/product.md" },
        { display = "Tasty", kind = "wiki", target = "food/x.md" },
        { display = "the spec", kind = "file", target = "PRODUCT.md" },
        { display = "Home", kind = "url", target = "https://ex.com" },
      }, got)
    end)

    it("skips images and in-doc anchor links", function()
      assert.are.same({}, wl._links_in_lines({ "![alt](img.png) and [top](#heading)" }))
    end)

    it("skips links inside fenced code", function()
      assert.are.same({}, wl._links_in_lines({ "```", "[[raw]] [a](b.md)", "```" }))
    end)
  end)

  describe("_match_at", function()
    -- rendered preview line; "lola/product" spans cols 6..17
    local links = {
      { display = "lola/product", kind = "wiki", target = "lola/product.md" },
      { display = "food/x", kind = "wiki", target = "food/x.md" },
    }
    local line = "docs lola/product and food/x end"

    it("returns the link whose display covers the cursor column", function()
      local m = wl._match_at(links, line, 8)
      assert.are.equal(1, #m)
      assert.are.equal("lola/product.md", m[1].target)
    end)

    it("returns empty when the cursor is on plain prose", function()
      assert.are.same({}, wl._match_at(links, line, 1))
    end)

    it("matches the second link when the cursor is on it", function()
      local m = wl._match_at(links, line, 24)
      assert.are.equal("food/x.md", m[1].target)
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

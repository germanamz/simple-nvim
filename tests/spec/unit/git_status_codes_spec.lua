-- Pins the git-status-code grammar extracted from telescope_smart: the XY
-- porcelain dominant-letter rule (previously duplicated verbatim in
-- format_prefix and _git_changes), the letter->highlight and letter->category
-- maps, and the code->display formatter.
local git_status_codes = require("config.git_status_codes")

describe("config.git_status_codes", function()
  describe("dominant_letter", function()
    it("prefers the staged X letter when it is set", function()
      assert.are.equal("M", git_status_codes.dominant_letter("M", "M"))
      assert.are.equal("A", git_status_codes.dominant_letter("A", " "))
      assert.are.equal("R", git_status_codes.dominant_letter("R", "M"))
    end)

    it("falls back to the worktree Y letter when X is space or untracked", function()
      assert.are.equal("M", git_status_codes.dominant_letter(" ", "M"))
      assert.are.equal("?", git_status_codes.dominant_letter("?", "?"))
    end)

    it("returns a space when neither side carries a letter", function()
      assert.are.equal(" ", git_status_codes.dominant_letter(" ", " "))
    end)
  end)

  describe("hl_for_letter", function()
    it("maps each status letter to its highlight group", function()
      assert.are.equal("SmartFilesAdded", git_status_codes.hl_for_letter("A"))
      assert.are.equal("SmartFilesRenamed", git_status_codes.hl_for_letter("R"))
      assert.are.equal("SmartFilesRenamed", git_status_codes.hl_for_letter("C"))
      assert.are.equal("SmartFilesDeleted", git_status_codes.hl_for_letter("D"))
      assert.are.equal("SmartFilesModified", git_status_codes.hl_for_letter("M"))
      assert.are.equal("SmartFilesModified", git_status_codes.hl_for_letter("T"))
      assert.are.equal("SmartFilesUntracked", git_status_codes.hl_for_letter("?"))
      assert.are.equal("SmartFilesConflict", git_status_codes.hl_for_letter("U"))
    end)

    it("returns nil for an unknown letter", function()
      assert.is_nil(git_status_codes.hl_for_letter("X"))
      assert.is_nil(git_status_codes.hl_for_letter(" "))
    end)
  end)

  describe("category", function()
    it("buckets each letter into a count category", function()
      assert.are.equal("untracked", git_status_codes.category("?"))
      assert.are.equal("added", git_status_codes.category("A"))
      assert.are.equal("renamed", git_status_codes.category("R"))
      assert.are.equal("renamed", git_status_codes.category("C"))
      assert.are.equal("deleted", git_status_codes.category("D"))
      assert.are.equal("modified", git_status_codes.category("M"))
      assert.are.equal("modified", git_status_codes.category("T"))
    end)

    it("returns nil for a non-status letter", function()
      assert.is_nil(git_status_codes.category(" "))
      assert.is_nil(git_status_codes.category("X"))
      -- Merge conflicts get a highlight but no count bucket.
      assert.is_nil(git_status_codes.category("U"))
    end)
  end)

  describe("code_to_display", function()
    it("renders nothing for nil or empty codes", function()
      assert.are.equal("  ", (git_status_codes.code_to_display(nil)))
      assert.are.equal("  ", (git_status_codes.code_to_display("")))
      assert.are.equal("  ", (git_status_codes.code_to_display("  ")))
    end)

    it("renders untracked as ?* with one highlight", function()
      local t, hls = git_status_codes.code_to_display("??")
      assert.are.equal("?*", t)
      assert.are.same({ { { 0, 2 }, "SmartFilesUntracked" } }, hls)
    end)

    it("renders a staged add without an unstaged marker", function()
      local t, hls = git_status_codes.code_to_display("A ")
      assert.are.equal("A ", t)
      assert.are.same({ { { 0, 1 }, "SmartFilesAdded" } }, hls)
    end)

    it("renders a worktree modification with the unstaged marker", function()
      local t, hls = git_status_codes.code_to_display(" M")
      assert.are.equal("M*", t)
      assert.are.same({
        { { 0, 1 }, "SmartFilesModified" },
        { { 1, 2 }, "SmartFilesUnstaged" },
      }, hls)
    end)

    it("prefers the staged (X) letter as dominant when both are set", function()
      assert.are.equal("M*", (git_status_codes.code_to_display("MM")))
    end)

    it("renders a base-only code with the base highlight on the leading b", function()
      local t, hls = git_status_codes.code_to_display("bD")
      assert.are.equal("bD", t)
      assert.are.same({
        { { 0, 1 }, "SmartFilesBase" },
        { { 1, 2 }, "SmartFilesDeleted" },
      }, hls)
    end)

    it("colors a merge-conflict code with the conflict highlight", function()
      local t, hls = git_status_codes.code_to_display("UU")
      assert.are.equal("U*", t)
      assert.are.same({
        { { 0, 1 }, "SmartFilesConflict" },
        { { 1, 2 }, "SmartFilesUnstaged" },
      }, hls)
    end)
  end)

  describe("code_to_icon", function()
    it("returns nil for nil, empty, and clean codes", function()
      assert.is_nil((git_status_codes.code_to_icon(nil)))
      assert.is_nil((git_status_codes.code_to_icon("")))
      assert.is_nil((git_status_codes.code_to_icon("  ")))
    end)

    it("trims the trailing space from a fully staged code", function()
      local label, hl = git_status_codes.code_to_icon("A ")
      assert.are.equal("A", label)
      assert.are.equal("SmartFilesAdded", hl)
    end)

    it("keeps the unstaged marker and colors by the dominant letter", function()
      local label, hl = git_status_codes.code_to_icon(" M")
      assert.are.equal("M*", label)
      assert.are.equal("SmartFilesModified", hl)
    end)

    it("colors untracked as a whole", function()
      local label, hl = git_status_codes.code_to_icon("??")
      assert.are.equal("?*", label)
      assert.are.equal("SmartFilesUntracked", hl)
    end)

    it("colors base-only codes with the base group", function()
      local label, hl = git_status_codes.code_to_icon("bM")
      assert.are.equal("bM", label)
      assert.are.equal("SmartFilesBase", hl)
    end)
  end)
end)

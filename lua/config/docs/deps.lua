-- Enumerate the dependencies a project declares, for the docs picker.
--
-- Everything here reads a manifest off disk. That constraint is the whole
-- design: the ecosystems' own dependency-listing commands are too slow or too
-- fragile to sit behind a keypress. `go list -m all` is not offline-safe (it
-- needs a go.mod for every module in the graph, including test-deps-of-deps
-- that were never downloaded, and failed in 3 of 4 real projects under
-- GOPROXY=off); `cargo metadata` without --no-deps wants a writable registry;
-- `npm ls` reports a pnpm tree's real dependencies as "extraneous"; `gradle
-- dependencies` starts a daemon. Parsing the manifest is milliseconds and never
-- wrong about what the project *declared*, which is the question the picker
-- actually asks.
--
-- Direct dependencies only. The transitive graph is thousands of entries you
-- did not choose and cannot act on.

local M = {}

-- Probed in order. A repo can carry several manifests — a Go service with a
-- package.json for its tooling is ordinary — so all matches contribute and the
-- picker labels each row with the ecosystem it came from.
local MANIFESTS = {
  { file = "go.mod", adapter = "go", lang = "go" },
  { file = "Cargo.toml", adapter = "rust", lang = "rust" },
  { file = "package.json", adapter = "js", lang = "js" },
  { file = "pyproject.toml", adapter = "python", lang = "python" },
  { file = "requirements.txt", adapter = "python", lang = "python" },
  { file = ".terraform.lock.hcl", adapter = "terraform", lang = "terraform" },
}

-- What a row is, in the order you are likely to want it. The Go adapter also
-- emits the 187-package standard library, which is genuinely useful to browse
-- but must not outrank the dependencies the project actually chose: ranked
-- purely alphabetically it opened the picker on `archive/tar` and pushed the
-- first real dependency to row 75. Unknown or absent kinds rank as direct,
-- since an adapter that does not classify its rows only emits direct ones.
local KIND_RANK = {
  direct = 1,
  provider = 1,
  dev = 2,
  build = 2,
  workspace = 2,
  indirect = 3,
  stdlib = 4,
}

--- Where to start walking up from: the current file's directory, else cwd.
---
--- A scratch or unnamed buffer has no path of its own, and the cwd is the only
--- other thing that says which project the user means.
---@param bufnr integer
---@return string
local function start_dir(bufnr)
  local name = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
  if name ~= "" then
    return vim.fs.dirname(name)
  end
  return vim.uv.cwd() or "."
end

--- Every direct dependency declared by the project around `bufnr`.
---
--- Rows carry the adapter that produced them so the picker can ask it for a URL
--- without re-deriving which language the row belongs to.
---@param bufnr integer
---@return table[] rows
function M.collect(bufnr)
  local dir = start_dir(bufnr)
  local rows = {}
  local seen = {}

  for _, m in ipairs(MANIFESTS) do
    -- Two of the entries map to the same adapter (pyproject.toml and
    -- requirements.txt), and a project may have both; the first hit wins so its
    -- dependencies are not listed twice.
    if not seen[m.adapter] then
      local root = vim.fs.root(dir, m.file)
      if root then
        local ok, ad = pcall(require, "config.docs.adapters." .. m.adapter)
        if ok and type(ad) == "table" and ad.deps then
          local ctx = { bufnr = bufnr, root = root, word = "", line = "", col = 0 }
          -- A malformed manifest is a normal thing to have open; it must not
          -- take the whole picker down with it.
          local got, items = pcall(ad.deps, ctx)
          if got and type(items) == "table" then
            seen[m.adapter] = true
            for _, item in ipairs(items) do
              item.lang = m.lang
              item.root = root
              item.adapter = ad
              rows[#rows + 1] = item
            end
          end
        end
      end
    end
  end

  M.sort(rows)
  return rows
end

--- Chosen dependencies first, then dev/build, then indirect, then stdlib.
---
--- Everything below rank 1 is kept rather than filtered: an indirect module is
--- a real answer to "what is in this build", and the standard library is half
--- of what you want to read in Go. They are only ever sunk, never dropped.
---@param rows table[]
function M.sort(rows)
  table.sort(rows, function(a, b)
    local ar = KIND_RANK[a.kind] or 1
    local br = KIND_RANK[b.kind] or 1
    if ar ~= br then
      return ar < br
    end
    if a.lang ~= b.lang then
      return a.lang < b.lang
    end
    return (a.name or "") < (b.name or "")
  end)
end

--- `serde                    1.0.219      rust`
---
--- Every kind but `direct` is spelled out. Adapters emit dev, build, workspace,
--- indirect, stdlib and provider rows, and rendering them all as bare names
--- makes a picker that looks flat while being ranked.
---@param row table
---@return string
function M.format(row)
  local version = row.version or ""
  local kind = row.kind
  local tag = (kind and kind ~= "direct") and ("%s (%s)"):format(row.lang, kind) or row.lang
  return ("%-34s %-14s %s"):format(row.name or "?", version, tag)
end

return M

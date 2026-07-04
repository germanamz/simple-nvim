-- Ollama model-management modal (v2): browse / install / delete / set-active the
-- local FIM completion model from a single Telescope UI, no CLI round-trips. This
-- is the file the design's "v2 — Model-management modal" section governs; the old
-- lean picker (pick_model/fetch_models/sort_models/is_preferred) moved here out of
-- config.ai so that module stays pure runtime-state (toggle, ghost swap, active
-- model + persistence). Selection routes back into config.ai.set_model, which
-- still owns the switch/persist/notify — this file never persists the model
-- itself, it only decides *which* name to hand over (and whether to confirm).
--
-- Why a curated catalog + a scraped cache + a free-text escape hatch (design's
-- "Key constraint"): Ollama has NO official API to enumerate the remote library
-- (issue #286; registry tags/list 404s; ollama.com/api/tags is a ~34-model
-- featured subset). So the installable universe is assembled from three sources,
-- merged and de-duped in build_rows():
--   1. CATALOG — a bundled Lua table of known-good FIM base/code models (+ a few
--      chat models flagged fim=false), the up-front "what should I install?" list.
--   2. LIBRARY CACHE — stdpath("state")/ollama-library.json = { fetched_at, names }.
--      Read on open (a guarded file read, NEVER a network call); refreshed only by
--      the explicit <C-u> action which scrapes ollama.com/library at runtime.
--   3. INSTALLED — GET /api/tags, the live local set (name:tag, size, details).
--
-- FIM capability (design): pre-install it comes from the CATALOG `fim` flag; once
-- installed it is verified authoritatively via POST /api/show
-- (`capabilities ∋ "insert"`, fallback: template contains ".Suffix"). The <CR>
-- gate confirms before setting a non-FIM (or FIM-unknown) model active, so a chat
-- model can't be silently wired in as the completion backend.
--
-- Startup safety (same discipline as config.ai): requiring this module runs NO
-- network / ollama / ollama.com call and reads no file — it only builds the
-- CATALOG-derived lookup and returns M. Every HTTP/curl/file touch lives inside
-- the modal actions, reached only via <leader>am / :AIModel. So `make test-smoke`
-- (headless, no Ollama, minuet absent) stays green: this file must never error at
-- require-time.
--
-- Reports A/B/C are the verified ground truth for the API shapes and idioms used
-- below; where a fact was UNCONFIRMED the spec fallback is used and commented.
local M = {}

local state_util = require("util.state")

-- Ollama's local HTTP surface (all localhost; never leaves the machine).
local OLLAMA_HOST = "http://localhost:11434"
local OLLAMA_TAGS_URL = OLLAMA_HOST .. "/api/tags"
local OLLAMA_SHOW_URL = OLLAMA_HOST .. "/api/show"
local OLLAMA_PULL_URL = OLLAMA_HOST .. "/api/pull"
local OLLAMA_DELETE_URL = OLLAMA_HOST .. "/api/delete"

-- The one remote page we scrape (opt-in, via <C-u> only). No API contract — see
-- scrape_library() for the fragility notes carried over from Report B.
local LIBRARY_URL = "https://ollama.com/library"

-- Mirrors config.ai's DEFAULT_MODEL (kept a private literal there, not on its M).
-- Used only for the "nothing installed yet" hint string, so a duplicated literal
-- is cheaper than a cross-module getter; if the default ever changes, change both.
local DEFAULT_MODEL = "qwen2.5-coder:7b-base"

-- Cmdline progress throttle: at most one nvim_echo repaint per this interval, so
-- a fast /api/pull stream can't flood redraws (design/Report A U4: ≤5/s).
local PROGRESS_THROTTLE_MS = 200

-- Curated install catalog. Each entry is a model *family*; `tags` (when present)
-- are expanded into one installable `name:tag` row each. For FIM families the tags
-- are the *base* variants on purpose — a bare `:latest` is usually the instruct
-- build, which is NOT clean FIM, so we never surface the bare base name for those
-- (the library cache still can, for browsing). Chat families carry no `tags`: they
-- appear as the bare base name and only matter as a `fim = false` warning source.
local CATALOG = {
  -- FIM-capable base / code models (fim = true). Tags are FIM base variants.
  {
    name = "qwen2.5-coder",
    fim = true,
    tags = { "0.5b-base", "1.5b-base", "3b-base", "7b-base", "14b-base", "32b-base" },
    desc = "Qwen2.5 Coder — FIM base (recommended default)",
  },
  {
    name = "qwen3-coder",
    fim = true,
    tags = { "30b" },
    desc = "Qwen3 Coder",
  },
  {
    name = "codegemma",
    fim = true,
    tags = { "2b", "code" },
    desc = "Google CodeGemma (2b / code = FIM)",
  },
  {
    name = "starcoder2",
    fim = true,
    tags = { "3b", "7b", "15b" },
    desc = "BigCode StarCoder2 — FIM",
  },
  {
    name = "deepseek-coder",
    fim = true,
    tags = { "1.3b-base", "6.7b-base", "33b-base" },
    desc = "DeepSeek Coder — FIM base",
  },
  {
    name = "deepseek-coder-v2",
    fim = true,
    tags = { "16b" },
    desc = "DeepSeek Coder V2 — FIM",
  },
  {
    name = "codellama",
    fim = true,
    tags = { "7b-code", "13b-code", "34b-code" },
    desc = "Meta Code Llama (code = FIM)",
  },
  {
    name = "codestral",
    fim = true,
    tags = { "22b" },
    desc = "Mistral Codestral — FIM",
  },
  {
    name = "stable-code",
    fim = true,
    tags = { "3b" },
    desc = "StabilityAI stable-code — FIM",
  },
  -- Chat models (fim = false): installable/switchable, but the <CR> gate warns
  -- before wiring one in as the completion model (garbage FIM output otherwise).
  {
    name = "llama3.1",
    fim = false,
    desc = "Meta Llama 3.1 — chat (no FIM)",
  },
  {
    name = "gemma3",
    fim = false,
    desc = "Google Gemma 3 — chat (no FIM)",
  },
}

-- exact-name -> fim flag, built once at require-time from CATALOG (pure Lua, no
-- side effects). Keyed by the exact installable name — "family:tag" for tagged
-- FIM families, the bare family name for tag-less chat entries — so only names
-- the catalog actually vouches for inherit a flag. Keying by family would let
-- an installed instruct tag (codellama:7b-instruct) inherit the base tags'
-- fim=true and slip past the <CR> /api/show gate. `nil` = unknown.
local CURATED_FIM = {}
for _, e in ipairs(CATALOG) do
  if e.tags then
    for _, t in ipairs(e.tags) do
      CURATED_FIM[e.name .. ":" .. t] = e.fim
    end
  else
    CURATED_FIM[e.name] = e.fim
  end
end

-- Memoized POST /api/show results, name -> { fim, family, parameter_size,
-- quantization_level }. Populated lazily by show_model() at gate time; reused so a
-- refresh can show a real FIM badge once one was resolved. Only positive lookups
-- are cached (a nil/unreachable answer is retried next time).
local show_cache = {}

-- The in-flight /api/pull process handle, or nil. Guards against a second
-- concurrent pull (design "second-invocation sanely"); cleared in on_exit.
local active_pull = nil

-- True while an ollama.com/library <C-u> scrape is running. Guards a second
-- concurrent scrape (which could tear the cache write); cleared in its callback.
local active_scrape = false

-- Monotonic clock of the last progress repaint, for PROGRESS_THROTTLE_MS. Reset
-- to 0 at each pull start so the first line paints immediately.
local last_echo = 0

-- Per-pull download aggregation: digest -> { total, completed } (bytes) for every
-- layer/blob seen so far in the CURRENT /api/pull stream. A model pulls as many
-- layers, each with its own digest and its own total/completed, so the overall
-- progress figure must SUM across all digests, not read one layer. Reset to {} at
-- each pull start (start_pull) so a later pull never inherits stale totals.
local pull_totals = {}

-- FIM autocomplete needs a *base* code model, so *coder* / *-base* names count as
-- FIM-eligible. (Moved from config.ai; now the sole "FIM-eligible?" heuristic for
-- rows whose fim flag is unknown, e.g. scraped library names not in the catalog —
-- feeds both build_rows' ranking float and the <C-f> filter via is_fim_eligible.)
local function is_preferred(name)
  local lower = name:lower()
  return lower:find("coder", 1, true) ~= nil or lower:find("-base", 1, true) ~= nil
end

-- A row counts as FIM-eligible when the catalog says so, or (flag unknown) when
-- the name looks like a coder/base model. Drives both the ranking float and the
-- <C-f> "FIM-eligible only" filter, so the two never disagree.
local function is_fim_eligible(row)
  return row.fim == true or (row.fim == nil and is_preferred(row.name))
end

-- Bytes -> decimal GB string "x.ygb" (bytes / 1e9, the way ollama itself reports
-- sizes; lowercase to match the modal's terse rows). One decimal, but a trailing
-- ".0" is dropped so whole sizes read "8gb" not "8.0gb". Empty string for a
-- missing size so an unknown / not-installed row shows nothing (never a placeholder).
local function size_gb(bytes)
  if not bytes then
    return ""
  end
  return (string.format("%.1fgb", bytes / 1e9):gsub("%.0gb$", "gb"))
end

-- "5m ago" / "2h ago" / "3d ago" for the cache-age hint in the prompt title.
local function age_str(fetched_at)
  if not fetched_at then
    return "never"
  end
  local secs = os.time() - fetched_at
  if secs < 60 then
    return secs .. "s ago"
  elseif secs < 3600 then
    return math.floor(secs / 60) .. "m ago"
  elseif secs < 86400 then
    return math.floor(secs / 3600) .. "h ago"
  end
  return math.floor(secs / 86400) .. "d ago"
end

-- Library cache path, resolved per call so the test harness's XDG swap is honored
-- (mirrors config.ai.model_path / config.review_base.state_path).
function M.library_cache_path()
  return vim.fn.stdpath("state") .. "/ollama-library.json"
end

-- Guarded read of the library cache. Returns { fetched_at, names } or nil (missing
-- / empty / malformed / absent state dir). Never errors — this is the only thing
-- the modal touches on open, and it must degrade to curated-only silently.
local function read_library_cache()
  local raw = state_util.read_file(M.library_cache_path())
  if not raw or raw == "" then
    return nil
  end
  local ok, data = pcall(vim.json.decode, raw)
  if ok and type(data) == "table" and type(data.names) == "table" then
    -- A missing/malformed fetched_at must not make age_str's subtraction throw
    -- and abort M.open: keep the (present) names but treat the cache as ageless
    -- (age_str(nil) => "never"). Only a bad `names` degrades to curated-only.
    if type(data.fetched_at) ~= "number" then
      data.fetched_at = nil
    end
    return data
  end
  return nil
end

-- Atomic write of the library cache via util.state (shared with config.ai's
-- model file and review_base's store) so a crashed write never leaves a
-- half-written JSON file.
local function write_library_cache(names)
  state_util.write_atomic(
    M.library_cache_path(),
    vim.json.encode({ fetched_at = os.time(), names = names })
  )
end

-- Installed set via GET /api/tags (plenary.curl), falling back to `ollama list`
-- (names only — the CLI gives no sizes/details). Returns
-- { map = { [name] = { size, family, parameter_size, quantization_level } },
--   names = { ... }, reachable = bool }. `reachable` lets the modal tell "server
-- down" (open catalog-only) from "server up, nothing pulled" (empty installed).
local function fetch_installed()
  local map, names = {}, {}
  local ok, curl = pcall(require, "plenary.curl")
  if ok then
    local res
    local got = pcall(function()
      -- on_error: without it plenary raises error() inside a luv callback on a
      -- refused/failed connection — where the surrounding pcall can't catch it
      -- — printing a stack trace and spinning the full timeout. With it, the
      -- sync call returns an empty response table (no .status; on_error's
      -- return is discarded on the sync path), which the status check below
      -- already treats as unreachable.
      res = curl.get(OLLAMA_TAGS_URL, {
        timeout = 1500,
        on_error = function(err)
          return err
        end,
      })
    end)
    if got and res and res.status == 200 and res.body then
      local dok, decoded = pcall(vim.json.decode, res.body)
      if dok and type(decoded) == "table" and type(decoded.models) == "table" then
        for _, m in ipairs(decoded.models) do
          if type(m) == "table" and type(m.name) == "string" then
            names[#names + 1] = m.name
            local d = type(m.details) == "table" and m.details or {}
            map[m.name] = {
              size = m.size,
              family = d.family,
              parameter_size = d.parameter_size,
              quantization_level = d.quantization_level,
            }
          end
        end
        return { map = map, names = names, reachable = true }
      end
    end
  end

  local sok, out = pcall(function()
    -- Bounded like the curl path above: a wedged ollama CLI must not freeze
    -- the UI on modal open. A timeout returns code 124, which the code == 0
    -- check below already treats as unreachable.
    return vim.system({ "ollama", "list" }, { text = true }):wait(2000)
  end)
  if sok and out and out.code == 0 and out.stdout then
    for line in out.stdout:gmatch("[^\n]+") do
      local name = line:match("^(%S+)")
      if name and name ~= "NAME" then
        names[#names + 1] = name
        map[name] = {}
      end
    end
    return { map = map, names = names, reachable = true }
  end

  return { map = map, names = names, reachable = false }
end

-- POST /api/show for one installed model. Returns { fim, family, parameter_size,
-- quantization_level } or nil (unreachable / not installed / decode fail). FIM is
-- authoritative here: `capabilities ∋ "insert"` (Report B, confirmed from
-- capability.go). Fallback for older servers that omit `capabilities`: the model
-- is FIM-capable when its template references `.Suffix` (exactly how the server
-- itself derives the insert capability). Memoized in show_cache.
local function show_model(name)
  if show_cache[name] then
    return show_cache[name]
  end
  local ok, curl = pcall(require, "plenary.curl")
  if not ok then
    return nil
  end
  local res
  local got = pcall(function()
    res = curl.post(OLLAMA_SHOW_URL, {
      headers = { content_type = "application/json" },
      body = vim.json.encode({ model = name }),
      timeout = 3000,
      -- See fetch_installed: keeps a server-down failure a quiet nil instead
      -- of an uncatchable luv-callback error().
      on_error = function(err)
        return err
      end,
    })
  end)
  if not got or not res or res.status ~= 200 or not res.body then
    return nil
  end
  local dok, obj = pcall(vim.json.decode, res.body)
  if not dok or type(obj) ~= "table" then
    return nil
  end
  local fim = false
  if type(obj.capabilities) == "table" then
    for _, c in ipairs(obj.capabilities) do
      if c == "insert" then
        fim = true
        break
      end
    end
  elseif type(obj.template) == "string" and obj.template:find(".Suffix", 1, true) then
    fim = true
  end
  local d = type(obj.details) == "table" and obj.details or {}
  local info = {
    fim = fim,
    family = d.family,
    parameter_size = d.parameter_size,
    quantization_level = d.quantization_level,
  }
  show_cache[name] = info
  return info
end

-- DELETE /api/delete. Returns ok, err. 200 => deleted (no body), 404 => not found
-- (Report B). Synchronous with a short timeout: delete is a fast local op, and the
-- modal wants the refreshed list right after.
local function delete_model(name)
  local ok, curl = pcall(require, "plenary.curl")
  if not ok then
    return false, "plenary.curl unavailable"
  end
  local res
  local got = pcall(function()
    res = curl.delete(OLLAMA_DELETE_URL, {
      headers = { content_type = "application/json" },
      body = vim.json.encode({ model = name }),
      timeout = 5000,
      -- See fetch_installed: keeps a server-down failure on the "unreachable"
      -- branch instead of an uncatchable luv-callback error().
      on_error = function(err)
        return err
      end,
    })
  end)
  -- A process-level failure yields an empty response table with no .status —
  -- report it as unreachable rather than "HTTP nil".
  if not got or not res or not res.status then
    return false, "Ollama unreachable"
  end
  if res.status == 200 then
    return true
  elseif res.status == 404 then
    return false, "not found"
  end
  return false, "HTTP " .. tostring(res.status)
end

-- Streamed POST /api/pull. Per Report A U1 we shell out to curl via vim.system
-- (the design's named primary) and self-buffer partial NDJSON lines: vim.system's
-- stdout callback delivers RAW pipe chunks, so we accumulate and split on "\n"
-- before vim.json.decode. All UI is dispatched via vim.schedule (the callbacks run
-- off the main loop). Terminal rules (Report B): a line with an `error` key is a
-- failure; `{"status":"success"}` is success; everything else is progress.
-- `--no-buffer -sS -N` = prompt flushing, show curl errors on stderr, no output
-- buffering. active_pull guards a second concurrent pull.
local function pull_model(model, on_progress, on_done, on_err)
  if active_pull then
    vim.notify("A model pull is already in progress", vim.log.levels.WARN)
    return
  end
  local buf, stderr_buf, failed = "", "", false
  local ok, handle = pcall(vim.system, {
    "curl",
    "--no-buffer",
    "-sS",
    "-N",
    -- --fail-with-body: an HTTP >=400 yields a nonzero exit (so on_exit treats it
    -- as failure) while still delivering the JSON error body for us to surface.
    "--fail-with-body",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-d",
    vim.json.encode({ model = model, stream = true }),
    OLLAMA_PULL_URL,
  }, {
    text = true,
    stderr = function(_, data)
      if data then
        stderr_buf = stderr_buf .. data
      end
    end,
    stdout = function(_, data)
      if not data then
        return
      end
      buf = buf .. data
      while true do
        local nl = buf:find("\n", 1, true)
        if not nl then
          break
        end
        local line = buf:sub(1, nl - 1)
        buf = buf:sub(nl + 1)
        if line ~= "" then
          local dok, obj = pcall(vim.json.decode, line)
          if dok and type(obj) == "table" then
            if obj.error then
              failed = true
              vim.schedule(function()
                on_err(obj.error)
              end)
            elseif obj.status == "success" then
              -- terminal success handled in on_exit (code 0)
            else
              vim.schedule(function()
                on_progress(obj)
              end)
            end
          end
        end
      end
    end,
  }, function(res)
    active_pull = nil
    -- Flush a final line the stream left without a trailing "\n" (an error body
    -- from --fail-with-body typically arrives this way): decode it and honor an
    -- `error` key so the outcome below sees the failure.
    if buf ~= "" then
      local dok, obj = pcall(vim.json.decode, vim.trim(buf))
      if dok and type(obj) == "table" and obj.error then
        failed = true
        vim.schedule(function()
          on_err(obj.error)
        end)
      end
    end
    vim.schedule(function()
      -- Success only when no error line was seen AND curl exited 0; otherwise
      -- surface the error (stderr / nonzero exit) — never a false "Pulled X".
      if failed then
        return
      end
      if res.code ~= 0 then
        local msg = vim.trim(stderr_buf)
        on_err(msg ~= "" and msg or ("curl exited " .. res.code))
      else
        on_done()
      end
    end)
  end)
  if not ok then
    vim.notify("Could not start pull (is `curl` installed?)", vim.log.levels.ERROR)
    return
  end
  active_pull = handle
end

-- Scrape ollama.com/library for base model names, cache them, refresh. Async via
-- plenary.curl `callback` (Report A: a callback makes the request non-blocking) so
-- the UI never freezes on the network. Extraction is Report B's confirmed anchor
-- pattern, loosened to accept single OR double quotes; the `[%w_.-]+` class stops
-- at `:` and `/`, so tag/subpath links are excluded for free, and we dedupe.
--
-- FRAGILITY (Report B): this is HTML scraping with no versioning contract — Ollama
-- can restyle the page and break the pattern; on zero matches we treat it as a
-- failure and KEEP the old cache. `/library` is a curated popularity subset, not
-- the full catalog; the free-text pull (<C-p>) covers anything missing.
local function scrape_library(on_done, on_err)
  local function handle(body)
    if not body or body == "" then
      return on_err("empty response")
    end
    local names, seen = {}, {}
    for name in body:gmatch("href=[\"']/library/([%w_.-]+)") do
      if not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
    if #names == 0 then
      return on_err("no models parsed (page format changed?)")
    end
    table.sort(names)
    write_library_cache(names)
    on_done(names)
  end

  local ok, curl = pcall(require, "plenary.curl")
  if ok then
    local got = pcall(function()
      curl.get(LIBRARY_URL, {
        -- opts.timeout only applies to plenary's sync path (job:sync); in
        -- callback mode it silently does nothing, so the 10s bound rides raw
        -- curl args instead.
        raw = { "--max-time", "10" },
        callback = function(res)
          vim.schedule(function()
            if res and res.status == 200 and res.body then
              handle(res.body)
            else
              on_err(res and ("HTTP " .. tostring(res.status)) or "no response")
            end
          end)
        end,
        -- Without on_error, a process-level curl failure (network down, DNS)
        -- makes plenary raise error() inside a luv callback — the pcall above
        -- returned long ago, so nothing catches it, on_err never runs, and
        -- active_scrape wedges true forever, permanently blocking <C-u>.
        on_error = function(err)
          vim.schedule(function()
            on_err((err and err.message) or "curl failed")
          end)
        end,
      })
    end)
    if got then
      return
    end
  end

  -- Fallback: curl via vim.system (Report A), also async.
  local sok = pcall(vim.system, { "curl", "-sSL", LIBRARY_URL }, { text = true }, function(res)
    vim.schedule(function()
      if res.code == 0 and res.stdout and res.stdout ~= "" then
        handle(res.stdout)
      else
        on_err(vim.trim(res.stderr or "") ~= "" and res.stderr or "curl failed")
      end
    end)
  end)
  if not sok then
    on_err("no HTTP client (plenary.curl / curl) available")
  end
end

-- Throttled, in-place cmdline progress line (Report A U3): nvim_echo(.., false, {})
-- writes the cmdline WITHOUT adding to :messages, and a single short line
-- overwrites the previous one. Called inside vim.schedule from the pull stream.
--
-- A pull streams MANY layers, each keyed by its own `digest` with its own `total`
-- / `completed` byte counts, so one layer's numbers would misreport the whole
-- download. We stash each digest's latest counts in pull_totals (recorded BEFORE
-- the throttle so a skipped repaint never drops a layer) and SUM across every
-- digest for the overall figure, rendered "<pct>% - <done>gb/<total>gb". Lines with
-- no byte counts (pulling manifest / verifying sha256 digest / writing manifest /
-- removing unused layers) are status-only — show the status string, not a stale
-- bar — as is the very-early state before any layer has reported a total.
local function show_progress(model, obj)
  -- Record this layer's latest byte counts first, unthrottled, so a repaint we skip
  -- for the throttle never loses a digest from the running total.
  if obj.digest and obj.total and obj.completed then
    pull_totals[obj.digest] = { total = obj.total, completed = obj.completed }
  end
  local now = vim.uv.hrtime() / 1e6
  if now - last_echo < PROGRESS_THROTTLE_MS then
    return
  end
  last_echo = now
  local line
  if obj.total and obj.completed then
    -- Byte-bearing line: aggregate across all digests seen so far this pull.
    local overall_total, overall_completed = 0, 0
    for _, layer in pairs(pull_totals) do
      overall_total = overall_total + (layer.total or 0)
      overall_completed = overall_completed + (layer.completed or 0)
    end
    if overall_total > 0 then
      local pct = math.floor(overall_completed / overall_total * 100)
      line = string.format(
        "Pulling %s: %d%% - %s/%s",
        model,
        pct,
        size_gb(overall_completed),
        size_gb(overall_total)
      )
    else
      -- No total yet (very first layer) — show the status, not a divide-by-zero bar.
      line = string.format("Pulling %s: %s", model, obj.status or "")
    end
  else
    -- Status-only line (manifest / verifying / writing / removing): show the status.
    line = string.format("Pulling %s: %s", model, obj.status or "")
  end
  vim.api.nvim_echo({ { line, "None" } }, false, {})
end

-- Clear the cmdline progress line (empty echo, still out of :messages).
local function clear_progress()
  vim.api.nvim_echo({ { "" } }, false, {})
end

-- Merge curated ∪ installed ∪ library into de-duped rows. Order matters: INSTALLED
-- rows are added first so their live flags/details win over a curated tag of the
-- same name; curated fills the "should-install" set; the library cache adds the
-- long tail of scraped base names. `active` marks the persisted completion model
-- (a full name:tag) wherever it lands. `fim_only` drops non-FIM-eligible rows.
local function build_rows(active, installed, cache_names, fim_only)
  local rows, seen = {}, {}

  local function add(name, fim, desc, is_installed, info)
    if seen[name] then
      return
    end
    seen[name] = true
    -- Prefer a resolved /api/show verdict if we already have one, else the
    -- curated/explicit hint (may be nil = unknown). Branch on nil explicitly:
    -- a resolved fim=false is authoritative and MUST win, but `... or fim` would
    -- discard that false and fall back to the curated flag — the bug this fixes.
    local resolved = is_installed and show_cache[name] or nil
    local row_fim = fim
    if resolved ~= nil then
      row_fim = resolved.fim
    end
    rows[#rows + 1] = {
      name = name,
      installed = is_installed or false,
      active = name == active,
      fim = row_fim,
      size = info and info.size or nil,
      parameter_size = info and info.parameter_size or nil,
      family = info and info.family or nil,
      desc = desc,
      install_target = name,
    }
  end

  -- 1. Installed (full name:tag), richest data. FIM hint from the catalog family.
  for _, name in ipairs(installed.names or {}) do
    local info = installed.map[name] or {}
    local parts = {}
    if info.family and info.family ~= "" then
      parts[#parts + 1] = info.family
    end
    if info.quantization_level and info.quantization_level ~= "" then
      parts[#parts + 1] = info.quantization_level
    end
    add(name, CURATED_FIM[name], table.concat(parts, " · "), true, info)
  end

  -- 2. Curated catalog: expand FIM families into base-tag rows; chat families as
  --    the bare base name.
  for _, e in ipairs(CATALOG) do
    if e.tags then
      for _, t in ipairs(e.tags) do
        add(e.name .. ":" .. t, e.fim, e.desc, false)
      end
    else
      add(e.name, e.fim, e.desc, false)
    end
  end

  -- 3. Library cache: scraped base names not already covered.
  for _, base in ipairs(cache_names or {}) do
    add(base, CURATED_FIM[base], "ollama.com/library", false)
  end

  if fim_only then
    local filtered = {}
    for _, row in ipairs(rows) do
      if is_fim_eligible(row) then
        filtered[#filtered + 1] = row
      end
    end
    rows = filtered
  end

  -- Rank: active first, then installed, then FIM-eligible, then name. Telescope's
  -- generic_sorter preserves this order while the prompt is empty (the modal opens
  -- in normal mode), and re-ranks by match once the user types.
  table.sort(rows, function(a, b)
    local function rank(r)
      local n = 0
      if not r.active then
        n = n + 1000
      end
      if not r.installed then
        n = n + 100
      end
      if not is_fim_eligible(r) then
        n = n + 10
      end
      return n
    end
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then
      return ra < rb
    end
    return a.name < b.name
  end)

  return rows
end

-- Test seams (tests/spec/unit/ai_models_spec.lua): build_rows is the module's
-- most logic-dense pure function (three-source merge/dedupe, the resolved-
-- fim=false-beats-curated-hint rule, the rank order), and show_cache is the
-- module state it reads. show_cache is only ever mutated in place, so the
-- exported reference stays valid.
M._build_rows = build_rows
M._show_cache = show_cache

-- One-line display: <marker> <name> <FIM badge> <size> <desc>. Marker precedence
-- ★ active > ● installed > ○ available (design). Plain string (no highlight
-- ranges) to match config.ai's simple entry style.
local function make_display(row)
  local marker = row.active and "★" or (row.installed and "●" or "○")
  local badge = row.fim == true and "FIM" or (row.fim == false and "chat" or " ? ")
  local meta = ""
  if row.installed then
    local m = {}
    if row.parameter_size and row.parameter_size ~= "" then
      m[#m + 1] = row.parameter_size
    end
    if row.size then
      m[#m + 1] = size_gb(row.size)
    end
    meta = table.concat(m, " ")
  end
  return string.format("%s %-30s %-4s %-12s %s", marker, row.name, badge, meta, row.desc or "")
end

local function make_finder(rows)
  local finders = require("telescope.finders")
  return finders.new_table({
    results = rows,
    entry_maker = function(row)
      return {
        value = row,
        ordinal = row.name .. " " .. (row.desc or ""),
        display = make_display(row),
      }
    end,
  })
end

-- Decide FIM for the <CR> gate: installed => authoritative /api/show (memoized);
-- else the curated/explicit flag on the row (may be nil = unknown).
local function resolve_fim(row)
  if row.installed then
    local info = show_model(row.name)
    if info then
      return info.fim
    end
  end
  return row.fim
end

-- The model-management modal. Repo Telescope idiom (Report C): pickers.new({}, {..})
-- then :find(), initial_mode = "normal". Requires of telescope live here (call
-- time), never at module load, to keep require-time side-effect-free.
function M.open()
  local active = require("config.ai").load_persisted_model()
  local installed = fetch_installed()
  if not installed.reachable then
    vim.notify(
      "Ollama unreachable — showing catalog only; start `ollama serve` to install/manage "
        .. "(default: `ollama pull "
        .. DEFAULT_MODEL
        .. "`)",
      vim.log.levels.WARN
    )
  end

  local cache = read_library_cache()
  local cache_names = cache and cache.names or {}

  -- Live sources captured in this closure. `installed` and `cache_names` are the
  -- last-known sets: <C-f> (a pure client-side FIM filter) rebuilds rows from
  -- them with NO network refetch, and a transient unreachable Ollama KEEPS the
  -- previous `installed` instead of blanking the list. Only <C-d>/<C-u> live
  -- re-fetch. `fim_only` is the <C-f> toggle the rebuild reads.
  local fim_only = false

  local pickers = require("telescope.pickers")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  -- Rebuild the row set from the CACHED installed/library data (no network) and
  -- swap it into the open picker in place (Report A U3: get_current_picker +
  -- picker:refresh(new_finder)). Guarded so a rebuild scheduled after the modal
  -- closed (e.g. an async pull's on_done) is a no-op.
  local function rebuild(prompt_bufnr)
    local ok, picker = pcall(action_state.get_current_picker, prompt_bufnr)
    if not ok or not picker then
      return
    end
    local active2 = require("config.ai").load_persisted_model()
    local rows = build_rows(active2, installed, cache_names, fim_only)
    picker:refresh(make_finder(rows), { reset_prompt = false })
  end

  -- Live re-fetch of the installed set (<C-d>/<C-u>), then rebuild. On a transient
  -- unreachable server KEEP the previously-known `installed` rather than replacing
  -- it with an empty one. Skips the fetch once the modal is gone.
  local function refetch(prompt_bufnr)
    local ok, picker = pcall(action_state.get_current_picker, prompt_bufnr)
    if not ok or not picker then
      return
    end
    local fresh = fetch_installed()
    if fresh.reachable then
      installed = fresh
    end
    rebuild(prompt_bufnr)
  end

  -- Kick off a streamed pull with cmdline progress; notify at start/done/error.
  -- Concurrency + confirm are checked FIRST, before any notify / last_echo reset,
  -- so a rejected or duplicate pull never prints a misleading "Pulling X" nor
  -- perturbs a running pull's throttle. Then close the picker BEFORE streaming so
  -- the in-place cmdline progress line is visible instead of clobbered by the
  -- open float (the row refresh is moot once closed — refetch no-ops).
  local function start_pull(prompt_bufnr, model)
    if active_pull then
      vim.notify("A model pull is already in progress", vim.log.levels.WARN)
      return
    end
    if vim.fn.confirm("Pull " .. model .. "?", "&Yes\n&No", 2) ~= 1 then
      return
    end
    actions.close(prompt_bufnr)
    last_echo = 0
    -- Fresh aggregation for this pull so its bar never inherits the last pull's
    -- digests/totals (shared upvalue with show_progress — reassigning it here is
    -- visible there).
    pull_totals = {}
    vim.notify("Pulling " .. model .. " …")
    pull_model(model, function(obj)
      show_progress(model, obj)
    end, function()
      clear_progress()
      vim.notify("Pulled " .. model)
      refetch(prompt_bufnr)
    end, function(err)
      clear_progress()
      vim.notify("Pull failed: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end

  local title
  if cache then
    title = string.format(
      "Ollama models — library cache: %d (%s) — active: %s",
      #cache_names,
      age_str(cache.fetched_at),
      active
    )
  else
    title = "Ollama models — library cache empty, press <C-u> — active: " .. active
  end

  pickers
    .new({}, {
      prompt_title = title,
      results_title = "<CR> set · <C-o> install · <C-d> delete · <C-u> update · <C-p> pull name · <C-f> FIM filter",
      initial_mode = "normal",
      finder = make_finder(build_rows(active, installed, cache_names, fim_only)),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        -- <CR>: set the active FIM completion model. Confirm before wiring in a
        -- non-FIM or FIM-unknown model (design gate). set_model owns persist/notify.
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          local row = selection and selection.value
          if not row then
            return
          end
          -- Happy path: an installed model the catalog already vouches for
          -- (fim == true) is trusted directly — skip the ~3s blocking /api/show +
          -- confirm on the common qwen2.5-coder-base path. Only fall through to
          -- the authoritative check + gate when the flag is false or unknown.
          if not (row.installed and row.fim == true) then
            local fim = resolve_fim(row)
            if fim ~= true then
              local why = fim == false and "is not FIM-capable; completions may be garbage."
                or "FIM capability is unknown (not installed / not in catalog)."
              local choice = vim.fn.confirm(
                row.name .. " " .. why .. "\nSet it as the completion model anyway?",
                "&Yes\n&No",
                2
              )
              if choice ~= 1 then
                return
              end
            end
          end
          actions.close(prompt_bufnr)
          require("config.ai").set_model(row.name)
          if not row.installed then
            vim.notify(
              "Note: " .. row.name .. " is not installed — pull it with <C-o>",
              vim.log.levels.WARN
            )
          end
        end)

        -- <C-o>: install (pull) the selected model with streamed progress.
        -- Bound to <C-o> (not <C-i>): terminals send the SAME keycode for <Tab>
        -- and <C-i>, so a stray Tab in the modal would kick off an unbounded pull.
        map({ "i", "n" }, "<C-o>", function()
          local selection = action_state.get_selected_entry()
          local row = selection and selection.value
          if not row then
            return
          end
          start_pull(prompt_bufnr, row.install_target or row.name)
        end)

        -- <C-d>: delete an installed model (confirm), then refresh. REFUSE to
        -- delete the active completion model: config.ai + minuet's live config
        -- would keep pointing at a now-gone model and FIM would 404 forever (this
        -- session and, via the persisted file, the next). Switch away with <CR>
        -- first. Non-active models delete as before.
        map({ "i", "n" }, "<C-d>", function()
          local selection = action_state.get_selected_entry()
          local row = selection and selection.value
          if not row or not row.installed then
            vim.notify("Select an installed model (●) to delete", vim.log.levels.WARN)
            return
          end
          if row.name == require("config.ai").load_persisted_model() then
            vim.notify(
              "That is the active completion model — switch to another with <CR> first, then delete.",
              vim.log.levels.WARN
            )
            return
          end
          local choice = vim.fn.confirm("Delete " .. row.name .. "?", "&Yes\n&No", 2)
          if choice ~= 1 then
            return
          end
          local ok, err = delete_model(row.name)
          if ok then
            show_cache[row.name] = nil
            vim.notify("Deleted " .. row.name)
            refetch(prompt_bufnr)
          else
            vim.notify("Delete failed: " .. tostring(err), vim.log.levels.ERROR)
          end
        end)

        -- <C-u>: refresh the scraped library cache from ollama.com, then refresh.
        -- Guarded against a second concurrent scrape (tears the cache write).
        map({ "i", "n" }, "<C-u>", function()
          if active_scrape then
            vim.notify("Library cache update already in progress", vim.log.levels.WARN)
            return
          end
          active_scrape = true
          vim.notify("Updating Ollama library cache …")
          scrape_library(function(names)
            active_scrape = false
            cache_names = names
            vim.notify(string.format("Library cache updated: %d models", #names))
            refetch(prompt_bufnr)
          end, function(err)
            active_scrape = false
            vim.notify(
              "Library update failed (kept old cache): " .. tostring(err),
              vim.log.levels.WARN
            )
          end)
        end)

        -- <C-p>: free-text escape hatch — pull an exact name:tag not in the list.
        map({ "i", "n" }, "<C-p>", function()
          vim.ui.input({ prompt = "Pull model (name:tag): " }, function(input)
            local model = input and vim.trim(input) or ""
            if model == "" then
              return
            end
            start_pull(prompt_bufnr, model)
          end)
        end)

        -- <C-f>: toggle the "FIM-eligible only" filter. Pure client-side — rebuild
        -- from the CACHED data with no network refetch.
        map({ "i", "n" }, "<C-f>", function()
          fim_only = not fim_only
          rebuild(prompt_bufnr)
          vim.notify(fim_only and "Showing FIM-eligible models only" or "Showing all models")
        end)

        return true
      end,
    })
    :find()
end

return M

-- Split a DevDocs `db.json` into one HTML file per page.
--
--   nvim --clean -l devdocs_split.lua <db.json> <pages-dir>
--
-- Run by config.docs.devdocs.install as its own process, never required. The
-- man bundle's db.json is 143 MB; decoding it inside the editor would freeze
-- it for seconds and hold a few hundred MB of strings until the next GC.
--
-- Every page path is checked before anything is written. They come off the
-- network, and a path that climbs out of the bundle (`../x`) or is absolute
-- fails the whole run rather than being skipped: a bundle carrying one is not a
-- bundle to trust with the rest of its paths either.

local db_path, out_dir = arg[1], arg[2]
if not db_path or not out_dir then
  error("usage: devdocs_split.lua <db.json> <pages-dir>")
end

local f = assert(io.open(db_path, "rb"))
local raw = f:read("*a")
f:close()

local db = vim.json.decode(raw)
raw = nil
if type(db) ~= "table" then
  error("db.json is not an object")
end

for path, html in pairs(db) do
  if type(path) ~= "string" or type(html) ~= "string" or path == "" then
    error("malformed page entry")
  end
  if path:sub(1, 1) == "/" or path:find("\\", 1, true) or path:find("%z") then
    error("unsafe page path: " .. path)
  end
  for segment in path:gmatch("[^/]+") do
    if segment == ".." or segment == "." then
      error("unsafe page path: " .. path)
    end
  end
end

local count = 0
for path, html in pairs(db) do
  local file = out_dir .. "/" .. path .. ".html"
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local w = assert(io.open(file, "wb"))
  w:write(html)
  w:close()
  count = count + 1
end
io.stdout:write(count, "\n")

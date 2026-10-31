-- Forward copied text to the SSH client's clipboard via OSC 52.
local M = {}
local text = ya.sync(function(_, kind)
  local items = {}
  local function add(f)
    local path = tostring(f.url)
    items[#items + 1] = kind == "filename" and (path:match("[^/\\]+$") or path) or path
  end
  for _, f in pairs(cx.active.selected) do add(f) end
  if #items == 0 and cx.active.current.hovered then add(cx.active.current.hovered) end
  return table.concat(items, "\n")
end)
local function base64(s)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local function char(shift) local k = (n >> shift) & 63; return alphabet:sub(k + 1, k + 1) end
    out[#out + 1] = char(18) .. char(12) .. (b and char(6) or "=") .. (c and char(0) or "=")
  end
  return table.concat(out)
end
function M:entry(job)
  local value = text(job.args[1] or "path")
  if value == "" then return end
  io.write("\27]52;c;" .. base64(value) .. "\7")
  io.flush()
end
return M

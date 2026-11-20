-- g V: list the drive letters that exist right now (USB drives included) and cd to the chosen one.
-- Drives are scanned on every key press, so a newly plugged-in drive shows up without restarting Yazi.
local M = {}

local emit = ya.emit or ya.mgr_emit or ya.manager_emit

function M:entry()
  local cands, roots = {}, {}
  for code = string.byte("A"), string.byte("Z") do
    local letter = string.char(code)
    local root = letter .. ":\\"
    if fs.cha(Url(root)) then
      cands[#cands + 1] = { on = letter, desc = root }
      roots[#roots + 1] = root
    end
  end
  if #cands == 0 then
    ya.notify { title = "Drives", content = "没有检测到可用磁盘", timeout = 3, level = "warn" }
    return
  end
  local index = ya.which { cands = cands, silent = false }
  if index then emit("cd", { roots[index] }) end
end

return M

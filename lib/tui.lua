--[[
  Passport System - TUI 框架
  提供菜单、表单、对话框等界面组件, 支持中文/全角字符(宽字符)对齐。

  所有组件都是阻塞式: 调用后进入自身的事件循环, 返回时界面已处理完毕。
  按 Ctrl+T 可在任意界面退出程序(CraftOS 标准行为)。
]]

local tui = {}

-- 调色板(普通电脑上 term 会自动降级为灰度)
local C = {
  bg      = colors.black,
  border  = colors.gray,
  titleFg = colors.white,
  titleBg = colors.cyan,
  textFg  = colors.white,
  dimFg   = colors.gray,
  accFg   = colors.yellow,
  errBg   = colors.red,
  errFg   = colors.white,
  okBg    = colors.green,
  okFg    = colors.black,
  selBg   = colors.cyan,
  selFg   = colors.black,
}
tui.C = C

------------------------------------------------------------------------------
-- 宽字符工具(中文/全角字符在终端中占 2 格)
------------------------------------------------------------------------------

local function charWidth(cp)
  if cp < 0x1100 then return 1 end
  if cp <= 0x115F then return 2 end
  if cp < 0x2E80 then return 1 end
  if cp <= 0x303E then return 2 end
  if cp == 0x303F then return 1 end
  if cp < 0x3041 then return 1 end
  if cp <= 0x33FF then return 2 end
  if cp < 0x3400 then return 1 end
  if cp <= 0x9FFF then return 2 end
  if cp < 0xA000 then return 1 end
  if cp <= 0xA4CF then return 2 end
  if cp < 0xAC00 then return 1 end
  if cp <= 0xD7A3 then return 2 end
  if cp < 0xF900 then return 1 end
  if cp <= 0xFAFF then return 2 end
  if cp < 0xFE30 then return 1 end
  if cp <= 0xFE4F then return 2 end
  if cp < 0xFF00 then return 1 end
  if cp <= 0xFF60 then return 2 end
  if cp < 0xFFE0 then return 1 end
  if cp <= 0xFFE6 then return 2 end
  if cp >= 0x1F000 then return 2 end
  return 1
end

-- 返回字符串第 i 字节处的下一个 UTF-8 字符的码点与结束位置
-- (对不完整的 UTF-8 序列做防护, 避免 nil 算术错误)
local function utf8Next(s, i)
  if i > #s then return nil end
  local b = s:byte(i)
  local n, cp
  if b < 0x80 then
    n, cp = 1, b
  elseif b < 0xE0 then
    n, cp = 2, (b % 0x20) * 0x40 + (s:byte(i + 1) or 0) % 0x40
  elseif b < 0xF0 then
    n, cp = 3, (b % 0x10) * 0x1000 + ((s:byte(i + 1) or 0) % 0x40) * 0x40 + (s:byte(i + 2) or 0) % 0x40
  else
    n, cp = 4, (b % 0x08) * 0x40000 + ((s:byte(i + 1) or 0) % 0x40) * 0x1000
      + ((s:byte(i + 2) or 0) % 0x40) * 0x40 + (s:byte(i + 3) or 0) % 0x40
  end
  return cp, i + n
end

-- 字符串在终端中的显示宽度
function tui.displayWidth(s)
  local w = 0
  local i = 1
  while i <= #s do
    local cp, nextI = utf8Next(s, i)
    w = w + charWidth(cp)
    i = nextI
  end
  return w
end

-- 按显示宽度填充到 width。align: "left" | "center" | "right"
function tui.pad(s, width, align)
  s = tostring(s or "")
  align = align or "left"
  local w = tui.displayWidth(s)
  if w >= width then return s end
  local fill = width - w
  if align == "center" then
    local l = math.floor(fill / 2)
    return string.rep(" ", l) .. s .. string.rep(" ", fill - l)
  elseif align == "right" then
    return string.rep(" ", fill) .. s
  end
  return s .. string.rep(" ", fill)
end

-- 按显示宽度截断, 不会截断半个中文字符
function tui.truncate(s, width)
  s = tostring(s or "")
  local w = 0
  local i = 1
  while i <= #s do
    local cp, nextI = utf8Next(s, i)
    local cw = charWidth(cp)
    if w + cw > width then
      return s:sub(1, i - 1)
    end
    w = w + cw
    i = nextI
  end
  return s
end

-- 用空格填满一个区域(清屏)
function tui.clearArea(x, y, w, h)
  term.setBackgroundColor(C.bg)
  term.setTextColor(C.bg)
  for row = 1, h do
    term.setCursorPos(x, y + row - 1)
    term.write(string.rep(" ", w))
  end
end

-- 带标题的边框盒
function tui.box(x, y, w, h, title)
  if w < 4 then w = 4 end
  if h < 3 then h = 3 end
  tui.clearArea(x, y, w, h)
  term.setBackgroundColor(C.bg)
  term.setTextColor(C.border)
  term.setCursorPos(x, y)
  term.write("┌" .. string.rep("─", w - 2) .. "┐")
  for r = 2, h - 1 do
    term.setCursorPos(x, y + r - 1)
    term.write("│")
    term.setCursorPos(x + w - 1, y + r - 1)
    term.write("│")
  end
  term.setCursorPos(x, y + h - 1)
  term.write("└" .. string.rep("─", w - 2) .. "┘")
  if title and title ~= "" then
    term.setBackgroundColor(C.titleBg)
    term.setTextColor(C.titleFg)
    term.setCursorPos(x + 2, y)
    term.write(tui.truncate(title, w - 4))
    term.setBackgroundColor(C.bg)
    term.setTextColor(C.border)
  end
end

-- 全屏主界面框架: 顶部标题 + 底部状态栏, 返回内容区高度
function tui.frame(title, statusText)
  local w, h = term.getSize()
  term.setBackgroundColor(C.bg)
  term.clear()
  -- 标题栏
  term.setBackgroundColor(C.titleBg)
  term.setTextColor(C.titleFg)
  term.setCursorPos(1, 1)
  term.write(tui.pad(" " .. tui.truncate(title, w - 2), w))
  -- 状态栏
  tui.statusBar(statusText)
  term.setBackgroundColor(C.bg)
  return h
end

-- 底部状态栏
function tui.statusBar(text)
  local w, h = term.getSize()
  term.setBackgroundColor(colors.gray)
  term.setTextColor(colors.black)
  term.setCursorPos(1, h)
  term.write(tui.pad(" " .. tui.truncate(tostring(text or ""), w - 2), w))
  term.setBackgroundColor(C.bg)
end

------------------------------------------------------------------------------
-- 菜单
------------------------------------------------------------------------------

-- 垂直菜单。options: { {label=..., desc=...}, ... }
-- 返回选中项的索引(1..n), 按 Esc 返回 nil
function tui.menu(title, options, width)
  local w, h = term.getSize()
  local mw = width or 46
  local mh = #options + 4
  if mw > w - 2 then mw = w - 2 end
  if mh > h - 2 then mh = h - 2 end
  local mx = math.max(1, math.floor((w - mw) / 2))
  local my = math.max(1, math.floor((h - mh) / 2))

  local sel = 1

  local function draw()
    tui.box(mx, my, mw, mh, title)
    for i, opt in ipairs(options) do
      local y = my + 2 + (i - 1)
      if i == sel then
        term.setBackgroundColor(C.selBg)
        term.setTextColor(C.selFg)
      else
        term.setBackgroundColor(C.bg)
        term.setTextColor(C.textFg)
      end
      term.setCursorPos(mx + 1, y)
      term.write(tui.pad("  " .. tostring(i) .. ") " .. opt.label, mw - 3))
    end
    -- 底部提示
    term.setBackgroundColor(C.bg)
    term.setTextColor(C.dimFg)
    term.setCursorPos(mx + 1, my + mh - 1)
    term.write(tui.pad("↑↓ select  Enter confirm  Esc back", mw - 2))
  end

  draw()
  while true do
    local ev, p1 = os.pullEvent()
    if ev == "key" then
      if p1 == keys.up then
        sel = sel - 1
        if sel < 1 then sel = #options end
        draw()
      elseif p1 == keys.down then
        sel = sel + 1
        if sel > #options then sel = 1 end
        draw()
      elseif p1 == keys.enter then
        return sel
      elseif p1 == keys.esc then
        return nil
      end
    elseif ev == "char" then
      local n = tonumber(p1)
      if n and n >= 1 and n <= #options then
        return n
      end
    end
  end
end

------------------------------------------------------------------------------
-- 表单
------------------------------------------------------------------------------

-- 表单。fields: { {key=..., label=..., type="text"|"number"|"password"|"choice",
--                  choices={...}, default=...}, ... }
-- 自动附加一个"确认提交"行。返回 { key=value }, 按 Esc 返回 nil
function tui.form(title, fields)
  local w, h = term.getSize()
  local fw = 48
  local fh = #fields + 5
  if fw > w - 2 then fw = w - 2 end
  if fh > h - 2 then fh = h - 2 end
  local fx = math.max(1, math.floor((w - fw) / 2))
  local fy = math.max(1, math.floor((h - fh) / 2))

  local values = {}
  for _, f in ipairs(fields) do
    values[f.key] = f.default or ""
  end

  local cur = 1
  local hint = ""

  local function fieldValue(f)
    local v = values[f.key]
    if f.type == "password" and v ~= "" then
      return string.rep("*", tui.displayWidth(v))
    elseif f.type == "choice" then
      local n = tonumber(v) or 1
      return (f.choices and f.choices[n]) or tostring(v)
    end
    return tostring(v)
  end

  local function draw()
    tui.box(fx, fy, fw, fh, title)
    -- 字段行
    for i, f in ipairs(fields) do
      local y = fy + 2 + (i - 1)
      if i == cur then
        term.setBackgroundColor(C.selBg)
        term.setTextColor(C.selFg)
      else
        term.setBackgroundColor(C.bg)
        term.setTextColor(C.textFg)
      end
      term.setCursorPos(fx + 1, y)
      term.write(tui.pad(f.label .. ":", 12))
      local v = fieldValue(f)
      if i ~= cur then
        term.write(tui.pad(tui.truncate(v, fw - 15), fw - 15))
      else
        term.write(tui.pad("", fw - 15))
      end
    end
    -- 提交行
    local sy = fy + 2 + #fields
    if #fields + 1 == cur then
      term.setBackgroundColor(C.selBg)
      term.setTextColor(C.selFg)
    else
      term.setBackgroundColor(C.bg)
      term.setTextColor(C.textFg)
    end
    term.setCursorPos(fx + 1, sy)
    term.write(tui.pad("  ✓ Submit", fw - 2))
    -- 提示行
    term.setBackgroundColor(C.bg)
    term.setTextColor(C.dimFg)
    term.setCursorPos(fx + 1, fy + fh - 1)
    term.write(tui.pad(hint ~= "" and hint or "↑↓ switch  Enter edit/submit  Esc cancel", fw - 2))
  end

  local function isChoice(i)
    return fields[i].type == "choice"
  end

  local function cycleChoice(i, dir)
    local f = fields[i]
    local n = tonumber(values[f.key]) or 1
    local total = #(f.choices or {})
    if total < 1 then return end
    n = n + dir
    if n < 1 then n = total elseif n > total then n = 1 end
    values[f.key] = tostring(n)
  end

  local function editField(i)
    local f = fields[i]
    local y = fy + 2 + (i - 1)
    if f.type == "choice" then
      cycleChoice(i, 1)
      return
    end
    term.setCursorPos(fx + 14, y)
    term.setBackgroundColor(C.bg)
    term.setTextColor(C.textFg)
    term.setCursorBlink(true)
    local v
    if f.type == "password" then
      v = read("*", nil, nil, values[f.key])
    else
      v = read(nil, nil, nil, values[f.key])
    end
    term.setCursorBlink(false)
    if v then
      if f.type == "number" and v ~= "" and not tonumber(v) then
        hint = "Error: enter a number"
        draw()
        return
      end
      values[f.key] = v
    end
    hint = ""
  end

  draw()
  while true do
    local ev, p1 = os.pullEvent()
    if ev == "key" then
      if p1 == keys.up then
        cur = cur - 1
        if cur < 1 then cur = #fields + 1 end
        hint = ""
        draw()
      elseif p1 == keys.down then
        cur = cur + 1
        if cur > #fields + 1 then cur = 1 end
        hint = ""
        draw()
      elseif p1 == keys.enter then
        if cur <= #fields then
          editField(cur)
        else
          -- 校验必填
          local missing = {}
          for _, f in ipairs(fields) do
            if f.required and (values[f.key] == nil or values[f.key] == "") then
              table.insert(missing, f.label)
            end
          end
          if #missing > 0 then
            hint = "Required: " .. table.concat(missing, ", ")
            draw()
          else
            return values
          end
        end
      elseif p1 == keys.left and isChoice(cur) then
        cycleChoice(cur, -1)
        draw()
      elseif p1 == keys.right and isChoice(cur) then
        cycleChoice(cur, 1)
        draw()
      elseif p1 == keys.esc then
        return nil
      end
    elseif ev == "char" and isChoice(cur) then
      local c = tonumber(p1)
      if c then
        values[fields[cur].key] = tostring(c)
        draw()
      end
    end
  end
end

------------------------------------------------------------------------------
-- 对话框
------------------------------------------------------------------------------

-- 消息框: 显示若干行文本, 按任意键关闭
-- lines: string 或 string 数组
function tui.msgBox(title, lines, okLabel)
  if type(lines) == "string" then lines = { lines } end
  okLabel = okLabel or "Press any key to close"
  local w, h = term.getSize()
  local mw = 48
  local mh = #lines + 4
  if mw > w - 2 then mw = w - 2 end
  if mh > h - 2 then mh = h - 2 end
  local mx = math.max(1, math.floor((w - mw) / 2))
  local my = math.max(1, math.floor((h - mh) / 2))

  tui.box(mx, my, mw, mh, title)
  term.setBackgroundColor(C.bg)
  term.setTextColor(C.textFg)
  for i, line in ipairs(lines) do
    term.setCursorPos(mx + 1, my + 2 + (i - 1))
    term.write(tui.pad(tui.truncate(line, mw - 2), mw - 2))
  end
  term.setTextColor(C.dimFg)
  term.setCursorPos(mx + 1, my + mh - 1)
  term.write(tui.pad(okLabel, mw - 2, "center"))

  os.pullEvent("key")
  os.pullEvent("key_up")
  return true
end

-- 确认框: 返回 boolean
function tui.confirm(title, lines, yesLabel, noLabel)
  if type(lines) == "string" then lines = { lines } end
  yesLabel = yesLabel or "Y Yes"
  noLabel = noLabel or "N No"
  local w, h = term.getSize()
  local mw = 48
  local mh = #lines + 4
  if mw > w - 2 then mw = w - 2 end
  if mh > h - 2 then mh = h - 2 end
  local mx = math.max(1, math.floor((w - mw) / 2))
  local my = math.max(1, math.floor((h - mh) / 2))

  tui.box(mx, my, mw, mh, title)
  term.setBackgroundColor(C.bg)
  term.setTextColor(C.textFg)
  for i, line in ipairs(lines) do
    term.setCursorPos(mx + 1, my + 2 + (i - 1))
    term.write(tui.pad(tui.truncate(line, mw - 2), mw - 2))
  end
  term.setTextColor(C.dimFg)
  term.setCursorPos(mx + 1, my + mh - 1)
  term.write(tui.pad(("  %s    %s"):format(yesLabel, noLabel), mw - 2, "center"))

  while true do
    local ev, p1 = os.pullEvent()
    if ev == "key" then
      if p1 == keys.y then return true end
      if p1 == keys.n then return false end
      if p1 == keys.enter then return true end
      if p1 == keys.esc then return false end
    elseif ev == "char" then
      local c = p1:lower()
      if c == "y" then return true end
      if c == "n" then return false end
    end
  end
end

return tui

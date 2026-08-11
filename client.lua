--[[
  Passport System - 客户端
  ========================
  部署到游戏中的"客户端电脑"(如边境检查站/出入境大厅)。
  可重命名为 startup.lua 实现开机自启。

  功能:
    1. 签发新护照(写入软盘 + 上传服务器)
    2. 查看护照(终端/显示器展示, 可打印)
    3. 编辑护照
    4. 签证盖章(入境/出境/签证, 打印回执)
    5. 双向同步: 服务器 ↔ 软盘
    6. 服务器状态 / 设置
]]

local config = require("lib.config")
local tui = require("lib.tui")
local passport = require("lib.passport")
local net = require("lib.net")

config.load()

------------------------------------------------------------------------------
-- 状态
------------------------------------------------------------------------------

local periph = { disk = false, monitor = false, printer = false }
local serverId = nil

local function scanPeriphs()
  periph.disk    = peripheral.isPresent(config.DISK_SIDE)
  periph.monitor = peripheral.isPresent(config.MONITOR_SIDE)
  periph.printer = peripheral.isPresent(config.PRINTER_SIDE)
end

local function refreshServer()
  if not rednet.isOpen() then
    serverId = nil -- 调制解调器未打开, 跳过查找
    return
  end
  serverId = net.getServerID()
end

local function statusText()
  return string.format("软盘:%s 显示器:%s 打印机:%s | %s",
    periph.disk and "有" or "无",
    periph.monitor and "有" or "无",
    periph.printer and "有" or "无",
    serverId and ("服务器 #" .. serverId) or "服务器离线")
end

-- 把表单里的 choice 值(索引字符串)转成实际选项
local function choiceValue(choices, v)
  local n = tonumber(v) or 1
  local c = choices[n]
  return c or tostring(v)
end

------------------------------------------------------------------------------
-- 显示器展示
------------------------------------------------------------------------------

local function monitorShow(p)
  if not periph.monitor then return false end
  local mon = peripheral.wrap(config.MONITOR_SIDE)
  if not mon then return false end
  local mw, mh = mon.getSize()
  if mw >= 60 then
    mon.setTextScale(0.5)
  elseif mw >= 40 then
    mon.setTextScale(1)
  end
  local w, h = mon.getSize()
  mon.clear()

  local ok, reason = passport.validate(p)
  local bg = ok and colors.green or colors.red

  -- 顶部横幅(全宽背景色)
  mon.setBackgroundColor(bg)
  mon.setTextColor(colors.white)
  mon.setCursorPos(1, 1)
  mon.write(tui.pad("★ 护 照 · P A S S P O R T ★", w, "center"))

  -- 正文
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
  local lines = {
    "编号   : " .. p.id,
    "姓名   : " .. p.name,
    "年龄   : " .. tostring(p.age or 0),
    "性别   : " .. p.gender,
    "国籍   : " .. p.nation,
    "照片   : " .. (p.photo and p.photo ~= "" and p.photo or "无"),
    "签发   : " .. p.issued,
    "有效期 : " .. p.expiry,
    "状态   : " .. (ok and "有效" or "无效"),
    "盖章   : " .. #(p.stamps or {}) .. " 次",
  }
  local y = 3
  for _, line in ipairs(lines) do
    if y < h then
      mon.setCursorPos(1, y)
      mon.write(tui.truncate(line, w))
      y = y + 1
    end
  end
  -- 底部状态条
  mon.setBackgroundColor(bg)
  mon.setTextColor(colors.white)
  mon.setCursorPos(1, h)
  mon.write(tui.pad(tui.truncate(reason or "", w), w, "center"))
  mon.setBackgroundColor(colors.black)
  return true
end

------------------------------------------------------------------------------
-- 打印机
------------------------------------------------------------------------------

-- 打印一页文字。lines 为字符串数组, 每行一次 write(不依赖光标自动推进)。
local function printerPage(title, lines)
  if not periph.printer then return false, "未连接打印机" end
  local pr = peripheral.wrap(config.PRINTER_SIDE)
  if not pr then return false, "打印机不可用" end
  if pr.getInkLevel() < 1 or pr.getPaperLevel() < 1 then
    return false, "打印机缺墨水或纸张"
  end
  if not pr.newPage() then
    return false, "无法开始新页面"
  end
  local pw, ph = pr.getPageSize()
  pr.setPageTitle(title)
  local y = 1
  for _, line in ipairs(lines) do
    if y > ph then break end
    pr.setCursorPos(1, y)
    pr.write(tui.truncate(tostring(line), pw))
    y = y + 1
  end
  if not pr.endPage() then
    return false, "打印结束失败"
  end
  return true
end

local function passportPageLines(p)
  local ok, reason = passport.validate(p)
  return {
    "==================================",
    "         P A S S P O R T",
    "            护  照",
    "==================================",
    "ID       : " .. p.id,
    "NAME     : " .. p.name,
    "AGE      : " .. tostring(p.age or 0),
    "GENDER   : " .. p.gender,
    "NATIONAL : " .. p.nation,
    "PHOTO    : " .. (p.photo and p.photo ~= "" and p.photo or "-"),
    "----------------------------------",
    "ISSUED   : " .. p.issued,
    "EXPIRES  : " .. p.expiry,
    "STATUS   : " .. (ok and "VALID" or "INVALID"),
    "STAMPS   : " .. #(p.stamps or {}),
    "==================================",
  }
end

local function visaReceiptLines(p, stamp)
  local stype = { ["入境"] = "IN", ["出境"] = "OUT", ["签证"] = "VISA" }
  return {
    "==============================",
    "      VISA STAMP RECEIPT",
    "==============================",
    "ID      : " .. p.id,
    "NAME    : " .. p.name,
    "TYPE    : " .. (stype[stamp.type] or stamp.type),
    "COUNTRY : " .. stamp.country,
    "TIME    : " .. stamp.time,
    "==============================",
    "   +---------------------+",
    "   |     签证专用章       |",
    "   |     STAMP SEAL      |",
    "   +---------------------+",
    "==============================",
  }
end

------------------------------------------------------------------------------
-- 护照详情全屏视图
------------------------------------------------------------------------------

local function showPassport(p)
  local w, h = term.getSize()
  local ok, reason = passport.validate(p)
  local stamps = p.stamps or {}
  local perPage = math.max(3, h - 14)
  local pages = math.max(1, math.ceil(#stamps / perPage))
  local page = 1

  local function draw()
    term.setBackgroundColor(colors.black)
    term.clear()
    -- 标题栏
  term.setBackgroundColor(colors.cyan)
  term.setTextColor(colors.white)
  term.setCursorPos(1, 1)
  term.write(tui.pad(" " .. tui.truncate("护照详情  " .. p.id, w - 2), w))

    local y = 2
    local function line(text, color)
      y = y + 1
      if y > h - 2 then return end
      term.setBackgroundColor(colors.black)
      term.setTextColor(color or colors.white)
      term.setCursorPos(1, y)
      term.write(tui.truncate(text, w))
    end

    line("")
    line(("姓名: %s    年龄: %d    性别: %s"):format(p.name, p.age or 0, p.gender))
    line(("国籍: %s    照片: %s"):format(p.nation, (p.photo and p.photo ~= "") and p.photo or "无"))
    line(("签发: %s    有效期至: %s"):format(p.issued, p.expiry))
    if p.note and p.note ~= "" then
      line("备注: " .. p.note)
    end
    line("状态: " .. (ok and "有效" or "无效") .. "  ·  " .. (reason or ""))

    y = y + 2
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.gray)
    term.setCursorPos(1, y)
    term.write(tui.truncate(("── 签证与出入境记录 (%d)  第 %d/%d 页 ──"):format(#stamps, page, pages), w))

    y = y + 1
    local startIdx = (page - 1) * perPage + 1
    for i = startIdx, math.min(startIdx + perPage - 1, #stamps) do
      local s = stamps[i]
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.white)
      term.setCursorPos(1, y)
      term.write(tui.truncate(("[%d] %s | %s | %s"):format(i, s.type or "?", s.country or "?", s.time or ""), w))
      y = y + 1
      if y > h - 2 then break end
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.gray)
    term.setCursorPos(1, h - 1)
    term.write(tui.truncate("←→翻页  P打印  M显示器  Esc返回", w))
  end

  draw()
  while true do
    local ev, p1 = os.pullEvent()
    if ev == "key" then
      if p1 == keys.left then
        page = page - 1
        if page < 1 then page = pages end
        draw()
      elseif p1 == keys.right then
        page = page + 1
        if page > pages then page = 1 end
        draw()
      elseif p1 == keys.esc then
        return
      end
    elseif ev == "char" then
      local c = p1:lower()
      if c == "p" then
        local okp, errp = printerPage("Passport " .. p.id, passportPageLines(p))
        if okp then
          tui.msgBox("打印", { "护照页已打印!" })
        else
          tui.msgBox("打印失败", { errp or "未知错误" })
        end
        draw()
      elseif c == "m" then
        local shown = monitorShow(p)
        if not shown then
          tui.msgBox("显示器", { "未连接显示器(" .. config.MONITOR_SIDE .. ")" })
          draw()
        end
      end
    end
  end
end

------------------------------------------------------------------------------
-- 各功能
------------------------------------------------------------------------------

local GENDER_CHOICES = { "男", "女", "其他" }
local STAMP_TYPES = { "入境", "出境", "签证" }

local function actIssue()
  if not periph.disk then
    tui.msgBox("签发护照", { "未连接磁盘驱动器(" .. config.DISK_SIDE .. ")", "请放置磁盘驱动器并插入软盘" })
    return
  end
  local values = tui.form("签发新护照", {
    { key = "name",       label = "姓名",     type = "text",   required = true, default = "" },
    { key = "age",        label = "年龄",     type = "number" },
    { key = "gender",     label = "性别",     type = "choice", choices = GENDER_CHOICES, default = "1" },
    { key = "nation",     label = "国籍",     type = "text",   default = "中国" },
    { key = "photo",      label = "照片描述", type = "text" },
    { key = "note",       label = "备注",     type = "text" },
    { key = "validYears", label = "有效期年", type = "number", default = tostring(config.DEFAULT_VALID_YEARS) },
  })
  if not values then return end

  local p = passport.new({
    name = values.name,
    age = tonumber(values.age),
    gender = choiceValue(GENDER_CHOICES, values.gender),
    nation = values.nation,
    photo = values.photo,
    note = values.note,
    validYears = tonumber(values.validYears),
  })

  local okw, errw = passport.writeDisk(config.DISK_SIDE, p)
  if not okw then
    tui.msgBox("签发失败", { errw or "写入软盘失败" })
    return
  end

  if serverId then
    local resp = net.request(serverId, { type = "register", data = p }, 6)
    if resp and resp.ok then
      local saved = resp.data.record
      if saved and saved.id ~= p.id then
        p = saved -- 服务器分配了官方编号, 回写软盘
        passport.writeDisk(config.DISK_SIDE, p)
      end
      tui.msgBox("签发成功", {
        "护照已写入软盘并登记到服务器",
        "编号    : " .. p.id,
        "姓名    : " .. p.name,
        "有效期至: " .. p.expiry,
      })
      if periph.printer and tui.confirm("打印护照页?", { "是否打印护照页作为纪念品?" }) then
        local okp, errp = printerPage("Passport " .. p.id, passportPageLines(p))
        if not okp then tui.msgBox("打印失败", { errp or "未知错误" }) end
      end
    else
      local e = (resp and resp.data and resp.data.error) or "服务器无响应"
      tui.msgBox("警告", {
        "服务器未登记(可能离线)",
        "原因: " .. tostring(e),
        "护照已保存在软盘, 稍后可「上传到服务器」",
      })
    end
  else
    tui.msgBox("签发成功(仅本地)", {
      "服务器离线, 护照仅保存在软盘",
      "编号: " .. p.id,
      "之后可在菜单选择「上传到服务器」",
    })
  end
  monitorShow(p)
end

local function actView()
  if not periph.disk then
    tui.msgBox("查看护照", { "未连接磁盘驱动器(" .. config.DISK_SIDE .. ")" })
    return
  end
  local p, err = passport.readDisk(config.DISK_SIDE)
  if not p then
    tui.msgBox("查看护照", { err or "读取失败" })
    return
  end
  showPassport(p)
end

local function actEdit()
  if not periph.disk then
    tui.msgBox("编辑护照", { "未连接磁盘驱动器(" .. config.DISK_SIDE .. ")" })
    return
  end
  local p, err = passport.readDisk(config.DISK_SIDE)
  if not p then
    tui.msgBox("编辑护照", { err or "读取失败" })
    return
  end
  local curGender = 1
  for i, g in ipairs(GENDER_CHOICES) do
    if g == p.gender then curGender = i end
  end
  local values = tui.form("编辑护照 " .. p.id, {
    { key = "name",   label = "姓名",     type = "text",   required = true, default = p.name },
    { key = "age",    label = "年龄",     type = "number", default = tostring(p.age or "") },
    { key = "gender", label = "性别",     type = "choice", choices = GENDER_CHOICES, default = tostring(curGender) },
    { key = "nation", label = "国籍",     type = "text",   default = p.nation },
    { key = "photo",  label = "照片描述", type = "text",   default = p.photo },
    { key = "note",   label = "备注",     type = "text",   default = p.note },
  })
  if not values then return end

  p.name = values.name
  p.age = tonumber(values.age) or p.age
  p.gender = choiceValue(GENDER_CHOICES, values.gender)
  p.nation = values.nation
  p.photo = values.photo
  p.note = values.note

  local okw, errw = passport.writeDisk(config.DISK_SIDE, p)
  if not okw then
    tui.msgBox("编辑失败", { errw or "写入软盘失败" })
    return
  end
  if serverId then
    local resp = net.request(serverId, { type = "update", data = p }, 6)
    if resp and resp.ok then
      tui.msgBox("编辑完成", { "已保存到软盘并同步到服务器" })
    else
      local e = (resp and resp.data and resp.data.error) or "服务器无响应"
      tui.msgBox("已保存到软盘", { "服务器同步失败: " .. tostring(e), "可用「上传到服务器」稍后重试" })
    end
  else
    tui.msgBox("已保存到软盘", { "服务器离线, 未同步" })
  end
  monitorShow(p)
end

local function actStamp()
  if not periph.disk then
    tui.msgBox("签证盖章", { "未连接磁盘驱动器(" .. config.DISK_SIDE .. ")" })
    return
  end
  local p, err = passport.readDisk(config.DISK_SIDE)
  if not p then
    tui.msgBox("签证盖章", { err or "读取失败" })
    return
  end
  local ok, reason = passport.validate(p)
  if not ok then
    tui.msgBox("无法盖章", { "该护照不可盖章: " .. reason })
    return
  end
  local values = tui.form("签证盖章 · " .. p.id, {
    { key = "type",    label = "盖章类型", type = "choice", choices = STAMP_TYPES, default = "1" },
    { key = "country", label = "国家/口岸", type = "text",   required = true },
    { key = "note",    label = "备注",     type = "text" },
  })
  if not values then return end

  local stamp = {
    type = choiceValue(STAMP_TYPES, values.type),
    country = values.country,
    note = values.note,
  }
  passport.addStamp(p, stamp)

  local okw, errw = passport.writeDisk(config.DISK_SIDE, p)
  if not okw then
    tui.msgBox("盖章失败", { errw or "写入软盘失败" })
    return
  end

  local synced = false
  if serverId then
    local resp = net.request(serverId, { type = "stamp", id = p.id, stamp = stamp }, 6)
    if resp and resp.ok then
      synced = true
    else
      local e = (resp and resp.data and resp.data.error) or "服务器无响应"
      tui.msgBox("盖章完成(未同步)", {
        "服务器同步失败: " .. tostring(e),
        "盖章记录已保存在软盘",
      })
    end
  end
  if synced then
    tui.msgBox("盖章完成", {
      ("已盖章: %s / %s"):format(stamp.type, stamp.country),
      "时间: " .. stamp.time,
      "已同步到服务器",
    })
  end
  if periph.printer and tui.confirm("打印回执?", { "是否打印签证盖章回执?" }) then
    local okp, errp = printerPage("Visa " .. stamp.type .. " " .. p.id, visaReceiptLines(p, stamp))
    if not okp then tui.msgBox("打印失败", { errp or "未知错误" }) end
  end
  monitorShow(p)
end

local function actSyncDown()
  if not periph.disk then
    tui.msgBox("同步", { "未连接磁盘驱动器(" .. config.DISK_SIDE .. ")" })
    return
  end
  if not serverId then refreshServer() end
  if not serverId then
    tui.msgBox("同步失败", { "未发现服务器, 无法同步" })
    return
  end
  local id = disk.isPresent(config.DISK_SIDE) and disk.getLabel(config.DISK_SIDE) or nil
  if not id then
    -- 从软盘上的护照文件读取编号
    local p, err = passport.readDisk(config.DISK_SIDE)
    if p then
      id = p.id
    else
      local vals = tui.form("同步到软盘", {
        { key = "id", label = "护照编号", type = "text", required = true },
      })
      if not vals then return end
      id = vals.id
    end
  end
  local resp = net.request(serverId, { type = "get", id = id }, 6)
  if resp and resp.ok then
    local okw, errw = passport.writeDisk(config.DISK_SIDE, resp.data.record)
    if okw then
      tui.msgBox("同步完成", { ("已将服务器上 %s 的数据写入软盘"):format(id) })
      monitorShow(resp.data.record)
    else
      tui.msgBox("同步失败", { errw or "写入软盘失败" })
    end
  else
    local e = (resp and resp.data and resp.data.error) or "服务器无响应"
    tui.msgBox("同步失败", { tostring(e) })
  end
end

local function actSyncUp()
  if not periph.disk then
    tui.msgBox("上传", { "未连接磁盘驱动器(" .. config.DISK_SIDE .. ")" })
    return
  end
  local p, err = passport.readDisk(config.DISK_SIDE)
  if not p then
    tui.msgBox("上传失败", { err or "读取失败" })
    return
  end
  if not serverId then refreshServer() end
  if not serverId then
    tui.msgBox("上传失败", { "未发现服务器" })
    return
  end
  local resp = net.request(serverId, { type = "register", data = p }, 6)
  if resp and resp.ok then
    local saved = resp.data.record
    if saved and saved.id ~= p.id then
      p = saved
      passport.writeDisk(config.DISK_SIDE, p) -- 服务器分配的编号回写软盘
    end
    tui.msgBox("上传完成", {
      ("已上传 %s (%s)"):format(p.id, resp.data.isNew and "新登记" or "更新"),
    })
  else
    local e = (resp and resp.data and resp.data.error) or "服务器无响应"
    tui.msgBox("上传失败", { tostring(e) })
  end
end

local function actStatus()
  if not serverId then refreshServer() end
  if not serverId then
    tui.msgBox("服务器状态", {
      "未发现护照服务器",
      "请确认: 服务器电脑已启动、已连接调制解调器",
    })
    return
  end
  local resp = net.request(serverId, { type = "stats" }, 5)
  if resp and resp.ok then
    local s = resp.data.stats
    tui.msgBox("服务器状态", {
      ("服务器电脑: #%d"):format(serverId),
      ("系统版本 : %s"):format(config.VERSION),
      ("护照总数 : %d"):format(s.total),
      ("有效 %d   吊销 %d   过期 %d"):format(s.active, s.revoked, s.expired),
      ("下一编号 : %s"):format(s.nextID),
    })
  else
    -- 服务器可能重启换了 ID, 重新发现一次
    refreshServer()
    if serverId then
      tui.msgBox("服务器状态", { ("已重新发现服务器 #%d"):format(serverId) })
    else
      tui.msgBox("服务器状态", { "服务器无响应(可能离线)" })
    end
  end
end

local function actSettings()
  local values = tui.form("设置服务器ID (0=自动发现)", {
    { key = "server", label = "服务器ID", type = "number", default = tostring(config.SERVER_ID) },
  })
  if not values then return end
  config.SERVER_ID = tonumber(values.server) or 0
  config.save()
  refreshServer()
  tui.msgBox("设置完成", {
    ("服务器ID: %d"):format(config.SERVER_ID),
    config.SERVER_ID == 0 and "将在需要时自动发现服务器" or "使用手动指定的服务器",
  })
end

------------------------------------------------------------------------------
-- 主循环
------------------------------------------------------------------------------

scanPeriphs()
local modemOk, modemErr = net.open()
if modemOk then
  refreshServer()
end

-- 启动提示(调制解调器缺失时)
if not modemOk then
  tui.msgBox("调制解调器", {
    modemErr or "未找到调制解调器",
    "网络功能不可用, 仅能使用软盘本地功能",
  })
end

local lastServerCheck = 0
while true do
  scanPeriphs()
  -- 离线时每 15 秒尝试重新发现服务器(rednet.lookup 会阻塞约 2 秒)
  if not serverId and os.time() - lastServerCheck >= 15 then
    lastServerCheck = os.time()
    refreshServer()
  end

  tui.frame("护照管理系统 v" .. config.VERSION, statusText())
  local sel = tui.menu("请选择操作", {
    { label = "签发新护照" },
    { label = "查看护照" },
    { label = "编辑护照" },
    { label = "签证盖章" },
    { label = "同步: 服务器 → 软盘" },
    { label = "上传: 软盘 → 服务器" },
    { label = "服务器状态" },
    { label = "设置" },
    { label = "退出" },
  })
  if not sel then break end -- Esc 退出
  if sel == 1 then actIssue()
  elseif sel == 2 then actView()
  elseif sel == 3 then actEdit()
  elseif sel == 4 then actStamp()
  elseif sel == 5 then actSyncDown()
  elseif sel == 6 then actSyncUp()
  elseif sel == 7 then actStatus()
  elseif sel == 8 then actSettings()
  elseif sel == 9 then break end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("已退出护照系统。")

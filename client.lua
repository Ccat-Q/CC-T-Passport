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
  return string.format("Disk:%s Mon:%s Print:%s | %s",
    periph.disk and "Y" or "N",
    periph.monitor and "Y" or "N",
    periph.printer and "Y" or "N",
    serverId and ("Server #" .. serverId) or "Server offline")
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
  mon.write(tui.pad("* P A S S P O R T *", w, "center"))

  -- 正文
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
  local lines = {
    "ID     : " .. p.id,
    "Name   : " .. p.name,
    "Age    : " .. tostring(p.age or 0),
    "Gender : " .. p.gender,
    "Nationality : " .. p.nation,
    "Photo  : " .. (p.photo and p.photo ~= "" and p.photo or "None"),
    "Issued : " .. p.issued,
    "Expiry : " .. p.expiry,
    "Status : " .. (ok and "VALID" or "INVALID"),
    "Stamps : " .. #(p.stamps or {}),
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
  if not periph.printer then return false, "No printer" end
  local pr = peripheral.wrap(config.PRINTER_SIDE)
  if not pr then return false, "Printer unavailable" end
  if pr.getInkLevel() < 1 or pr.getPaperLevel() < 1 then
    return false, "Printer out of ink or paper"
  end
  if not pr.newPage() then
    return false, "Cannot start new page"
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
    return false, "Failed to end page"
  end
  return true
end

local function passportPageLines(p)
  local ok, reason = passport.validate(p)
  return {
    "==================================",
    "         P A S S P O R T",
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
  local stype = { ["Entry"] = "IN", ["Exit"] = "OUT", ["Visa"] = "VISA" }
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
  term.write(tui.pad(" " .. tui.truncate("Passport Details  " .. p.id, w - 2), w))

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
    line(("Name: %s    Age: %d    Gender: %s"):format(p.name, p.age or 0, p.gender))
    line(("Nationality: %s    Photo: %s"):format(p.nation, (p.photo and p.photo ~= "") and p.photo or "None"))
    line(("Issued: %s    Expires: %s"):format(p.issued, p.expiry))
    if p.note and p.note ~= "" then
      line("Note: " .. p.note)
    end
    line("Status: " .. (ok and "VALID" or "INVALID") .. "  ·  " .. (reason or ""))

    y = y + 2
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.gray)
    term.setCursorPos(1, y)
    term.write(tui.truncate(("-- Visa Records (%d)  Page %d/%d --"):format(#stamps, page, pages), w))

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
    term.write(tui.truncate("< > page  P print  M monitor  Esc back", w))
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
          tui.msgBox("Print", { "Passport page printed!" })
        else
          tui.msgBox("Print Failed", { errp or "Unknown error" })
        end
        draw()
      elseif c == "m" then
        local shown = monitorShow(p)
        if not shown then
          tui.msgBox("Monitor", { "No monitor (" .. config.MONITOR_SIDE .. ")" })
          draw()
        end
      end
    end
  end
end

------------------------------------------------------------------------------
-- 各功能
------------------------------------------------------------------------------

local GENDER_CHOICES = { "Male", "Female", "Other" }
local STAMP_TYPES = { "Entry", "Exit", "Visa" }

local function actIssue()
  if not periph.disk then
    tui.msgBox("Issue Passport", { "No disk drive (" .. config.DISK_SIDE .. ")", "Place a disk drive with a floppy inserted" })
    return
  end
  local values = tui.form("Issue New Passport", {
    { key = "name",       label = "Name",       type = "text",   required = true, default = "" },
    { key = "age",        label = "Age",        type = "number" },
    { key = "gender",     label = "Gender",     type = "choice", choices = GENDER_CHOICES, default = "1" },
    { key = "nation",     label = "Nationality", type = "text",  default = "China" },
    { key = "photo",      label = "Photo Desc", type = "text" },
    { key = "note",       label = "Note",       type = "text" },
    { key = "validYears", label = "Valid Years", type = "number", default = tostring(config.DEFAULT_VALID_YEARS) },
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
    tui.msgBox("Issue Failed", { errw or "Disk write failed" })
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
      tui.msgBox("Issue Successful", {
        "Passport written to disk and registered on server",
        "ID      : " .. p.id,
        "Name    : " .. p.name,
        "Expires : " .. p.expiry,
      })
      if periph.printer and tui.confirm("Print Passport Page?", { "Print a souvenir passport page?" }) then
        local okp, errp = printerPage("Passport " .. p.id, passportPageLines(p))
        if not okp then tui.msgBox("Print Failed", { errp or "Unknown error" }) end
      end
    else
      local e = (resp and resp.data and resp.data.error) or "Server not responding"
      tui.msgBox("Warning", {
        "Not registered (server offline?)",
        "Reason: " .. tostring(e),
        "Passport saved to disk; you can \"Upload: Disk to Server\" later",
      })
    end
  else
    tui.msgBox("Issued (Local Only)", {
      "Server offline; passport saved to disk only",
      "ID: " .. p.id,
      "Choose \"Upload: Disk to Server\" from the menu later",
    })
  end
  monitorShow(p)
end

local function actView()
  if not periph.disk then
    tui.msgBox("View Passport", { "No disk drive (" .. config.DISK_SIDE .. ")" })
    return
  end
  local p, err = passport.readDisk(config.DISK_SIDE)
  if not p then
    tui.msgBox("View Passport", { err or "Read failed" })
    return
  end
  showPassport(p)
end

local function actEdit()
  if not periph.disk then
    tui.msgBox("Edit Passport", { "No disk drive (" .. config.DISK_SIDE .. ")" })
    return
  end
  local p, err = passport.readDisk(config.DISK_SIDE)
  if not p then
    tui.msgBox("Edit Passport", { err or "Read failed" })
    return
  end
  local curGender = 1
  for i, g in ipairs(GENDER_CHOICES) do
    if g == p.gender then curGender = i end
  end
  local values = tui.form("Edit Passport " .. p.id, {
    { key = "name",   label = "Name",        type = "text",   required = true, default = p.name },
    { key = "age",    label = "Age",         type = "number", default = tostring(p.age or "") },
    { key = "gender", label = "Gender",      type = "choice", choices = GENDER_CHOICES, default = tostring(curGender) },
    { key = "nation", label = "Nationality", type = "text",   default = p.nation },
    { key = "photo",  label = "Photo Desc",  type = "text",   default = p.photo },
    { key = "note",   label = "Note",        type = "text",   default = p.note },
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
    tui.msgBox("Edit Failed", { errw or "Disk write failed" })
    return
  end
  if serverId then
    local resp = net.request(serverId, { type = "update", data = p }, 6)
    if resp and resp.ok then
      tui.msgBox("Edit Complete", { "Saved to disk and synced to server" })
    else
      local e = (resp and resp.data and resp.data.error) or "Server not responding"
      tui.msgBox("Saved to Disk", { "Server sync failed: " .. tostring(e), "Use \"Upload: Disk to Server\" to retry later" })
    end
  else
    tui.msgBox("Saved to Disk", { "Server offline, not synced" })
  end
  monitorShow(p)
end

local function actStamp()
  if not periph.disk then
    tui.msgBox("Stamp Visa", { "No disk drive (" .. config.DISK_SIDE .. ")" })
    return
  end
  local p, err = passport.readDisk(config.DISK_SIDE)
  if not p then
    tui.msgBox("Stamp Visa", { err or "Read failed" })
    return
  end
  local ok, reason = passport.validate(p)
  if not ok then
    tui.msgBox("Cannot Stamp", { "This passport cannot be stamped: " .. reason })
    return
  end
  local values = tui.form("Stamp Visa · " .. p.id, {
    { key = "type",    label = "Stamp Type",   type = "choice", choices = STAMP_TYPES, default = "1" },
    { key = "country", label = "Country/Port", type = "text",   required = true },
    { key = "note",    label = "Note",         type = "text" },
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
    tui.msgBox("Stamp Failed", { errw or "Disk write failed" })
    return
  end

  local synced = false
  if serverId then
    local resp = net.request(serverId, { type = "stamp", id = p.id, stamp = stamp }, 6)
    if resp and resp.ok then
      synced = true
    else
      local e = (resp and resp.data and resp.data.error) or "Server not responding"
      tui.msgBox("Stamp Complete (Not Synced)", {
        "Server sync failed: " .. tostring(e),
        "Stamp saved to disk",
      })
    end
  end
  if synced then
    tui.msgBox("Stamp Complete", {
      ("Stamped: %s / %s"):format(stamp.type, stamp.country),
      "Time: " .. stamp.time,
      "Synced to server",
    })
  end
  if periph.printer and tui.confirm("Print Receipt?", { "Print the visa stamp receipt?" }) then
    local okp, errp = printerPage("Visa " .. stamp.type .. " " .. p.id, visaReceiptLines(p, stamp))
    if not okp then tui.msgBox("Print Failed", { errp or "Unknown error" }) end
  end
  monitorShow(p)
end

local function actSyncDown()
  if not periph.disk then
    tui.msgBox("Sync", { "No disk drive (" .. config.DISK_SIDE .. ")" })
    return
  end
  if not serverId then refreshServer() end
  if not serverId then
    tui.msgBox("Sync Failed", { "No server found, cannot sync" })
    return
  end
  local id = disk.isPresent(config.DISK_SIDE) and disk.getLabel(config.DISK_SIDE) or nil
  if not id then
    -- 从软盘上的护照文件读取编号
    local p, err = passport.readDisk(config.DISK_SIDE)
    if p then
      id = p.id
    else
      local vals = tui.form("Sync to Disk", {
        { key = "id", label = "Passport ID", type = "text", required = true },
      })
      if not vals then return end
      id = vals.id
    end
  end
  local resp = net.request(serverId, { type = "get", id = id }, 6)
  if resp and resp.ok then
    local okw, errw = passport.writeDisk(config.DISK_SIDE, resp.data.record)
    if okw then
      tui.msgBox("Sync Complete", { ("Server data for %s written to disk"):format(id) })
      monitorShow(resp.data.record)
    else
      tui.msgBox("Sync Failed", { errw or "Disk write failed" })
    end
  else
    local e = (resp and resp.data and resp.data.error) or "Server not responding"
    tui.msgBox("Sync Failed", { tostring(e) })
  end
end

local function actSyncUp()
  if not periph.disk then
    tui.msgBox("Upload", { "No disk drive (" .. config.DISK_SIDE .. ")" })
    return
  end
  local p, err = passport.readDisk(config.DISK_SIDE)
  if not p then
    tui.msgBox("Upload Failed", { err or "Read failed" })
    return
  end
  if not serverId then refreshServer() end
  if not serverId then
    tui.msgBox("Upload Failed", { "No server found" })
    return
  end
  local resp = net.request(serverId, { type = "register", data = p }, 6)
  if resp and resp.ok then
    local saved = resp.data.record
    if saved and saved.id ~= p.id then
      p = saved
      passport.writeDisk(config.DISK_SIDE, p) -- 服务器分配的编号回写软盘
    end
    tui.msgBox("Upload Complete", {
      ("Uploaded %s (%s)"):format(p.id, resp.data.isNew and "new" or "update"),
    })
  else
    local e = (resp and resp.data and resp.data.error) or "Server not responding"
    tui.msgBox("Upload Failed", { tostring(e) })
  end
end

local function actStatus()
  if not serverId then refreshServer() end
  if not serverId then
    tui.msgBox("Server Status", {
      "No passport server found",
      "Check: server computer is running and has a modem",
    })
    return
  end
  local resp = net.request(serverId, { type = "stats" }, 5)
  if resp and resp.ok then
    local s = resp.data.stats
    tui.msgBox("Server Status", {
      ("Server computer: #%d"):format(serverId),
      ("Version: %s"):format(config.VERSION),
      ("Total passports: %d"):format(s.total),
      ("Valid %d  Revoked %d  Expired %d"):format(s.active, s.revoked, s.expired),
      ("Next ID: %s"):format(s.nextID),
    })
  else
    -- 服务器可能重启换了 ID, 重新发现一次
    refreshServer()
    if serverId then
      tui.msgBox("Server Status", { ("Re-discovered server #%d"):format(serverId) })
    else
      tui.msgBox("Server Status", { "Server not responding (offline?)" })
    end
  end
end

local function actSettings()
  local values = tui.form("Set Server ID (0=auto-detect)", {
    { key = "server", label = "Server ID", type = "number", default = tostring(config.SERVER_ID) },
  })
  if not values then return end
  config.SERVER_ID = tonumber(values.server) or 0
  config.save()
  refreshServer()
  tui.msgBox("Settings Saved", {
    ("Server ID: %d"):format(config.SERVER_ID),
    config.SERVER_ID == 0 and "Auto-detect server when needed" or "Use manually specified server",
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
  tui.msgBox("Modem", {
    modemErr or "No modem found",
    "Network unavailable; disk-local features only",
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

  tui.frame("Passport System v" .. config.VERSION, statusText())
  local sel = tui.menu("Select action", {
    { label = "Issue Passport" },
    { label = "View Passport" },
    { label = "Edit Passport" },
    { label = "Stamp Visa" },
    { label = "Sync: Server to Disk" },
    { label = "Upload: Disk to Server" },
    { label = "Server Status" },
    { label = "Settings" },
    { label = "Exit" },
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
print("Exited Passport System.")

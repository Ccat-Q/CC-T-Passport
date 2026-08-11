--[[
  Passport System - 中央服务器
  ============================
  负责保存所有护照数据(/db/passports.dat), 通过 rednet 向客户端提供服务。
  部署到游戏中的"服务器电脑"后, 可重命名为 startup.lua 实现开机自启。

  在游戏内输入 `id` 命令可查看本机电脑 ID, 供客户端手动指定使用。
]]

local config = require("lib.config")
local db = require("lib.db")
local passport = require("lib.passport")

local data = db.load()

local function log(msg)
  print(("[%s] %s"):format(os.date("%H:%M:%S"), tostring(msg)))
end

-- 向客户端回包
local function reply(client, reqId, ok, payload)
  local resp = { type = "response", reqId = reqId, ok = ok, data = payload }
  rednet.send(client, resp, config.PROTOCOL)
end

-- 处理业务请求
local function handle(client, msg)
  local t = msg.type
  if t == "ping" then
    reply(client, msg.reqId, true, {
      pong = true,
      version = config.VERSION,
      time = os.time(),
      serverID = os.getComputerID(),
    })
  elseif t == "register" then
    if type(msg.data) ~= "table" then
      reply(client, msg.reqId, false, { error = "数据格式错误" })
      return
    end
    local rec, isNew = db.register(data, msg.data)
    local ok, err = db.save(data)
    if not ok then
      reply(client, msg.reqId, false, { error = "服务器数据库写入失败: " .. tostring(err) })
      return
    end
    log(("登记护照 %s (%s) 姓名=%s"):format(rec.id, isNew and "新签" or "更新", rec.name))
    reply(client, msg.reqId, true, { record = rec, isNew = isNew })
  elseif t == "get" then
    local rec = db.get(data, msg.id)
    if rec then
      reply(client, msg.reqId, true, { record = rec })
    else
      reply(client, msg.reqId, false, { error = "未找到护照 " .. tostring(msg.id) })
    end
  elseif t == "stamp" then
    if type(msg.stamp) ~= "table" then
      reply(client, msg.reqId, false, { error = "盖章数据格式错误" })
      return
    end
    local rec, err = db.addStamp(data, msg.id, msg.stamp)
    if rec then
      db.save(data)
      log(("盖章 %s : %s / %s"):format(msg.id, msg.stamp.type or "?", msg.stamp.country or "?"))
      reply(client, msg.reqId, true, { record = rec })
    else
      reply(client, msg.reqId, false, { error = err or "盖章失败" })
    end
  elseif t == "update" then
    local rec = msg.data
    if type(rec) ~= "table" or not rec.id then
      reply(client, msg.reqId, false, { error = "数据格式错误" })
      return
    end
    if not db.get(data, rec.id) then
      reply(client, msg.reqId, false, { error = "护照不存在, 请先登记" })
      return
    end
    data.passports[rec.id] = rec
    db.save(data)
    log(("更新护照 %s"):format(rec.id))
    reply(client, msg.reqId, true, { record = rec })
  elseif t == "check" then
    local rec = db.get(data, msg.id)
    if not rec then
      reply(client, msg.reqId, false, { error = "未找到护照 " .. tostring(msg.id) })
      return
    end
    local ok, reason = passport.validate(rec)
    reply(client, msg.reqId, ok, { record = rec, reason = reason })
  elseif t == "revoke" then
    local rec, err = db.revoke(data, msg.id)
    if rec then
      db.save(data)
      log(("吊销护照 %s"):format(msg.id))
      reply(client, msg.reqId, true, { record = rec })
    else
      reply(client, msg.reqId, false, { error = err or "吊销失败" })
    end
  elseif t == "remove" then
    local ok = db.remove(data, msg.id)
    if ok then db.save(data) end
    log(("删除护照 %s : %s"):format(msg.id, ok and "成功" or "未找到"))
    reply(client, msg.reqId, ok, {})
  elseif t == "stats" then
    reply(client, msg.reqId, true, { stats = db.stats(data) })
  else
    reply(client, msg.reqId, false, { error = "未知请求类型: " .. tostring(t) })
  end
end

-- 开机画面
local function banner()
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.cyan)
  print("============================================")
  print("    护照管理系统 · 中央服务器 v" .. config.VERSION)
  print("============================================")
  term.setTextColor(colors.white)
  print()
  print("  本机电脑 ID : " .. os.getComputerID())
  print("  数据库文件  : " .. config.SERVER_DB)
  local st = db.stats(data)
  print("  已存护照    : " .. st.total .. " (有效 " .. st.active
    .. " / 吊销 " .. st.revoked .. " / 过期 " .. st.expired .. ")")
  print("  下一编号    : " .. st.nextID)
  print()
  print("  运行中... Ctrl+T 停止, Ctrl+R 重启")
  print("--------------------------------------------------")
end

-- 启动前检查
local modem = peripheral.find("modem")
if not modem then
  term.setTextColor(colors.red)
  print("错误: 未连接调制解调器!")
  print("请在电脑背面(或其他面)放置有线调制解调器。")
  term.setTextColor(colors.white)
  return
end
local ok, err = pcall(rednet.open, peripheral.getName(modem))
if not ok then
  term.setTextColor(colors.red)
  print("错误: 打开调制解调器失败: " .. tostring(err))
  term.setTextColor(colors.white)
  return
end

-- 注册发现服务(供客户端 rednet.lookup)
local hostOk, hostErr = pcall(rednet.host, config.DISCOVERY_PROTOCOL, config.DISCOVERY_NAME)
if not hostOk then
  term.setTextColor(colors.yellow)
  print("警告: 注册发现服务失败: " .. tostring(hostErr))
  print("       (可能已有一个服务器在运行?)")
  term.setTextColor(colors.white)
end

banner()

parallel.waitForAny(
  -- 业务请求循环
  function()
    while true do
      local client, msg, proto = rednet.receive(config.PROTOCOL)
      if type(msg) == "table" then
        local okc, errc = pcall(handle, client, msg)
        if not okc then
          log(("处理请求出错: %s"):format(errc))
          reply(client, msg.reqId, false, { error = "服务器内部错误" })
        end
      end
    end
  end,
  -- 每秒刷新一次状态行
  function()
    while true do
      os.sleep(1)
      local w, h = term.getSize()
      local st = db.stats(data)
      term.setBackgroundColor(colors.gray)
      term.setTextColor(colors.black)
      term.setCursorPos(1, h)
      local line = ("  护照总数 %d  有效 %d  吊销 %d  过期 %d"):format(
        st.total, st.active, st.revoked, st.expired)
      term.write(line .. string.rep(" ", w - #line))
      term.setBackgroundColor(colors.black)
    end
  end
)

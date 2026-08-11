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
      reply(client, msg.reqId, false, { error = "Bad data format" })
      return
    end
    local rec, isNew = db.register(data, msg.data)
    local ok, err = db.save(data)
    if not ok then
      reply(client, msg.reqId, false, { error = "Server DB write failed: " .. tostring(err) })
      return
    end
    log(("Registered %s (%s) name=%s"):format(rec.id, isNew and "new" or "update", rec.name))
    reply(client, msg.reqId, true, { record = rec, isNew = isNew })
  elseif t == "get" then
    local rec = db.get(data, msg.id)
    if rec then
      reply(client, msg.reqId, true, { record = rec })
    else
      reply(client, msg.reqId, false, { error = "Passport not found: " .. tostring(msg.id) })
    end
  elseif t == "stamp" then
    if type(msg.stamp) ~= "table" then
      reply(client, msg.reqId, false, { error = "Bad stamp data" })
      return
    end
    local rec, err = db.addStamp(data, msg.id, msg.stamp)
    if rec then
      db.save(data)
      log(("Stamped %s: %s / %s"):format(msg.id, msg.stamp.type or "?", msg.stamp.country or "?"))
      reply(client, msg.reqId, true, { record = rec })
    else
      reply(client, msg.reqId, false, { error = err or "Stamp failed" })
    end
  elseif t == "update" then
    local rec = msg.data
    if type(rec) ~= "table" or not rec.id then
      reply(client, msg.reqId, false, { error = "Bad data format" })
      return
    end
    if not db.get(data, rec.id) then
      reply(client, msg.reqId, false, { error = "Passport not found, register it first" })
      return
    end
    data.passports[rec.id] = rec
    db.save(data)
    log(("Updated passport %s"):format(rec.id))
    reply(client, msg.reqId, true, { record = rec })
  elseif t == "check" then
    local rec = db.get(data, msg.id)
    if not rec then
      reply(client, msg.reqId, false, { error = "Passport not found: " .. tostring(msg.id) })
      return
    end
    local ok, reason = passport.validate(rec)
    reply(client, msg.reqId, ok, { record = rec, reason = reason })
  elseif t == "revoke" then
    local rec, err = db.revoke(data, msg.id)
    if rec then
      db.save(data)
      log(("Revoked passport %s"):format(msg.id))
      reply(client, msg.reqId, true, { record = rec })
    else
      reply(client, msg.reqId, false, { error = err or "Revoke failed" })
    end
  elseif t == "remove" then
    local ok = db.remove(data, msg.id)
    if ok then db.save(data) end
    log(("Deleted passport %s: %s"):format(msg.id, ok and "ok" or "not found"))
    reply(client, msg.reqId, ok, {})
  elseif t == "stats" then
    reply(client, msg.reqId, true, { stats = db.stats(data) })
  else
    reply(client, msg.reqId, false, { error = "Unknown request type: " .. tostring(t) })
  end
end

-- 开机画面
local function banner()
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.cyan)
  print("============================================")
  print("    Passport System · Central Server v" .. config.VERSION)
  print("============================================")
  term.setTextColor(colors.white)
  print()
  print("  Computer ID: " .. os.getComputerID())
  print("  Database file: " .. config.SERVER_DB)
  local st = db.stats(data)
  print("  Passports: " .. st.total .. " (valid " .. st.active
    .. " / revoked " .. st.revoked .. " / expired " .. st.expired .. ")")
  print("  Next ID: " .. st.nextID)
  print()
  print("  Running... Ctrl+T stop, Ctrl+R restart")
  print("--------------------------------------------------")
end

-- 启动前检查
local modem = peripheral.find("modem")
if not modem then
  term.setTextColor(colors.red)
  print("Error: no modem attached!")
  print("Place a wired modem on the computer (back or any side).")
  term.setTextColor(colors.white)
  return
end
local ok, err = pcall(rednet.open, peripheral.getName(modem))
if not ok then
  term.setTextColor(colors.red)
  print("Error: failed to open modem: " .. tostring(err))
  term.setTextColor(colors.white)
  return
end

-- 注册发现服务(供客户端 rednet.lookup)
local hostOk, hostErr = pcall(rednet.host, config.DISCOVERY_PROTOCOL, config.DISCOVERY_NAME)
if not hostOk then
  term.setTextColor(colors.yellow)
  print("Warning: failed to register discovery service: " .. tostring(hostErr))
  print("       (another server may already be running?)")
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
          log(("Error handling request: %s"):format(errc))
          reply(client, msg.reqId, false, { error = "Server internal error" })
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
      local line = ("  Passports %d  valid %d  revoked %d  expired %d"):format(
        st.total, st.active, st.revoked, st.expired)
      term.write(line .. string.rep(" ", w - #line))
      term.setBackgroundColor(colors.black)
    end
  end
)

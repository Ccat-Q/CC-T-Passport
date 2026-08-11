--[[
  Passport System - 红石网络通信(客户端用)
  服务发现使用 rednet.host / rednet.lookup (CraftOS 内置机制)。
]]

local config = require("lib.config")
local net = {}

local reqCounter = 0

-- 打开调制解调器(自动找到侧边)
function net.open()
  local modem = peripheral.find("modem")
  if not modem then
    return false, "No modem found (install a wired/wireless modem)"
  end
  local side = peripheral.getName(modem)
  if not rednet.isOpen(side) then
    local ok, err = pcall(rednet.open, side)
    if not ok then
      return false, "Failed to open modem: " .. tostring(err)
    end
  end
  return true
end

-- 自动发现服务器。返回服务器电脑 ID 或 nil
function net.findServer()
  -- 优先用主机名精确查找
  local id = rednet.lookup(config.DISCOVERY_PROTOCOL, config.DISCOVERY_NAME)
  if id then return id end
  -- 退化为任意注册了该协议的电脑
  local ids = { rednet.lookup(config.DISCOVERY_PROTOCOL) }
  if #ids > 0 then return ids[1] end
  return nil
end

-- 获取服务器 ID: 手动配置优先, 否则自动发现
function net.getServerID()
  if config.SERVER_ID and config.SERVER_ID > 0 then
    return config.SERVER_ID
  end
  return net.findServer()
end

-- 生成请求编号(用于匹配响应)
function net.nextReqId()
  reqCounter = reqCounter + 1
  return string.format("%d-%d-%d", os.time(), reqCounter, math.random(1000, 9999))
end

-- 发送业务请求并等待响应。
-- payload: { type="register"|"get"|"stamp"|"update"|"check"|"stats"|"remove", ... }
-- 返回响应表, 超时返回 nil
function net.request(serverId, payload, timeout)
  payload = payload or {}
  payload.reqId = net.nextReqId()
  timeout = timeout or 6

  if not rednet.send(serverId, payload, config.PROTOCOL) then
    return nil
  end
  local deadline = os.time() + timeout
  while os.time() < deadline do
    local sender, msg, proto = rednet.receive(config.PROTOCOL, 0.5)
    if sender == serverId and type(msg) == "table"
      and msg.type == "response" and msg.reqId == payload.reqId then
      return msg
    end
  end
  return nil
end

-- 连接测试
function net.ping(serverId, timeout)
  local resp = net.request(serverId, { type = "ping" }, timeout or 3)
  return resp
end

return net

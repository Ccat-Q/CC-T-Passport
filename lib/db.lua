--[[
  Passport System - 服务器数据库
  数据保存在 /db/passports.dat (textutils.serialize 序列化),
  采用"写临时文件再替换"的原子写入, 崩溃不丢数据。
]]

local config = require("lib.config")
local db = {}

-- 载入数据库(不存在则返回空库)
function db.load()
  local data = { seq = 1, passports = {} }
  if fs.exists(config.SERVER_DB) then
    local f = fs.open(config.SERVER_DB, "r")
    if f then
      local raw = f.readAll()
      f.close()
      local ok, t = pcall(textutils.unserialize, raw)
      if ok and type(t) == "table" and type(t.passports) == "table" then
        data = t
      end
    end
  end
  return data
end

-- 保存数据库(原子写入)
function db.save(data)
  local ok, err = pcall(fs.makeDir, "/db")
  if not ok then return false, err end
  local tmp = config.SERVER_DB .. ".tmp"
  local f = fs.open(tmp, "w")
  if not f then return false, "Cannot write database" end
  f.write(textutils.serialize(data))
  f.close()
  if fs.exists(config.SERVER_DB) then
    fs.delete(config.SERVER_DB)
  end
  fs.move(tmp, config.SERVER_DB)
  return true
end

-- 注册(新签)或更新护照。返回 record, isNew
-- 若 rec.id 为空则分配官方编号 PN-YYYY-NNNN
function db.register(data, rec)
  local id = rec.id or ""
  if id == "" then
    id = string.format("PN-%s-%04d", os.date("%Y", os.epoch("utc") / 1000), data.seq)
    data.seq = data.seq + 1
    rec.id = id
    return rec, true
  end
  local isNew = data.passports[id] == nil
  rec.id = id
  data.passports[id] = rec
  return rec, isNew
end

-- 按 ID 查询
function db.get(data, id)
  return data.passports[id]
end

-- 删除
function db.remove(data, id)
  if data.passports[id] then
    data.passports[id] = nil
    return true
  end
  return false
end

-- 追加盖章记录(自动保存由调用方负责)
function db.addStamp(data, id, stamp)
  local rec = data.passports[id]
  if not rec then
    return nil, "Passport not found: " .. tostring(id)
  end
  local pmod = require("lib.passport")
  pmod.addStamp(rec, stamp)
  return rec
end

-- 吊销
function db.revoke(data, id)
  local rec = data.passports[id]
  if not rec then
    return nil, "Passport not found: " .. tostring(id)
  end
  rec.status = "revoked"
  return rec
end

-- 统计
function db.stats(data)
  local total, active, revoked, expired = 0, 0, 0, 0
  local now = os.epoch("utc") / 1000
  for _, p in pairs(data.passports) do
    total = total + 1
    if p.status == "revoked" then
      revoked = revoked + 1
    elseif p.expires and now > p.expires then
      expired = expired + 1
    else
      active = active + 1
    end
  end
  return {
    total = total,
    active = active,
    revoked = revoked,
    expired = expired,
    nextID = string.format("PN-%s-%04d", os.date("%Y", os.epoch("utc") / 1000), data.seq),
  }
end

return db

--[[
  Passport System - 护照数据模型 & 软盘读写
  服务器与客户端共用本文件。
]]

local config = require("lib.config")
local passport = {}

-- 客户端本地生成一个临时护照编号(服务器登记后可能换成官方编号)
-- 限制在 13 字符以内, 满足软盘标签长度限制
function passport.provisionalID()
  local t = os.epoch("utc") / 1000
  local sub = (os.clock() * 10000) % 10000
  return string.format("PN-%04d-%04d", t % 10000, math.floor(sub))
end

-- 新建护照记录。data: 表单收集的字段表
function passport.new(data)
  data = data or {}
  local validYears = tonumber(data.validYears) or config.DEFAULT_VALID_YEARS
  if validYears < 1 then validYears = 1 end
  local now = os.epoch("utc") / 1000
  local p = {
    id         = (data.id and data.id ~= "") and data.id or passport.provisionalID(),
    name       = data.name or "Unknown",
    age        = tonumber(data.age) or 0,
    gender     = data.gender or "Unknown",
    nation     = data.nation or "Unknown",
    photo      = data.photo or "",
    note       = data.note or "",
    validYears = validYears,
    issued     = os.date("%Y-%m-%d %H:%M:%S", now),
    expiry     = os.date("%Y-%m-%d", now + validYears * 365 * 24 * 3600),
    expires    = now + validYears * 365 * 24 * 3600,
    status     = data.status or "active", -- active / revoked
    stamps     = data.stamps or {},       -- 签证/出入境记录
  }
  return p
end

-- 校验护照有效性。返回 ok, 原因
function passport.validate(p)
  if type(p) ~= "table" or not p.id or p.id == "" then
    return false, "Invalid passport data"
  end
  if p.status == "revoked" then
    return false, "Passport has been revoked"
  end
  if p.expires and os.epoch("utc") / 1000 > p.expires then
    return false, "Passport expired (" .. tostring(p.expiry) .. ")"
  end
  return true, "Valid until " .. tostring(p.expiry or "?") .. ")"
end

-- 添加签证/出入境记录。stamp: { type="入境"|"出境"|"签证", country=..., note=... }
-- 返回追加后的记录
function passport.addStamp(p, stamp)
  stamp = stamp or {}
  stamp.time = os.date("%Y-%m-%d %H:%M:%S", os.epoch("utc") / 1000)
  stamp.idx = #p.stamps + 1
  table.insert(p.stamps, stamp)
  return stamp
end

-- 护照状态的中文描述
function passport.statusText(p)
  local ok, reason = passport.validate(p)
  return ok and "VALID" or "INVALID"
end

------------------------------------------------------------------------------
-- 软盘读写
------------------------------------------------------------------------------

-- 从软盘读取护照。返回 record, 或 nil, 错误信息
function passport.readDisk(side)
  side = side or config.DISK_SIDE
  if not disk.isPresent(side) then
    return nil, "No disk in drive"
  end
  if not disk.hasData(side) then
    return nil, "Disk has no filesystem (format a blank floppy first)"
  end
  local mount = disk.getMountPath(side) or "disk"
  local path = "/" .. mount .. "/" .. config.DISK_FILE
  if not fs.exists(path) then
    return nil, "No passport file on disk (" .. config.DISK_FILE .. ")"
  end
  local f = fs.open(path, "r")
  if not f then
    return nil, "Cannot open passport file"
  end
  local raw = f.readAll()
  f.close()
  local ok, data = pcall(textutils.unserialize, raw)
  if not ok or type(data) ~= "table" then
    return nil, "Passport file is corrupted or invalid"
  end
  return data
end

-- 写入护照到软盘(先写临时文件再替换, 防止写入中断损坏数据)。
-- 返回 true, 或 nil, 错误信息
function passport.writeDisk(side, p)
  side = side or config.DISK_SIDE
  if not disk.isPresent(side) then
    return nil, "No disk in drive"
  end
  if not disk.hasData(side) then
    return nil, "Disk has no filesystem (format a blank floppy first)"
  end
  local mount = disk.getMountPath(side) or "disk"
  local dir = "/" .. mount
  local path = dir .. "/" .. config.DISK_FILE
  local tmp = dir .. "/." .. config.DISK_FILE .. ".tmp"

  local f = fs.open(tmp, "w")
  if not f then
    return nil, "Cannot write to disk (full or read-only?)"
  end
  f.write(textutils.serialize(p))
  f.close()

  if fs.exists(path) then
    fs.delete(path)
  end
  fs.move(tmp, path)
  disk.setLabel(side, p.id)
  return true
end

return passport

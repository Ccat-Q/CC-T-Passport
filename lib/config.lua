--[[
  Passport System - 共享配置
  服务器与客户端电脑都需要安装本文件(lib/config.lua)。

  外设朝向约定(客户端):
    back   - 有线调制解调器(modem)
    right  - 磁盘驱动器(drive)
    top    - 显示器(monitor, 可选)
    bottom - 打印机(printer, 可选)
  如需修改朝向, 直接改下面的字符串即可。
]]

local config = {
  NAME    = "护照管理系统",
  VERSION = "1.0.0",

  -- 红石网络协议名(整个系统必须一致)
  PROTOCOL           = "passport",          -- 业务消息协议
  DISCOVERY_PROTOCOL = "passport_discover", -- 服务器发现协议
  DISCOVERY_NAME     = "passport-server",   -- 服务器在发现协议中注册的主机名

  -- 服务器电脑 ID:
  --   0  = 每次启动自动发现(推荐, 依赖 rednet.lookup)
  --   N  = 手动指定服务器电脑 ID(输入 `id` 命令可查看), 可跳过发现过程
  SERVER_ID = 0,

  -- 外设朝向(客户端)
  MODEM_SIDE   = "back",   -- 调制解调器
  DISK_SIDE    = "right",  -- 磁盘驱动器
  MONITOR_SIDE = "top",    -- 显示器(可选)
  PRINTER_SIDE = "bottom", -- 打印机(可选)

  -- 文件路径
  CONFIG_FILE = "/.passport_config",  -- 客户端本地持久化配置
  SERVER_DB   = "/db/passports.dat",  -- 服务器数据库
  DISK_FILE   = "passport.dat",       -- 软盘上的护照文件名

  -- 护照默认有效期(年)
  DEFAULT_VALID_YEARS = 5,
}

-- 读取持久化配置(客户端)
function config.load()
  if fs.exists(config.CONFIG_FILE) then
    local f = fs.open(config.CONFIG_FILE, "r")
    if f then
      local raw = f.readAll()
      f.close()
      local ok, t = pcall(textutils.unserialize, raw)
      if ok and type(t) == "table" and t.SERVER_ID then
        config.SERVER_ID = t.SERVER_ID
      end
    end
  end
end

-- 保存持久化配置(客户端)
function config.save()
  local f = fs.open(config.CONFIG_FILE, "w")
  if f then
    f.write(textutils.serialize({ SERVER_ID = config.SERVER_ID }))
    f.close()
  end
end

return config

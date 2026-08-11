# 护照管理系统 (Passport System) for CC: Tweaked

基于 [CC: Tweaked](https://tweaked.cc/) 的 Minecraft 护照/出入境管理系统。
适用于 **Minecraft 1.21.1 + CC: Tweaked 1.113+**。

## 快速开始（3 步）

```
① 准备外设：服务器电脑装 1 个 modem；每台客户端电脑装 modem + 磁盘驱动器
② 下载安装：wget https://raw.githubusercontent.com/Ccat-Q/CC-T-Passport/main/install.lua
③ 运行安装：install server   ← 服务器电脑
             install client   ← 每台客户端电脑
```

装好后服务器电脑运行 `server`，客户端电脑运行 `client`，状态栏出现 `服务器 #123` 即连接成功。

## 架构

```
                    ┌─────────────────────────┐
                    │   服务器电脑 (中央数据库) │
                    │   /db/passports.dat     │
                    │   rednet 服务 + 发现     │
                    └───────────┬─────────────┘
                                │ rednet (红石网络)
        ┌───────────────┬───────┴────────┬───────────────┐
        │               │                │               │
   ┌────┴─────┐   ┌─────┴────┐     ┌─────┴────┐    ┌─────┴────┐
   │客户端电脑A │   │客户端电脑B │  ... │ 边境检查站 │    │ 出入境大厅 │
   │(签发/编辑)│   │(查验/盖章)│     │ 显示器    │    │ 显示器+打印 │
   └────┬─────┘   └─────┬────┘     └──────────┘    └──────────┘
        │               │
     软盘(护照)      软盘(护照)
```

- **混合式存储**：每本护照 = 一张软盘（`passport.dat`）+ 服务器数据库中的一条记录。
- 创建护照时**同时**写入软盘并上传服务器；客户端可以**双向同步**。
- 服务器离线时仍可签发/查验（仅软盘），之后再手动上传。
- 支持**显示器**（大屏展示查验结果）与**打印机**（纸质护照页 / 签证回执）。

## 文件结构

| 文件 | 用途 | 部署到 |
|---|---|---|
| `server.lua` | 中央服务器主程序 | 服务器电脑 |
| `client.lua` | 客户端主程序（TUI） | 客户端电脑 |
| `lib/config.lua` | 共享配置（协议名/外设朝向/服务器ID） | 两者 |
| `lib/passport.lua` | 护照数据模型 + 软盘读写 | 两者 |
| `lib/db.lua` | 服务器数据库（原子写入） | 服务器 |
| `lib/net.lua` | rednet 通信（发现/请求） | 客户端 |
| `lib/tui.lua` | TUI 框架（菜单/表单/对话框，中文对齐） | 客户端 |
| `install.lua` | 一键安装器（由 `tools/package.ps1` 生成） | 两者 |
| `tools/package.ps1` | 打包脚本（重新生成 install.lua） | 开发机 |

## 部署步骤

### 1. 准备电脑与外设

**服务器电脑**（建议用高级电脑）：
- 任意一面放置**有线调制解调器**（modem）

**客户端电脑**（每台）：
- **背面**（`back`）：有线调制解调器
- **右侧**（`right`）：磁盘驱动器（drive）
- **顶部**（`top`，可选）：显示器（monitor）
- **底部**（`bottom`，可选）：打印机（printer）

> 外设朝向如需调整，改 `lib/config.lua` 顶部的 `MODEM_SIDE` / `DISK_SIDE` / `MONITOR_SIDE` / `PRINTER_SIDE`。

### 2. 上传代码

方式一（推荐）：在每台电脑上直接下载安装器：

```lua
wget https://raw.githubusercontent.com/Ccat-Q/CC-T-Passport/main/install.lua
```

然后运行：

```
install server    ← 在服务器电脑上
install client    ← 在每台客户端电脑上
```

> 前提：CC: Tweaked 的 HTTP API 需开启（单机默认开启；联机服需在 `computercraft-server.toml` 允许 http，默认白名单为空即放行所有域名）。

安装器会自动创建 `lib/` 目录并写入对应文件，**无需手动建目录或放文件**：

- `install server` → 写入 `lib/config.lua`、`lib/passport.lua`、`lib/db.lua`、`server.lua`
- `install client` → 写入 `lib/config.lua`、`lib/passport.lua`、`lib/net.lua`、`lib/tui.lua`、`client.lua`

> 外设朝向如需调整，改 `lib/config.lua` 顶部的 `MODEM_SIDE` / `DISK_SIDE` / `MONITOR_SIDE` / `PRINTER_SIDE`（默认 `back` / `right` / `top` / `bottom`，与上面的外设摆放一致，通常不用改）。

方式二：如果上述直链不可用，可用 `pastebin get <code> install` 下载。

方式三：按文件结构手动 `edit` / `wget` 逐个创建文件。

### 3. 启动

```
# 服务器电脑
server          # 或把 server.lua 重命名为 startup.lua 开机自启

# 客户端电脑
client
```

### 4. 确认连接

客户端状态栏显示 `服务器 #123` 即连接成功。
若显示"服务器离线"，检查：
- 服务器电脑是否已运行 `server`
- 两端调制解调器是否已连接且都有电
- 距离是否超出无线范围（无线 modem 建议中继器，或使用有线网络）

也可在客户端「设置」里手动填入服务器电脑 ID（在服务器电脑上输入 `id` 命令查看）。

## 使用指南

### 客户端菜单

| 菜单 | 说明 |
|---|---|
| 1. 签发新护照 | 填写姓名/年龄/性别/国籍/照片等 → 写入软盘 + 上传服务器 |
| 2. 查看护照 | 读取软盘，终端展示详情（←→翻页 / P 打印 / M 显示器） |
| 3. 编辑护照 | 修改软盘上的护照信息，同步服务器 |
| 4. 签证盖章 | 入境/出境/签证盖章（记录国家口岸+时间），可打印回执 |
| 5. 同步: 服务器→软盘 | 按编号从服务器拉取最新数据写入软盘 |
| 6. 上传: 软盘→服务器 | 把软盘数据登记/更新到服务器 |
| 7. 服务器状态 | 查看服务器统计（总数/有效/吊销/过期） |
| 8. 设置 | 手动指定服务器 ID（0 = 自动发现） |

### 服务器控制台

- 实时日志：每次登记/更新/盖章
- 底部状态行：护照统计
- `Ctrl+T` 停止，`Ctrl+R` 重启

### 数据说明

- 软盘文件：`passport.dat`（`textutils.serialize` 序列化）
- 服务器数据库：`/db/passports.dat`（原子写入，崩溃不丢数据）
- 护照编号：`PN-YYYY-NNNN`（服务器分配）；服务器离线时先用本地临时编号，上传后自动换成官方编号并回写软盘

## 常见问题

**Q: 软盘"无文件系统"？**
空白软盘插入磁盘驱动器后会自动格式化；如果不行，先把软盘插进电脑的软盘槽（手持右键）再插入驱动器。

**Q: 客户端一直"服务器离线"？**
先确认服务器 `server` 正在运行；再在客户端「设置」手动填入服务器电脑 ID。

**Q: 打印机缺墨水/纸张？**
打印机需要染料（墨水）和纸，对着打印机放置对应物品。

**Q: 显示器上中文乱码/错位？**
确认 CC: Tweaked 版本 ≥ 1.100（1.21.1 对应的 1.113+ 均支持 Unicode 渲染）。

## 开发

修改源码后重新生成安装器：

```
powershell -ExecutionPolicy Bypass -File tools\package.ps1
```

生成的 `install.lua` 会包含全部源码，上传到电脑后再次运行 `install server` / `install client` 即可覆盖更新。

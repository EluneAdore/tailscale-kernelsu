# Tailscale Native for KernelSU

> **KernelSU 纯内核模式 · 零 VPN 槽占用 · 真正开箱即用的「极致免维护」组网方案**

基于 **KernelSU** 的原生内核模式 **Tailscale** 管理模块，专为追求极致稳定、省心长效的 Android 用户打造。无需占用系统 VPN 虚拟接口插槽（可与 Clash、Surge 等分流代理完美共存），直接使用官方 Linux 原生静态二进制与内核 TUN 设备，提供极致网络性能与极低系统开销。深度贯彻**「一次配置，长期免维护 (Set and Forget)」**设计理念，并集成高颜值暗黑科技风 **WebUI** 控制面板。

---

## 📸 WebUI 控制面板预览

模块集成专为 Android 移动端触控优化的高颜值暗黑科技风 **WebUI** 控制面板，在 KernelSU 管理器内直接打开：

<div align="center">
  <img src="preview.jpg" alt="Tailscale Native WebUI 界面预览" width="400" style="max-width: 100%; border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.5);" />
</div>

### 🎨 界面视觉与交互特色
- **大标题体系与 68px 科技胶囊**：各卡片大标题统一专属图标与徽标；内部参数行严格对齐 68px 科技胶囊标签（`HOST`, `STATE`, `CORE`, `DAEMON`, `TUN`, `DERP` 等），彻底杜绝杂乱 Emoji，像素级上下左右严格对齐。
- **双栈触控芯片与独立双 PID**：IPv4 / IPv6 触控芯片卡片一键即时复制地址；主网络核心 (`CORE`, tailscaled) 与保活守护 (`DAEMON`, watchdog.sh) 独立监控显示。
- **局域网设备即时测速 (Peers)**：即时显示 Tailnet 节点在线状态、Direct P2P 直连通道与中继状态，内置平滑常驻 Ping 延迟测速探测器。
- **出口节点与子网广播 (Exit Node)**：防抖动下拉选择器一键切换出口节点；支持允许局域网免分流 (Allow LAN) 与一键自动探测物理 Wi-Fi 广播子网路由。
- **分流路由协同与服务管控**：一键切换 Accept Routes 与 Accept DNS（可交由外部代理分流）；提供服务启动/重启/停止与 Pre-auth key 密钥秒级一键绑定。
- **暗黑终端底层运行日志**：终端控制台实时查看底层运行状态，支持 ALL / INFO / WARN / ERROR 分类筛选、日志刷新、一键复制与清除。

---

## 🛡️ 极致免维护设计 (Set and Forget)

针对传统移动端组网工具频繁被杀后台、占满 VPN 插槽、网络切换假死、更新繁琐等痛点，本模块从底层实现真正**开箱即忘**的免维护体验：
- 🔄 **内核全自动静默升级**：后台自动检测 Tailscale 官方稳定源，静默下载校验与平滑热重启，自动备份旧版本至历史存档，终生免去手动寻找刷机包更新的繁琐。
- 🐕 **双进程看门狗秒级自愈**：`tailscaled` 核心主程序与 `watchdog.sh` 保活看门狗采用独立双 PID 架构；遭遇 Android 系统 LMK 激进杀后台数秒内自动复活拉起，永不断联。
- 🚀 **开机全自动静默就绪**：深度整合系统服务启动流程，开机就绪后自动静默加载 TUN 驱动、开启内核 IPv4/IPv6 转发与策略路由，无需开机后手动点开任何 App。
- 📶 **全场景网络热漫游**：依托 WireGuard 内核漫游特性，Wi-Fi / 5G / 飞行模式切换毫秒级重连；内置 Android DNS 动态补全与网关路由注入，彻底根除网络假死。
- 🕊️ **零 VPN 槽位冲突 · 和谐共存**：基于纯 Linux 内核 TUN (`tailscale0`)，完全不挤占系统单一 VPN 接口，可与 Clash / Surge 等分流代理全天候无缝并发共存。
- 💾 **认证凭据持久化隔离**：设备密钥与网络策略独立持久化存储，模块覆盖升级、系统小版本 OTA 或清理缓存均不丢失配置，一次认证，终生无需重复扫码授权。

---

## 🌟 核心特性速览

- 🚀 **原生内核网络 (Non-VPN Mode)**：Linux 内核 TUN 驱动 (`tailscale0`) 与策略路由，零性能折损，与第三方代理 100% 兼容共存。
- 📱 **KernelSU WebUI 原生控制**：管理器内直接唤起，无需安装任何臃肿第三方客户端 App。
- 🔑 **灵活认证绑定**：支持 Pre-auth Key 密钥一键秒级绑定或 Web 授权单点登录，支持一键重置解绑。
- 🌐 **Exit Node 出口双向管理**：支持指定任意 Tailnet 节点为上网出口，也可将当前手机广播为全局出口 (`0.0.0.0/0, ::/0`)。
- 📡 **Subnet Router 子网路由**：一键探测当前物理 Wi-Fi 内网网段（如 `192.168.2.0/24`）并向 Tailnet 广播。
- ⚙️ **自定义后台与出站代理**：支持自定义 Headscale 控制服务器地址，以及出站代理（`HTTP/SOCKS5 Proxy`）。
- 📜 **实时分级日志查看器**：集成黑框终端控制台，支持日志等级筛选、一键复制到剪贴板与清空。

---

## 📦 模块目录结构

```text
tailscale-kernelsu/
├── module.prop                  # 模块元数据 (id: tailscale_native)
├── customize.sh                 # KernelSU 安装与配置迁移脚本
├── service.sh                   # 开机启动脚本 (初始化 TUN、IP转发、启动服务)
├── uninstall.sh                 # 卸载清理脚本
├── icon.png                     # 模块图标
├── preview.jpg                  # WebUI 控制面板高清界面预览图
├── tailscale-native-v1.102.4.zip# 编译打包好的即刷即用 ZIP 模块文件 (运行 ./build.sh 一键生成)
├── system/bin/                  # 官方 ARM64 静态二进制 (tailscale, tailscaled)
├── scripts/                     # 后台控制脚本 (control.sh, iptables.sh, update.sh, watchdog.sh)
├── webroot/                     # WebUI 前端资源 (index.html, style.css, app.js, icon.png)
└── build.sh                     # 模块打包构建脚本
```

---

## 📲 安装与使用指南

### 1. 刷入模块
1. 将 `tailscale-native-v1.102.4.zip` 传输至手机。
2. 打开 **KernelSU 管理器** -> **模块** -> 点击 **安装** 选择 `.zip` 刷入，完成后重启设备。

### 2. 打开 WebUI 控制面板
重启后打开 **KernelSU 管理器**，找到 **Tailscale Native** 模块，点击 **WebUI** 按钮即可进入控制面板。

### 3. 设备登录绑定
- **密钥登录（推荐）**：在 [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys) 生成 Auth Key，粘贴到输入框中点击“密钥一键绑定”。
- **网页授权登录**：点击“获取网页登录链接”，在手机浏览器中打开完成授权。

### 4. 路由与 Exit Node 广播生效说明
开启“广播本机作为 Exit Node 出口”或“广播子网路由”后：登录 [Tailscale Machines 管理后台](https://login.tailscale.com/admin/machines)，找到本机点击 `···` -> **Edit route settings**，勾选批准（Approve）对应的 Subnet 路由与 Exit node 即可生效。

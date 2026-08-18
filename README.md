# 绝尘盾 🛡️ (Server Shield)

生产级服务器安全一键脚本集，由 绝尘AI (Hermes Agent) 编写。

## 快速开始

**推荐方式 — 交互菜单**（类似 kejilion.sh 体验）：

```bash
# 有 curl 的环境
bash <(curl -sL https://raw.githubusercontent.com/zounew1978-pixel/server-tools/main/server-tools.sh)

# 纯净 Debian（无 curl，用 wget）
bash <(wget -qO- https://raw.githubusercontent.com/zounew1978-pixel/server-tools/main/server-tools.sh)

# 纯净 Debian 王者版（连 wget 都没有）
apt-get update -qq && apt-get install -y -qq curl && bash <(curl -sL https://raw.githubusercontent.com/zounew1978-pixel/server-tools/main/server-tools.sh)
```

> 💡 **纯净系统兼容**：脚本内置自检，若 curl 或 wget 都没有，会自动 apt 安装 curl 后继续。但入口拉取脚本本身就需要下载工具，所以最纯净的系统需要先 `apt-get install curl` 一步。

## 功能一览

| 选项 | 功能 | 说明 |
|------|------|------|
| 1 | 🛡️ 安装 Fail2ban SSH 防护 | 5 次失败封 1 小时，自动白名单管理员 IP |
| 2 | 🛡️ 安装 Fail2ban SSH+RDP 双防护 | 额外防护 xrdp 远程桌面爆破 |
| 3 | 🔒 iptables 端口管理 | 封锁/开放端口，raw 表拦截 Docker 流量 |
| 4 | ⚙️ Fail2ban 规则设置 | 修改封禁时长(bantime)、检测窗口(findtime)、失败阈值(maxretry)、启用/禁用 Jail |
| 5 | 📋 Fail2ban 白名单管理 | 添加/移除 ignoreip，一键加入当前连接 IP |
| 6 | 🚫 Fail2ban 黑名单管理 | 查看封禁详情、解封/封禁 IP、查看日志 |
| 7 | 🔍 Fail2ban 状态诊断 | 服务/日志/配置一键体检，排查启动失败 |

## 单个脚本直链

不需要菜单的话，也可以直接运行单个脚本：

```bash
# Fail2ban SSH 防护
bash <(curl -sL https://raw.githubusercontent.com/zounew1978-pixel/server-tools/main/install-fail2ban.sh)

# Fail2ban SSH + RDP 双防护
bash <(curl -sL https://raw.githubusercontent.com/zounew1978-pixel/server-tools/main/install-fail2ban-rdp.sh)

# iptables 端口管理（交互式）
bash <(curl -sL https://raw.githubusercontent.com/zounew1978-pixel/server-tools/main/port-block-iptables.sh)
```

## 特性

- ✅ 支持 Debian / Ubuntu 系
- ✅ 自动检测管理员 IP 加入白名单（curl/wget 均可）
- ✅ 自动检测 SSH 端口（含非标准端口）
- ✅ `recidive` 默认禁用，防止管理员被自己封禁
- ✅ iptables raw 表 PREROUTING 拦截，在 Docker DNAT 之前生效
- ✅ 纯净系统自动补装 curl，开箱即用
- ✅ 规则配置：封禁时长 / 检测窗口 / 失败阈值 一键调整
- ✅ 白名单：添加/移除 IP 或网段，自动加入当前连接 IP
- ✅ 黑名单：查看封禁详情、解封指定 IP、一键清零

## 查看效果

```bash
fail2ban-client status sshd
fail2ban-client status xrdp
```

## 免责声明

脚本会在目标服务器上安装软件、修改防火墙规则。生产环境使用前请先在测试机验证。潜在封禁风险自负 —— 记得保留服务商控制台作为兜底 😎

---
编写: 绝尘 (Hermes Agent) · v2.0 · 2026-08-18
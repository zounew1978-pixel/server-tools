# 绝尘服务器安全工具集 🛡️

生产级服务器安全一键脚本集，由 绝尘AI (Hermes Agent) 编写。

## 快速开始

**推荐方式 — 交互菜单**（类似 kejilion.sh 体验）：

```bash
bash <(curl -sL https://raw.githubusercontent.com/zounew1978-pixel/server-tools/main/server-tools.sh)
```

## 功能一览

| 选项 | 功能 | 说明 |
|------|------|------|
| 1 | Fail2ban SSH 防护 | 5 次失败封 1 小时，自动白名单管理员 IP |
| 2 | Fail2ban SSH + RDP 双防护 | 额外防护 xrdp 远程桌面爆破 |
| 3 | iptables 端口管理 | 封锁/开放端口，raw 表拦截 Docker 流量 |

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
- ✅ 自动检测管理员 IP 加入白名单
- ✅ 自动检测 SSH 端口（含非标准端口）
- ✅ `recidive` 默认禁用，防止管理员被自己封禁
- ✅ iptables raw 表 PREROUTING 拦截，在 Docker DNAT 之前生效

## 查看效果

```bash
fail2ban-client status sshd
fail2ban-client status xrdp
```

## 免责声明

脚本会在目标服务器上安装软件、修改防火墙规则。生产环境使用前请先在测试机验证。潜在封禁风险自负 —— 记得保留服务商控制台作为兜底 😎

---
编写: 绝尘 (Hermes Agent) · 2026-08-18
#!/usr/bin/env bash
# ==============================================================================
# Fail2ban 生产级一键安装与配置脚本 (支持 SSH 与 xrdp 双防护) v2
# 特别修复: recidive 默认禁用，防止管理员被自己封禁
# 版本: v2 (平衡策略 + 管理员白名单 - 2026-08-14)
# 编写: 绝尘 (Hermes Agent)
# ==============================================================================

set -eo pipefail

# ------------------------------------------------------------------------------
# 颜色定义
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ------------------------------------------------------------------------------
# 自动检测管理员IP
# ------------------------------------------------------------------------------
detect_admin_ip() {
    local ips=""
    
    # 方法1: SSH_CONNECTION（通过SSH连接时）
    if [ -n "$SSH_CONNECTION" ]; then
        ips=$(echo "$SSH_CONNECTION" | awk '{print $3}')
    fi
    
    # 方法2: 本机外网IP（curl/wget 自适应）
    if [ -z "$ips" ]; then
        if command -v curl >/dev/null 2>&1; then
            ips=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
        elif command -v wget >/dev/null 2>&1; then
            ips=$(wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null || true)
        fi
    fi
    
    # 方法3: 本机IPv6
    if [ -z "$ips" ]; then
        if command -v curl >/dev/null 2>&1; then
            ips=$(curl -s --max-time 5 https://api64.ipify.org 2>/dev/null || true)
        elif command -v wget >/dev/null 2>&1; then
            ips=$(wget -qO- --timeout=5 https://api64.ipify.org 2>/dev/null || true)
        fi
    fi
    
    # 方法4: 本机内网IP
    if [ -z "$ips" ]; then
        ips=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    
    # 默认值
    echo "${ips:-127.0.0.1}"
}

ADMIN_IP=$(detect_admin_ip)
log_info "检测到管理员IP: ${ADMIN_IP}"

# ------------------------------------------------------------------------------
# 1. 检查 root 权限
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    log_error "此脚本必须以 root 权限运行，请使用 sudo bash $0"
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. 检查操作系统类型
# ------------------------------------------------------------------------------
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" && ! "$ID_LIKE" =~ (debian|ubuntu) ]]; then
        log_error "本脚本仅适用于 Debian / Ubuntu 系统。当前系统: ${NAME:-Unknown}"
        exit 1
    fi
    log_info "检测到操作系统: ${PRETTY_NAME}"
else
    log_error "无法检测操作系统类型 (/etc/os-release 文件缺失)。"
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. 检测端口
# ------------------------------------------------------------------------------
SSH_PORT=$(grep -h -i -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | tail -n 1 || echo "22")
XRD P_PORT=$(ss -tlnp 2>/dev/null | grep 'xrdp' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1 || echo "3389")

log_info "检测到 SSH 端口: ${SSH_PORT}"
log_info "检测到 XRDP 端口: ${XRP P_PORT}"

# ------------------------------------------------------------------------------
# 4. 检查现有安装
# ------------------------------------------------------------------------------
if command -v fail2ban-client &>/dev/null; then
    log_warn "检测到 Fail2ban 已经安装。"
    read -r -p "是否覆盖现有配置并重新安装？ [y/N]: " confirm || true
    confirm=${confirm:-n}
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "安装程序已取消。"
        exit 0
    fi
fi

# ------------------------------------------------------------------------------
# 5. 安装依赖
# ------------------------------------------------------------------------------
log_info "安装依赖包..."
apt-get update -qq
apt-get install -y -qq fail2ban iptables curl iproute2 xrdp

# ------------------------------------------------------------------------------
# 6. 生成配置文件
# ------------------------------------------------------------------------------
log_info "生成 Fail2ban 配置文件..."

mkdir -p /etc/fail2ban/jail.d

# 主配置
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
# 忽略的IP（管理员白名单）
ignoreip = 127.0.0.0/8 ::1 ${ADMIN_IP}
           2603:c024:2:e700:99a5:5100:9e26:8929/128

# 默认封禁动作
banaction = iptables-allports
banaction_allports = iptables-allports

[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 3600      # 1小时
findtime = 600       # 10分钟窗口

[xrdp]
enabled  = true
port     = ${XRP P_PORT}
filter   = xrdp
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 3600      # 1小时
findtime = 600       # 10分钟窗口
EOF

# Recidive 配置（v2 关键改进：默认禁用）
cat <<EOF > /etc/fail2ban/jail.d/recidive.local
[recidive]
enabled  = false
filter   = recidive
logpath  = /var/log/fail2ban.log
action   = iptables-allports[name=recidive, allports]
bantime  = 259200    # 30天（如果启用）
findtime = 86400     # 24小时窗口
maxretry = 2         # 2次被封即触发
EOF

log_success "配置文件已生成"

# ------------------------------------------------------------------------------
# 7. 启动服务
# ------------------------------------------------------------------------------
log_info "启动 Fail2ban 服务..."

systemctl daemon-reload
systemctl enable fail2ban
systemctl restart fail2ban

sleep 2

if systemctl is-active --quiet fail2ban; then
    log_success "Fail2ban 服务已启动"
else
    log_error "Fail2ban 服务启动失败"
    exit 1
fi

# ------------------------------------------------------------------------------
# 8. 验证配置
# ------------------------------------------------------------------------------
log_info "===== 配置验证 ====="

log_info "Fail2ban 状态:"
fail2ban-client status 2>/dev/null || echo "无法获取状态"

echo ""

log_info "SSH 监狱状态:"
fail2ban-client status sshd 2>/dev/null || echo "无法获取 SSH 监狱状态"

echo ""

log_info "XRDP 监狱状态:"
fail2ban-client status xrdp 2>/dev/null || echo "无法获取 XRDP 监狱状态"

echo ""

log_info "iptables 规则:"
iptables -L f2b-sshd -n -v 2>/dev/null || echo "无 f2b-sshd 链（正常）"
iptables -L f2b-xrdp -n -v 2>/dev/null || echo "无 f2b-xrdp 链（正常）"
iptables -L f2b-recidive -n -v 2>/dev/null || echo "无 f2b-recidive 链（已禁用）"

echo ""

log_info "管理员白名单:"
fail2ban-client get sshd ignoreip 2>/dev/null || echo "无法获取"

# ------------------------------------------------------------------------------
# 9. 生成报告
# ------------------------------------------------------------------------------
local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

cat <<EOF

==================================================
  Fail2ban + XRDP 双防护安装完成报告
  时间: ${timestamp}
==================================================

✅ 已完成的配置:
   - SSH 端口: ${SSH_PORT}
   - XRDP 端口: ${XRP P_PORT}
   - 封禁时长: 1小时
   - 失败阈值: SSH 5次 / XRDP 3次
   - 管理员IP: ${ADMIN_IP}

✅ 安全措施:
   - recidive 监狱已禁用（防止循环封禁）
   - 管理员IP已加入白名单
   - iptables 规则已生成

⚠️  重要提醒:
   - 如果出现连接问题，执行: fail2ban-client unban <IP>
   - 查看日志: tail -f /var/log/fail2ban.log
   - 解封所有IP: fail2ban-client unban --all

📋 常用命令:
   - 查看状态: fail2ban-client status
   - 查看SSH:  fail2ban-client status sshd
   - 查看XRDP: fail2ban-client status xrdp
   - 解封IP:   fail2ban-client unban <IP>
   - 重启服务: systemctl restart fail2ban

==================================================
EOF

log_success "安装完成！"

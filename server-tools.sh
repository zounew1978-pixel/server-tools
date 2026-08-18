#!/usr/bin/env bash
# ==============================================================================
# 绝尘服务器安全工具集 (Server Tools)
# 一键装载：Fail2ban 防护 + iptables 端口管理
# 用法: bash <(curl -sL https://raw.githubusercontent.com/zounew1978-pixel/server-tools/main/server-tools.sh)
# 编写: 绝尘 (Hermes Agent)
# 版本: v1.0 — 2026-08-18
# ==============================================================================
set -e

# 颜色定义
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

# 检查 root
if [ "$EUID" -ne 0 ]; then
    log_error "请以 root 身份运行（sudo bash）"
    exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# 功能1: Fail2ban SSH 防护
# ──────────────────────────────────────────────────────────────────────────────
install_fail2ban_ssh() {
    echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  安装 Fail2ban — SSH 防护${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}\n"

    log_info "更新软件包列表..."
    apt-get update -qq

    log_info "安装 fail2ban..."
    apt-get install -y -qq fail2ban iptables-persistent netfilter-persistent 2>/dev/null || \
    apt-get install -y -qq fail2ban

    # 自动检测管理员IP
    local admin_ip=""
    [ -n "$SSH_CONNECTION" ] && admin_ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    [ -z "$admin_ip" ] && admin_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
    [ -z "$admin_ip" ] && admin_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    log_info "检测到管理员IP: ${admin_ip}"

    # 检测 SSH 端口
    local ssh_port=$(grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    log_info "检测到 SSH 端口: ${ssh_port}"

    cat > /etc/fail2ban/jail.local <<EOL
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${admin_ip}
bantime = 3600
findtime = 600
maxretry = 5
banaction = iptables-multiport
banaction_allports = iptables-allports

[sshd]
enabled = true
port = ${ssh_port}
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600

[sshd-dos]
enabled = true
port = ${ssh_port}
filter = sshd
logpath = /var/log/auth.log
maxretry = 10
bantime = 600
findtime = 60

[recidive]
enabled = false
EOL

    systemctl restart fail2ban 2>/dev/null || true
    sleep 2

    log_success "Fail2ban SSH 防护安装完成！"
    echo -e "  ${GREEN}✓${NC} 管理员 IP 白名单: ${admin_ip}"
    echo -e "  ${GREEN}✓${NC} SSH 端口: ${ssh_port}"
    echo -e "  ${GREEN}✓${NC} 5 次失败 → 封 1 小时"
    echo -e "  ${GREEN}✓${NC} recidive 默认禁用（防止管理员自封）\n"
    echo -e "  查看状态: ${CYAN}fail2ban-client status sshd${NC}\n"
}

# ──────────────────────────────────────────────────────────────────────────────
# 功能2: Fail2ban SSH + RDP 双防护
# ──────────────────────────────────────────────────────────────────────────────
install_fail2ban_rdp() {
    echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  安装 Fail2ban — SSH + RDP 双防护${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}\n"

    log_info "更新软件包列表..."
    apt-get update -qq

    log_info "安装 fail2ban..."
    apt-get install -y -qq fail2ban iptables-persistent netfilter-persistent 2>/dev/null || \
    apt-get install -y -qq fail2ban

    # 检测管理员IP
    local admin_ip=""
    [ -n "$SSH_CONNECTION" ] && admin_ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    [ -z "$admin_ip" ] && admin_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
    [ -z "$admin_ip" ] && admin_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    log_info "检测到管理员IP: ${admin_ip}"

    # 检测 SSH 端口
    local ssh_port=$(grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    log_info "检测到 SSH 端口: ${ssh_port}"

    # 检测 RDP 端口（xrdp）
    local rdp_port=$(grep -i "^port=" /etc/xrdp/xrdp.ini 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ' || echo "3389")
    log_info "检测到 RDP 端口: ${rdp_port}"

    # 创建 xrdp 过滤器
    cat > /etc/fail2ban/filter.d/xrdp.conf <<'EOL'
[Definition]
failregex = ^\[INFO\] Socket \d+: Connection from \S+ port \d+ to port \d+$
            ^\[ERROR\] recv\(sess\) failed for \S+:\d+: Connection reset by peer$
            ^\[ERROR\] xrdp: process \d+ exiting with signal \d+$
            ^\[WARN\] libxrdp connection rejected from \S+:\d+$
ignoreregex =
EOL

    cat > /etc/fail2ban/jail.local <<EOL
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${admin_ip}
bantime = 3600
findtime = 600
maxretry = 5
banaction = iptables-multiport
banaction_allports = iptables-allports

[sshd]
enabled = true
port = ${ssh_port}
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600

[sshd-dos]
enabled = true
port = ${ssh_port}
filter = sshd
logpath = /var/log/auth.log
maxretry = 10
bantime = 600
findtime = 60

[xrdp]
enabled = true
port = ${rdp_port}
filter = xrdp
logpath = /var/log/xrdp.log
maxretry = 5
bantime = 3600
findtime = 600

[recidive]
enabled = false
EOL

    systemctl restart fail2ban 2>/dev/null || true
    sleep 2

    log_success "Fail2ban SSH+RDP 双防护安装完成！"
    echo -e "  ${GREEN}✓${NC} 管理员 IP 白名单: ${admin_ip}"
    echo -e "  ${GREEN}✓${NC} SSH 端口: ${ssh_port}"
    echo -e "  ${GREEN}✓${NC} RDP 端口: ${rdp_port}"
    echo -e "  ${GREEN}✓${NC} 5 次失败 → 封 1 小时"
    echo -e "  ${GREEN}✓${NC} recidive 默认禁用（防止管理员自封）\n"
    echo -e "  查看状态: ${CYAN}fail2ban-client status sshd${NC}"
    echo -e "  ${CYAN}fail2ban-client status xrdp${NC}\n"
}

# ──────────────────────────────────────────────────────────────────────────────
# 功能3: iptables 端口管理工具
# ──────────────────────────────────────────────────────────────────────────────
port_block_manager() {
    echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  iptables 端口管理工具${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}\n"

    detect_ssh_ports() {
        local ports=()
        local cfg_port
        cfg_port=$(grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
        [ -n "$cfg_port" ] && ports+=("$cfg_port")
        while IFS= read -r p; do
            [ -n "$p" ] && ports+=("$p")
        done < <(ss -tlnp 2>/dev/null | grep "sshd" | awk '{print $4}' | rev | cut -d: -f1 | rev | sort -u)
        if [ -n "$SSH_CONNECTION" ]; then
            local conn_port
            conn_port=$(echo "$SSH_CONNECTION" | awk '{print $4}')
            [ -n "$conn_port" ] && ports+=("$conn_port")
        fi
        printf "%s\n" "${ports[@]}" | sort -n -u
    }

    while true; do
        local blocked_ports
        blocked_ports=$(iptables -t raw -L PREROUTING -n 2>/dev/null | grep "DROP" | grep "dpt:" | sed 's/.*dpt:\([0-9]*\).*/\1/' | sort -n -u | tr '\n' ' ')

        echo -e "${BOLD}当前已封锁端口:${NC}"
        if [ -z "$blocked_ports" ]; then
            echo -e "  ${GREEN}(无)${NC}"
        else
            echo -e "  ${RED}${blocked_ports}${NC}"
        fi

        echo -e "\n${BOLD}请选择操作:${NC}"
        echo -e "  ${CYAN}1${NC}) 封锁端口"
        echo -e "  ${CYAN}2${NC}) 开放端口"
        echo -e "  ${CYAN}3${NC}) 查看已封锁端口"
        echo -e "  ${CYAN}0${NC}) 返回主菜单\n"

        read -rp "输入选择 [0-3]: " action
        case $action in
            1)
                read -rp "输入要封锁的端口号: " port
                if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                    local ssh_ports=($(detect_ssh_ports))
                    for sp in "${ssh_ports[@]}"; do
                        if [ "$port" = "$sp" ]; then
                            log_warn "⚠️  ${port} 是 SSH 端口，封锁会断开当前连接！"
                            read -rp "确认封锁？(y/N): " confirm
                            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && continue 2
                        fi
                    done
                    iptables -t raw -C PREROUTING -p tcp --dport "$port" -j DROP 2>/dev/null && \
                        log_warn "端口 ${port} 已封锁，跳过" || \
                        { iptables -t raw -A PREROUTING -p tcp --dport "$port" -j DROP && \
                          log_success "端口 ${port} 已封锁（外部访问）"; }
                    netfilter-persistent save 2>/dev/null || true
                else
                    log_error "无效端口号"
                fi
                ;;
            2)
                read -rp "输入要开放的端口号: " port
                if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                    if iptables -t raw -C PREROUTING -p tcp --dport "$port" -j DROP 2>/dev/null; then
                        iptables -t raw -D PREROUTING -p tcp --dport "$port" -j DROP && \
                        log_success "端口 ${port} 已开放"
                        netfilter-persistent save 2>/dev/null || true
                    else
                        log_warn "端口 ${port} 未被封锁"
                    fi
                else
                    log_error "无效端口号"
                fi
                ;;
            3)
                echo -e "\n${BOLD}已封锁端口列表:${NC}"
                if [ -z "$blocked_ports" ]; then
                    echo -e "  ${GREEN}(无)${NC}"
                else
                    for p in $blocked_ports; do
                        echo -e "  ${RED}端口 ${p}${NC}"
                    done
                fi
                read -rp "按回车继续..."
                ;;
            0) break ;;
            *) log_error "无效选择" ;;
        esac
        echo
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# 主菜单
# ──────────────────────────────────────────────────────────────────────────────
show_menu() {
    clear
    echo -e "${CYAN}"
    echo '  ╔══════════════════════════════════════════╗'
    echo '  ║       绝尘服务器安全工具集 v1.0          ║'
    echo '  ║     Server Security Tools by 绝尘AI      ║'
    echo '  ╚══════════════════════════════════════════╝'
    echo -e "${NC}"
    echo -e "  ${BOLD}请选择要执行的操作:${NC}\n"
    echo -e "  ${CYAN}1${NC}) 🛡️  安装 Fail2ban — SSH 防护"
    echo -e "  ${CYAN}2${NC}) 🛡️  安装 Fail2ban — SSH + RDP 双防护"
    echo -e "  ${CYAN}3${NC}) 🔒  iptables 端口管理（封锁/开放）"
    echo -e "  ${CYAN}0${NC}) ❌  退出\n"
    echo -n -e "${BOLD}请输入 [0-3]: ${NC}"
    read -r choice
    echo

    case $choice in
        1) install_fail2ban_ssh ;;
        2) install_fail2ban_rdp ;;
        3) port_block_manager ;;
        0)
            echo -e "${GREEN}已退出。保重！${NC}"
            exit 0
            ;;
        *)
            log_error "无效选择，请重新输入"
            sleep 1
            ;;
    esac

    if [ "$choice" != "0" ]; then
        echo -e "\n${CYAN}────────────────────────────────────────${NC}"
        read -rp "按回车返回主菜单..."
        show_menu
    fi
}

# 启动
show_menu
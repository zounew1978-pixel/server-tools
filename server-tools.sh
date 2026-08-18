#!/usr/bin/env bash
# ==============================================================================
# 绝尘盾 (Server Shield) v2.0 — 服务器安全工具集
# 一键装载：Fail2ban 防护 + iptables 端口管理 + 规则/白名单/黑名单管理
# 用法: bash <(curl -sL https://raw.githubusercontent.com/zounew1978-pixel/server-tools/main/server-tools.sh)
# 或:   bash <(wget -qO- https://raw.githubusercontent.com/zounew1978-pixel/server-tools/main/server-tools.sh)
# 纯Debian(无curl/wget): apt-get update -qq && apt-get install -y -qq curl && bash <(curl -sL ...)
# 编写: 绝尘 (Hermes Agent)
# 版本: v2.0 — 2026-08-18 (规则+白名单+黑名单管理)
# ==============================================================================
# 交互菜单脚本不启用 set -e（任何子命令失败会导致整个脚本退出）
set -o pipefail

# ── 颜色定义 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ── 环境自检 ──
ensure_http_client() {
    if command -v curl >/dev/null 2>&1; then
        HTTP_GET="curl -s --max-time 5"
    elif command -v wget >/dev/null 2>&1; then
        HTTP_GET="wget -qO- --timeout=5"
    else
        log_warn "未检测到 curl / wget，尝试自动安装 curl..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y -qq curl >/dev/null 2>&1 || {
                log_error "自动安装 curl 失败，请手动执行: apt-get install -y curl"
                exit 1
            }
            HTTP_GET="curl -s --max-time 5"
        else
            log_error "既无 curl 也无 wget，且系统不是 apt 系，无法自动安装。"
            log_error "请先手动安装 curl 后重试。"
            exit 1
        fi
    fi
}

# 检查 root
if [ "$EUID" -ne 0 ]; then
    log_error "请以 root 身份运行（sudo bash）"
    exit 1
fi

ensure_http_client

# ── 服务管理：兼容 systemd / sysvinit / 容器环境 ──
# 纯净 Debian 可能是容器（无 systemd 作为 PID 1），systemctl 命令会直接失败，
# 因此先检测 PID 1 是否是 systemd，再决定用哪套服务管理工具。
SYSTEMD_RUNNING=false
if [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = "systemd" ]; then
    SYSTEMD_RUNNING=true
fi

# 通用的 fail2ban 服务控制命令
f2b_cmd() {
    local action="$1"  # start / stop / restart / status
    if $SYSTEMD_RUNNING; then
        systemctl "$action" fail2ban 2>&1
    elif command -v service >/dev/null 2>&1; then
        service fail2ban "$action" 2>&1
    elif [ -x /etc/init.d/fail2ban ]; then
        /etc/init.d/fail2ban "$action" 2>&1
    else
        echo "[ERROR] 找不到可用的服务管理工具 (systemctl/service/init.d)"
        return 1
    fi
}

# 检查 fail2ban 是否在运行（不依赖 systemd）
f2b_is_active() {
    if $SYSTEMD_RUNNING; then
        systemctl is-active --quiet fail2ban 2>/dev/null
    elif command -v pgrep >/dev/null 2>&1; then
        pgrep -x fail2ban-server >/dev/null 2>&1 || pgrep -f "fail2ban-server" >/dev/null 2>&1
    else
        pidof fail2ban-server >/dev/null 2>&1
    fi
}

# 设置开机自启（兼容 systemd / sysvinit / openrc）
f2b_enable_service() {
    if $SYSTEMD_RUNNING; then
        systemctl enable fail2ban 2>&1 | grep -iv "^$" || true
    elif command -v update-rc.d >/dev/null 2>&1; then
        update-rc.d fail2ban enable >/dev/null 2>&1 && log_info "已通过 sysvinit 设置开机自启"
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update add fail2ban default >/dev/null 2>&1 && log_info "已通过 openrc 设置开机自启"
    else
        log_warn "无法自动设置开机自启，请手动处理"
    fi
}

# 完整诊断：服务状态 / 日志 / 配置
f2b_diagnose() {
    echo
    log_info "① 系统信息"
    echo -e "   主机名:   $(hostname)"
    echo -e "   PID 1:    $(ps -p 1 -o comm= 2>/dev/null || echo '未知')"
    echo -e "   系统:     $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
    echo -e "   fail2ban: $(fail2ban-client version 2>/dev/null || echo '未安装')"
    echo -e "   systemd 管理: $($SYSTEMD_RUNNING && echo '是 (PID1=systemd)' || echo '否 (使用 service/init.d)')"
    echo
    log_info "② 服务状态"
    if $SYSTEMD_RUNNING; then
        systemctl status fail2ban --no-pager 2>&1 | head -12
        echo
        echo -e "   开机自启: $(systemctl is-enabled fail2ban 2>&1 || true)"
    else
        f2b_cmd status 2>&1 | head -6
        echo
        if command -v ls >/dev/null 2>&1; then
            echo -e "   sysvinit 自启链接: $(ls /etc/rc2.d/ 2>/dev/null | grep -i fail2ban || echo '无 (未设置开机自启)')"
        fi
    fi
    echo
    log_info "③ fail2ban 日志 (最近 15 行)"
    if $SYSTEMD_RUNNING && command -v journalctl >/dev/null 2>&1; then
        journalctl -u fail2ban -n 15 --no-pager 2>&1 | head -17 || true
    fi
    tail -15 /var/log/fail2ban.log 2>/dev/null || echo "   (无 /var/log/fail2ban.log)"
    echo
    log_info "④ jail.local 配置 (前 25 行)"
    head -25 /etc/fail2ban/jail.local 2>/dev/null || echo "   (无 jail.local)"
    echo
    log_info "⑤ fail2ban-client 状态"
    fail2ban-client status 2>&1 || true
    echo
    read -rp "按回车返回主菜单..."
}

# 安装后验证失败时的快速诊断
f2b_diagnose_quick() {
    echo
    if $SYSTEMD_RUNNING; then
        systemctl status fail2ban --no-pager 2>&1 | head -12
    else
        echo "   (非 systemd 系统) PID1=$(ps -p 1 -o comm= 2>/dev/null)，尝试 service/init.d 方式："
        f2b_cmd status 2>&1 | head -6
    fi
    echo
    echo -e "   日志尾部："
    tail -10 /var/log/fail2ban.log 2>/dev/null || echo "   (无 /var/log/fail2ban.log)"
}

# ── 公共函数 ──

get_public_ip() {
    local ip=""
    ip=$($HTTP_GET https://api.ipify.org 2>/dev/null || true)
    [ -z "$ip" ] && ip=$($HTTP_GET https://api64.ipify.org 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    echo "${ip:-127.0.0.1}"
}

# 检查 fail2ban 是否已安装并运行
check_f2b_installed() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        log_error "Fail2ban 未安装！请先选「1」或「2」安装。"
        return 1
    fi
    # 检查服务是否在运行（兼容 systemd / sysvinit / 容器）
    if ! f2b_is_active; then
        log_warn "Fail2ban 服务未运行，尝试启动..."
        f2b_cmd start || {
            echo    # 换行
            log_error "启动失败！以下为诊断信息："
            f2b_diagnose_quick
            log_error "请运行菜单 7「🔍 状态诊断」查看完整信息。"
            return 1
        }
        sleep 1
        if ! f2b_is_active; then
            log_error "启动后服务仍未运行！请运行菜单 7「🔍 状态诊断」查看原因。"
            return 1
        fi
        log_success "服务启动成功 ✓"
    fi
    return 0
}

# 读取 jail.local 配置值
get_jail_cfg() {
    local key="$1"
    local jail="${2:-DEFAULT}"
    if [ "$jail" = "DEFAULT" ]; then
        grep -i "^${key}[[:space:]]*=" /etc/fail2ban/jail.local 2>/dev/null | head -1 | cut -d= -f2- | xargs
    else
        # 在特定 jail 段内查找
        awk -v j="[${jail}]" -v k="^${key}[[:space:]]*=" '
            $0 ~ j { found=1; next }
            /^\[.*\]/ { found=0 }
            found && $0 ~ k { print; exit }
        ' /etc/fail2ban/jail.local 2>/dev/null | cut -d= -f2- | xargs
    fi
}

# 获取所有启用的 jail 列表
get_enabled_jails() {
    local jails=()
    local current_jail=""
    while IFS= read -r line; do
        line=$(echo "$line" | xargs)
        if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
            current_jail="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^enabled[[:space:]]*=[[:space:]]*(.*)$ ]] && [ -n "$current_jail" ]; then
            local val="${BASH_REMATCH[1]}"
            if [ "$val" = "true" ] || [ "$val" = "yes" ]; then
                jails+=("$current_jail")
            fi
            current_jail=""
        fi
    done < /etc/fail2ban/jail.local 2>/dev/null
    # 也通过 fail2ban-client 获取
    while IFS= read -r j; do
        [ -n "$j" ] && jails+=("$j")
    done < <(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*Jail list:\s*//' | tr ',' ' ')
    printf "%s\n" "${jails[@]}" | sort -u | tr '\n' ' '
}

# 检测 SSH 端口
detect_ssh_port() {
    local port
    port=$(grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    echo "${port:-22}"
}

# 检测 RDP 端口
detect_rdp_port() {
    local port
    port=$(grep -i "^port=" /etc/xrdp/xrdp.ini 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ')
    echo "${port:-3389}"
}

# ──────────────────────────────────────────────────────────────────────────────
# 功能1: Fail2ban SSH 防护
# ──────────────────────────────────────────────────────────────────────────────
install_fail2ban_ssh() {
    echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  安装 Fail2ban — SSH 防护${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}\n"

    log_info "更新软件包列表..."
    apt-get update -qq

    log_info "安装 fail2ban + python3-systemd (journald 后端)..."
    apt-get install -y -qq fail2ban python3-systemd iptables-persistent netfilter-persistent 2>/dev/null || \
    apt-get install -y -qq fail2ban python3-systemd

    local admin_ip=""
    [ -n "$SSH_CONNECTION" ] && admin_ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    [ -z "$admin_ip" ] && admin_ip=$(get_public_ip)
    log_info "检测到管理员IP: ${admin_ip}"

    local ssh_port=$(detect_ssh_port)
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
backend = systemd
maxretry = 5
bantime = 3600
findtime = 600

[recidive]
enabled = false
EOL

    # 设为开机自启并立即启动（兼容 systemd/sysvinit/容器）
    log_info "设置开机自启..."
    f2b_enable_service
    log_info "确保日志文件存在..."
    touch /var/log/auth.log 2>/dev/null || true
    log_info "启动 fail2ban 服务..."
    f2b_cmd restart
    sleep 2

    log_success "Fail2ban SSH 防护安装完成！"
    if f2b_is_active; then
        log_success "服务状态: 运行中 ✓（开机自启已配置）"
    else
        log_warn "服务未运行！快速诊断："
        f2b_diagnose_quick
        log_warn "可稍后运行菜单 7「🔍 状态诊断」查看完整信息。"
    fi
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

    log_info "安装 fail2ban + python3-systemd (journald 后端)..."
    apt-get install -y -qq fail2ban python3-systemd iptables-persistent netfilter-persistent 2>/dev/null || \
    apt-get install -y -qq fail2ban python3-systemd

    local admin_ip=""
    [ -n "$SSH_CONNECTION" ] && admin_ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    [ -z "$admin_ip" ] && admin_ip=$(get_public_ip)
    log_info "检测到管理员IP: ${admin_ip}"

    local ssh_port=$(detect_ssh_port)
    log_info "检测到 SSH 端口: ${ssh_port}"

    local rdp_port=$(detect_rdp_port)
    log_info "检测到 RDP 端口: ${rdp_port}"

    # xrdp 检测：没装 xrdp 就降级为纯 SSH 防护
    if ! command -v xrdp >/dev/null 2>&1 && [ ! -f /etc/xrdp/xrdp.ini ]; then
        log_warn "未检测到 xrdp 服务，跳过 RDP 防护（降级为 SSH 防护）"
        install_fail2ban_ssh
        return
    fi
    # 确保 xrdp 日志文件存在，避免 fail2ban 启动失败
    touch /var/log/xrdp.log 2>/dev/null || true

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
backend = systemd
maxretry = 5
bantime = 3600
findtime = 600

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

    # 设为开机自启并立即启动（兼容 systemd/sysvinit/容器）
    log_info "设置开机自启..."
    f2b_enable_service
    log_info "确保日志文件存在..."
    touch /var/log/auth.log 2>/dev/null || true
    log_info "启动 fail2ban 服务..."
    f2b_cmd restart
    sleep 2

    log_success "Fail2ban SSH+RDP 双防护安装完成！"
    if f2b_is_active; then
        log_success "服务状态: 运行中 ✓（开机自启已配置）"
    else
        log_warn "服务未运行！快速诊断："
        f2b_diagnose_quick
        log_warn "可稍后运行菜单 7「🔍 状态诊断」查看完整信息。"
    fi
    echo -e "  ${GREEN}✓${NC} 管理员 IP 白名单: ${admin_ip}"
    echo -e "  ${GREEN}✓${NC} SSH 端口: ${ssh_port}"
    echo -e "  ${GREEN}✓${NC} RDP 端口: ${rdp_port}"
    echo -e "  ${GREEN}✓${NC} 5 次失败 → 封 1 小时"
    echo -e "  ${GREEN}✓${NC} recidive 默认禁用（防止管理员自封）\n"
    echo -e "  查看状态: ${CYAN}fail2ban-client status sshd${NC}"
    echo -e "  ${CYAN}fail2ban-client status xrdp${NC}\n"
}

# ──────────────────────────────────────────────────────────────────────────────
# 功能3: iptables 端口管理
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
# 功能4: Fail2ban 规则设置
# ──────────────────────────────────────────────────────────────────────────────
fail2ban_rule_config() {
    echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Fail2ban 规则设置${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}\n"

    check_f2b_installed || return 1

    local jail_cfg="/etc/fail2ban/jail.local"
    if [ ! -f "$jail_cfg" ]; then
        log_error "找不到 ${jail_cfg}，请先安装 Fail2ban（选项1或2）"
        return 1
    fi

    while true; do
        # 读取当前值
        local cur_bantime=$(get_jail_cfg "bantime")
        local cur_findtime=$(get_jail_cfg "findtime")
        local cur_maxretry=$(get_jail_cfg "maxretry")
        local cur_ignoreip=$(get_jail_cfg "ignoreip")
        local enabled_jails=$(get_enabled_jails)

        echo -e "${BOLD}当前全局规则:${NC}"
        echo -e "  ${CYAN}封禁时长(bantime):${NC}   ${YELLOW}${cur_bantime:-3600}${NC} 秒"
        echo -e "  ${CYAN}检测窗口(findtime):${NC}  ${YELLOW}${cur_findtime:-600}${NC} 秒"
        echo -e "  ${CYAN}失败阈值(maxretry):${NC}  ${YELLOW}${cur_maxretry:-5}${NC} 次"
        echo -e "  ${CYAN}白名单(ignoreip):${NC}    ${YELLOW}${cur_ignoreip}${NC}"
        echo -e "  ${CYAN}已启用Jail:${NC}           ${YELLOW}${enabled_jails:-无}${NC}"

        echo -e "\n${BOLD}修改规则:${NC}"
        echo -e "  ${CYAN}1${NC}) 修改封禁时长 (bantime)"
        echo -e "  ${CYAN}2${NC}) 修改检测窗口 (findtime)"
        echo -e "  ${CYAN}3${NC}) 修改失败阈值 (maxretry)"
        echo -e "  ${CYAN}4${NC}) 切换某个 Jail 的启用/禁用"
        echo -e "  ${CYAN}5${NC}) 查看所有 Jail 的详细配置"
        echo -e "  ${CYAN}0${NC}) 返回主菜单\n"

        read -rp "输入选择 [0-5]: " action
        case $action in
            1) # 修改封禁时长
                echo -e "\n${BOLD}选择封禁时长:${NC}"
                echo -e "  ${CYAN}1${NC}) 10 分钟 (600秒) — 温和"
                echo -e "  ${CYAN}2${NC}) 1 小时 (3600秒) — 推荐"
                echo -e "  ${CYAN}3${NC}) 1 天 (86400秒) — 严厉"
                echo -e "  ${CYAN}4${NC}) 7 天 (604800秒) — 极严厉"
                echo -e "  ${CYAN}5${NC}) 永久 (-1) — 永久封禁"
                echo -e "  ${CYAN}6${NC}) 自定义输入\n"
                read -rp "选择 [1-6] (默认2): " bantime_choice
                local new_bantime
                case ${bantime_choice:-2} in
                    1) new_bantime=600 ;;
                    2) new_bantime=3600 ;;
                    3) new_bantime=86400 ;;
                    4) new_bantime=604800 ;;
                    5) new_bantime=-1 ;;
                    6) read -rp "输入封禁秒数: " new_bantime ;;
                    *) new_bantime=3600 ;;
                esac
                if [[ "$new_bantime" =~ ^-?[0-9]+$ ]] && [ "$new_bantime" -ne 0 ]; then
                    sed -i "s/^bantime = .*/bantime = ${new_bantime}/" "$jail_cfg"
                    log_success "全局 bantime 已设为 ${new_bantime} 秒"
                    systemctl restart fail2ban
                else
                    log_error "无效值"
                fi
                ;;
            2) # 修改检测窗口
                echo -e "\n${BOLD}选择检测窗口:${NC}"
                echo -e "  ${CYAN}1${NC}) 5 分钟 (300秒) — 激进"
                echo -e "  ${CYAN}2${NC}) 10 分钟 (600秒) — 推荐"
                echo -e "  ${CYAN}3${NC}) 30 分钟 (1800秒) — 温和"
                echo -e "  ${CYAN}4${NC}) 自定义输入\n"
                read -rp "选择 [1-4] (默认2): " findtime_choice
                local new_findtime
                case ${findtime_choice:-2} in
                    1) new_findtime=300 ;;
                    2) new_findtime=600 ;;
                    3) new_findtime=1800 ;;
                    4) read -rp "输入检测窗口秒数: " new_findtime ;;
                    *) new_findtime=600 ;;
                esac
                if [[ "$new_findtime" =~ ^[0-9]+$ ]] && [ "$new_findtime" -ge 60 ]; then
                    sed -i "s/^findtime = .*/findtime = ${new_findtime}/" "$jail_cfg"
                    log_success "全局 findtime 已设为 ${new_findtime} 秒"
                    systemctl restart fail2ban
                else
                    log_error "检测窗口至少 60 秒"
                fi
                ;;
            3) # 修改失败阈值
                echo -e "\n${BOLD}选择失败阈值:${NC}"
                echo -e "  ${CYAN}1${NC}) 3 次 — 激进（低流量服务器）"
                echo -e "  ${CYAN}2${NC}) 5 次 — 推荐"
                echo -e "  ${CYAN}3${NC}) 10 次 — 温和（高流量）"
                echo -e "  ${CYAN}4${NC}) 自定义输入\n"
                read -rp "选择 [1-4] (默认2): " retry_choice
                local new_maxretry
                case ${retry_choice:-2} in
                    1) new_maxretry=3 ;;
                    2) new_maxretry=5 ;;
                    3) new_maxretry=10 ;;
                    4) read -rp "输入失败次数阈值: " new_maxretry ;;
                    *) new_maxretry=5 ;;
                esac
                if [[ "$new_maxretry" =~ ^[0-9]+$ ]] && [ "$new_maxretry" -ge 1 ] && [ "$new_maxretry" -le 100 ]; then
                    sed -i "s/^maxretry = .*/maxretry = ${new_maxretry}/" "$jail_cfg"
                    log_success "全局 maxretry 已设为 ${new_maxretry} 次"
                    systemctl restart fail2ban
                else
                    log_error "阈值范围为 1-100"
                fi
                ;;
            4) # 切换 Jail 启用/禁用
                # 列出所有 jail
                local jails=()
                while IFS= read -r line; do
                    if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
                        jails+=("${BASH_REMATCH[1]}")
                    fi
                done < "$jail_cfg"
                if [ ${#jails[@]} -eq 0 ]; then
                    log_warn "配置文件中没有找到任何 Jail"
                    read -rp "按回车继续..."
                    continue
                fi
                echo -e "\n${BOLD}选择要切换的 Jail:${NC}"
                local i=1
                declare -A jail_menu
                for j in "${jails[@]}"; do
                    local status=$(get_jail_cfg "enabled" "$j")
                    local status_icon=""
                    [ "$status" = "true" ] && status_icon="🟢" || status_icon="🔴"
                    echo -e "  ${CYAN}${i}${NC}) ${status_icon} ${j}"
                    jail_menu[$i]="$j"
                    ((i++))
                done
                echo -e "  ${CYAN}0${NC}) 返回\n"
                read -rp "选择: " jail_choice
                if [[ "$jail_choice" =~ ^[0-9]+$ ]] && [ "$jail_choice" -gt 0 ] && [ "$jail_choice" -lt "$i" ]; then
                    local selected_jail="${jail_menu[$jail_choice]}"
                    local cur_enabled=$(get_jail_cfg "enabled" "$selected_jail")
                    if [ "$cur_enabled" = "true" ]; then
                        sed -i "/^\[${selected_jail}\]/,/^\[/ s/^enabled = true/enabled = false/" "$jail_cfg"
                        log_warn "${selected_jail} 已禁用"
                    else
                        sed -i "/^\[${selected_jail}\]/,/^\[/ s/^enabled = false/enabled = true/" "$jail_cfg"
                        log_success "${selected_jail} 已启用"
                    fi
                    systemctl restart fail2ban
                fi
                ;;
            5) # 查看所有 Jail 详细配置
                echo -e "\n${BOLD}所有 Jail 配置:${NC}"
                echo -e "${CYAN}────────────────────────────────────────${NC}"
                local current_jail=""
                while IFS= read -r line; do
                    line=$(echo "$line" | xargs)
                    if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
                        current_jail="${BASH_REMATCH[1]}"
                        echo -e "\n${BOLD}[${current_jail}]${NC}"
                    elif [ -n "$current_jail" ] && [[ "$line" =~ ^[a-zA-Z] ]]; then
                        echo -e "  ${line}"
                    fi
                done < "$jail_cfg"
                echo -e "\n${CYAN}────────────────────────────────────────${NC}"
                read -rp "按回车继续..."
                ;;
            0) break ;;
            *) log_error "无效选择" ;;
        esac
        echo
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# 功能5: Fail2ban 白名单管理
# ──────────────────────────────────────────────────────────────────────────────
fail2ban_whitelist() {
    echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Fail2ban 白名单管理${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}\n"

    check_f2b_installed || return 1

    local jail_cfg="/etc/fail2ban/jail.local"
    if [ ! -f "$jail_cfg" ]; then
        log_error "找不到 ${jail_cfg}，请先安装 Fail2ban"
        return 1
    fi

    while true; do
        # 读取当前白名单
        local cur_ignoreip=$(get_jail_cfg "ignoreip")
        echo -e "${BOLD}当前白名单 (ignoreip):${NC}"
        if [ -n "$cur_ignoreip" ]; then
            echo -e "  ${YELLOW}${cur_ignoreip}${NC}"
            # 按空格拆分显示
            echo -e "${BOLD}列表:${NC}"
            local i=1
            for ip in $cur_ignoreip; do
                echo -e "  ${GREEN}${i}${NC}) ${ip}"
                ((i++))
            done
        else
            echo -e "  ${RED}(空)${NC}"
        fi

        echo -e "\n${BOLD}操作:${NC}"
        echo -e "  ${CYAN}1${NC}) 添加 IP 到白名单"
        echo -e "  ${CYAN}2${NC}) 从白名单移除 IP"
        echo -e "  ${CYAN}3${NC}) 添加当前连接 IP 到白名单"
        echo -e "  ${CYAN}4${NC}) 添加网段 (如 192.168.1.0/24)"
        echo -e "  ${CYAN}0${NC}) 返回主菜单\n"

        read -rp "输入选择 [0-4]: " action
        case $action in
            1) # 添加 IP
                read -rp "输入要添加的 IP 地址: " new_ip
                if [ -n "$new_ip" ]; then
                    if echo "$cur_ignoreip" | grep -q "$new_ip"; then
                        log_warn "${new_ip} 已在白名单中"
                    else
                        local updated_ignoreip="${cur_ignoreip} ${new_ip}"
                        # 用空格替换多个空格
                        updated_ignoreip=$(echo "$updated_ignoreip" | tr -s ' ')
                        sed -i "s|^ignoreip = .*|ignoreip = ${updated_ignoreip}|" "$jail_cfg"
                        log_success "${new_ip} 已加入白名单"
                        systemctl restart fail2ban
                    fi
                fi
                ;;
            2) # 移除 IP
                if [ -z "$cur_ignoreip" ]; then
                    log_warn "白名单为空，无 IP 可移除"
                    read -rp "按回车继续..."
                    continue
                fi
                read -rp "输入要移除的 IP 地址: " del_ip
                if [ -n "$del_ip" ]; then
                    local updated_ignoreip=""
                    for ip in $cur_ignoreip; do
                        [ "$ip" != "$del_ip" ] && updated_ignoreip="${updated_ignoreip} ${ip}"
                    done
                    updated_ignoreip=$(echo "$updated_ignoreip" | xargs)
                    if [ -z "$updated_ignoreip" ]; then
                        # 保留至少本地回环
                        updated_ignoreip="127.0.0.1/8 ::1"
                    fi
                    sed -i "s|^ignoreip = .*|ignoreip = ${updated_ignoreip}|" "$jail_cfg"
                    log_success "${del_ip} 已从白名单移除"
                    systemctl restart fail2ban
                fi
                ;;
            3) # 添加当前连接 IP
                local conn_ip=""
                [ -n "$SSH_CONNECTION" ] && conn_ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
                [ -z "$conn_ip" ] && conn_ip=$(get_public_ip)
                if [ -n "$conn_ip" ]; then
                    if echo "$cur_ignoreip" | grep -q "$conn_ip"; then
                        log_warn "${conn_ip} 已在白名单中"
                    else
                        local updated_ignoreip="${cur_ignoreip} ${conn_ip}"
                        updated_ignoreip=$(echo "$updated_ignoreip" | tr -s ' ')
                        sed -i "s|^ignoreip = .*|ignoreip = ${updated_ignoreip}|" "$jail_cfg"
                        log_success "当前连接 IP ${conn_ip} 已加入白名单"
                        systemctl restart fail2ban
                    fi
                else
                    log_error "无法获取当前连接 IP"
                fi
                ;;
            4) # 添加网段
                read -rp "输入网段 (如 192.168.1.0/24): " network
                if [ -n "$network" ]; then
                    if echo "$cur_ignoreip" | grep -q "$network"; then
                        log_warn "${network} 已在白名单中"
                    else
                        local updated_ignoreip="${cur_ignoreip} ${network}"
                        updated_ignoreip=$(echo "$updated_ignoreip" | tr -s ' ')
                        sed -i "s|^ignoreip = .*|ignoreip = ${updated_ignoreip}|" "$jail_cfg"
                        log_success "网段 ${network} 已加入白名单"
                        systemctl restart fail2ban
                    fi
                fi
                ;;
            0) break ;;
            *) log_error "无效选择" ;;
        esac
        echo
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# 功能6: Fail2ban 黑名单管理
# ──────────────────────────────────────────────────────────────────────────────
fail2ban_blacklist() {
    echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Fail2ban 黑名单管理${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}\n"

    check_f2b_installed || return 1

    while true; do
        # 获取所有 jail 的状态
        local jails_str=$(get_enabled_jails)
        local jails=($jails_str)

        echo -e "${BOLD}被封禁 IP 概览:${NC}"
        local total_banned=0
        if [ ${#jails[@]} -eq 0 ]; then
            echo -e "  ${YELLOW}(无已启用的 Jail)${NC}"
        else
            for j in "${jails[@]}"; do
                local banned_count
                banned_count=$(fail2ban-client status "$j" 2>/dev/null | grep "Currently banned:" | awk '{print $NF}')
                local total_count
                total_count=$(fail2ban-client status "$j" 2>/dev/null | grep "Total banned:" | awk '{print $NF}')
                banned_count=${banned_count:-0}
                total_count=${total_count:-0}
                total_banned=$((total_banned + banned_count))
                local icon="🟢"
                [ "$banned_count" -gt 0 ] && icon="🔴"
                echo -e "  ${icon} ${BOLD}${j}${NC}: 当前${RED}${banned_count}${NC}个 / 累计${total_count}个"
            done
        fi
        echo -e "  ${BOLD}总封禁:${NC} ${RED}${total_banned}${NC} 个 IP\n"

        echo -e "${BOLD}操作:${NC}"
        echo -e "  ${CYAN}1${NC}) 查看某个 Jail 的封禁详情"
        echo -e "  ${CYAN}2${NC}) 解封指定 IP"
        echo -e "  ${CYAN}3${NC}) 解封所有 IP"
        echo -e "  ${CYAN}4${NC}) 手动封禁一个 IP"
        echo -e "  ${CYAN}5${NC}) 查看 fail2ban 日志"
        echo -e "  ${CYAN}0${NC}) 返回主菜单\n"

        read -rp "输入选择 [0-5]: " action
        case $action in
            1) # 查看某个 Jail 的封禁详情
                if [ ${#jails[@]} -eq 0 ]; then
                    log_warn "没有可用的 Jail"
                    read -rp "按回车继续..."
                    continue
                fi
                echo -e "\n${BOLD}选择 Jail:${NC}"
                local i=1
                declare -A jail_sel
                for j in "${jails[@]}"; do
                    echo -e "  ${CYAN}${i}${NC}) ${j}"
                    jail_sel[$i]="$j"
                    ((i++))
                done
                echo -e "  ${CYAN}0${NC}) 返回\n"
                read -rp "选择: " jail_idx
                if [[ "$jail_idx" =~ ^[0-9]+$ ]] && [ "$jail_idx" -gt 0 ] && [ "$jail_idx" -lt "$i" ]; then
                    local sel_j="${jail_sel[$jail_idx]}"
                    echo -e "\n${BOLD}${sel_j} 封禁详情:${NC}"
                    echo -e "${CYAN}────────────────────────────────────────${NC}"
                    fail2ban-client status "$sel_j" 2>/dev/null | grep -E "Banned IP|Currently banned|Total banned|Status" || echo "  (无输出)"
                    local banned_ips
                    banned_ips=$(fail2ban-client status "$sel_j" 2>/dev/null | grep "Banned IP list:" | sed 's/.*Banned IP list:\s*//')
                    if [ -n "$banned_ips" ]; then
                        echo -e "\n${BOLD}被封禁 IP 列表:${NC}"
                        for bip in $banned_ips; do
                            echo -e "  ${RED}${bip}${NC}"
                        done
                    else
                        echo -e "\n  ${GREEN}(当前无封禁 IP)${NC}"
                    fi
                    echo -e "${CYAN}────────────────────────────────────────${NC}"
                    read -rp "按回车继续..."
                fi
                ;;
            2) # 解封指定 IP
                read -rp "输入要解封的 IP 地址: " unban_ip
                if [ -n "$unban_ip" ]; then
                    local unbanned=0
                    for j in "${jails[@]}"; do
                        if fail2ban-client set "$j" unbanip "$unban_ip" 2>/dev/null; then
                            log_success "已从 ${j} 解封 ${unban_ip}"
                            ((unbanned++))
                        fi
                    done
                    if [ "$unbanned" -eq 0 ]; then
                        log_warn "${unban_ip} 可能未被封禁，或已过期自动解封"
                    else
                        log_success "已在 ${unbanned} 个 Jail 中解封 ${unban_ip}"
                    fi
                fi
                ;;
            3) # 解封所有 IP
                echo -e "\n${YELLOW}⚠️  即将解封所有 Jail 中的所有 IP！${NC}"
                read -rp "确认解封所有？(y/N): " confirm_all
                if [[ "$confirm_all" =~ ^[yY]$ ]]; then
                    for j in "${jails[@]}"; do
                        local count
                        count=$(fail2ban-client status "$j" 2>/dev/null | grep "Currently banned:" | awk '{print $NF}')
                        if [ "${count:-0}" -gt 0 ]; then
                            fail2ban-client set "$j" unbanip --all 2>/dev/null || \
                            fail2ban-client unban --all 2>/dev/null || true
                            log_success "${j}: 已解封所有 IP"
                        fi
                    done
                    log_success "全部解封完成！"
                else
                    log_info "已取消"
                fi
                ;;
            4) # 手动封禁 IP
                read -rp "输入要封禁的 IP 地址: " ban_ip
                if [ -n "$ban_ip" ]; then
                    if [ ${#jails[@]} -eq 0 ]; then
                        log_error "没有可用的 Jail"
                        read -rp "按回车继续..."
                        continue
                    fi
                    echo -e "\n${BOLD}封禁到哪个 Jail？${NC}"
                    local i=1
                    declare -A jail_ban
                    for j in "${jails[@]}"; do
                        echo -e "  ${CYAN}${i}${NC}) ${j}"
                        jail_ban[$i]="$j"
                        ((i++))
                    done
                    echo -e "  ${CYAN}0${NC}) 全部\n"
                    read -rp "选择: " ban_idx
                    if [[ "$ban_idx" =~ ^[0-9]+$ ]]; then
                        if [ "$ban_idx" -eq 0 ]; then
                            for j in "${jails[@]}"; do
                                fail2ban-client set "$j" banip "$ban_ip" 2>/dev/null && \
                                log_success "${ban_ip} 已封禁到 ${j}"
                            done
                        elif [ "$ban_idx" -gt 0 ] && [ "$ban_idx" -lt "$i" ]; then
                            local target_j="${jail_ban[$ban_idx]}"
                            fail2ban-client set "$target_j" banip "$ban_ip" 2>/dev/null && \
                            log_success "${ban_ip} 已封禁到 ${target_j}" || \
                            log_error "封禁失败，请检查 IP 格式"
                        fi
                    fi
                fi
                ;;
            5) # 查看日志
                local log_files=("/var/log/fail2ban.log" "/var/log/fail2ban/fail2ban.log")
                local log_file=""
                for f in "${log_files[@]}"; do
                    [ -f "$f" ] && log_file="$f" && break
                done
                if [ -z "$log_file" ]; then
                    log_warn "找不到 fail2ban 日志文件"
                    read -rp "按回车继续..."
                    continue
                fi
                echo -e "\n${BOLD}最近 20 条日志:${NC}"
                echo -e "${CYAN}────────────────────────────────────────${NC}"
                tail -20 "$log_file" 2>/dev/null | while IFS= read -r line; do
                    if echo "$line" | grep -qi "ban\|unban\|fail\|error\|warn"; then
                        echo -e "${YELLOW}${line}${NC}"
                    else
                        echo -e "  ${line}"
                    fi
                done
                echo -e "${CYAN}────────────────────────────────────────${NC}"
                echo -e "  完整日志: ${CYAN}tail -f ${log_file}${NC}"
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
    echo '  ║         绝尘盾 Server Shield v2.2        ║'
    echo '  ║     Server Security Tools by 绝尘AI      ║'
    echo '  ╚══════════════════════════════════════════╝'
    echo -e "${NC}"
    echo -e "  ${BOLD}请选择要执行的操作:${NC}\n"
    echo -e "  ${CYAN}1${NC}) 🛡️  安装 Fail2ban — SSH 防护"
    echo -e "  ${CYAN}2${NC}) 🛡️  安装 Fail2ban — SSH + RDP 双防护"
    echo -e "  ${CYAN}3${NC}) 🔒  iptables 端口管理（封锁/开放）"
    echo -e "  ${CYAN}4${NC}) ⚙️   Fail2ban 规则设置（bantime/findtime/maxretry）"
    echo -e "  ${CYAN}5${NC}) 📋  Fail2ban 白名单管理（ignoreip）"
    echo -e "  ${CYAN}6${NC}) 🚫  Fail2ban 黑名单管理（封禁/解封）"
    echo -e "  ${CYAN}7${NC}) 🔍  Fail2ban 状态诊断（服务/日志/配置）"
    echo -e "  ${CYAN}0${NC}) ❌  退出\n"
    echo -n -e "${BOLD}请输入 [0-7]: ${NC}"
    read -r choice
    echo

    case $choice in
        1) install_fail2ban_ssh ;;
        2) install_fail2ban_rdp ;;
        3) port_block_manager ;;
        4) fail2ban_rule_config ;;
        5) fail2ban_whitelist ;;
        6) fail2ban_blacklist ;;
        7) f2b_diagnose ;;
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
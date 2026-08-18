#!/bin/bash
# ============================================================
# 端口封锁/开放管理工具 — iptables Port Manager v2.0
# 使用 raw 表 PREROUTING 在 Docker DNAT 之前拦截外部流量
# 支持：封锁端口 / 开放端口 / SSH端口安全检测
# 用法: sudo bash port-block-iptables.sh
# ============================================================

set -e

# ─── 颜色 ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── 工具函数 ───
detect_ssh_ports() {
    # 全面检测所有 SSH 监听端口（sshd_config + 实际监听 + 当前连接）
    local ports=()

    # 方法1: 从 sshd_config 读取
    local cfg_port
    cfg_port=$(grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    [ -n "$cfg_port" ] && ports+=("$cfg_port")

    # 方法2: 从实际监听端口读取（兼容非标准端口）
    while IFS= read -r p; do
        [ -n "$p" ] && ports+=("$p")
    done < <(ss -tlnp 2>/dev/null | grep "sshd" | awk '{print $4}' | rev | cut -d: -f1 | rev | sort -u)

    # 方法3: 当前 SSH 连接使用的端口
    if [ -n "$SSH_CONNECTION" ]; then
        local conn_port
        conn_port=$(echo "$SSH_CONNECTION" | awk '{print $4}')
        [ -n "$conn_port" ] && ports+=("$conn_port")
    fi

    # 去重输出
    printf "%s\n" "${ports[@]}" | sort -n -u
}

detect_ssh_client_ip() {
    # 获取当前 SSH 连接的客户端 IP
    if [ -n "$SSH_CONNECTION" ]; then
        echo "$SSH_CONNECTION" | awk '{print $1}'
    fi
}

get_blocked_ports() {
    # 从 raw 表 PREROUTING 中提取已封锁的端口列表
    iptables -t raw -L PREROUTING -n 2>/dev/null | grep "DROP" | grep "dpt:" | \
        sed 's/.*dpt:\([0-9]*\).*/\1/' | sort -n -u
}

show_blocked_ports() {
    local ports=($(get_blocked_ports))
    if [ ${#ports[@]} -eq 0 ]; then
        echo -e "  ${GREEN}暂无已封锁的端口${NC}"
    else
        echo -e "  ${YELLOW}已封锁端口列表:${NC}"
        for p in "${ports[@]}"; do
            # 获取该端口关联的白名单
            local whitelist=($(iptables -t raw -L PREROUTING -n 2>/dev/null | \
                grep "dpt:$p" | grep "RETURN" | awk '{print $4}'))
            echo -e "    ${RED}端口 $p${NC} → 白名单: ${GREEN}${whitelist[*]:-无}${NC}"
        done
    fi
    echo ""
}

delete_port_rules() {
    local port=$1
    # 获取该端口相关的所有规则的行号（倒序，避免删除时编号变化）
    local lines=($(iptables -t raw -L PREROUTING --line-numbers -n 2>/dev/null | \
        grep "dpt:$port" | awk '{print $1}' | sort -rn))
    for line in "${lines[@]}"; do
        iptables -t raw -D PREROUTING $line 2>/dev/null || true
    done
    # IPv6
    if ip6tables -t raw -L PREROUTING -n &>/dev/null; then
        local lines6=($(ip6tables -t raw -L PREROUTING --line-numbers -n 2>/dev/null | \
            grep "dpt:$port" | awk '{print $1}' | sort -rn))
        for line in "${lines6[@]}"; do
            ip6tables -t raw -D PREROUTING $line 2>/dev/null || true
        done
    fi
}

# ─── 标题 ───
clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       🔒 iptables 端口管理工具 v2.0                ║${NC}"
echo -e "${CYAN}║    封锁/开放 端口  |  SSH端口安全检测               ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# ─── 检查 root ───
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请以 root 身份运行此脚本 (sudo bash $0)${NC}"
    exit 1
fi

# ─── 检测 SSH 信息 ───
SSH_PORTS=($(detect_ssh_ports))
SSH_CLIENT_IP=$(detect_ssh_client_ip)
echo -e "${BLUE}🔐 安全检测: SSH 端口 = ${SSH_PORTS[*]}${NC}"
if [ -n "$SSH_CLIENT_IP" ]; then
    echo -e "${BLUE}   当前连接来源: ${SSH_CLIENT_IP}${NC}"
fi
echo -e "${BLUE}   规则: SSH 端口永久受保护，禁止封锁${NC}"
echo -e "${BLUE}   SSH 防护请用 → install-fail2ban.sh${NC}"
echo ""

# ─── 安装 iptables-persistent ───
echo -e "${YELLOW}📦 检查 iptables-persistent...${NC}"
if dpkg -l iptables-persistent &>/dev/null 2>&1; then
    echo -e "${GREEN}✅ 已安装${NC}"
else
    echo -e "${YELLOW}⏳ 正在安装...${NC}"
    apt-get update -qq
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
    echo -e "${GREEN}✅ 安装完成${NC}"
fi
echo ""

# ─── 显示当前状态 ───
echo -e "${YELLOW}📋 当前封锁状态:${NC}"
show_blocked_ports

# 显示 Docker 端口映射供参考
if command -v docker &>/dev/null; then
    echo -e "${YELLOW}🐳 Docker 端口映射 (供参考):${NC}"
    docker ps --format 'table {{.Names}}\t{{.Ports}}' 2>/dev/null | head -30
    echo ""
fi

# ═══════════════════════════════════════════════════════════════
#  主菜单
# ═══════════════════════════════════════════════════════════════
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                 主菜单                              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo -e "  ${RED}1) 🔒 封锁端口${NC}     — 阻止外部直连某个端口"
echo -e "  ${GREEN}2) 🔓 开放端口${NC}     — 解除某个端口的封锁"
echo -e "  ${YELLOW}3) 🚪 退出${NC}"
echo ""
read -p "➡️  请选择操作 [1-3]: " ACTION

case "$ACTION" in
    2)
        # ═══════════════════════════════════════════════════════
        #  开放端口流程
        # ═══════════════════════════════════════════════════════
        echo ""
        echo -e "${GREEN}🔓 开放端口${NC}"
        echo ""

        BLOCKED_PORTS=($(get_blocked_ports))
        if [ ${#BLOCKED_PORTS[@]} -eq 0 ]; then
            echo -e "${YELLOW}⚠️  当前没有已封锁的端口，无需操作${NC}"
            echo ""
            read -p "按回车键退出..." _
            exit 0
        fi

        echo -e "当前已封锁的端口:"
        for i in "${!BLOCKED_PORTS[@]}"; do
            # 获取该端口关联的白名单
            WL=($(iptables -t raw -L PREROUTING -n 2>/dev/null | \
                grep "dpt:${BLOCKED_PORTS[$i]}" | grep "RETURN" | awk '{print $4}'))
            echo -e "  $((i+1))) ${RED}${BLOCKED_PORTS[$i]}${NC} → 白名单: ${GREEN}${WL[*]:-无}${NC}"
        done
        echo -e "  ${GREEN}0) 🔓 开放所有端口${NC}"
        echo ""
        read -p "➡️  请输入序号 (0=全部开放, 1-N=单个开放): " UNBLOCK_INPUT

        if [ "$UNBLOCK_INPUT" = "0" ]; then
            # 开放所有端口
            echo ""
            echo -e "${YELLOW}⚠️  即将开放所有已封锁的端口 (共 ${#BLOCKED_PORTS[@]} 个)${NC}"
            read -p "➡️  确认全部开放? (y/N): " CONFIRM
            if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}🛑 已取消${NC}"
                exit 0
            fi
            echo ""
            for PORT in "${BLOCKED_PORTS[@]}"; do
                echo -e "${YELLOW}🔄 正在删除端口 ${PORT} 的封锁规则...${NC}"
                delete_port_rules $PORT
            done
            iptables-save > /etc/iptables/rules.v4
            if ip6tables-save &>/dev/null; then
                ip6tables-save > /etc/iptables/rules.v6
            fi
            echo -e "${GREEN}✅ 已全部开放 (${#BLOCKED_PORTS[@]} 个端口)${NC}"
            echo ""
            echo -e "${YELLOW}📋 更新后的封锁状态:${NC}"
            show_blocked_ports

        elif [[ "$UNBLOCK_INPUT" =~ ^[0-9]+$ ]]; then
            # 判断输入是序号还是端口号
            if [ "$UNBLOCK_INPUT" -le "${#BLOCKED_PORTS[@]}" ] && [ "$UNBLOCK_INPUT" -gt 0 ]; then
                UNBLOCK_PORT=${BLOCKED_PORTS[$((UNBLOCK_INPUT-1))]}
            else
                UNBLOCK_PORT=$UNBLOCK_INPUT
            fi

            # 确认
            echo ""
            echo -e "${YELLOW}⚠️  即将开放端口: ${RED}${UNBLOCK_PORT}${NC}"
            read -p "➡️  确认开放? (y/N): " CONFIRM
            if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}🛑 已取消${NC}"
                exit 0
            fi

            # 删除规则
            echo -e "${YELLOW}🔄 正在删除端口 ${UNBLOCK_PORT} 的封锁规则...${NC}"
            delete_port_rules $UNBLOCK_PORT
            iptables-save > /etc/iptables/rules.v4
            if ip6tables-save &>/dev/null; then
                ip6tables-save > /etc/iptables/rules.v6
            fi
            echo -e "${GREEN}✅ 端口 ${UNBLOCK_PORT} 已开放${NC}"

            # 验证
            echo ""
            echo -e "${YELLOW}📋 更新后的封锁状态:${NC}"
            show_blocked_ports
        else
            echo -e "${RED}❌ 无效输入${NC}"
            exit 1
        fi
        ;;

    3)
        echo -e "${YELLOW}👋 退出${NC}"
        exit 0
        ;;

    1|*)
        # ═══════════════════════════════════════════════════════
        #  封锁端口流程
        # ═══════════════════════════════════════════════════════
        echo ""
        echo -e "${RED}🔒 封锁端口${NC}"
        echo ""

        # 再次显示已封锁端口
        echo -e "${YELLOW}当前已封锁端口 (供参考，避免重复):${NC}"
        show_blocked_ports

        # 输入端口
        echo -e "${CYAN}🎯 输入要封锁的端口${NC}"
        echo -e "${YELLOW}提示: 支持单个端口 (如 8029) 或多个端口 (如 8029 8080 9090)${NC}"
        echo ""
        read -p "➡️  请输入要封锁的端口: " PORTS_INPUT
        if [ -z "$PORTS_INPUT" ]; then
            echo -e "${RED}❌ 端口不能为空${NC}"
            exit 1
        fi

        IFS=' ' read -ra PORTS <<< "$PORTS_INPUT"

        # ═══ SSH 安全检测 — 拒绝封锁 ═══
        SSH_BLOCKED=false
        FILTERED_PORTS=()
        for PORT in "${PORTS[@]}"; do
            IS_SSH=false
            for SP in "${SSH_PORTS[@]}"; do
                if [ "$PORT" = "$SP" ]; then
                    IS_SSH=true
                    break
                fi
            done
            if $IS_SSH; then
                SSH_BLOCKED=true
                echo -e "${RED}  🚫 端口 ${PORT} 是 SSH 端口，禁止封锁！${NC}"
            else
                FILTERED_PORTS+=("$PORT")
            fi
        done

        PORTS=("${FILTERED_PORTS[@]}")

        if $SSH_BLOCKED; then
            echo ""
            echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║       🚫 SSH 端口受永久保护，已自动跳过               ║${NC}"
            echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
            echo -e "${RED}  SSH 防护请使用 install-fail2ban.sh${NC}"
            echo -e "${RED}  本脚本只封锁应用端口，不碰 SSH${NC}"
            echo ""
        fi

        # 如果所有端口都被过滤掉了，退出
        if [ ${#PORTS[@]} -eq 0 ]; then
            echo -e "${YELLOW}🛑 没有非 SSH 端口需要封锁，退出${NC}"
            exit 0
        fi

        echo ""

        # 白名单设置
        echo -e "${CYAN}🔓 设置白名单 (允许访问的来源)${NC}"
        echo -e "${YELLOW}默认白名单 (强烈建议保留):${NC}"
        echo -e "  1) ${GREEN}127.0.0.1${NC} — 本机 (NPM 反代、localhost 访问)"
        echo -e "  2) ${GREEN}172.17.0.0/16${NC} — Docker 默认网桥 (容器间通信)"
        echo ""

        read -p "➡️  是否使用默认白名单 [127.0.0.1, 172.17.0.0/16]? (Y/n): " USE_DEFAULT
        if [[ "$USE_DEFAULT" =~ ^[Nn] ]]; then
            echo -e "请输入自定义白名单，每行一个，输入空行结束:"
            echo -e "${YELLOW}格式: IP 或 CIDR (如 192.168.1.0/24)${NC}"
            WHITELIST=()
            while true; do
                read -p "  ➡️  添加白名单 (直接回车结束): " IP
                [ -z "$IP" ] && break
                WHITELIST+=("$IP")
                echo -e "${GREEN}  ✅ 已添加: $IP${NC}"
            done
            if [ ${#WHITELIST[@]} -eq 0 ]; then
                echo -e "${RED}❌ 白名单不能为空，否则连本机都无法访问！${NC}"
                exit 1
            fi
        else
            WHITELIST=("127.0.0.1" "172.17.0.0/16")
            echo -e "${GREEN}✅ 使用默认白名单: 127.0.0.1, 172.17.0.0/16${NC}"
        fi

        # 如果有 SSH 额外白名单，追加（已禁用 — SSH 端口永久受保护）
        # 保留此占位以便将来扩展

        echo ""

        # 确认操作
        echo -e "${YELLOW}⚠️  即将执行以下操作:${NC}"
        echo -e "  封锁端口: ${RED}${PORTS[*]}${NC}"
        echo -e "  白名单:   ${GREEN}${WHITELIST[*]}${NC}"
        echo -e "  规则位置: raw 表 PREROUTING 链"
        echo ""
        echo -e "${RED}⚠️  警告: 规则立即生效，请确保你还有其他方式访问服务器${NC}"
        echo ""
        read -p "➡️  确认执行? (y/N): " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}🛑 已取消${NC}"
            exit 0
        fi
        echo ""

        # 应用规则
        echo -e "${YELLOW}🛡️  正在应用规则...${NC}"
        for PORT in "${PORTS[@]}"; do
            if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                echo -e "${RED}❌ 无效端口号: $PORT，跳过${NC}"
                continue
            fi

            # 清理旧规则
            delete_port_rules $PORT

            # 添加白名单
            for IP in "${WHITELIST[@]}"; do
                iptables -t raw -A PREROUTING -p tcp --dport "$PORT" -s "$IP" -j RETURN
                echo -e "  ${GREEN}✅ 放行: $IP → 端口 $PORT${NC}"
            done

            # DROP 其余
            iptables -t raw -A PREROUTING -p tcp --dport "$PORT" -j DROP
            echo -e "  ${RED}🔒 封锁: 其他所有来源 → 端口 $PORT${NC}"

            # IPv6
            if ip6tables -t raw -L PREROUTING -n &>/dev/null; then
                ip6tables -t raw -A PREROUTING -p tcp --dport "$PORT" -s ::1 -j RETURN
                ip6tables -t raw -A PREROUTING -p tcp --dport "$PORT" -j DROP
                echo -e "  ${GREEN}✅ IPv6: 放行 ::1, 封锁其他 → 端口 $PORT${NC}"
            fi
        done
        echo ""

        # 保存
        echo -e "${YELLOW}💾 持久化保存...${NC}"
        iptables-save > /etc/iptables/rules.v4
        if ip6tables-save &>/dev/null; then
            ip6tables-save > /etc/iptables/rules.v6
        fi
        echo -e "${GREEN}✅ 规则已保存，重启后自动加载${NC}"
        echo ""

        # 验证
        echo -e "${YELLOW}🔍 验证规则:${NC}"
        iptables -t raw -L PREROUTING -n -v --line-numbers 2>/dev/null | head -30
        echo ""

        # 测试本机连通性
        echo -e "${YELLOW}🧪 本机连通性测试:${NC}"
        for PORT in "${PORTS[@]}"; do
            if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 http://127.0.0.1:$PORT/ &>/dev/null; then
                echo -e "  ${GREEN}✅ 本机 127.0.0.1:$PORT → 可达${NC}"
            else
                echo -e "  ${YELLOW}⚠️  本机 127.0.0.1:$PORT → 不可达 (可能端口无服务监听)${NC}"
            fi
        done
        echo ""

        # 显示摘要
        echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║              ✅ 操作完成！                          ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "封锁端口: ${RED}${PORTS[*]}${NC}"
        echo -e "白名单:   ${GREEN}${WHITELIST[*]}${NC}"
        echo ""
        # SSH 端口已自动过滤，不显示旧提示
        # SSH 防护由 install-fail2ban.sh 负责
        ;;
esac

echo ""
echo -e "${GREEN}🎉 完成！${NC}"
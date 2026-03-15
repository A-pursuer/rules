#!/usr/bin/env bash
# pursuer.sh — VPS 工具箱主入口
# 用法：
#   交互菜单：bash pursuer.sh
#   非交互式：export NEW_SSH_PORT=xxx && bash <(curl -fsSL URL) --init-system
#   参数方式：bash <(curl -fsSL URL) --init-system --port xxx

set -euo pipefail

# ── 常量 ────────────────────────────────────────────────────────
GITHUB_RAW="https://raw.githubusercontent.com/A-pursuer/rules/refs/heads/main"
SSH_PUBKEY_URL="https://sshid.io/pursuer"

# ── 颜色 ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── 打印工具 ─────────────────────────────────────────────────────
info()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
title()   { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }
confirm() {
    local msg="${1:-确认执行？}"
    echo -en "${YELLOW}${msg} [y/N] ${NC}"
    read -r ans
    [[ "${ans,,}" == "y" ]]
}

# ── 权限检查 ─────────────────────────────────────────────────────
check_root() {
    [[ $EUID -ne 0 ]] && { error "此脚本需要 root 权限"; exit 1; }
}

# ── 下载并执行远端脚本 ───────────────────────────────────────────
# 用法：run_remote <脚本名> [传给脚本的参数...]
run_remote() {
    local script_name="$1"; shift
    local url="${GITHUB_RAW}/${script_name}"
    local tmp
    tmp=$(mktemp /tmp/pursuer_XXXXXX.sh)

    echo -e "${CYAN}[↓]${NC} 正在下载 ${url} ..."
    if ! curl -fsSL "$url" -o "$tmp"; then
        error "下载失败: $url"
        rm -f "$tmp"
        return 1
    fi
    chmod +x "$tmp"
    bash "$tmp" "$@" || { local rc=$?; rm -f "$tmp"; return "$rc"; }
    rm -f "$tmp"
}

# ════════════════════════════════════════════════════════════════
# 模块：配置 SSH 密钥登录（本地执行，含私有公钥 URL）
# ════════════════════════════════════════════════════════════════
module_ssh_key() {
    title "配置 SSH 密钥登录"
    local sshd_config="/etc/ssh/sshd_config"
    local auth_keys="/root/.ssh/authorized_keys"
    local backup="${sshd_config}.bak.$(date +%Y%m%d%H%M%S)"

    cp "$sshd_config" "$backup"
    info "已备份 → $backup"

    trap 'error "发生错误，正在还原备份..."; cp "$backup" "$sshd_config"' ERR

    # 拉取公钥
    local key_content
    key_content=$(curl -fsSL "$SSH_PUBKEY_URL") || { error "拉取公钥失败"; return 1; }
    [[ -z "$key_content" ]] && { error "公钥内容为空"; return 1; }

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    # 去重追加
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        grep -qxF "$line" "$auth_keys" 2>/dev/null || echo "$line" >> "$auth_keys"
    done <<< "$key_content"
    info "公钥已追加"

    chown -R root:root /root/.ssh
    chmod 600 "$auth_keys"
    info ".ssh 权限已设置"

    # 修改 sshd_config
    for directive in PermitRootLogin PasswordAuthentication PubkeyAuthentication \
                     ChallengeResponseAuthentication KbdInteractiveAuthentication; do
        sed -i -E "s/^([[:space:]]*${directive}[[:space:]]+.*)$/# \1/" "$sshd_config"
    done

    cat >> "$sshd_config" <<'EOF'

# === 由 pursuer.sh 追加 ===
PermitRootLogin yes
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
EOF
    info "SSH 配置已追加"

    sshd -t || { error "语法校验失败，还原备份"; cp "$backup" "$sshd_config"; return 1; }
    info "语法校验通过"
    systemctl restart ssh
    info "SSH 服务已重启"

    trap - ERR

    # SSH 登录 Telegram 告警
    setup_ssh_alert
}

# ════════════════════════════════════════════════════════════════
# SSH 登录 Telegram 告警配置
# 环境变量：DEVICE_NAME、TG_TOKEN、TG_ID
# ════════════════════════════════════════════════════════════════
setup_ssh_alert() {
    title "配置 SSH 登录 Telegram 告警"

    local token="${TG_TOKEN:-}"
    local tg_id="${TG_ID:-}"

    # 设备名每台机器不同，强制交互输入
    local device=""
    echo -en "${YELLOW}请输入设备名称（不含 | 等特殊字符）: ${NC}"
    read -r device
    # 去掉 sed 分隔符 | 防止注入
    device="${device//|/}"

    if [[ -z "$token" ]]; then
        echo -en "${YELLOW}请输入 Telegram Bot Token: ${NC}"
        read -r token
    fi
    if [[ -z "$tg_id" ]]; then
        echo -en "${YELLOW}请输入 Telegram Chat ID: ${NC}"
        read -r tg_id
    fi

    [[ -z "$device" || -z "$token" || -z "$tg_id" ]] && {
        error "设备名、Token、Chat ID 均不能为空"; return 1
    }

    local target="/etc/profile.d/ssh_protect.sh"
    local tmp
    tmp=$(mktemp /tmp/pursuer_XXXXXX.sh)

    echo -e "${CYAN}[↓]${NC} 正在下载 secure-ssh ..."
    if ! curl -fsSL "${GITHUB_RAW}/secure-ssh" -o "$tmp"; then
        error "下载失败"; rm -f "$tmp"; return 1
    fi

    sed -i \
        -e "s|DEVICE|${device}|g" \
        -e "s|TG_TOKEN|${token}|g" \
        -e "s|TG_ID|${tg_id}|g" \
        "$tmp"

    mv "$tmp" "$target"
    chmod 555 "$target"
    info "告警脚本已安装 → $target"
    info "下次 SSH 登录时将发送 Telegram 通知"
}

# ════════════════════════════════════════════════════════════════
# 模块：系统初始化（basic_ops + NTP）
# ════════════════════════════════════════════════════════════════
module_init_system() {
    title "系统初始化"

    # 确定 SSH 端口（优先级：参数 > 环境变量 > 交互输入）
    local port="${NEW_SSH_PORT:-}"
    if [[ -z "$port" ]]; then
        echo -en "${YELLOW}请输入 SSH 端口: ${NC}"
        read -r port
    fi

    # 验证端口号
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        error "无效端口: $port"; return 1
    fi

    # 确定时区（优先级：参数 > 环境变量 > 交互输入）
    local tz="${NEW_TIMEZONE:-}"
    if [[ -z "$tz" ]]; then
        echo -en "${YELLOW}请输入时区 [默认 Asia/Shanghai]: ${NC}"
        read -r tz
        tz="${tz:-Asia/Shanghai}"
    fi
    # 时区格式校验（只允许字母/数字/下划线/连字符/斜杠，防止 sed 分隔符注入）
    if ! [[ "$tz" =~ ^[A-Za-z0-9_/+-]+$ ]]; then
        error "无效时区格式: $tz"; return 1
    fi

    info "SSH 端口: $port"
    info "时区: $tz"

    # 安装基础包
    info "更新包列表并安装基础工具..."
    apt update -qq
    apt install -y ufw curl wget unzip socat cron unattended-upgrades

    # 启用自动安全更新（非交互）
    info "启用 unattended-upgrades 自动安全更新..."
    echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" \
        | debconf-set-selections
    dpkg-reconfigure -f noninteractive unattended-upgrades
    info "自动安全更新已启用"

    # 执行 basic_ops（替换端口 + 时区）
    info "执行系统加固（SSH端口/BBR/时区）..."
    run_basic_ops "$port" "$tz"

    # NTP 同步
    info "配置 chrony NTP 时间同步..."
    systemctl stop systemd-timesyncd 2>/dev/null || true
    systemctl disable systemd-timesyncd 2>/dev/null || true
    apt install -y chrony
    systemctl enable --now chrony
    chronyc makestep

    # 最终验证输出
    verify_init_system "$port" "$tz"
}

# 系统初始化完成后的统一验证输出
verify_init_system() {
    local port="$1"
    local tz="$2"

    echo ""
    echo -e "${BOLD}${CYAN}══════════════ 验证结果 ══════════════${NC}"

    # 时间
    echo -e "\n${BOLD}[ 时间 ]${NC}"
    date -R

    # 时区
    echo -e "\n${BOLD}[ 时区 ]${NC}"
    timedatectl show --property=Timezone --value

    # SSH 端口
    echo -e "\n${BOLD}[ SSH 端口 ]${NC}"
    if ss -tlnp | grep -q ":${port}"; then
        echo -e "${GREEN}✓ 端口 ${port} 正在监听${NC}"
    else
        echo -e "${YELLOW}⚠ 端口 ${port} 暂未监听（SSH 服务可能需要稍等）${NC}"
    fi

    # BBR
    echo -e "\n${BOLD}[ BBR 拥塞控制 ]${NC}"
    lsmod | grep -i bbr || echo -e "${YELLOW}⚠ BBR 模块未检测到${NC}"
    echo "sysctl: $(sysctl -n net.ipv4.tcp_congestion_control)"

    # FQ
    echo -e "\n${BOLD}[ FQ 队列调度 ]${NC}"
    lsmod | grep -i sch_fq || echo -e "${YELLOW}⚠ sch_fq 模块未检测到${NC}"
    echo "sysctl: $(sysctl -n net.core.default_qdisc)"

    # chrony
    echo -e "\n${BOLD}[ NTP 同步状态 ]${NC}"
    chronyc tracking | grep -E "Reference ID|System time|Leap status"

    # unattended-upgrades
    echo -e "\n${BOLD}[ 自动安全更新 ]${NC}"
    if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
        echo -e "${GREEN}✓ unattended-upgrades 已启用${NC}"
    else
        echo -e "${YELLOW}⚠ unattended-upgrades 未检测到${NC}"
    fi

    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"
}

# 下载 basic_ops 并替换端口和时区占位符后执行
run_basic_ops() {
    local port="$1"
    local tz="$2"
    local url="${GITHUB_RAW}/basic_ops"
    local tmp
    tmp=$(mktemp /tmp/pursuer_XXXXXX.sh)

    echo -e "${CYAN}[↓]${NC} 正在下载 ${url} ..."
    if ! curl -fsSL "$url" -o "$tmp"; then
        error "下载失败: $url"; rm -f "$tmp"; return 1
    fi

    # 替换端口占位符（basic_ops 默认值为 22111）
    sed -i "s/22111/${port}/g" "$tmp"
    # 替换时区占位符（basic_ops 默认值为 Asia/Shanghai）
    sed -i "s|Asia/Shanghai|${tz}|g" "$tmp"

    chmod +x "$tmp"
    bash "$tmp" || { local rc=$?; rm -f "$tmp"; return "$rc"; }
    rm -f "$tmp"
}

# ════════════════════════════════════════════════════════════════
# 模块：安装 Nginx（占位，待实现）
# ════════════════════════════════════════════════════════════════
module_install_nginx() {
    title "安装 Nginx"
    warn "模块尚未实现，敬请期待"
    # run_remote "install_nginx"
}

# ════════════════════════════════════════════════════════════════
# 模块：安装 Hysteria2 代理
# 环境变量：CF_TOKEN、CF_ZONE_ID、HYS_PASS、HYS_PORT
# ════════════════════════════════════════════════════════════════
module_install_hysteria() {
    title "安装 Hysteria2 代理"

    # ── 收集参数 ──────────────────────────────────────────────
    local cf_token="${CF_TOKEN:-}"
    local cf_zone_id="${CF_ZONE_ID:-}"
    local hys_pass="${HYS_PASS:-}"
    local hys_port="${HYS_PORT:-}"

    # 域名：强制交互（每台机器不同）
    local hys_domain=""
    echo -en "${YELLOW}请输入 Hysteria2 域名（如 hs.example.com）: ${NC}"
    read -r hys_domain
    [[ -z "$hys_domain" ]] && { error "域名不能为空"; return 1; }

    # 端口：强制交互（不设默认值，避免上传 GitHub 后暴露习惯端口）
    if [[ -z "$hys_port" ]]; then
        echo -en "${YELLOW}请输入 Hysteria2 端口: ${NC}"
        read -r hys_port
    fi
    if ! [[ "$hys_port" =~ ^[0-9]+$ ]] || (( hys_port < 1 || hys_port > 65535 )); then
        error "无效端口: $hys_port"; return 1
    fi

    # CF 凭证：环境变量回退交互
    if [[ -z "$cf_token" ]]; then
        echo -en "${YELLOW}请输入 Cloudflare API Token: ${NC}"
        read -r cf_token
    fi
    if [[ -z "$cf_zone_id" ]]; then
        echo -en "${YELLOW}请输入 Cloudflare Zone ID: ${NC}"
        read -r cf_zone_id
    fi

    # 密码：环境变量回退交互
    if [[ -z "$hys_pass" ]]; then
        echo -en "${YELLOW}请输入 Hysteria2 密码: ${NC}"
        read -r hys_pass
    fi

    [[ -z "$cf_token" || -z "$cf_zone_id" || -z "$hys_pass" ]] && {
        error "CF Token、Zone ID、密码均不能为空"; return 1
    }

    info "域名: $hys_domain  端口: $hys_port"

    # ── 1. 安装并配置 acme.sh ─────────────────────────────────
    info "安装 acme.sh ..."
    local acme_email="${ACME_EMAIL:-}"
    if [[ -z "$acme_email" ]]; then
        echo -en "${YELLOW}请输入 acme.sh 注册邮箱: ${NC}"
        read -r acme_email
    fi
    [[ -z "$acme_email" ]] && { error "邮箱不能为空"; return 1; }
    curl -fsSL https://get.acme.sh | sh -s "email=${acme_email}"
    mkdir -p /root/cert
    /root/.acme.sh/acme.sh --upgrade --auto-upgrade
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    # ── 2. 申请证书（Cloudflare DNS-01）──────────────────────
    info "申请证书：$hys_domain ..."
    CF_Token="$cf_token" CF_Zone_ID="$cf_zone_id" \
        /root/.acme.sh/acme.sh --issue -d "$hys_domain" --dns dns_cf

    # ── 3. 安装 Hysteria2 ─────────────────────────────────────
    info "安装 Hysteria2 ..."
    bash <(curl -fsSL https://get.hy2.sh/)

    # ── 4. 目录 + 安装证书 ────────────────────────────────────
    mkdir -p /etc/hysteria/web/ /etc/hysteria/cert/
    /root/.acme.sh/acme.sh --install-cert -d "$hys_domain" \
        --key-file   "/etc/hysteria/cert/${hys_domain}.key" \
        --fullchain-file "/etc/hysteria/cert/${hys_domain}.cer"

    chmod +r "/etc/hysteria/cert/${hys_domain}.cer" \
             "/etc/hysteria/cert/${hys_domain}.key"

    # ── 5. 下载资源文件 ───────────────────────────────────────
    info "下载 geoip.dat ..."
    wget -q "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/geoip.dat" \
        -O /usr/local/bin/geoip.dat

    info "下载伪装页面 ..."
    wget -q "${GITHUB_RAW}/404.html" -O /etc/hysteria/web/index.html
    chmod +r /etc/hysteria/web/index.html

    info "下载配置文件模板 ..."
    wget -q "${GITHUB_RAW}/conf" -O /etc/hysteria/config.yaml

    sed -i \
        -e "s|HYS_PORT|${hys_port}|g" \
        -e "s|HYS_DOMAIN|${hys_domain}|g" \
        -e "s|HYS_PASS|${hys_pass}|g" \
        /etc/hysteria/config.yaml

    # ── 6. 创建自动续期脚本（写入实际域名，非变量引用）──────
    info "创建 autossl.sh ..."
    cat > /root/autossl.sh <<EOF
#!/bin/bash
# Hysteria2 SSL 证书自动续期
/root/.acme.sh/acme.sh --install-cert -d ${hys_domain} \\
    --key-file   /etc/hysteria/cert/${hys_domain}.key \\
    --fullchain-file /etc/hysteria/cert/${hys_domain}.cer \\
    --reloadcmd "systemctl restart hysteria-server"
EOF
    chmod +x /root/autossl.sh

    # 立即执行一次验证
    bash /root/autossl.sh

    # ── 7. 添加 cron 续期任务（幂等）────────────────────────
    if grep -qF "autossl.sh" /etc/crontab 2>/dev/null; then
        warn "crontab 中已存在 autossl.sh 任务，跳过"
    else
        echo "10 10 6 * * root /bin/bash /root/autossl.sh > /dev/null 2>&1" >> /etc/crontab
        info "已添加续期任务：每月6日 10:10 执行"
    fi

    # ── 8. 启动服务 ───────────────────────────────────────────
    systemctl enable hysteria-server.service
    systemctl restart hysteria-server.service

    echo ""
    systemctl status hysteria-server.service --no-pager -l
}

# ════════════════════════════════════════════════════════════════
# 模块：安装 acme.sh（占位，待实现）
# ════════════════════════════════════════════════════════════════
module_install_acme() {
    title "安装 acme.sh (SSL 证书)"
    warn "模块尚未实现，敬请期待"
    # run_remote "install_acme"
}

# ════════════════════════════════════════════════════════════════
# 交互菜单
# ════════════════════════════════════════════════════════════════
show_menu() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║       Pursuer VPS Toolbox            ║"
    echo "  ╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}── 系统初始化 ──────────────────────────${NC}"
    echo -e "  ${GREEN}1${NC}. 配置 SSH 密钥登录"
    echo -e "  ${GREEN}2${NC}. 系统初始化（基础包 / SSH端口 / BBR / 时区 / NTP）"
    echo ""
    echo -e "  ${BOLD}── 软件安装 ────────────────────────────${NC}"
    echo -e "  ${GREEN}3${NC}. 安装 Nginx"
    echo -e "  ${GREEN}4${NC}. 安装 acme.sh（SSL 证书）"
    echo -e "  ${GREEN}5${NC}. 安装 Hysteria2 代理"
    echo ""
    echo -e "  ${RED}0${NC}. 退出"
    echo ""
    echo -en "  请选择 [0-5]: "
}

# ════════════════════════════════════════════════════════════════
# 参数解析（非交互模式）
# ════════════════════════════════════════════════════════════════
parse_args() {
    local action=""

    # 第一遍：收集所有参数和变量
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port|-p)
                export NEW_SSH_PORT="$2"; shift 2 ;;
            --port=*)
                export NEW_SSH_PORT="${1#*=}"; shift ;;
            --tz|-t)
                export NEW_TIMEZONE="$2"; shift 2 ;;
            --tz=*)
                export NEW_TIMEZONE="${1#*=}"; shift ;;
            --ssh-key|--init-system|--nginx|--acme|--hysteria)
                action="$1"; shift ;;
            --help|-h)
                echo "用法: pursuer.sh [选项]"
                echo "  --port   PORT    指定 SSH 端口"
                echo "  --tz     ZONE    指定时区（默认 Asia/Shanghai）"
                echo "  --ssh-key        配置 SSH 密钥登录 + Telegram 告警（设备名交互输入）"
                echo "  --init-system    系统初始化（基础包/SSH端口/BBR/时区/NTP）"
                echo "  --nginx          安装 Nginx"
                echo "  --acme           安装 acme.sh"
                echo "  --hysteria       安装 Hysteria2 代理"
                echo ""
                echo "环境变量（适用于 Termius Snippet）:"
                echo "  NEW_SSH_PORT     SSH 端口"
                echo "  NEW_TIMEZONE     时区"
                echo "  TG_TOKEN         Telegram Bot Token"
                echo "  TG_ID            Telegram Chat ID"
                echo "  ACME_EMAIL       acme.sh 注册邮箱        （Hysteria2）"
                echo "  CF_TOKEN         Cloudflare API Token    （Hysteria2）"
                echo "  CF_ZONE_ID       Cloudflare Zone ID      （Hysteria2）"
                echo "  HYS_PASS         Hysteria2 密码          （Hysteria2）"
                echo "  HYS_PORT         Hysteria2 端口（Hysteria2，建议通过 snippet 指定）"
                echo "  # 域名、设备名每台机器不同，运行时交互输入"
                echo ""
                echo "示例:"
                echo "  export TG_TOKEN=xxx TG_ID=yyy && bash <(curl -fsSL URL) --ssh-key"
                echo "  export CF_TOKEN=xxx CF_ZONE_ID=yyy HYS_PASS=zzz && \\"
                echo "  bash <(curl -fsSL URL) --hysteria"
                exit 0 ;;
            *)
                error "未知参数: $1"; exit 1 ;;
        esac
    done

    # 第二步：执行动作
    check_root
    case "$action" in
        --ssh-key)     module_ssh_key ;;
        --init-system) module_init_system ;;
        --nginx)       module_install_nginx ;;
        --acme)        module_install_acme ;;
        --hysteria)    module_install_hysteria ;;
        "")            error "未指定操作，使用 --help 查看帮助"; exit 1 ;;
    esac
    exit 0
}

# ════════════════════════════════════════════════════════════════
# 主程序
# ════════════════════════════════════════════════════════════════
main() {
    # 有参数时走非交互流程
    if [[ $# -gt 0 ]]; then
        parse_args "$@"
        return
    fi

    # 无参数走交互菜单
    check_root
    while true; do
        show_menu
        read -r choice
        case "$choice" in
            1) confirm "确认配置 SSH 密钥登录？" && module_ssh_key ;;
            2) confirm "确认执行系统初始化？" && module_init_system ;;
            3) confirm "确认安装 Nginx？"        && module_install_nginx ;;
            4) confirm "确认安装 acme.sh？"     && module_install_acme ;;
            5) confirm "确认安装 Hysteria2？"   && module_install_hysteria ;;
            0) echo "再见！"; exit 0 ;;
            *) warn "无效选项，请重新输入" ;;
        esac
        echo ""
        echo -en "${CYAN}按 Enter 返回菜单...${NC}"
        read -r
    done
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWK_ENGINE_V4="${SCRIPT_DIR}/tcp_tune_v4.awk"
AWK_ENGINE_V5="${SCRIPT_DIR}/tcp_tune_v5.awk"

CONF_PATH_DEFAULT="/etc/sysctl.d/99-tcp-auto-tune.conf"
STATE_DIR_DEFAULT="/var/lib/tcp-auto-tune"
PROBE_TARGETS_DEFAULT="1.1.1.1,8.8.8.8,9.9.9.9"

COMMAND="${1:-recommend}"
if [[ $# -gt 0 ]]; then
    shift
fi

PROFILE="${TCP_TUNE_PROFILE:-general}"
CLIENT_BW_MBPS="${TCP_TUNE_CLIENT_BW_MBPS:-}"
CLIENT_RTT_MS="${TCP_TUNE_CLIENT_RTT_MS:-}"
VPS_BW_MBPS="${TCP_TUNE_VPS_BW_MBPS:-}"
RAMP_RATE="${TCP_TUNE_RAMP_RATE:-auto}"
EXTREME_MODE="${TCP_TUNE_EXTREME:-auto}"
CC_ALGO="${TCP_TUNE_CC:-auto}"
QDISC="${TCP_TUNE_QDISC:-auto}"
ENGINE_MODE="${TCP_TUNE_ENGINE:-auto}"
PROBE_TARGETS="${TCP_TUNE_PROBE_TARGETS:-$PROBE_TARGETS_DEFAULT}"
CONF_PATH="${TCP_TUNE_CONF_PATH:-$CONF_PATH_DEFAULT}"
STATE_DIR="${TCP_TUNE_STATE_DIR:-$STATE_DIR_DEFAULT}"
PING_COUNT="${TCP_TUNE_PING_COUNT:-3}"
INTERACTIVE=0
CONFIG_ONLY=0
SHOW_DIFF=0

OS_ID=""
OS_VERSION_ID=""
OS_PRETTY=""
MEM_MB=""
DEFAULT_IFACE=""
DEFAULT_GW=""
LINK_SPEED_MBPS=""
CURRENT_CC=""
CURRENT_QDISC=""
AVAILABLE_CC=""
CAKE_AVAILABLE=""
PROBE_RTT_MS=""
PROBE_JITTER_MS=""
PROBE_LOSS_PCT=""
PROBE_SAMPLE_COUNT=0
PATH_MODE="auto"
DECISION_CONFIDENCE="high"
SELECTED_ENGINE=""
MODEL_NAME=""

declare -a WARNINGS=()
declare -a ASSUMPTIONS=()

log() {
    printf '%s\n' "$*"
}

warn() {
    WARNINGS+=("$*")
}

assume() {
    ASSUMPTIONS+=("$*")
}

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

trim() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

normalize_sysctl_value() {
    printf '%s\n' "${1:-}" | tr '\t' ' ' | awk '{$1=$1; print}'
}

lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_number() {
    [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

float_le() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'
}

float_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'
}

float_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'
}

float_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

min_float() {
    awk -v a="$1" -v b="$2" 'BEGIN { print (a < b ? a : b) }'
}

clamp_float() {
    awk -v x="$1" -v lo="$2" -v hi="$3" 'BEGIN { if (x < lo) x = lo; if (x > hi) x = hi; print x }'
}

normalize_profile() {
    case "$(lower "$1")" in
        interactive|low|low-latency|low_latency|ssh|api|game|gaming|低延迟|交互型|游戏)
            printf 'interactive'
            ;;
        general|balanced|common|默认|通用|通用型|均衡)
            printf 'general'
            ;;
        throughput|high|high-latency|high_latency|bulk|download|streaming|高延迟|吞吐|下载)
            printf 'throughput'
            ;;
        *)
            die "不支持的 profile: $1，可选 interactive/general/throughput"
            ;;
    esac
}

has_word() {
    local haystack=" ${1:-} "
    local needle="${2:-}"
    [[ -n "$needle" ]] || return 1
    [[ "$haystack" == *" ${needle} "* ]]
}

profile_label() {
    case "$1" in
        interactive)
            printf '低延迟、交互型、SSH/API/游戏优先'
            ;;
        general)
            printf '通用型'
            ;;
        throughput)
            printf '高延迟/吞吐优先'
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

show_help() {
    cat <<'EOF'
用法:
  ./tcp-auto-tune.sh probe
  ./tcp-auto-tune.sh recommend [选项]
  ./tcp-auto-tune.sh apply [选项]
  ./tcp-auto-tune.sh rollback

核心选项:
  --profile interactive|general|throughput
  --engine auto|v4|v5
  --client-bandwidth MBPS
  --client-rtt MS
  --vps-bandwidth MBPS
  --ramp-rate 0.1-1
  --extreme auto|on|off
  --cc auto|bbr3|bbr2|bbr|cubic
  --qdisc auto|fq|cake
  --probe-targets 1.1.1.1,8.8.8.8
  --interactive
  --diff
  --config-only

环境变量:
  TCP_TUNE_PROFILE
  TCP_TUNE_ENGINE
  TCP_TUNE_CLIENT_BW_MBPS
  TCP_TUNE_CLIENT_RTT_MS
  TCP_TUNE_VPS_BW_MBPS
  TCP_TUNE_RAMP_RATE
  TCP_TUNE_EXTREME
  TCP_TUNE_CC
  TCP_TUNE_QDISC
  TCP_TUNE_PROBE_TARGETS

说明:
  1. probe/recommend 默认只读，不写系统文件。
  2. apply 仅写 /etc/sysctl.d/99-tcp-auto-tune.conf，并保存运行时回滚快照。
  3. auto 会在保守版 V4 子集和保守版 V5 子集之间自动择优。
  4. --cc auto 会按 bbr3 > bbr2 > bbr > cubic 自动选择。
  5. --qdisc auto 会在低延迟场景下尽量探测并使用 cake，否则回退到 fq。
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                PROFILE="$2"
                shift 2
                ;;
            --engine)
                ENGINE_MODE="$2"
                shift 2
                ;;
            --client-bandwidth)
                CLIENT_BW_MBPS="$2"
                shift 2
                ;;
            --client-rtt)
                CLIENT_RTT_MS="$2"
                shift 2
                ;;
            --vps-bandwidth)
                VPS_BW_MBPS="$2"
                shift 2
                ;;
            --ramp-rate)
                RAMP_RATE="$2"
                shift 2
                ;;
            --extreme)
                EXTREME_MODE="$2"
                shift 2
                ;;
            --cc)
                CC_ALGO="$2"
                shift 2
                ;;
            --qdisc)
                QDISC="$2"
                shift 2
                ;;
            --probe-targets)
                PROBE_TARGETS="$2"
                shift 2
                ;;
            --interactive)
                INTERACTIVE=1
                shift
                ;;
            --diff)
                SHOW_DIFF=1
                shift
                ;;
            --config-only)
                CONFIG_ONLY=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                die "未知参数: $1"
                ;;
        esac
    done
}

require_file() {
    [[ -f "$1" ]] || die "缺少文件: $1"
}

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "该命令需要 root 权限"
}

detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION_ID="${VERSION_ID:-unknown}"
        OS_PRETTY="${PRETTY_NAME:-unknown}"
    else
        OS_ID="unknown"
        OS_VERSION_ID="unknown"
        OS_PRETTY="unknown"
    fi

    if [[ "$OS_ID" != "debian" || "$OS_VERSION_ID" != "13" ]]; then
        warn "当前系统不是 Debian 13，脚本仍可运行，但仅对 Debian 13 做了针对性设计"
    fi
}

detect_mem_mb() {
    MEM_MB="$(awk '/MemTotal:/ { printf "%d\n", $2 / 1024 }' /proc/meminfo 2>/dev/null || printf '0')"
    [[ -n "$MEM_MB" && "$MEM_MB" != "0" ]] || MEM_MB="1024"
}

detect_route() {
    local route_line
    route_line="$(ip route show default 2>/dev/null | awk 'NR==1 {print; exit}')"
    DEFAULT_IFACE="$(printf '%s\n' "$route_line" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
    DEFAULT_GW="$(printf '%s\n' "$route_line" | awk '{for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit }}')"
}

detect_link_speed() {
    LINK_SPEED_MBPS=""
    if [[ -n "$DEFAULT_IFACE" && -r "/sys/class/net/${DEFAULT_IFACE}/speed" ]]; then
        LINK_SPEED_MBPS="$(cat "/sys/class/net/${DEFAULT_IFACE}/speed" 2>/dev/null || true)"
    fi
    if ! is_number "${LINK_SPEED_MBPS:-}" || float_le "$LINK_SPEED_MBPS" 0 || [[ "$LINK_SPEED_MBPS" == "4294967295" ]]; then
        LINK_SPEED_MBPS=""
    fi
}

sysctl_read() {
    sysctl -n "$1" 2>/dev/null || true
}

detect_tcp_stack() {
    CURRENT_CC="$(sysctl_read net.ipv4.tcp_congestion_control)"
    CURRENT_QDISC="$(sysctl_read net.core.default_qdisc)"
    AVAILABLE_CC="$(sysctl_read net.ipv4.tcp_available_congestion_control)"
    detect_cake_availability
}

detect_cake_availability() {
    local kernel_release modules_builtin
    CAKE_AVAILABLE="no"

    if [[ "${CURRENT_QDISC:-}" == "cake" ]] || [[ -d /sys/module/sch_cake ]]; then
        CAKE_AVAILABLE="yes"
        return
    fi

    if command -v modprobe >/dev/null 2>&1 && modprobe -n -q sch_cake >/dev/null 2>&1; then
        CAKE_AVAILABLE="yes"
        return
    fi

    kernel_release="$(uname -r 2>/dev/null || true)"
    modules_builtin="/lib/modules/${kernel_release}/modules.builtin"
    if [[ -r "$modules_builtin" ]] && grep -Eq '(^|/)sch_cake(\.ko(\.[^/]+)?)?$' "$modules_builtin"; then
        CAKE_AVAILABLE="yes"
        return
    fi

    if command -v tc >/dev/null 2>&1 && tc qdisc help 2>&1 | grep -qw 'cake'; then
        CAKE_AVAILABLE="maybe"
        return
    fi
}

pick_best_cc() {
    local algo
    for algo in bbr3 bbr2 bbr cubic; do
        if has_word "$AVAILABLE_CC" "$algo"; then
            printf '%s' "$algo"
            return
        fi
    done
    printf 'cubic'
}

ping_target() {
    local target="$1"
    local out avg mdev loss
    out="$(LC_ALL=C ping -n -c "$PING_COUNT" -W 1 "$target" 2>/dev/null || true)"
    avg="$(printf '%s\n' "$out" | awk -F'=' '/^rtt / { split($2, a, "/"); gsub(/ /, "", a[2]); print a[2]; exit }')"
    mdev="$(printf '%s\n' "$out" | awk -F'=' '/^rtt / { split($2, a, "/"); gsub(/ /, "", a[4]); print a[4]; exit }')"
    loss="$(printf '%s\n' "$out" | awk -F', ' '/packet loss/ { gsub(/%/, "", $3); print $3 + 0; exit }')"
    if is_number "${avg:-}"; then
        printf '%s|%s|%s\n' "${avg:-0}" "${mdev:-0}" "${loss:-100}"
        return 0
    fi
    return 1
}

median_from_lines() {
    if [[ $# -eq 0 ]]; then
        return 1
    fi
    printf '%s\n' "$@" | sort -n | awk '
        { a[++n] = $1 }
        END {
            if (n == 0) exit 1
            if (n % 2 == 1) {
                print a[(n + 1) / 2]
            } else {
                print (a[n / 2] + a[n / 2 + 1]) / 2
            }
        }
    '
}

probe_targets() {
    local raw="$PROBE_TARGETS"
    local item result
    local -a avgs=()
    local -a mdevs=()
    local -a losses=()
    local IFS=','
    read -r -a targets <<< "$raw"
    PROBE_RTT_MS=""
    PROBE_JITTER_MS=""
    PROBE_LOSS_PCT=""
    PROBE_SAMPLE_COUNT=0

    for item in "${targets[@]}"; do
        item="$(trim "$item")"
        [[ -n "$item" ]] || continue
        if result="$(ping_target "$item")"; then
            avgs+=("${result%%|*}")
            result="${result#*|}"
            mdevs+=("${result%%|*}")
            losses+=("${result##*|}")
        fi
    done

    PROBE_SAMPLE_COUNT="${#avgs[@]}"
    if [[ "$PROBE_SAMPLE_COUNT" -gt 0 ]]; then
        PROBE_RTT_MS="$(median_from_lines "${avgs[@]}")"
        PROBE_JITTER_MS="$(median_from_lines "${mdevs[@]}")"
        PROBE_LOSS_PCT="$(median_from_lines "${losses[@]}")"
    fi
}

downgrade_confidence() {
    case "$DECISION_CONFIDENCE" in
        high)
            DECISION_CONFIDENCE="medium"
            ;;
        medium)
            DECISION_CONFIDENCE="low"
            ;;
    esac
}

prompt_value() {
    local __var="$1"
    local message="$2"
    local default_value="${3:-}"
    local reply=""
    if [[ "$INTERACTIVE" -eq 1 && -t 0 ]]; then
        if [[ -n "$default_value" ]]; then
            read -r -p "${message} [默认 ${default_value}]: " reply
            reply="${reply:-$default_value}"
        else
            read -r -p "${message}: " reply
        fi
        printf -v "$__var" '%s' "$reply"
    fi
}

resolve_vps_bw() {
    if is_number "${VPS_BW_MBPS:-}"; then
        return
    fi

    prompt_value VPS_BW_MBPS "请输入 VPS 带宽 Mbps" "${LINK_SPEED_MBPS:-1000}"
    if is_number "${VPS_BW_MBPS:-}"; then
        return
    fi

    if is_number "${LINK_SPEED_MBPS:-}"; then
        VPS_BW_MBPS="$LINK_SPEED_MBPS"
        assume "未提供 VPS 带宽，使用主网卡链路速率 ${LINK_SPEED_MBPS} Mbps 作为近似值"
        downgrade_confidence
        return
    fi

    VPS_BW_MBPS="1000"
    assume "无法探测 VPS 带宽，保守回退到 1000 Mbps"
    downgrade_confidence
}

resolve_client_bw() {
    local guessed=""
    if is_number "${CLIENT_BW_MBPS:-}"; then
        return
    fi

    case "$PROFILE" in
        interactive)
            guessed="$(min_float "$VPS_BW_MBPS" 300)"
            ;;
        general)
            guessed="$(min_float "$VPS_BW_MBPS" 1000)"
            ;;
        throughput)
            guessed="$VPS_BW_MBPS"
            ;;
    esac

    prompt_value CLIENT_BW_MBPS "请输入终端用户本地带宽 Mbps" "$guessed"
    if is_number "${CLIENT_BW_MBPS:-}"; then
        return
    fi

    CLIENT_BW_MBPS="$guessed"
    assume "未提供终端用户本地带宽，按 profile=${PROFILE} 假设为 ${guessed} Mbps"
    downgrade_confidence
}

resolve_client_rtt() {
    local fallback=""
    if is_number "${CLIENT_RTT_MS:-}"; then
        return
    fi

    if is_number "${PROBE_RTT_MS:-}"; then
        fallback="$PROBE_RTT_MS"
    else
        case "$PROFILE" in
            interactive)
                fallback="40"
                ;;
            general)
                fallback="80"
                ;;
            throughput)
                fallback="180"
                ;;
        esac
    fi

    prompt_value CLIENT_RTT_MS "请输入真实用户访问 RTT 毫秒" "$fallback"
    if is_number "${CLIENT_RTT_MS:-}"; then
        if [[ "$CLIENT_RTT_MS" == "$fallback" ]] && is_number "${PROBE_RTT_MS:-}"; then
            assume "未提供真实用户 RTT，使用公网探针 RTT ${fallback} ms 代替"
            downgrade_confidence
        fi
        return
    fi

    CLIENT_RTT_MS="$fallback"
    if is_number "${PROBE_RTT_MS:-}"; then
        assume "未提供真实用户 RTT，使用公网探针 RTT ${fallback} ms 代替"
    else
        assume "无法探测真实用户 RTT，按 profile=${PROFILE} 回退到 ${fallback} ms"
    fi
    downgrade_confidence
}

recommend_path_mode() {
    if [[ "$PROFILE" == "throughput" ]]; then
        PATH_MODE="high"
        return
    fi
    if float_gt "$CLIENT_RTT_MS" 120; then
        PATH_MODE="high"
    else
        PATH_MODE="low"
    fi
}

auto_ramp() {
    local base
    case "$PROFILE" in
        interactive)
            if float_le "$CLIENT_RTT_MS" 40; then
                base="0.30"
            elif float_le "$CLIENT_RTT_MS" 80; then
                base="0.34"
            elif float_le "$CLIENT_RTT_MS" 160; then
                base="0.38"
            else
                base="0.42"
            fi
            ;;
        general)
            if float_le "$CLIENT_RTT_MS" 40; then
                base="0.48"
            elif float_le "$CLIENT_RTT_MS" 120; then
                base="0.56"
            elif float_le "$CLIENT_RTT_MS" 220; then
                base="0.62"
            else
                base="0.68"
            fi
            ;;
        throughput)
            if float_le "$CLIENT_RTT_MS" 120; then
                base="0.68"
            elif float_le "$CLIENT_RTT_MS" 250; then
                base="0.76"
            else
                base="0.82"
            fi
            ;;
    esac

    if float_le "$MEM_MB" 512; then
        base="$(awk -v x="$base" 'BEGIN { print x - 0.05 }')"
    fi
    if [[ "$DECISION_CONFIDENCE" == "low" ]]; then
        base="$(awk -v x="$base" 'BEGIN { print x - 0.05 }')"
    fi

    RAMP_RATE="$(clamp_float "$base" 0.20 0.90)"
}

resolve_ramp() {
    if is_number "${RAMP_RATE:-}"; then
        RAMP_RATE="$(clamp_float "$RAMP_RATE" 0.10 1.00)"
        return
    fi
    auto_ramp
}

resolve_extreme() {
    local mode
    mode="$(lower "$EXTREME_MODE")"
    case "$mode" in
        on|1|true)
            EXTREME_MODE="on"
            ;;
        off|0|false)
            EXTREME_MODE="off"
            ;;
        auto|"")
            if [[ "$PROFILE" == "throughput" ]] \
                && float_ge "$MEM_MB" 8192 \
                && float_ge "$CLIENT_RTT_MS" 200 \
                && float_ge "$CLIENT_BW_MBPS" "$VPS_BW_MBPS" \
                && [[ "$DECISION_CONFIDENCE" == "high" ]] \
                && { [[ -z "$PROBE_LOSS_PCT" ]] || float_lt "$PROBE_LOSS_PCT" 1; }; then
                EXTREME_MODE="on"
                assume "满足高延迟大吞吐场景条件，自动启用激进模式"
            else
                EXTREME_MODE="off"
                assume "默认关闭激进模式，以优先保证生产可用性"
            fi
            ;;
        *)
            die "不支持的 extreme 值: $EXTREME_MODE，可选 auto/on/off"
            ;;
    esac
}

resolve_engine() {
    local wanted
    wanted="$(lower "$ENGINE_MODE")"
    case "$wanted" in
        auto|"")
            if [[ "$DECISION_CONFIDENCE" == "low" ]] || float_le "$MEM_MB" 512; then
                SELECTED_ENGINE="v4"
                assume "探测信息不足或内存偏小，默认选择更保守的 V4 子集"
            elif [[ "$PROFILE" == "throughput" ]] || float_gt "$CLIENT_RTT_MS" 180; then
                SELECTED_ENGINE="v5"
                assume "高延迟或吞吐优先场景，默认选择 V5 子集"
            elif [[ "$PROFILE" == "interactive" ]]; then
                SELECTED_ENGINE="v4"
                assume "交互优先场景默认选择 V4 子集，优先稳态和可预测性"
            elif float_le "$CLIENT_RTT_MS" 120 && float_lt "$MEM_MB" 4096; then
                SELECTED_ENGINE="v4"
                assume "常规低中延迟通用场景，默认选择更通用的 V4 子集"
            else
                SELECTED_ENGINE="v5"
                assume "保留更高自适应空间，默认选择 V5 子集"
            fi
            ;;
        v4)
            SELECTED_ENGINE="v4"
            ;;
        v5)
            SELECTED_ENGINE="v5"
            ;;
        *)
            die "不支持的 engine: $ENGINE_MODE，可选 auto/v4/v5"
            ;;
    esac

    if [[ "$SELECTED_ENGINE" == "v4" ]]; then
        MODEL_NAME="conservative_v4_subset"
        if [[ "$EXTREME_MODE" == "on" ]]; then
            warn "V4 引擎不支持激进模式，已忽略 extreme=on"
        fi
    else
        MODEL_NAME="conservative_v5_subset"
    fi
}

resolve_cc_qdisc() {
    local wanted_cc wanted_qdisc best_cc
    wanted_cc="$(lower "$CC_ALGO")"
    case "$wanted_cc" in
        auto|"")
            best_cc="$(pick_best_cc)"
            if [[ -n "$best_cc" ]]; then
                CC_ALGO="$best_cc"
            else
                CC_ALGO="cubic"
            fi
            if [[ "$CC_ALGO" == "cubic" ]]; then
                assume "系统未检测到 BBR 家族拥塞控制，回退到 CUBIC"
            elif [[ "$CC_ALGO" != "bbr" ]]; then
                assume "检测到 ${CC_ALGO}，优先使用更高代际 BBR"
            fi
            ;;
        bbr3|bbr2|bbr|cubic)
            if [[ -n "$AVAILABLE_CC" ]] && ! has_word "$AVAILABLE_CC" "$wanted_cc"; then
                die "当前内核未检测到拥塞控制算法: $wanted_cc"
            fi
            CC_ALGO="$wanted_cc"
            ;;
        *)
            die "不支持的拥塞控制算法: $CC_ALGO"
            ;;
    esac

    wanted_qdisc="$(lower "$QDISC")"
    case "$wanted_qdisc" in
        auto|"")
            if [[ "$SELECTED_ENGINE" == "v4" ]] \
                && [[ "$PATH_MODE" == "low" ]] \
                && [[ "$CAKE_AVAILABLE" == "yes" ]] \
                && float_le "$VPS_BW_MBPS" 2000 \
                && [[ "$DECISION_CONFIDENCE" != "low" ]]; then
                QDISC="cake"
                assume "V4 低延迟路径检测到 sch_cake 可用，自动选择 cake"
            elif [[ "$PROFILE" == "interactive" ]] \
                && [[ "$CAKE_AVAILABLE" == "yes" ]] \
                && float_le "$VPS_BW_MBPS" 2000 \
                && [[ "$DECISION_CONFIDENCE" != "low" ]]; then
                QDISC="cake"
                assume "低延迟场景检测到 sch_cake 可用，自动选择 cake"
            elif [[ "$PROFILE" == "general" ]] \
                && [[ "$PATH_MODE" == "low" ]] \
                && [[ "$CAKE_AVAILABLE" == "yes" ]] \
                && float_le "$CLIENT_RTT_MS" 80 \
                && float_le "$VPS_BW_MBPS" 1000 \
                && [[ "$DECISION_CONFIDENCE" == "high" ]]; then
                QDISC="cake"
                assume "常规低延迟通用场景检测到 sch_cake，可优先使用 cake"
            else
                QDISC="fq"
                if [[ "$PROFILE" == "interactive" && "$CAKE_AVAILABLE" == "maybe" ]]; then
                    assume "仅检测到 tc 支持 cake，未能确认内核 sch_cake 可用性，保守回退到 fq"
                elif [[ "$PROFILE" == "interactive" && "$CAKE_AVAILABLE" == "no" ]]; then
                    assume "未检测到 sch_cake，低延迟场景保守回退到 fq"
                elif [[ "$SELECTED_ENGINE" == "v4" && "$PATH_MODE" == "low" && "$CAKE_AVAILABLE" == "no" ]]; then
                    assume "V4 低延迟路径未检测到 sch_cake，保守回退到 fq"
                fi
            fi
            ;;
        fq|cake)
            if [[ "$wanted_qdisc" == "cake" && "$CAKE_AVAILABLE" == "no" ]]; then
                die "当前系统未检测到 sch_cake，可改用 --qdisc fq 或先安装/加载 cake"
            fi
            if [[ "$wanted_qdisc" == "cake" && "$CAKE_AVAILABLE" == "maybe" ]]; then
                warn "仅检测到 tc 支持 cake，未能确认内核 sch_cake 可用性，继续按用户指定尝试"
            fi
            QDISC="$wanted_qdisc"
            ;;
        *)
            die "不支持的 qdisc: $QDISC"
            ;;
    esac
}

gather_context() {
    detect_os
    detect_mem_mb
    detect_route
    detect_link_speed
    detect_tcp_stack
    probe_targets
}

resolve_decision_inputs() {
    PROFILE="$(normalize_profile "$PROFILE")"
    resolve_vps_bw
    resolve_client_bw
    resolve_client_rtt
    recommend_path_mode
    resolve_ramp
    resolve_extreme
    resolve_engine
    resolve_cc_qdisc
}

print_probe_summary() {
    log "系统探测结果:"
    log "- 系统: ${OS_PRETTY}"
    log "- 内存: ${MEM_MB} MB"
    log "- 默认网卡: ${DEFAULT_IFACE:-unknown}"
    log "- 默认网关: ${DEFAULT_GW:-unknown}"
    log "- 链路速率: ${LINK_SPEED_MBPS:-unknown} Mbps"
    log "- 当前拥塞控制: ${CURRENT_CC:-unknown}"
    log "- 当前 qdisc: ${CURRENT_QDISC:-unknown}"
    log "- 可用拥塞控制: ${AVAILABLE_CC:-unknown}"
    log "- CAKE 可用性: ${CAKE_AVAILABLE:-unknown}"
    log "- 公网探针 RTT: ${PROBE_RTT_MS:-unknown} ms"
    log "- 公网探针抖动: ${PROBE_JITTER_MS:-unknown} ms"
    log "- 公网探针丢包: ${PROBE_LOSS_PCT:-unknown} %"
}

print_recommend_summary() {
    log "推荐摘要:"
    log "- Profile: $(profile_label "$PROFILE")"
    log "- Engine: ${SELECTED_ENGINE}"
    log "- 决策可信度: ${DECISION_CONFIDENCE}"
    log "- 算法路径: ${PATH_MODE}"
    log "- 终端用户本地带宽: ${CLIENT_BW_MBPS} Mbps"
    log "- 真实访问 RTT: ${CLIENT_RTT_MS} ms"
    log "- VPS 带宽: ${VPS_BW_MBPS} Mbps"
    log "- 拥塞控制: ${CC_ALGO}"
    log "- qdisc: ${QDISC}"
    log "- rampUpRate: ${RAMP_RATE}"
    log "- 激进模式: ${EXTREME_MODE}"
    if [[ "${#ASSUMPTIONS[@]}" -gt 0 ]]; then
        log "自动假设:"
        local item
        for item in "${ASSUMPTIONS[@]}"; do
            log "- ${item}"
        done
    fi
    if [[ "${#WARNINGS[@]}" -gt 0 ]]; then
        log "警告:"
        local warn_item
        for warn_item in "${WARNINGS[@]}"; do
            log "- ${warn_item}"
        done
    fi
}

build_config() {
    local engine_file
    if [[ "$SELECTED_ENGINE" == "v4" ]]; then
        engine_file="$AWK_ENGINE_V4"
    else
        engine_file="$AWK_ENGINE_V5"
    fi
    cat <<EOF
# Managed by tcp-auto-tune.sh
# model = ${MODEL_NAME}
# engine = ${SELECTED_ENGINE}
# profile = ${PROFILE}
# path_mode = ${PATH_MODE}
# confidence = ${DECISION_CONFIDENCE}
# generated_at = $(date '+%Y-%m-%d %H:%M:%S %z')
# os = ${OS_PRETTY}
# mem_mb = ${MEM_MB}
# client_bw_mbps = ${CLIENT_BW_MBPS}
# client_rtt_ms = ${CLIENT_RTT_MS}
# vps_bw_mbps = ${VPS_BW_MBPS}
# ramp_rate = ${RAMP_RATE}
# extreme_mode = ${EXTREME_MODE}
EOF
    awk \
        -f "$engine_file" \
        -v path_mode="$PATH_MODE" \
        -v client_bw_mbps="$CLIENT_BW_MBPS" \
        -v vps_bw_mbps="$VPS_BW_MBPS" \
        -v latency_ms="$CLIENT_RTT_MS" \
        -v mem_mb="$MEM_MB" \
        -v ramp_rate="$RAMP_RATE" \
        -v extreme_mode="$([[ "$EXTREME_MODE" == "on" ]] && printf '1' || printf '0')" \
        -v cc_algo="$CC_ALGO" \
        -v qdisc="$QDISC" \
        /dev/null
}

print_runtime_diff_from_file() {
    local config_file="$1"
    local line key desired current desired_norm current_norm changed compared_count changed_count unchanged_count
    changed=0
    compared_count=0
    changed_count=0
    unchanged_count=0
    log "运行时差异:"
    while IFS= read -r line; do
        [[ -n "$(trim "$line")" ]] || continue
        [[ "${line#\#}" == "$line" ]] || continue
        key="$(trim "${line%%=*}")"
        desired="$(trim "${line#*=}")"
        [[ -n "$key" ]] || continue
        current="$(sysctl -n "$key" 2>/dev/null || printf '<unsupported>')"
        desired_norm="$(normalize_sysctl_value "$desired")"
        current_norm="$(normalize_sysctl_value "$current")"
        compared_count=$((compared_count + 1))
        if [[ "$current_norm" != "$desired_norm" ]]; then
            changed=1
            changed_count=$((changed_count + 1))
            log "- ${key}: current=${current_norm} -> desired=${desired_norm}"
        else
            unchanged_count=$((unchanged_count + 1))
        fi
    done < "$config_file"

    if [[ "$changed" -eq 0 ]]; then
        log "- 当前运行时已与建议配置一致"
    fi
    log "- 差异统计: compared=${compared_count} changed=${changed_count} unchanged=${unchanged_count}"
}

save_runtime_backup() {
    local config_file="$1"
    local runtime_file="${STATE_DIR}/last-runtime.conf"
    local line key current
    mkdir -p "$STATE_DIR"
    : > "$runtime_file"
    while IFS= read -r line; do
        [[ -n "$(trim "$line")" ]] || continue
        [[ "${line#\#}" == "$line" ]] || continue
        key="$(trim "${line%%=*}")"
        [[ -n "$key" ]] || continue
        current="$(sysctl -n "$key" 2>/dev/null || true)"
        if [[ -n "$current" ]]; then
            printf '%s = %s\n' "$key" "$current" >> "$runtime_file"
        fi
    done < "$config_file"
}

save_file_backup() {
    mkdir -p "$STATE_DIR"
    if [[ -f "$CONF_PATH" ]]; then
        cp "$CONF_PATH" "${STATE_DIR}/last-file.conf"
        printf '1\n' > "${STATE_DIR}/last-file-existed"
    else
        rm -f "${STATE_DIR}/last-file.conf"
        printf '0\n' > "${STATE_DIR}/last-file-existed"
    fi
}

apply_sysctl_file() {
    local config_file="$1"
    local output rc
    set +e
    output="$(sysctl -p "$config_file" 2>&1)"
    rc=$?
    set -e
    if [[ -n "$output" ]]; then
        log "sysctl 输出:"
        printf '%s\n' "$output"
    fi
    [[ "$rc" -eq 0 ]] || return 1
}

command_probe() {
    gather_context
    print_probe_summary
}

command_recommend() {
    local tmp_config=""
    gather_context
    resolve_decision_inputs
    if [[ "$CONFIG_ONLY" -eq 1 ]]; then
        build_config
        return
    fi
    if [[ "$SHOW_DIFF" -eq 1 ]]; then
        tmp_config="$(mktemp /tmp/tcp-auto-tune.recommend.XXXXXX)"
        trap '[[ -n "${tmp_config:-}" ]] && rm -f "$tmp_config"' RETURN
        build_config > "$tmp_config"
    fi
    print_probe_summary
    print_recommend_summary
    if [[ "$SHOW_DIFF" -eq 1 ]]; then
        print_runtime_diff_from_file "$tmp_config"
    fi
    log "生成配置:"
    if [[ "$SHOW_DIFF" -eq 1 ]]; then
        cat "$tmp_config"
    else
        build_config
    fi
    if [[ -n "$tmp_config" ]]; then
        rm -f "$tmp_config"
        trap - RETURN
    fi
}

command_apply() {
    local tmp_config=""
    require_root
    gather_context
    resolve_decision_inputs
    print_probe_summary
    print_recommend_summary
    tmp_config="$(mktemp /tmp/tcp-auto-tune.XXXXXX)"
    trap '[[ -n "${tmp_config:-}" ]] && rm -f "$tmp_config"' RETURN
    build_config > "$tmp_config"
    if [[ "$SHOW_DIFF" -eq 1 ]]; then
        print_runtime_diff_from_file "$tmp_config"
    fi
    save_runtime_backup "$tmp_config"
    save_file_backup
    mkdir -p "$(dirname "$CONF_PATH")"
    cp "$tmp_config" "$CONF_PATH"
    chmod 644 "$CONF_PATH"
    if ! apply_sysctl_file "$CONF_PATH"; then
        log "sysctl 应用失败，正在回滚..."
        local _rollback_ok=0
        apply_sysctl_file "${STATE_DIR}/last-runtime.conf" && _rollback_ok=1
        if [[ -f "${STATE_DIR}/last-file-existed" && "$(cat "${STATE_DIR}/last-file-existed")" == "1" && -f "${STATE_DIR}/last-file.conf" ]]; then
            cp "${STATE_DIR}/last-file.conf" "$CONF_PATH"
        else
            rm -f "$CONF_PATH"
        fi
        if [[ "$_rollback_ok" -eq 1 ]]; then
            die "sysctl 应用失败，已自动回滚至 apply 前状态"
        else
            die "sysctl 应用失败，且回滚快照重播也失败，请手工核对当前 sysctl 状态"
        fi
    fi
    log "已应用: ${CONF_PATH}"
    rm -f "$tmp_config"
    trap - RETURN
}

command_rollback() {
    local runtime_file="${STATE_DIR}/last-runtime.conf"
    local existed_file="${STATE_DIR}/last-file-existed"
    require_root
    [[ -f "$runtime_file" ]] || die "找不到运行时回滚快照: $runtime_file"
    apply_sysctl_file "$runtime_file" || die "回滚失败：sysctl 无法重播快照 $runtime_file"
    if [[ -f "$existed_file" && "$(cat "$existed_file")" == "1" && -f "${STATE_DIR}/last-file.conf" ]]; then
        cp "${STATE_DIR}/last-file.conf" "$CONF_PATH"
    else
        rm -f "$CONF_PATH"
    fi
    log "已回滚最近一次 tcp-auto-tune 应用"
}

parse_args "$@"
require_file "$AWK_ENGINE_V4"
require_file "$AWK_ENGINE_V5"

case "$COMMAND" in
    probe)
        command_probe
        ;;
    recommend)
        command_recommend
        ;;
    apply)
        command_apply
        ;;
    rollback)
        command_rollback
        ;;
    help|-h|--help)
        show_help
        ;;
    *)
        die "未知命令: $COMMAND，可选 probe/recommend/apply/rollback"
        ;;
esac

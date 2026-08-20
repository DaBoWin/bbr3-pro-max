#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# mihomo VLESS Reality 一键服务端
#
# 不带参数运行 = 进入交互菜单。
#
# 也支持直接用子命令（便于脚本化调用）：
#   install
#   status
#   info
#   diagnose
#   restart
#   add-user <username>
#   del-user <username>
#   list-user
#   uninstall
#   menu
#
# 默认：
#   Port = 随机高位端口（20000-60000）
#   SNI  = www.apple.com
#   DEST = www.apple.com:443
#
# 自定义：
#   SNI=www.microsoft.com \
#   DEST=www.microsoft.com:443 \
#   bash install-mihomo-vless.sh
#
# ============================================================

export DEBIAN_FRONTEND=noninteractive

APP_NAME="mihomo"
SCRIPT_VERSION="1.3.0"

BIN="/usr/local/bin/mihomo"
CONF_DIR="/etc/mihomo"
CONF_FILE="${CONF_DIR}/config.yaml"
USERS_FILE="${CONF_DIR}/users"
INFO_FILE="${CONF_DIR}/node-info"
SERVER_ENV="${CONF_DIR}/server.env"
CLIENT_DIR="${CONF_DIR}/clients"
SNELL_BIN="/usr/local/bin/snell-server"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
SNELL_SERVICE_FILE="/etc/systemd/system/snell.service"

SERVICE_FILE="/etc/systemd/system/mihomo.service"

PORT="${PORT:-}"
TUIC_PORT="${TUIC_PORT:-}"
SNELL_PORT="${SNELL_PORT:-}"
SNI="${SNI:-www.apple.com}"
DEST="${DEST:-${SNI}:443}"
TUIC_UUID="${TUIC_UUID:-}"
TUIC_PASSWORD="${TUIC_PASSWORD:-}"
SNELL_PSK="${SNELL_PSK:-}"
TUIC_CERT="${CONF_DIR}/tuic-cert.pem"
TUIC_KEY="${CONF_DIR}/tuic-key.pem"

# 记录"用户显式用环境变量指定"的端口。
# server.env 载入之后要把它们盖回来，保证环境变量优先级最高。
ENV_PORT="${PORT}"
ENV_TUIC_PORT="${TUIC_PORT}"
ENV_SNELL_PORT="${SNELL_PORT}"

# 可重复调用版本：菜单每次回到主界面都会刷新，
# 否则安装/卸载之后界面上显示的还是旧端口。
refresh_settings() {

    if [[ -r "${SERVER_ENV}" ]]; then
        # shellcheck disable=SC1090
        source "${SERVER_ENV}"
    else
        PORT="${ENV_PORT}"
        TUIC_PORT="${ENV_TUIC_PORT}"
        SNELL_PORT="${ENV_SNELL_PORT}"
    fi

    if [[ -n "${ENV_PORT}" ]]; then
        PORT="${ENV_PORT}"
    fi

    if [[ -n "${ENV_TUIC_PORT}" ]]; then
        TUIC_PORT="${ENV_TUIC_PORT}"
    fi

    if [[ -n "${ENV_SNELL_PORT}" ]]; then
        SNELL_PORT="${ENV_SNELL_PORT}"
    fi
}

TMP_DIR="$(mktemp -d /tmp/mihomo-install.XXXXXX)"

cleanup() {
    rm -rf "${TMP_DIR}" 2>/dev/null || true
}

trap cleanup EXIT

# ============================================================
# 基础函数
# ============================================================

log() {
    echo "[+] $*"
}

warn() {
    echo "[!] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
}

die() {
    error "$*"
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "请使用 root 运行。"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================================
# 交互输入
# ============================================================

# 用 `bash <(curl ...)` 运行时 stdin 还是终端，直接 read 没问题；
# 但用 `curl ... | bash` 运行时 stdin 是脚本正文，read 会读到脚本内容。
# 所以优先从 /dev/tty 读，两种方式都能正常交互。
ask() {
    local prompt="$1"
    local varname="$2"
    local value=""

    if [[ -r /dev/tty ]]; then
        read -r -p "${prompt}" value < /dev/tty || return 1
    else
        read -r -p "${prompt}" value || return 1
    fi

    printf -v "${varname}" '%s' "${value}"
}

interactive_available() {
    [[ -r /dev/tty ]] || [[ -t 0 ]]
}

pause() {
    local discard=""

    echo
    ask "按回车继续..." discard || true
}

confirm() {
    local prompt="$1"
    local answer=""

    ask "${prompt} [y/N]： " answer || return 1

    [[ "${answer}" == "y" || "${answer}" == "Y" ]]
}

# ============================================================
# 安装状态 / 服务状态
# ============================================================

is_installed() {
    # 不要用 `systemctl list-unit-files | grep -q`：
    # grep -q 命中后立即退出，上游 systemctl 还在输出剩余 unit，
    # 会被 SIGPIPE 杀掉（退出码 141）。脚本开了 set -o pipefail，
    # 整条管道因此被判为失败，导致装好了也报"尚未安装"。
    # 这里改成既不经过管道、也不依赖 systemctl 输出格式的判断。
    [[ -f "${SERVICE_FILE}" ]] ||
        systemctl cat mihomo.service >/dev/null 2>&1
}

# 输出：运行中 / 已停止 / 未安装
unit_state() {
    local unit="$1"

    if ! systemctl cat "${unit}.service" >/dev/null 2>&1 &&
        [[ ! -f "/etc/systemd/system/${unit}.service" ]]; then
        echo "未安装"
        return
    fi

    if systemctl is-active --quiet "${unit}" 2>/dev/null; then
        echo "运行中"
    else
        echo "已停止"
    fi
}

# 检查某端口是否处于监听状态，打印带标记的一行。
# 注意 grep 无匹配会返回 1，这里必须 || true，否则 set -e 直接退出。
check_listen() {
    local proto="$1"
    local port="$2"
    local label="$3"
    local found=""

    if [[ -z "${port}" ]]; then
        printf "  [ -- ] %-6s %s %-6s 未配置\n" "${label}" "${proto}" "-"
        return
    fi

    if [[ "${proto}" == "udp" ]]; then
        found="$(ss -lunpH 2>/dev/null | grep -E ":${port}[[:space:]]" || true)"
    else
        found="$(ss -lntpH 2>/dev/null | grep -E ":${port}[[:space:]]" || true)"
    fi

    if [[ -n "${found}" ]]; then
        printf "  [ OK ] %-6s %s %-6s 正在监听\n" "${label}" "${proto}" "${port}"
    else
        printf "  [FAIL] %-6s %s %-6s 未监听\n" "${label}" "${proto}" "${port}"
    fi
}

# ============================================================
# 检查系统
# ============================================================

check_os() {

    [[ -f /etc/os-release ]] ||
        die "无法检测系统。"

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID}" in
        debian|ubuntu)
            ;;
        *)
            die "不支持的系统：${PRETTY_NAME:-${ID}}"
            ;;
    esac

    log "系统：${PRETTY_NAME:-${ID}}"

    if command_exists systemd-detect-virt; then
        VIRT="$(systemd-detect-virt 2>/dev/null || true)"

        if [[ -n "${VIRT}" && "${VIRT}" != "none" ]]; then
            log "虚拟化环境：${VIRT}"
        fi
    fi
}

# ============================================================
# 安装系统依赖
# ============================================================

install_dependencies() {

    log "安装系统依赖..."

    apt-get update -y

    # 注意：
    # Debian 13 中 awk 是虚拟包，不能：
    #
    #   apt install awk
    #
    # 所以这里只安装真正需要的包。
    apt-get install -y \
        ca-certificates \
        curl \
        wget \
        gzip \
        unzip \
        openssl \
        uuid-runtime \
        iproute2 \
        procps \
        nftables \
        jq \
        socat

    # awk 应该由 Debian 基础系统提供。
    if ! command_exists awk; then
        log "系统没有 awk，安装 mawk..."
        apt-get install -y mawk
    fi

    local required_commands=(
        curl
        wget
        gzip
        openssl
        uuidgen
        ip
        ss
        jq
        awk
        sed
        grep
    )

    local cmd

    for cmd in "${required_commands[@]}"; do
        if ! command_exists "${cmd}"; then
            die "缺少必要命令：${cmd}"
        fi
    done

    log "系统依赖检查通过。"
}

# ============================================================
# CPU 架构
# ============================================================

detect_arch() {

    ARCH="$(uname -m)"

    case "${ARCH}" in

        x86_64|amd64)
            TARGET_ARCH="amd64"
            ;;

        aarch64|arm64)
            TARGET_ARCH="arm64"
            ;;

        armv7l|armv7)
            TARGET_ARCH="armv7"
            ;;

        *)
            die "暂不支持 CPU 架构：${ARCH}"
            ;;
    esac

    log "CPU 架构：${ARCH}"
}

# ============================================================
# 获取 mihomo 最新稳定版
# ============================================================

get_mihomo_release() {

    log "获取 mihomo 最新稳定版..."

    RELEASE_JSON="$(
        curl -fsSL \
            --retry 3 \
            --connect-timeout 10 \
            --max-time 30 \
            "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    )" || die "无法访问 GitHub API。"

    MIHOMO_VERSION="$(
        echo "${RELEASE_JSON}" |
        jq -r '.tag_name // empty'
    )"

    [[ -n "${MIHOMO_VERSION}" ]] ||
        die "无法获取 mihomo 版本。"

    log "mihomo 版本：${MIHOMO_VERSION}"
}

# ============================================================
# 根据 Release Asset 自动选择下载文件
# ============================================================

download_mihomo() {

    log "查找对应架构的 mihomo 二进制..."

    local assets

    assets="$(
        echo "${RELEASE_JSON}" |
        jq -r '.assets[].name'
    )"

    [[ -n "${assets}" ]] ||
        die "Release 中没有找到 Assets。"

    local asset=""

    case "${TARGET_ARCH}" in

        amd64)

            # 优先使用 compatible，兼容范围最大。
            asset="$(
                echo "${assets}" |
                grep -E "^mihomo-linux-amd64-compatible-${MIHOMO_VERSION}\.gz$" |
                head -n1 || true
            )"

            # 如果没有 compatible，则尝试普通 amd64。
            if [[ -z "${asset}" ]]; then
                asset="$(
                    echo "${assets}" |
                    grep -E "^mihomo-linux-amd64(-v[0-9]+)?-${MIHOMO_VERSION}\.gz$" |
                    head -n1 || true
                )"
            fi
            ;;

        arm64)

            asset="$(
                echo "${assets}" |
                grep -E "^mihomo-linux-arm64-v8-${MIHOMO_VERSION}\.gz$" |
                head -n1 || true
            )"

            if [[ -z "${asset}" ]]; then
                asset="$(
                    echo "${assets}" |
                    grep -E "^mihomo-linux-arm64-${MIHOMO_VERSION}\.gz$" |
                    head -n1 || true
                )"
            fi
            ;;

        armv7)

            asset="$(
                echo "${assets}" |
                grep -E "^mihomo-linux-armv7-${MIHOMO_VERSION}\.gz$" |
                head -n1 || true
            )"
            ;;

    esac

    [[ -n "${asset}" ]] ||
        die "没有找到 ${TARGET_ARCH} 对应的 mihomo Release 文件。"

    log "下载文件：${asset}"

    local download_url

    download_url="$(
        echo "${RELEASE_JSON}" |
        jq -r \
            --arg name "${asset}" \
            '.assets[] | select(.name == $name) | .browser_download_url'
    )"

    [[ -n "${download_url}" ]] ||
        die "无法获取下载地址。"

    curl -fL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 180 \
        "${download_url}" \
        -o "${TMP_DIR}/mihomo.gz" ||
        die "下载 mihomo 失败。"

    gzip -dc \
        "${TMP_DIR}/mihomo.gz" \
        > "${TMP_DIR}/mihomo" ||
        die "解压 mihomo 失败。"

    chmod +x "${TMP_DIR}/mihomo"

    # 基础运行测试
    "${TMP_DIR}/mihomo" -v >/dev/null 2>&1 ||
        die "下载的 mihomo 无法运行。"

    install -m 0755 \
        "${TMP_DIR}/mihomo" \
        "${BIN}"

    log "mihomo 安装完成。"

    "${BIN}" -v || true
}

# ============================================================
# 创建系统用户
# ============================================================

create_system_user() {

    if ! id mihomo >/dev/null 2>&1; then

        log "创建 mihomo 系统用户..."

        useradd \
            --system \
            --no-create-home \
            --shell /usr/sbin/nologin \
            mihomo
    fi

    mkdir -p \
        "${CONF_DIR}" \
        "${CLIENT_DIR}"

    touch "${USERS_FILE}"

    chown -R mihomo:mihomo "${CONF_DIR}"

    chmod 755 "${CONF_DIR}"
    chmod 700 "${CLIENT_DIR}"
    chmod 600 "${USERS_FILE}"
}

# ============================================================
# 公网 IPv4
# ============================================================

detect_ipv4() {

    log "检测公网 IPv4..."

    PUBLIC_IPV4=""

    local apis=(
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://ifconfig.me/ip"
    )

    local api
    local result

    for api in "${apis[@]}"; do

        result="$(
            curl -4fsSL \
                --connect-timeout 5 \
                --max-time 10 \
                "${api}" 2>/dev/null |
            tr -d '[:space:]' || true
        )"

        if [[ "${result}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            PUBLIC_IPV4="${result}"
            break
        fi
    done

    [[ -n "${PUBLIC_IPV4}" ]] ||
        die "无法检测公网 IPv4。"

    log "公网 IPv4：${PUBLIC_IPV4}"
}

# ============================================================
# 公网 IPv6
# ============================================================

detect_ipv6() {

    log "检测公网 IPv6..."

    PUBLIC_IPV6=""

    local apis=(
        "https://api6.ipify.org"
        "https://ipv6.icanhazip.com"
    )

    local api
    local result

    for api in "${apis[@]}"; do

        result="$(
            curl -6fsSL \
                --connect-timeout 5 \
                --max-time 10 \
                "${api}" 2>/dev/null |
            tr -d '[:space:]' || true
        )"

        if [[ "${result}" == *:* ]]; then
            PUBLIC_IPV6="${result}"
            break
        fi
    done

    if [[ -n "${PUBLIC_IPV6}" ]]; then
        log "公网 IPv6：${PUBLIC_IPV6}"
    else
        warn "未检测到公网 IPv6。"
    fi
}

# ============================================================
# IPv6 / IP Forwarding
# ============================================================

configure_network() {

    log "配置 IPv4 / IPv6 网络参数..."

    cat > /etc/sysctl.d/99-mihomo-network.conf <<'EOF'
# mihomo network configuration

net.ipv4.ip_forward=1

net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0

net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
EOF

    sysctl --system >/dev/null 2>&1 || true

    if [[ -n "${PUBLIC_IPV6}" ]]; then
        log "IPv6 已检测到并保持启用。"
    else
        warn "当前 VPS 没有可用公网 IPv6，不会人为伪造 IPv6 配置。"
    fi
}

# ============================================================
# BBR
# ============================================================

configure_bbr() {

    log "检测 BBR..."

    if [[ ! -f /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
        warn "当前内核无法检测 TCP 拥塞控制算法。"
        return
    fi

    local available
    available="$(
        cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null ||
        true
    )"

    if echo "${available}" | grep -qw bbr; then

        cat > /etc/sysctl.d/99-mihomo-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

        sysctl --system >/dev/null 2>&1 || true

        local current
        current="$(
            cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null ||
            true
        )"

        if [[ "${current}" == "bbr" ]]; then
            log "BBR 已启用。"
        else
            warn "内核支持 BBR，但当前算法为：${current}"
        fi

    else

        warn "当前 Linux 内核没有 BBR。"
        warn "不会自动替换内核，以避免破坏 VPS。"

    fi
}

# ============================================================
# 选择并检查监听端口
# ============================================================

port_is_available() {
    ss -lntH 2>/dev/null |
        awk -v port="${1}" '$4 ~ (":" port "$") { found = 1 } END { exit(found ? 1 : 0) }'
}

select_port() {
    if [[ -n "${PORT}" ]]; then
        [[ "${PORT}" =~ ^[0-9]+$ ]] &&
            (( PORT >= 1024 && PORT <= 65535 )) ||
            die "PORT 必须是 1024-65535 之间的整数。"
        return
    fi

    local candidate
    for _ in {1..100}; do
        candidate="$((20000 + ((RANDOM << 1 | RANDOM & 1)) % 40001))"
        if port_is_available "${candidate}"; then
            PORT="${candidate}"
            log "随机 VLESS 监听端口：${PORT}"
            return
        fi
    done

    die "无法找到可用的随机 TCP 端口。"
}

select_aux_port() {
    local variable_name="$1"
    local label="$2"
    local current="${!variable_name}"
    local candidate

    if [[ -n "${current}" ]]; then
        [[ "${current}" =~ ^[0-9]+$ ]] &&
            (( current >= 1024 && current <= 65535 )) ||
            die "${label}端口必须是 1024-65535 之间的整数。"
        if ! port_is_available "${current}"; then
            die "${label}端口 ${current} 已被占用。"
        fi
        return
    fi

    for _ in {1..100}; do
        candidate="$((20000 + ((RANDOM << 1 | RANDOM & 1)) % 40001))"
        if [[ "${candidate}" != "${PORT}" ]] && port_is_available "${candidate}"; then
            printf -v "${variable_name}" '%s' "${candidate}"
            log "随机 ${label}监听端口：${candidate}"
            return
        fi
    done

    die "无法为 ${label} 找到可用的随机端口。"
}

check_port() {
    log "检查 TCP ${PORT}..."

    if ! port_is_available "${PORT}"; then
        die "TCP ${PORT} 已被其他程序占用。"
    fi
}

# ============================================================
# 防火墙
# ============================================================

configure_firewall() {

    log "配置防火墙..."

    # UFW
    if command_exists ufw; then

        if ufw status 2>/dev/null |
            grep -q "Status: active"; then

            ufw allow "${PORT}/tcp" >/dev/null || true
            ufw allow "${PORT}/udp" >/dev/null || true
            ufw allow "${TUIC_PORT}/tcp" >/dev/null || true
            ufw allow "${TUIC_PORT}/udp" >/dev/null || true
            ufw allow "${SNELL_PORT}/tcp" >/dev/null || true
            ufw allow "${SNELL_PORT}/udp" >/dev/null || true

            log "UFW：已放行 VLESS ${PORT}、TUIC ${TUIC_PORT}、Snell ${SNELL_PORT}。"
        fi
    fi

    # firewalld
    if command_exists firewall-cmd; then

        if systemctl is-active --quiet firewalld 2>/dev/null; then

            firewall-cmd \
                --permanent \
                --add-port="${PORT}/tcp" >/dev/null || true
            firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null || true
            firewall-cmd --permanent --add-port="${TUIC_PORT}/tcp" >/dev/null || true
            firewall-cmd --permanent --add-port="${TUIC_PORT}/udp" >/dev/null || true
            firewall-cmd --permanent --add-port="${SNELL_PORT}/tcp" >/dev/null || true
            firewall-cmd --permanent --add-port="${SNELL_PORT}/udp" >/dev/null || true

            firewall-cmd \
                --reload >/dev/null || true

            log "firewalld：已放行 VLESS ${PORT}、TUIC ${TUIC_PORT}、Snell ${SNELL_PORT}。"
        fi
    fi

    warn "如果 VPS 使用云厂商安全组，请放行 VLESS TCP ${PORT}、TUIC UDP ${TUIC_PORT}、Snell TCP/UDP ${SNELL_PORT}。"
}

# ============================================================
# 生成 UUID
# ============================================================

generate_uuid() {
    uuidgen
}

# ============================================================
# 生成 Reality Key
# ============================================================

generate_reality_keypair() {

    log "生成 Reality KeyPair..."

    local output

    output="$("${BIN}" generate reality-keypair)" ||
        die "Reality KeyPair 生成失败。"

    PRIVATE_KEY="$(
        echo "${output}" |
        sed -n 's/^PrivateKey: *//p' |
        head -n1 |
        tr -d '[:space:]'
    )"

    PUBLIC_KEY="$(
        echo "${output}" |
        sed -n 's/^PublicKey: *//p' |
        head -n1 |
        tr -d '[:space:]'
    )"

    [[ -n "${PRIVATE_KEY}" ]] ||
        die "没有获取到 Reality PrivateKey。"

    [[ -n "${PUBLIC_KEY}" ]] ||
        die "没有获取到 Reality PublicKey。"

    log "Reality KeyPair 生成完成。"
}

# ============================================================
# Short ID
# ============================================================

generate_short_id() {

    SHORT_ID="$(openssl rand -hex 8)"

    log "Reality Short ID：${SHORT_ID}"
}

# ============================================================
# TUIC / Snell 凭据和服务
# ============================================================

generate_aux_credentials() {
    [[ -n "${TUIC_UUID}" ]] || TUIC_UUID="$(generate_uuid)"
    [[ -n "${TUIC_PASSWORD}" ]] || TUIC_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
    [[ -n "${SNELL_PSK}" ]] || SNELL_PSK="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)"

    mkdir -p "${SNELL_CONF_DIR}"

    if [[ ! -s "${TUIC_CERT}" || ! -s "${TUIC_KEY}" ]]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "${TUIC_KEY}" \
            -out "${TUIC_CERT}" \
            -days 3650 \
            -subj "/CN=${SNI}" >/dev/null 2>&1 ||
            die "TUIC 证书生成失败。"
    fi

    chmod 600 "${TUIC_KEY}"
    chmod 644 "${TUIC_CERT}"

    # 证书位于 ${CONF_DIR}（mihomo SAFE_PATHS 允许的目录），
    # 由 root 通过 openssl 生成；私钥为 600 权限，必须让 mihomo 服务用户可读。
    chown mihomo:mihomo "${TUIC_KEY}" "${TUIC_CERT}" 2>/dev/null || true
}

write_snell_config() {
    mkdir -p "${SNELL_CONF_DIR}"

    # snell-server v4/v5 只接受 listen / psk / ipv6 / dns / egress-interface。
    # obfs、obfs-host 在 v4 之后已移除；version 由二进制本身决定，不是配置项。
    # 写入这些无效键会让服务端与开启 obfs 的客户端握手失败（表现为"能连上端口但不通"）。
    cat > "${SNELL_CONF_FILE}" <<EOF
[snell-server]
listen = 0.0.0.0:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = false
EOF

    chmod 600 "${SNELL_CONF_FILE}"
}

install_snell() {
    [[ "${TARGET_ARCH}" == "amd64" ]] ||
        die "Snell v5 自动安装目前仅支持 amd64。"

    local snell_url="${SNELL_URL:-https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip}"

    log "下载 Snell v5..."
    curl -fL --retry 3 --connect-timeout 15 --max-time 120 \
        "${snell_url}" -o "${TMP_DIR}/snell.zip" ||
        die "Snell v5 下载失败。"

    unzip -p "${TMP_DIR}/snell.zip" snell-server > "${TMP_DIR}/snell-server" ||
        die "Snell v5 压缩包格式无效。"

    chmod 0755 "${TMP_DIR}/snell-server"
    install -m 0755 "${TMP_DIR}/snell-server" "${SNELL_BIN}"
    write_snell_config
}

create_snell_systemd() {
    cat > "${SNELL_SERVICE_FILE}" <<EOF
[Unit]
Description=Snell v5 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SNELL_BIN} -c ${SNELL_CONF_FILE}
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snell >/dev/null
}

start_snell() {
    systemctl restart snell
    sleep 2
    if ! systemctl is-active --quiet snell; then
        warn "Snell v5 启动失败。"
        journalctl -u snell --no-pager -n 80 || true
        die "Snell v5 服务未能启动。"
    fi
    log "Snell v5 正常运行。"
}

# ============================================================
# 初始化用户
# ============================================================

initialize_user() {

    if [[ -s "${USERS_FILE}" ]]; then

        FIRST_LINE="$(head -n1 "${USERS_FILE}")"

        DEFAULT_USERNAME="$(echo "${FIRST_LINE}" | cut -d'|' -f1)"
        DEFAULT_UUID="$(echo "${FIRST_LINE}" | cut -d'|' -f2)"

        return
    fi

    DEFAULT_USERNAME="user1"
    DEFAULT_UUID="$(generate_uuid)"

    echo "${DEFAULT_USERNAME}|${DEFAULT_UUID}" > "${USERS_FILE}"

    chmod 600 "${USERS_FILE}"

    log "初始用户：${DEFAULT_USERNAME}"
}

# ============================================================
# 写入 mihomo 配置
# ============================================================

write_config() {

    log "生成 mihomo 配置..."

    cat > "${CONF_FILE}" <<EOF
mixed-port: 7890
mode: direct
log-level: info
ipv6: true

listeners:
  - name: vless-reality
    type: vless
    listen: 0.0.0.0
    port: ${PORT}

    users:
EOF

    while IFS='|' read -r username uuid; do

        [[ -n "${username}" ]] || continue
        [[ -n "${uuid}" ]] || continue

        cat >> "${CONF_FILE}" <<EOF
      - username: ${username}
        uuid: ${uuid}
        flow: xtls-rprx-vision
EOF

    done < "${USERS_FILE}"

    cat >> "${CONF_FILE}" <<EOF

    reality-config:
      dest: ${DEST}
      private-key: ${PRIVATE_KEY}

      short-id:
        - ${SHORT_ID}

      server-names:
        - ${SNI}
EOF

    cat >> "${CONF_FILE}" <<EOF

  - name: tuic
    type: tuic
    listen: 0.0.0.0
    port: ${TUIC_PORT}
    users:
      ${TUIC_UUID}: ${TUIC_PASSWORD}
    certificate: ${TUIC_CERT}
    private-key: ${TUIC_KEY}
    congestion-controller: bbr
    max-idle-time: 15000
    authentication-timeout: 1000
    alpn:
      - h3
EOF

    chmod 600 "${CONF_FILE}"
    chown mihomo:mihomo "${CONF_FILE}"
}

# ============================================================
# 验证 mihomo 配置
# ============================================================

validate_config() {

    log "验证 mihomo 配置..."

    if "${BIN}" \
        -d "${CONF_DIR}" \
        -f "${CONF_FILE}" \
        -t >/dev/null 2>&1; then

        log "mihomo 配置验证通过。"

    else

        echo
        error "mihomo 配置验证失败。"
        echo

        "${BIN}" \
            -d "${CONF_DIR}" \
            -f "${CONF_FILE}" \
            -t || true

        exit 1
    fi
}

# ============================================================
# 创建 systemd
# ============================================================

create_systemd() {

    log "创建 systemd 服务..."

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=mihomo VLESS Reality Server
Documentation=https://wiki.metacubex.one/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

User=mihomo
Group=mihomo

ExecStart=${BIN} -d ${CONF_DIR} -f ${CONF_FILE}

Restart=on-failure
RestartSec=3

LimitNOFILE=1048576

NoNewPrivileges=true

PrivateTmp=true
ProtectHome=true
ProtectSystem=full

ReadWritePaths=${CONF_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mihomo >/dev/null
}

# ============================================================
# 启动 mihomo
# ============================================================

start_mihomo() {

    log "启动 mihomo..."

    systemctl restart mihomo

    sleep 2

    if ! systemctl is-active --quiet mihomo; then

        error "mihomo 启动失败。"

        journalctl \
            -u mihomo \
            --no-pager \
            -n 80

        exit 1
    fi

    log "mihomo 正常运行。"
}

# ============================================================
# 生成 VLESS URI
# ============================================================

make_vless_uri() {

    local uuid="$1"
    local username="$2"
    local address="$3"

    echo "vless://${uuid}@${address}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#mihomo-${username}"
}

make_tuic_uri() {
    local address="$1"
    echo "tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${address}:${TUIC_PORT}?alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1&sni=${SNI}#mihomo-tuic"
}

make_snell_line() {
    local address="$1"
    # 不能带 obfs：snell-server v5 不支持混淆，客户端开启会导致握手失败。
    echo "mihomo-snell = snell, ${address}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, reuse=true, tfo=true"
}

# ============================================================
# 生成客户端配置
# ============================================================

generate_client_configs() {

    log "生成客户端配置..."

    mkdir -p "${CLIENT_DIR}"

    chmod 700 "${CLIENT_DIR}"

    local first_line
    first_line="$(head -n1 "${USERS_FILE}")"

    local username
    local uuid

    username="$(echo "${first_line}" | cut -d'|' -f1)"
    uuid="$(echo "${first_line}" | cut -d'|' -f2)"

    local uri

    uri="$(make_vless_uri "${uuid}" "${username}" "${PUBLIC_IPV4}")"

    echo "${uri}" > "${CLIENT_DIR}/vless-uri.txt"

    # --------------------------------------------------------
    # Mihomo / Clash Meta
    # --------------------------------------------------------

    cat > "${CLIENT_DIR}/mihomo.yaml" <<EOF
proxies:
  - name: mihomo-vless-reality
    type: vless
    server: ${PUBLIC_IPV4}
    port: ${PORT}
    uuid: ${uuid}
    udp: true
    tls: true
    servername: ${SNI}
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
EOF

    # --------------------------------------------------------
    # sing-box
    # --------------------------------------------------------

    cat > "${CLIENT_DIR}/sing-box.json" <<EOF
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "mihomo-vless-reality",
      "server": "${PUBLIC_IPV4}",
      "server_port": ${PORT},
      "uuid": "${uuid}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${PUBLIC_KEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    }
  ]
}
EOF

    # --------------------------------------------------------
    # V2RayN
    # --------------------------------------------------------

    echo "${uri}" > "${CLIENT_DIR}/v2rayn-vless.txt"

    cat > "${CLIENT_DIR}/tuic.yaml" <<EOF
proxies:
  - name: mihomo-tuic
    type: tuic
    server: ${PUBLIC_IPV4}
    port: ${TUIC_PORT}
    uuid: ${TUIC_UUID}
    password: ${TUIC_PASSWORD}
    alpn:
      - h3
    disable-sni: false
    reduce-rtt: true
    udp-relay-mode: native
    congestion-controller: bbr
    skip-cert-verify: true
    sni: ${SNI}
EOF

    cat > "${CLIENT_DIR}/tuic-uri.txt" <<EOF
$(make_tuic_uri "${PUBLIC_IPV4}")
EOF

    cat > "${CLIENT_DIR}/snell-surge.conf" <<EOF
$(make_snell_line "${PUBLIC_IPV4}")
EOF

    # --------------------------------------------------------
    # IPv6 URI
    # --------------------------------------------------------

    if [[ -n "${PUBLIC_IPV6}" ]]; then

        local ipv6_uri

        ipv6_uri="vless://${uuid}@\[${PUBLIC_IPV6}\]:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#mihomo-${username}-IPv6"

        echo "${ipv6_uri}" > "${CLIENT_DIR}/vless-ipv6-uri.txt"

    fi

    chmod 600 "${CLIENT_DIR}"/*

    chown -R mihomo:mihomo "${CLIENT_DIR}"
}

# ============================================================
# 保存服务端信息
# ============================================================

save_info() {

    cat > "${SERVER_ENV}" <<EOF
PORT=${PORT}
TUIC_PORT=${TUIC_PORT}
SNELL_PORT=${SNELL_PORT}
SNI=${SNI}
DEST=${DEST}
PUBLIC_IPV4=${PUBLIC_IPV4}
PUBLIC_IPV6=${PUBLIC_IPV6}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
TUIC_UUID=${TUIC_UUID}
TUIC_PASSWORD=${TUIC_PASSWORD}
SNELL_PSK=${SNELL_PSK}
EOF

    chmod 600 "${SERVER_ENV}"

    chown mihomo:mihomo "${SERVER_ENV}"

    cat > "${INFO_FILE}" <<EOF
============================================================
mihomo VLESS Reality Server
安装脚本版本：${SCRIPT_VERSION}
============================================================

mihomo:
${MIHOMO_VERSION}

Server IPv4:
${PUBLIC_IPV4}

Server IPv6:
${PUBLIC_IPV6:-N/A}

Port:
${PORT}

Protocol:
VLESS

Transport:
TCP

Security:
Reality

SNI:
${SNI}

DEST:
${DEST}

Reality Public Key:
${PUBLIC_KEY}

Reality Short ID:
${SHORT_ID}

Flow:
xtls-rprx-vision

============================================================
FIRST USER
============================================================

Username:
${DEFAULT_USERNAME}

UUID:
${DEFAULT_UUID}

VLESS URI:

$(make_vless_uri "${DEFAULT_UUID}" "${DEFAULT_USERNAME}" "${PUBLIC_IPV4}")

============================================================
TUIC (UDP ${TUIC_PORT})
============================================================

UUID:
${TUIC_UUID}

Password:
${TUIC_PASSWORD}

SNI:
${SNI}

TUIC URI:

$(make_tuic_uri "${PUBLIC_IPV4}")

============================================================
Snell v5 (TCP ${SNELL_PORT})
============================================================

PSK:
${SNELL_PSK}

obfs:
不使用（snell-server v5 已移除混淆，客户端也必须关闭）

Surge:

$(make_snell_line "${PUBLIC_IPV4}")

============================================================
CLIENT FILES
============================================================

Mihomo / Clash:
${CLIENT_DIR}/mihomo.yaml

sing-box:
${CLIENT_DIR}/sing-box.json

V2RayN:
${CLIENT_DIR}/v2rayn-vless.txt

VLESS URI:
${CLIENT_DIR}/vless-uri.txt

TUIC:
${CLIENT_DIR}/tuic.yaml
${CLIENT_DIR}/tuic-uri.txt

Snell v5 / Surge:
${CLIENT_DIR}/snell-surge.conf

============================================================
EOF

    if [[ -n "${PUBLIC_IPV6}" ]]; then

        cat >> "${INFO_FILE}" <<EOF

IPv6 VLESS URI:

$(cat "${CLIENT_DIR}/vless-ipv6-uri.txt")

EOF

    fi

    chmod 600 "${INFO_FILE}"
    chown mihomo:mihomo "${INFO_FILE}"
}

# ============================================================
# 安装
# ============================================================

install_all() {

    require_root

    echo
    echo "============================================================"
    echo "          mihomo VLESS Reality 一键安装器"
    echo "                 版本 ${SCRIPT_VERSION}"
    echo "============================================================"
    echo

    check_os
    install_dependencies
    detect_arch
    get_mihomo_release
    download_mihomo

    mkdir -p "${CONF_DIR}" "${CLIENT_DIR}"

    create_system_user

    detect_ipv4
    detect_ipv6

    # 重装场景：先停止已有服务，释放它们占用的端口，
    # 否则从 server.env 载入的旧 PORT 会被正在运行的旧实例占用，导致 check_port 失败。
    log "停止可能正在运行的旧服务（如果存在）..."
    systemctl stop mihomo 2>/dev/null || true
    systemctl stop snell 2>/dev/null || true
    # 兜底：清理不受 systemd 管理的残留进程（否则孤儿进程会继续占用端口）。
    pkill -x mihomo 2>/dev/null || true
    pkill -x snell-server 2>/dev/null || true
    sleep 1

    select_port
    select_aux_port TUIC_PORT "TUIC"
    select_aux_port SNELL_PORT "Snell"
    check_port
    generate_aux_credentials

    generate_reality_keypair
    generate_short_id

    initialize_user

    configure_network
    configure_bbr

    write_config
    validate_config

    create_systemd
    install_snell
    create_snell_systemd

    configure_firewall

    save_info
    generate_client_configs

    start_mihomo
    start_snell

    echo
    echo "============================================================"
    echo "                 安装完成"
    echo "============================================================"
    echo
    echo "脚本版本：${SCRIPT_VERSION}"
    echo "mihomo：${MIHOMO_VERSION}"
    echo
    echo "服务器 IPv4：${PUBLIC_IPV4}"
    echo "服务器 IPv6：${PUBLIC_IPV6:-未检测到}"
    echo
    echo "SNI：${SNI}"
    echo "DEST：${DEST}"
    echo
    echo "------------------------------------------------------------"
    echo "VLESS Reality  (TCP ${PORT})"
    echo "------------------------------------------------------------"
    echo
    make_vless_uri \
        "${DEFAULT_UUID}" \
        "${DEFAULT_USERNAME}" \
        "${PUBLIC_IPV4}"
    echo
    echo "------------------------------------------------------------"
    echo "TUIC  (UDP ${TUIC_PORT})"
    echo "------------------------------------------------------------"
    echo
    make_tuic_uri "${PUBLIC_IPV4}"
    echo
    echo "------------------------------------------------------------"
    echo "Snell v5  (TCP ${SNELL_PORT})"
    echo "------------------------------------------------------------"
    echo
    make_snell_line "${PUBLIC_IPV4}"
    echo
    echo "------------------------------------------------------------"
    echo "客户端配置"
    echo "------------------------------------------------------------"
    echo
    echo "Mihomo / Clash："
    echo "${CLIENT_DIR}/mihomo.yaml"
    echo
    echo "sing-box："
    echo "${CLIENT_DIR}/sing-box.json"
    echo
    echo "V2RayN："
    echo "${CLIENT_DIR}/v2rayn-vless.txt"
    echo
    echo "完整节点信息："
    echo "${INFO_FILE}"
    echo
    echo "------------------------------------------------------------"
    echo "管理命令"
    echo "------------------------------------------------------------"
    echo
    echo "交互菜单（推荐，不带参数即可）："
    echo "  $0"
    echo
    echo "状态："
    echo "  $0 status"
    echo
    echo "诊断（TUIC/端口/证书/防火墙）："
    echo "  $0 diagnose"
    echo
    echo "重启："
    echo "  $0 restart"
    echo
    echo "添加用户："
    echo "  $0 add-user alice"
    echo
    echo "删除用户："
    echo "  $0 del-user alice"
    echo
    echo "用户列表："
    echo "  $0 list-user"
    echo
    echo "卸载："
    echo "  $0 uninstall"
    echo
    echo "日志："
    echo "  journalctl -u mihomo -f"
    echo
    echo "============================================================"
}

# ============================================================
# status
# ============================================================

show_status() {

    require_root

    echo
    echo "============================================================"
    echo "mihomo status    (脚本版本 ${SCRIPT_VERSION})"
    echo "============================================================"
    echo

    if is_installed; then

        systemctl \
            --no-pager \
            --full \
            status mihomo || true

    else

        echo "mihomo 尚未安装。"
    fi

    echo
    echo "============================================================"
    echo "监听端口"
    echo "============================================================"
    echo

    check_listen tcp "${PORT}" "VLESS"
    check_listen udp "${TUIC_PORT}" "TUIC"
    check_listen tcp "${SNELL_PORT}" "Snell"

    echo

    if [[ -f "${INFO_FILE}" ]]; then

        echo "============================================================"
        echo "节点信息"
        echo "============================================================"
        echo

        cat "${INFO_FILE}"
    fi
}

# ============================================================
# 查看节点信息
# ============================================================

show_nodes() {

    require_root

    [[ -f "${INFO_FILE}" ]] ||
        die "找不到 ${INFO_FILE}，请先安装节点。"

    cat "${INFO_FILE}"
}

# ============================================================
# 诊断
# ============================================================

diagnose() {

    require_root

    echo
    echo "============================================================"
    echo "连通性诊断"
    echo "============================================================"
    echo

    echo "服务状态："
    printf "  mihomo : %s\n" "$(unit_state mihomo)"
    printf "  snell  : %s\n" "$(unit_state snell)"
    echo

    echo "本机监听："
    check_listen tcp "${PORT}" "VLESS"
    check_listen udp "${TUIC_PORT}" "TUIC"
    check_listen tcp "${SNELL_PORT}" "Snell"
    echo

    # --------------------------------------------------------
    # TUIC 证书。
    # 之前 TUIC 起不来就是这里：证书生成在 /etc/snell 且属主是 root，
    # 而 mihomo 以 mihomo 用户运行，读不到私钥，listener 静默失败。
    # --------------------------------------------------------

    echo "TUIC 证书："

    local cert_path="${TUIC_CERT}"
    local key_path="${TUIC_KEY}"
    local from_conf=""

    if [[ -r "${CONF_FILE}" ]]; then

        # certificate: 只出现在 tuic listener。
        # private-key: 在 reality-config 里也有（值是 base64 密钥而不是路径），
        # 所以只取"值以 / 开头"的那一行。
        from_conf="$(
            awk '/^[[:space:]]*certificate:[[:space:]]*\// { print $2; exit }' \
                "${CONF_FILE}"
        )"

        if [[ -n "${from_conf}" ]]; then
            cert_path="${from_conf}"
        fi

        from_conf="$(
            awk '/^[[:space:]]*private-key:[[:space:]]*\// { print $2; exit }' \
                "${CONF_FILE}"
        )"

        if [[ -n "${from_conf}" ]]; then
            key_path="${from_conf}"
        fi
    fi

    if [[ -s "${cert_path}" ]]; then
        echo "  [ OK ] 证书 ${cert_path}"
    else
        echo "  [FAIL] 证书不存在：${cert_path}"
    fi

    if [[ -s "${key_path}" ]]; then
        printf "  [ OK ] 私钥 %s  (%s)\n" \
            "${key_path}" \
            "$(stat -c '%U:%G %a' "${key_path}" 2>/dev/null || echo '权限未知')"
    else
        echo "  [FAIL] 私钥不存在：${key_path}"
    fi

    # mihomo 只允许读取工作目录内的文件（SAFE_PATHS）。
    if [[ "${key_path}" != "${CONF_DIR}/"* ]]; then
        echo "  [FAIL] 私钥不在 ${CONF_DIR} 内，mihomo 会拒绝加载该文件"
        echo "         修复：把证书移入 ${CONF_DIR} 并同步改 ${CONF_FILE}"
    fi

    # 最关键的一项：服务用户到底能不能读私钥。
    if command_exists runuser && id mihomo >/dev/null 2>&1; then

        if runuser -u mihomo -- test -r "${key_path}" 2>/dev/null; then
            echo "  [ OK ] mihomo 用户可读私钥"
        else
            echo "  [FAIL] mihomo 用户读不到私钥 → TUIC listener 会静默失败"
            echo "         修复：chown mihomo:mihomo ${key_path}"
        fi
    fi

    echo
    echo "配置校验："

    if [[ -x "${BIN}" && -r "${CONF_FILE}" ]]; then

        if "${BIN}" -d "${CONF_DIR}" -f "${CONF_FILE}" -t >/dev/null 2>&1; then
            echo "  [ OK ] mihomo -t 通过"
        else
            echo "  [FAIL] mihomo -t 失败："
            "${BIN}" -d "${CONF_DIR}" -f "${CONF_FILE}" -t 2>&1 |
                sed 's/^/         /' || true
        fi
    else
        echo "  [ -- ] 尚未安装，跳过"
    fi

    echo
    echo "防火墙："

    local ufw_out=""

    if command_exists ufw; then
        ufw_out="$(ufw status 2>/dev/null || true)"
    fi

    if [[ "${ufw_out}" == *"Status: active"* ]]; then

        if [[ -n "${TUIC_PORT}" && "${ufw_out}" == *"${TUIC_PORT}/udp"* ]]; then
            echo "  [ OK ] ufw 已放行 ${TUIC_PORT}/udp"
        else
            echo "  [FAIL] ufw 已启用但没放行 ${TUIC_PORT}/udp"
            echo "         修复：ufw allow ${TUIC_PORT}/udp"
        fi
    else
        echo "  [ -- ] ufw 未启用"
    fi

    local nft_out=""

    if command_exists nft; then

        nft_out="$(nft list ruleset 2>/dev/null || true)"

        if [[ -z "${nft_out}" ]]; then
            echo "  [ OK ] nftables 无规则"
        elif [[ "${nft_out}" == *"drop"* || "${nft_out}" == *"reject"* ]]; then
            echo "  [ !! ] nftables 存在 drop/reject 规则，需确认是否拦了 UDP ${TUIC_PORT}"
            echo "         查看：nft list ruleset"
        else
            echo "  [ OK ] nftables 无 drop/reject 规则"
        fi
    fi

    echo
    echo "最近的 mihomo 异常日志："

    local logs=""

    logs="$(
        journalctl -u mihomo --no-pager -n 200 2>/dev/null |
            grep -iE "error|warn|fail|tuic" |
            tail -n 15 || true
    )"

    if [[ -n "${logs}" ]]; then
        echo "${logs}" | sed 's/^/  /'
    else
        echo "  （无）"
    fi

    echo
    echo "------------------------------------------------------------"
    echo "如果上面本机监听全是 [ OK ] 但客户端还是连不上，"
    echo "问题就在服务器之外，按顺序排查："
    echo
    echo "  1. 云厂商安全组单独放行 UDP ${TUIC_PORT:-<TUIC端口>}"
    echo "     （VLESS 走 TCP，VLESS 通不代表 UDP 通）"
    echo
    echo "  2. 抓包确认客户端的包有没有到达服务器："
    echo "       tcpdump -ni any udp port ${TUIC_PORT:-<TUIC端口>}"
    echo "     没有任何包 = 被拦在服务器之外"
    echo
    echo "  3. TUIC 用的是自签证书，客户端必须开启跳过证书校验"
    echo "     （Clash 系 skip-cert-verify、sing-box insecure）"
    echo "------------------------------------------------------------"
    echo
}

# ============================================================
# restart
# ============================================================

restart_service() {

    require_root

    systemctl restart mihomo
    systemctl restart snell

    sleep 2

    if systemctl is-active --quiet mihomo && systemctl is-active --quiet snell; then
        echo "mihomo 与 Snell 重启成功。"
    else
        echo "mihomo 或 Snell 重启失败。"
        journalctl -u mihomo -u snell --no-pager -n 80
        exit 1
    fi
}

# ============================================================
# 添加用户
# ============================================================

add_user() {

    require_root

    local username="${1:-}"

    [[ -n "${username}" ]] ||
        die "用法：$0 add-user <username>"

    if ! [[ "${username}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        die "用户名只能包含：字母、数字、.、_、-"
    fi

    if grep -q "^${username}|" "${USERS_FILE}" 2>/dev/null; then
        die "用户 ${username} 已存在。"
    fi

    local uuid
    uuid="$(generate_uuid)"

    echo "${username}|${uuid}" >> "${USERS_FILE}"

    chmod 600 "${USERS_FILE}"

    write_config
    validate_config

    systemctl restart mihomo

    sleep 2

    if ! systemctl is-active --quiet mihomo; then

        warn "添加用户后 mihomo 启动失败。"

        journalctl \
            -u mihomo \
            --no-pager \
            -n 80

        exit 1
    fi

    local uri

    uri="$(make_vless_uri "${uuid}" "${username}" "${PUBLIC_IPV4}")"

    cat > "${CLIENT_DIR}/${username}.yaml" <<EOF
proxies:
  - name: mihomo-${username}
    type: vless
    server: ${PUBLIC_IPV4}
    port: ${PORT}
    uuid: ${uuid}
    udp: true
    tls: true
    servername: ${SNI}
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
EOF

    cat > "${CLIENT_DIR}/${username}-sing-box.json" <<EOF
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "mihomo-${username}",
      "server": "${PUBLIC_IPV4}",
      "server_port": ${PORT},
      "uuid": "${uuid}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${PUBLIC_KEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    }
  ]
}
EOF

    echo "${uri}" \
        > "${CLIENT_DIR}/${username}-v2rayn.txt"

    chmod 600 "${CLIENT_DIR}"/*

    chown -R mihomo:mihomo "${CLIENT_DIR}"

    echo
    echo "============================================================"
    echo "用户添加成功"
    echo "============================================================"
    echo
    echo "用户名：${username}"
    echo "UUID：${uuid}"
    echo
    echo "VLESS URI："
    echo
    echo "${uri}"
    echo
}

# ============================================================
# 删除用户
# ============================================================

delete_user() {

    require_root

    local username="${1:-}"

    [[ -n "${username}" ]] ||
        die "用法：$0 del-user <username>"

    grep -q "^${username}|" "${USERS_FILE}" ||
        die "用户 ${username} 不存在。"

    local count

    count="$(grep -c '|' "${USERS_FILE}" || true)"

    if [[ "${count}" -le 1 ]]; then
        die "不能删除最后一个用户。"
    fi

    cp "${USERS_FILE}" "${USERS_FILE}.bak"

    grep -v "^${username}|" \
        "${USERS_FILE}.bak" \
        > "${USERS_FILE}"

    rm -f \
        "${CLIENT_DIR}/${username}.yaml" \
        "${CLIENT_DIR}/${username}-sing-box.json" \
        "${CLIENT_DIR}/${username}-v2rayn.txt"

    write_config

    if ! validate_config; then

        cp "${USERS_FILE}.bak" "${USERS_FILE}"

        write_config

        die "删除用户失败，已恢复原配置。"
    fi

    systemctl restart mihomo

    sleep 2

    if ! systemctl is-active --quiet mihomo; then

        cp "${USERS_FILE}.bak" "${USERS_FILE}"

        write_config

        systemctl restart mihomo

        die "删除用户后 mihomo 启动失败，已恢复。"
    fi

    rm -f "${USERS_FILE}.bak"

    echo "用户 ${username} 已删除。"
}

# ============================================================
# 用户列表
# ============================================================

list_users() {

    require_root

    echo
    echo "============================================================"
    echo "mihomo users"
    echo "============================================================"
    echo

    if [[ ! -s "${USERS_FILE}" ]]; then
        echo "没有用户。"
        return
    fi

    printf "%-24s %s\n" "USERNAME" "UUID"
    printf "%-24s %s\n" "--------" "----"

    while IFS='|' read -r username uuid; do

        [[ -n "${username}" ]] || continue

        printf "%-24s %s\n" \
            "${username}" \
            "${uuid}"

    done < "${USERS_FILE}"

    echo
}

# ============================================================
# 卸载
# ============================================================

uninstall_all() {

    require_root

    echo
    echo "============================================================"
    echo "卸载 mihomo"
    echo "============================================================"
    echo
    echo "将删除："
    echo
    echo "  ${BIN}"
    echo "  ${CONF_DIR}"
    echo "  ${SERVICE_FILE}"
    echo
    echo "并删除本脚本创建的 BBR / 网络 sysctl 文件。"
    echo

    local answer=""

    # 走 ask() 而不是裸 read：通过 `curl ... | bash` 运行时
    # stdin 是脚本正文，裸 read 会读到脚本内容而不是用户输入。
    ask "确认卸载？输入 YES： " answer ||
        die "无法读取输入，已取消。"

    [[ "${answer}" == "YES" ]] ||
        die "已取消。"

    systemctl disable --now mihomo 2>/dev/null || true
    systemctl disable --now snell 2>/dev/null || true

    rm -f "${SERVICE_FILE}" "${SNELL_SERVICE_FILE}"
    rm -f "${BIN}" "${SNELL_BIN}"

    systemctl daemon-reload

    rm -rf "${CONF_DIR}"
    rm -rf "${SNELL_CONF_DIR}"

    rm -f /etc/sysctl.d/99-mihomo-bbr.conf
    rm -f /etc/sysctl.d/99-mihomo-network.conf

    sysctl --system >/dev/null 2>&1 || true

    echo
    echo "mihomo 已卸载。"
    echo
    echo "注意：没有自动删除防火墙规则。"
}

# ============================================================
# 交互菜单
# ============================================================

# 菜单里的动作统一放进子 shell 执行。
# 原因：脚本里到处是 die()（内部就是 exit 1），
# 在主 shell 直接调用会把整个菜单一起带走。
# 子 shell 不会继承 EXIT trap，所以 TMP_DIR 也不会被提前清理。
run_action() {
    local rc=0

    ( "$@" ) || rc=$?

    if [[ "${rc}" -ne 0 ]]; then
        echo
        warn "操作未成功完成（退出码 ${rc}）。"
    fi

    return 0
}

menu_header() {

    local mihomo_state
    local snell_state

    mihomo_state="$(unit_state mihomo)"
    snell_state="$(unit_state snell)"

    echo
    echo "============================================================"
    echo "        mihomo 多协议节点管理器      版本 ${SCRIPT_VERSION}"
    echo "============================================================"
    echo
    printf "  服务    mihomo %s    snell %s\n" \
        "${mihomo_state}" \
        "${snell_state}"

    if is_installed; then
        printf "  节点    VLESS tcp/%s   TUIC udp/%s   Snell tcp/%s\n" \
            "${PORT:-未知}" \
            "${TUIC_PORT:-未知}" \
            "${SNELL_PORT:-未知}"
        printf "  地址    %s\n" "${PUBLIC_IPV4:-未知}"
    else
        echo "  节点    尚未安装"
    fi

    echo
    echo "------------------------------------------------------------"
    echo "  1) 安装 / 重装节点"
    echo "  2) 查看节点信息（订阅链接）"
    echo "  3) 服务状态与监听端口"
    echo "  4) 连通性诊断"
    echo "  5) 重启服务"
    echo "  6) 用户管理"
    echo "  7) 卸载"
    echo "  0) 退出"
    echo "------------------------------------------------------------"
    echo
}

user_menu() {

    local choice=""
    local username=""

    while true; do

        echo
        echo "------------------------------------------------------------"
        echo "  用户管理"
        echo "------------------------------------------------------------"
        echo "  1) 用户列表"
        echo "  2) 添加用户"
        echo "  3) 删除用户"
        echo "  0) 返回主菜单"
        echo "------------------------------------------------------------"
        echo

        ask "请选择 [0-3]： " choice || return 0

        case "${choice}" in

            1)
                run_action list_users
                pause
                ;;

            2)
                if ask "新用户名（字母/数字/.、_、-）： " username; then
                    run_action add_user "${username}"
                fi
                pause
                ;;

            3)
                run_action list_users

                if ask "要删除的用户名： " username; then
                    run_action delete_user "${username}"
                fi
                pause
                ;;

            0)
                return 0
                ;;

            *)
                warn "无效选择：${choice}"
                ;;
        esac
    done
}

main_menu() {

    require_root

    local choice=""

    while true; do

        # 安装/卸载会改写 server.env，
        # 动作跑在子 shell 里不会影响主 shell 的变量，
        # 所以每轮都重新载入一次，界面才不会显示旧端口。
        refresh_settings

        menu_header

        ask "请选择 [0-7]： " choice || return 0

        case "${choice}" in

            1)
                if is_installed; then
                    echo
                    warn "检测到已安装。重装会重新生成 Reality 密钥对和 short-id，"
                    warn "现有 VLESS 客户端配置将全部失效，需要重新导入。"
                    echo

                    if ! confirm "确认继续重装？"; then
                        echo "已取消。"
                        pause
                        continue
                    fi
                fi

                run_action install_all
                pause
                ;;

            2)
                run_action show_nodes
                pause
                ;;

            3)
                run_action show_status
                pause
                ;;

            4)
                run_action diagnose
                pause
                ;;

            5)
                run_action restart_service
                pause
                ;;

            6)
                user_menu
                ;;

            7)
                run_action uninstall_all
                pause
                ;;

            0)
                echo
                echo "退出。"
                return 0
                ;;

            *)
                warn "无效选择：${choice}"
                pause
                ;;
        esac
    done
}

# ============================================================
# 用法
# ============================================================

usage() {
    echo
    echo "用法：不带参数运行进入交互菜单，或使用子命令："
    echo
    echo "  $0                     # 交互菜单"
    echo "  $0 menu"
    echo "  $0 install"
    echo "  $0 status"
    echo "  $0 info                # 只打印节点信息"
    echo "  $0 diagnose            # 连通性诊断"
    echo "  $0 restart"
    echo "  $0 add-user <username>"
    echo "  $0 del-user <username>"
    echo "  $0 list-user"
    echo "  $0 uninstall"
    echo
}

# ============================================================
# Main
# ============================================================

main() {

    local command="${1:-}"

    if [[ "${command}" =~ ^PORT=([0-9]+)$ ]]; then
        PORT="${BASH_REMATCH[1]}"
        ENV_PORT="${PORT}"
        shift
        command="${1:-}"
    fi

    refresh_settings

    # 无参数：能交互就进菜单。
    # 不能交互（例如 CI、cron、`curl | bash` 且没有 /dev/tty）时，
    # 保持旧行为直接安装，避免自动化调用卡在菜单上。
    if [[ -z "${command}" ]]; then

        if interactive_available; then
            main_menu
            return
        fi

        command="install"
    fi

    case "${command}" in

        menu)
            main_menu
            ;;

        install)
            install_all
            ;;

        status)
            show_status
            ;;

        info|node|nodes)
            show_nodes
            ;;

        diagnose|doctor|check)
            diagnose
            ;;

        restart)
            restart_service
            ;;

        add-user)
            add_user "${2:-}"
            ;;

        del-user)
            delete_user "${2:-}"
            ;;

        list-user|list-users)
            list_users
            ;;

        uninstall)
            uninstall_all
            ;;

        -h|--help|help)
            usage
            ;;

        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"

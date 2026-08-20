#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# mihomo VLESS Reality 一键服务端
#
# 支持：
#   install
#   status
#   restart
#   add-user <username>
#   del-user <username>
#   list-user
#   uninstall
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

BIN="/usr/local/bin/mihomo"
CONF_DIR="/etc/mihomo"
CONF_FILE="${CONF_DIR}/config.yaml"
USERS_FILE="${CONF_DIR}/users"
INFO_FILE="${CONF_DIR}/node-info"
SERVER_ENV="${CONF_DIR}/server.env"
CLIENT_DIR="${CONF_DIR}/clients"

SERVICE_FILE="/etc/systemd/system/mihomo.service"

PORT="${PORT:-}"
SNI="${SNI:-www.apple.com}"
DEST="${DEST:-${SNI}:443}"

load_saved_settings() {
    if [[ -z "${PORT}" && -r "${SERVER_ENV}" ]]; then
        # shellcheck disable=SC1090
        source "${SERVER_ENV}"
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
            log "随机监听端口：${PORT}"
            return
        fi
    done

    die "无法找到可用的随机 TCP 端口。请使用 PORT=端口号 手动指定。"
}

check_port() {
    log "检查 TCP ${PORT}..."

    if ! port_is_available "${PORT}"; then
        die "TCP ${PORT} 已被其他程序占用。请使用 PORT=端口号 指定其他端口。"
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

            log "UFW：已放行 TCP/UDP ${PORT}。"
        fi
    fi

    # firewalld
    if command_exists firewall-cmd; then

        if systemctl is-active --quiet firewalld 2>/dev/null; then

            firewall-cmd \
                --permanent \
                --add-port="${PORT}/tcp" >/dev/null || true

            firewall-cmd \
                --permanent \
                --add-port="${PORT}/udp" >/dev/null || true

            firewall-cmd \
                --reload >/dev/null || true

            log "firewalld：已放行 TCP/UDP ${PORT}。"
        fi
    fi

    warn "如果 VPS 使用云厂商安全组，请另外放行 TCP ${PORT}。"
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
SNI=${SNI}
DEST=${DEST}
PUBLIC_IPV4=${PUBLIC_IPV4}
PUBLIC_IPV6=${PUBLIC_IPV6}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
EOF

    chmod 600 "${SERVER_ENV}"

    chown mihomo:mihomo "${SERVER_ENV}"

    cat > "${INFO_FILE}" <<EOF
============================================================
mihomo VLESS Reality Server
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

    select_port
    check_port

    generate_reality_keypair
    generate_short_id

    initialize_user

    configure_network
    configure_bbr

    write_config
    validate_config

    create_systemd

    configure_firewall

    save_info
    generate_client_configs

    start_mihomo

    echo
    echo "============================================================"
    echo "                 安装完成"
    echo "============================================================"
    echo
    echo "mihomo：${MIHOMO_VERSION}"
    echo
    echo "服务器 IPv4：${PUBLIC_IPV4}"
    echo "服务器 IPv6：${PUBLIC_IPV6:-未检测到}"
    echo "端口：${PORT}"
    echo
    echo "SNI：${SNI}"
    echo "DEST：${DEST}"
    echo
    echo "Reality Public Key："
    echo "${PUBLIC_KEY}"
    echo
    echo "Reality Short ID："
    echo "${SHORT_ID}"
    echo
    echo "UUID："
    echo "${DEFAULT_UUID}"
    echo
    echo "------------------------------------------------------------"
    echo "VLESS URI"
    echo "------------------------------------------------------------"
    echo
    make_vless_uri \
        "${DEFAULT_UUID}" \
        "${DEFAULT_USERNAME}" \
        "${PUBLIC_IPV4}"
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
    echo "状态："
    echo "  $0 status"
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
    echo "mihomo status"
    echo "============================================================"
    echo

    if systemctl list-unit-files 2>/dev/null |
        grep -q "^mihomo.service"; then

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

    ss -lntp 2>/dev/null |
        grep ":${PORT}" ||
        true

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
# restart
# ============================================================

restart_service() {

    require_root

    systemctl restart mihomo

    sleep 2

    if systemctl is-active --quiet mihomo; then
        echo "mihomo 重启成功。"
    else
        echo "mihomo 重启失败。"
        journalctl -u mihomo --no-pager -n 80
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

    read -r -p "确认卸载？输入 YES： " answer

    [[ "${answer}" == "YES" ]] ||
        die "已取消。"

    systemctl disable --now mihomo 2>/dev/null || true

    rm -f "${SERVICE_FILE}"
    rm -f "${BIN}"

    systemctl daemon-reload

    rm -rf "${CONF_DIR}"

    rm -f /etc/sysctl.d/99-mihomo-bbr.conf
    rm -f /etc/sysctl.d/99-mihomo-network.conf

    sysctl --system >/dev/null 2>&1 || true

    echo
    echo "mihomo 已卸载。"
    echo
    echo "注意：没有自动删除防火墙规则。"
}

# ============================================================
# Main
# ============================================================

main() {

    local command="${1:-install}"

    if [[ "${command}" =~ ^PORT=([0-9]+)$ ]]; then
        PORT="${BASH_REMATCH[1]}"
        command="${2:-install}"
    fi

    load_saved_settings

    case "${command}" in

        install)
            install_all
            ;;

        status)
            show_status
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

        *)
            echo
            echo "用法："
            echo
            echo "  $0 install"
            echo "  $0 status"
            echo "  $0 restart"
            echo "  $0 add-user <username>"
            echo "  $0 del-user <username>"
            echo "  $0 list-user"
            echo "  $0 uninstall"
            echo
            exit 1
            ;;
    esac
}

main "$@"

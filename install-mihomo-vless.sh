#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# mihomo VLESS + Reality 一键服务端
#
# 支持：
#   install
#   status
#   restart
#   uninstall
#   add-user
#   del-user
#   list-user
#
# 默认：
#   Port: 443
#   SNI:  www.apple.com
#   DEST: www.apple.com:443
#
# 安装：
#   bash install-mihomo-vless.sh
#
# 自定义：
#   SNI=www.microsoft.com \
#   DEST=www.microsoft.com:443 \
#   bash install-mihomo-vless.sh
#
# ============================================================

export DEBIAN_FRONTEND=noninteractive

APP="mihomo"
BIN="/usr/local/bin/mihomo"
CONF_DIR="/etc/mihomo"
CONF="${CONF_DIR}/config.yaml"
USERS_FILE="${CONF_DIR}/users"
INFO_FILE="${CONF_DIR}/node-info"
CLIENT_DIR="${CONF_DIR}/clients"
SERVICE="/etc/systemd/system/mihomo.service"

PORT="${PORT:-443}"
SNI="${SNI:-www.apple.com}"
DEST="${DEST:-${SNI}:443}"

TMP_DIR="/tmp/mihomo-install.$$"

cleanup() {
    rm -rf "${TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo "[+] $*"
}

warn() {
    echo "[!] $*" >&2
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 运行。"
}

# ============================================================
# 基础检测
# ============================================================

check_os() {

    [[ -f /etc/os-release ]] || die "无法检测操作系统。"

    . /etc/os-release

    case "${ID}" in
        debian|ubuntu)
            ;;
        *)
            die "当前系统 ${ID} 不在支持列表中，请使用 Debian/Ubuntu。"
            ;;
    esac

    info "系统：${PRETTY_NAME}"
}

install_dependencies() {

    info "安装依赖..."

    apt-get update -y

    apt-get install -y \
        curl \
        wget \
        ca-certificates \
        gzip \
        openssl \
        uuid-runtime \
        iproute2 \
        procps \
        nftables \
        jq \
        coreutils \
        sed \
        grep \
        awk \
        socat

}

# ============================================================
# CPU 架构
# ============================================================

detect_arch() {

    ARCH="$(uname -m)"

    case "${ARCH}" in

        x86_64|amd64)
            MIHOMO_ARCH="amd64"

            CPU_FLAGS="$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || true)"

            if echo "${CPU_FLAGS}" | grep -qw avx2; then
                MIHOMO_VARIANT="v3"
            elif echo "${CPU_FLAGS}" | grep -qw avx; then
                MIHOMO_VARIANT="v2"
            else
                MIHOMO_VARIANT="compatible"
            fi
            ;;

        aarch64|arm64)
            MIHOMO_ARCH="arm64"
            MIHOMO_VARIANT="v8"
            ;;

        armv7l|armv7)
            MIHOMO_ARCH="armv7"
            MIHOMO_VARIANT="compatible"
            ;;

        armv6l|armv6)
            MIHOMO_ARCH="armv6"
            MIHOMO_VARIANT="compatible"
            ;;

        *)
            die "不支持的 CPU 架构：${ARCH}"
            ;;
    esac

    info "CPU：${ARCH}"
}

# ============================================================
# 获取最新稳定版本
# ============================================================

get_latest_version() {

    info "获取 mihomo 最新稳定版..."

    LATEST_VERSION="$(
        curl -fsSL \
            --retry 3 \
            --connect-timeout 10 \
            https://api.github.com/repos/MetaCubeX/mihomo/releases/latest |
        jq -r '.tag_name'
    )"

    [[ -n "${LATEST_VERSION}" ]] || die "无法获取 mihomo 最新版本。"

    [[ "${LATEST_VERSION}" != "null" ]] ||
        die "GitHub API 没有返回稳定版本。"

    info "mihomo：${LATEST_VERSION}"
}

# ============================================================
# 下载 mihomo
# ============================================================

download_mihomo() {

    mkdir -p "${TMP_DIR}"

    local FILE=""
    local URL=""

    case "${MIHOMO_ARCH}" in

        amd64)

            if [[ "${MIHOMO_VARIANT}" == "compatible" ]]; then
                FILE="mihomo-linux-amd64-compatible-${LATEST_VERSION}.gz"
            else
                FILE="mihomo-linux-amd64-${MIHOMO_VARIANT}-${LATEST_VERSION}.gz"
            fi
            ;;

        arm64)
            FILE="mihomo-linux-arm64-v8-${LATEST_VERSION}.gz"
            ;;

        armv7)
            FILE="mihomo-linux-armv7-${LATEST_VERSION}.gz"
            ;;

        armv6)
            FILE="mihomo-linux-armv6-${LATEST_VERSION}.gz"
            ;;

        *)
            die "未知架构。"
            ;;
    esac

    URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${FILE}"

    info "下载：${FILE}"

    if ! curl -fL \
        --retry 3 \
        --connect-timeout 15 \
        "${URL}" \
        -o "${TMP_DIR}/mihomo.gz"; then

        # amd64 fallback
        if [[ "${MIHOMO_ARCH}" == "amd64" ]]; then

            FILE="mihomo-linux-amd64-compatible-${LATEST_VERSION}.gz"

            URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${FILE}"

            warn "优化版本下载失败，尝试 compatible..."

            curl -fL \
                --retry 3 \
                --connect-timeout 15 \
                "${URL}" \
                -o "${TMP_DIR}/mihomo.gz"
        else
            die "下载 mihomo 失败。"
        fi
    fi

    gzip -dc "${TMP_DIR}/mihomo.gz" > "${TMP_DIR}/mihomo"

    chmod +x "${TMP_DIR}/mihomo"

    install -m 0755 \
        "${TMP_DIR}/mihomo" \
        "${BIN}"

    info "mihomo 已安装。"

    "${BIN}" -v || true
}

# ============================================================
# 创建用户
# ============================================================

create_system_user() {

    if ! id mihomo >/dev/null 2>&1; then

        info "创建 mihomo 系统用户..."

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

    chmod 600 "${USERS_FILE}"

    chown -R mihomo:mihomo "${CONF_DIR}"

    chmod 755 "${CONF_DIR}"
    chmod 700 "${CLIENT_DIR}"
}

# ============================================================
# UUID
# ============================================================

generate_uuid() {

    uuidgen
}

# ============================================================
# Reality Key
# ============================================================

generate_reality() {

    info "生成 Reality KeyPair..."

    REALITY_OUTPUT="$("${BIN}" generate reality-keypair)"

    PRIVATE_KEY="$(
        echo "${REALITY_OUTPUT}" |
        awk -F': ' '/PrivateKey/ {print $2}' |
        tr -d '[:space:]'
    )"

    PUBLIC_KEY="$(
        echo "${REALITY_OUTPUT}" |
        awk -F': ' '/PublicKey/ {print $2}' |
        tr -d '[:space:]'
    )"

    [[ -n "${PRIVATE_KEY}" ]] ||
        die "Reality PrivateKey 生成失败。"

    [[ -n "${PUBLIC_KEY}" ]] ||
        die "Reality PublicKey 生成失败。"

    info "Reality KeyPair 生成完成。"
}

# ============================================================
# Short ID
# ============================================================

generate_short_id() {

    SHORT_ID="$(openssl rand -hex 8)"

    info "Short ID：${SHORT_ID}"
}

# ============================================================
# 公网 IPv4
# ============================================================

detect_public_ipv4() {

    info "检测公网 IPv4..."

    PUBLIC_IPV4=""

    for API in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://ifconfig.me/ip"
    do

        PUBLIC_IPV4="$(
            curl -4fsSL \
                --connect-timeout 5 \
                --max-time 10 \
                "${API}" 2>/dev/null |
            tr -d '[:space:]' || true
        )"

        if [[ "${PUBLIC_IPV4}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        fi

        PUBLIC_IPV4=""
    done

    [[ -n "${PUBLIC_IPV4}" ]] ||
        die "无法检测公网 IPv4。"

    info "公网 IPv4：${PUBLIC_IPV4}"
}

# ============================================================
# 公网 IPv6
# ============================================================

detect_public_ipv6() {

    info "检测公网 IPv6..."

    PUBLIC_IPV6=""

    for API in \
        "https://api6.ipify.org" \
        "https://ipv6.icanhazip.com"
    do

        PUBLIC_IPV6="$(
            curl -6fsSL \
                --connect-timeout 5 \
                --max-time 10 \
                "${API}" 2>/dev/null |
            tr -d '[:space:]' || true
        )"

        if [[ "${PUBLIC_IPV6}" == *:* ]]; then
            break
        fi

        PUBLIC_IPV6=""
    done

    if [[ -n "${PUBLIC_IPV6}" ]]; then
        info "公网 IPv6：${PUBLIC_IPV6}"
    else
        warn "未检测到公网 IPv6。"
        PUBLIC_IPV6=""
    fi
}

# ============================================================
# IPv6 内核参数
# ============================================================

configure_ipv6() {

    info "检查 IPv6..."

    if [[ ! -d /proc/sys/net/ipv6 ]]; then
        warn "当前内核没有 IPv6 支持。"
        return
    fi

    cat > /etc/sysctl.d/99-mihomo-network.conf <<'EOF'
# mihomo network tuning

net.ipv4.ip_forward=1

net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0

net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
EOF

    sysctl --system >/dev/null 2>&1 || true

    if [[ -n "${PUBLIC_IPV6}" ]]; then
        info "IPv6 已启用。"
    else
        info "IPv6 内核支持已保留，但当前 VPS 没有可检测公网 IPv6。"
    fi
}

# ============================================================
# BBR
# ============================================================

configure_bbr() {

    info "配置 BBR..."

    KERNEL="$(uname -r)"

    if [[ ! -f /proc/sys/net/ipv4/tcp_congestion_control ]]; then
        warn "系统不支持 TCP 拥塞控制检测。"
        return
    fi

    AVAILABLE="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"

    if echo "${AVAILABLE}" | grep -qw bbr; then

        cat > /etc/sysctl.d/99-mihomo-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

        sysctl --system >/dev/null 2>&1 || true

        CURRENT="$(cat /proc/sys/net/ipv4/tcp_congestion_control)"

        if [[ "${CURRENT}" == "bbr" ]]; then
            info "BBR 已启用。"
        else
            warn "BBR 模块存在，但当前拥塞控制算法为：${CURRENT}"
        fi

    else

        warn "当前内核没有 BBR。"
        warn "不会强制修改内核或安装第三方内核。"
        warn "请升级到支持 BBR 的现代 Linux 内核后再运行脚本。"

    fi
}

# ============================================================
# 检查 443
# ============================================================

check_port() {

    if command -v ss >/dev/null 2>&1; then

        EXISTING="$(
            ss -lntp 2>/dev/null |
            awk '$4 ~ /:443$/'
        )"

        if [[ -n "${EXISTING}" ]]; then

            # 如果已经是 mihomo 自己，不报错
            if echo "${EXISTING}" | grep -q "mihomo"; then
                info "TCP 443 已由 mihomo 占用。"
            else
                echo
                warn "TCP 443 当前已被其他程序占用："
                echo "${EXISTING}"
                echo
                die "请停止占用 443 的程序后再运行安装。"
            fi
        fi
    fi
}

# ============================================================
# 防火墙
# ============================================================

configure_firewall() {

    info "配置防火墙..."

    # UFW
    if command -v ufw >/dev/null 2>&1; then

        if ufw status 2>/dev/null | grep -q "Status: active"; then

            ufw allow 443/tcp >/dev/null || true
            ufw allow 443/udp >/dev/null || true

            info "UFW：已放行 TCP/UDP 443。"

        fi
    fi

    # firewalld
    if command -v firewall-cmd >/dev/null 2>&1; then

        if systemctl is-active --quiet firewalld 2>/dev/null; then

            firewall-cmd \
                --permanent \
                --add-port=443/tcp >/dev/null || true

            firewall-cmd \
                --permanent \
                --add-port=443/udp >/dev/null || true

            firewall-cmd --reload >/dev/null || true

            info "firewalld：已放行 TCP/UDP 443。"
        fi
    fi

    # nftables
    if systemctl is-active --quiet nftables 2>/dev/null; then
        info "检测到 nftables 正在运行。"
        warn "云厂商安全组仍需自行放行 TCP 443。"
    fi

    echo
    warn "如果 VPS 有云厂商安全组，请确保 TCP 443 已放行。"
}

# ============================================================
# 生成 users 文件
# ============================================================

create_first_user() {

    if [[ -s "${USERS_FILE}" ]]; then

        FIRST_LINE="$(head -n1 "${USERS_FILE}")"

        UUID="$(echo "${FIRST_LINE}" | cut -d'|' -f2)"
        USERNAME="$(echo "${FIRST_LINE}" | cut -d'|' -f1)"

        return
    fi

    UUID="$(generate_uuid)"
    USERNAME="user1"

    echo "${USERNAME}|${UUID}" > "${USERS_FILE}"

    chmod 600 "${USERS_FILE}"

    info "UUID：${UUID}"
}

# ============================================================
# 写 mihomo 配置
# ============================================================

write_config() {

    info "生成 mihomo 配置..."

    {
        echo "mixed-port: 7890"
        echo "mode: direct"
        echo "log-level: info"
        echo "ipv6: true"
        echo
        echo "listeners:"
        echo
        echo "  - name: vless-reality"
        echo "    type: vless"
        echo "    listen: 0.0.0.0"
        echo "    port: ${PORT}"
        echo
        echo "    users:"

        while IFS='|' read -r NAME USER_UUID; do

            [[ -n "${NAME}" ]] || continue
            [[ -n "${USER_UUID}" ]] || continue

            echo "      - username: ${NAME}"
            echo "        uuid: ${USER_UUID}"
            echo "        flow: xtls-rprx-vision"

        done < "${USERS_FILE}"

        echo
        echo "    reality-config:"
        echo "      dest: ${DEST}"
        echo "      private-key: ${PRIVATE_KEY}"
        echo "      short-id:"
        echo "        - ${SHORT_ID}"
        echo "      server-names:"
        echo "        - ${SNI}"

    } > "${CONF}"

    chown mihomo:mihomo "${CONF}"
    chmod 600 "${CONF}"
}

# ============================================================
# systemd
# ============================================================

create_service() {

    info "创建 systemd 服务..."

    cat > "${SERVICE}" <<EOF
[Unit]
Description=mihomo Proxy Kernel
Documentation=https://wiki.metacubex.one/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

User=mihomo
Group=mihomo

ExecStart=${BIN} -d ${CONF_DIR} -f ${CONF}

Restart=on-failure
RestartSec=3

LimitNOFILE=1048576

NoNewPrivileges=true

PrivateTmp=true

ProtectSystem=full
ProtectHome=true

ReadWritePaths=${CONF_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mihomo >/dev/null
}

# ============================================================
# 启动
# ============================================================

start_service() {

    info "启动 mihomo..."

    systemctl restart mihomo

    sleep 2

    if ! systemctl is-active --quiet mihomo; then

        echo
        warn "mihomo 启动失败。"
        echo

        journalctl \
            -u mihomo \
            --no-pager \
            -n 80

        exit 1
    fi

    info "mihomo 正常运行。"
}

# ============================================================
# 生成客户端文件
# ============================================================

generate_client_configs() {

    mkdir -p "${CLIENT_DIR}"

    chmod 700 "${CLIENT_DIR}"

    # 当前第一个用户
    FIRST_LINE="$(head -n1 "${USERS_FILE}")"

    USERNAME="$(echo "${FIRST_LINE}" | cut -d'|' -f1)"
    UUID="$(echo "${FIRST_LINE}" | cut -d'|' -f2)"

    # -------------------------
    # VLESS URI
    # -------------------------

    VLESS_URI="vless://${UUID}@${PUBLIC_IPV4}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#mihomo-${USERNAME}"

    if [[ -n "${PUBLIC_IPV6}" ]]; then

        VLESS_URI_IPV6="vless://${UUID}@\[${PUBLIC_IPV6}\]:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#mihomo-${USERNAME}-IPv6"

    else

        VLESS_URI_IPV6=""

    fi

    echo "${VLESS_URI}" > "${CLIENT_DIR}/vless-uri.txt"

    # -------------------------
    # Mihomo / Clash Meta
    # -------------------------

    cat > "${CLIENT_DIR}/mihomo.yaml" <<EOF
proxies:
  - name: mihomo-vless-reality
    type: vless
    server: ${PUBLIC_IPV4}
    port: 443
    uuid: ${UUID}
    udp: true
    tls: true
    servername: ${SNI}
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
EOF

    # -------------------------
    # sing-box
    # -------------------------

    cat > "${CLIENT_DIR}/sing-box.json" <<EOF
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "mihomo-vless-reality",
      "server": "${PUBLIC_IPV4}",
      "server_port": 443,
      "uuid": "${UUID}",
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

    # -------------------------
    # V2RayN
    # -------------------------

    echo "${VLESS_URI}" > "${CLIENT_DIR}/v2rayn-vless.txt"

    # -------------------------
    # 节点信息
    # -------------------------

    cat > "${INFO_FILE}" <<EOF
==================================================
mihomo VLESS Reality Node
==================================================

mihomo version:
${LATEST_VERSION}

Server IPv4:
${PUBLIC_IPV4}

Server IPv6:
${PUBLIC_IPV6:-N/A}

Port:
443

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

UUID:
${UUID}

Username:
${USERNAME}

Reality Public Key:
${PUBLIC_KEY}

Reality Private Key:
${PRIVATE_KEY}

Reality Short ID:
${SHORT_ID}

Flow:
xtls-rprx-vision

==================================================
VLESS URI
==================================================

${VLESS_URI}

EOF

    if [[ -n "${VLESS_URI_IPV6}" ]]; then

        cat >> "${INFO_FILE}" <<EOF

IPv6 VLESS URI:

${VLESS_URI_IPV6}

EOF

    fi

    cat >> "${INFO_FILE}" <<EOF

Client files:

${CLIENT_DIR}/mihomo.yaml
${CLIENT_DIR}/sing-box.json
${CLIENT_DIR}/v2rayn-vless.txt

==================================================
EOF

    chown -R mihomo:mihomo "${CLIENT_DIR}" "${INFO_FILE}"

    chmod 600 \
        "${CLIENT_DIR}"/* \
        "${INFO_FILE}"
}

# ============================================================
# 保存安装信息
# ============================================================

save_node_info() {

    mkdir -p "${CONF_DIR}"

    cat > "${CONF_DIR}/server.env" <<EOF
PORT=${PORT}
SNI=${SNI}
DEST=${DEST}
PUBLIC_IPV4=${PUBLIC_IPV4}
PUBLIC_IPV6=${PUBLIC_IPV6}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
EOF

    chmod 600 "${CONF_DIR}/server.env"

    chown mihomo:mihomo "${CONF_DIR}/server.env"
}

# ============================================================
# 安装
# ============================================================

install_all() {

    require_root

    echo
    echo "=================================================="
    echo "       mihomo VLESS Reality 一键安装器"
    echo "=================================================="
    echo

    check_os

    install_dependencies

    detect_arch

    get_latest_version

    detect_public_ipv4

    detect_public_ipv6

    check_port

    download_mihomo

    create_system_user

    create_first_user

    generate_reality

    generate_short_id

    configure_ipv6

    configure_bbr

    write_config

    create_service

    configure_firewall

    save_node_info

    start_service

    generate_client_configs

    echo
    echo "=================================================="
    echo "             安装完成"
    echo "=================================================="
    echo
    echo "服务器 IPv4：${PUBLIC_IPV4}"
    echo "服务器 IPv6：${PUBLIC_IPV6:-未检测到}"
    echo "端口：443"
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
    echo "${UUID}"
    echo
    echo "--------------------------------------------------"
    echo "VLESS URI："
    echo
    echo "${VLESS_URI}"
    echo
    echo "--------------------------------------------------"
    echo "客户端配置："
    echo
    echo "mihomo / Clash："
    echo "${CLIENT_DIR}/mihomo.yaml"
    echo
    echo "sing-box："
    echo "${CLIENT_DIR}/sing-box.json"
    echo
    echo "V2RayN："
    echo "${CLIENT_DIR}/v2rayn-vless.txt"
    echo
    echo "完整信息："
    echo "${INFO_FILE}"
    echo
    echo "--------------------------------------------------"
    echo "管理命令："
    echo
    echo "查看状态："
    echo "  $0 status"
    echo
    echo "重启："
    echo "  $0 restart"
    echo
    echo "添加用户："
    echo "  $0 add-user 用户名"
    echo
    echo "删除用户："
    echo "  $0 del-user 用户名"
    echo
    echo "用户列表："
    echo "  $0 list-user"
    echo
    echo "卸载："
    echo "  $0 uninstall"
    echo
    echo "查看日志："
    echo "  journalctl -u mihomo -f"
    echo
    echo "=================================================="
}

# ============================================================
# 状态
# ============================================================

status() {

    require_root

    echo
    echo "========== mihomo status =========="
    echo

    if systemctl list-unit-files | grep -q '^mihomo.service'; then

        systemctl --no-pager --full status mihomo || true

    else

        echo "mihomo 尚未安装。"
    fi

    echo
    echo "========== listeners =========="
    echo

    ss -lntp 2>/dev/null | grep ':443' || true

    echo

    if [[ -f "${INFO_FILE}" ]]; then
        echo "========== node info =========="
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

    sleep 1

    if systemctl is-active --quiet mihomo; then
        echo "mihomo 已重启。"
    else
        echo "mihomo 重启失败。"
        journalctl -u mihomo --no-pager -n 50
        exit 1
    fi
}

# ============================================================
# 添加用户
# ============================================================

add_user() {

    require_root

    local NAME="${1:-}"

    [[ -n "${NAME}" ]] ||
        die "用法：$0 add-user 用户名"

    [[ "${NAME}" =~ ^[a-zA-Z0-9._-]+$ ]] ||
        die "用户名只能包含字母、数字、点、下划线和短横线。"

    if grep -q "^${NAME}|" "${USERS_FILE}" 2>/dev/null; then
        die "用户 ${NAME} 已存在。"
    fi

    local NEW_UUID
    NEW_UUID="$(generate_uuid)"

    echo "${NAME}|${NEW_UUID}" >> "${USERS_FILE}"

    chmod 600 "${USERS_FILE}"

    write_config

    systemctl restart mihomo

    sleep 1

    if ! systemctl is-active --quiet mihomo; then

        warn "添加用户后 mihomo 启动失败。"

        journalctl \
            -u mihomo \
            --no-pager \
            -n 50

        exit 1
    fi

    # 生成该用户 URI
    local URI

    URI="vless://${NEW_UUID}@${PUBLIC_IPV4}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#mihomo-${NAME}"

    echo
    echo "用户添加成功：${NAME}"
    echo
    echo "UUID：${NEW_UUID}"
    echo
    echo "VLESS URI："
    echo
    echo "${URI}"
    echo

    # 生成独立文件
    cat > "${CLIENT_DIR}/${NAME}.yaml" <<EOF
proxies:
  - name: mihomo-${NAME}
    type: vless
    server: ${PUBLIC_IPV4}
    port: 443
    uuid: ${NEW_UUID}
    udp: true
    tls: true
    servername: ${SNI}
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
EOF

    cat > "${CLIENT_DIR}/${NAME}-sing-box.json" <<EOF
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "mihomo-${NAME}",
      "server": "${PUBLIC_IPV4}",
      "server_port": 443,
      "uuid": "${NEW_UUID}",
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

    echo "${URI}" > "${CLIENT_DIR}/${NAME}-v2rayn.txt"

    chown -R mihomo:mihomo "${CLIENT_DIR}"
    chmod 600 "${CLIENT_DIR}"/*

    info "客户端配置已生成。"
}

# ============================================================
# 删除用户
# ============================================================

del_user() {

    require_root

    local NAME="${1:-}"

    [[ -n "${NAME}" ]] ||
        die "用法：$0 del-user 用户名"

    grep -q "^${NAME}|" "${USERS_FILE}" ||
        die "用户 ${NAME} 不存在。"

    local COUNT

    COUNT="$(grep -c '|' "${USERS_FILE}")"

    if [[ "${COUNT}" -le 1 ]]; then
        die "不能删除最后一个用户。"
    fi

    cp "${USERS_FILE}" "${USERS_FILE}.bak"

    grep -v "^${NAME}|" \
        "${USERS_FILE}.bak" \
        > "${USERS_FILE}"

    rm -f \
        "${CLIENT_DIR}/${NAME}.yaml" \
        "${CLIENT_DIR}/${NAME}-sing-box.json" \
        "${CLIENT_DIR}/${NAME}-v2rayn.txt"

    write_config

    systemctl restart mihomo

    sleep 1

    if ! systemctl is-active --quiet mihomo; then

        warn "删除用户后 mihomo 启动失败，恢复旧配置。"

        cp "${USERS_FILE}.bak" "${USERS_FILE}"

        write_config

        systemctl restart mihomo

        exit 1
    fi

    echo "用户 ${NAME} 已删除。"
}

# ============================================================
# 用户列表
# ============================================================

list_users() {

    require_root

    echo
    echo "=============================="
    echo "        mihomo users"
    echo "=============================="
    echo

    if [[ ! -s "${USERS_FILE}" ]]; then
        echo "没有用户。"
        return
    fi

    printf "%-20s %s\n" "USERNAME" "UUID"
    printf "%-20s %s\n" "--------" "----"

    while IFS='|' read -r NAME UUID; do

        [[ -n "${NAME}" ]] || continue

        printf "%-20s %s\n" \
            "${NAME}" \
            "${UUID}"

    done < "${USERS_FILE}"

    echo
}

# ============================================================
# uninstall
# ============================================================

uninstall() {

    require_root

    echo
    echo "这将删除："
    echo
    echo "  mihomo"
    echo "  ${CONF_DIR}"
    echo "  systemd service"
    echo
    read -r -p "确认卸载？输入 YES： " ANSWER

    [[ "${ANSWER}" == "YES" ]] ||
        die "已取消。"

    systemctl disable --now mihomo 2>/dev/null || true

    rm -f "${SERVICE}"
    rm -f "${BIN}"

    systemctl daemon-reload

    rm -rf "${CONF_DIR}"

    rm -f /etc/sysctl.d/99-mihomo-bbr.conf
    rm -f /etc/sysctl.d/99-mihomo-network.conf

    sysctl --system >/dev/null 2>&1 || true

    echo
    echo "mihomo 已卸载。"
    echo
    echo "注意：没有删除 UFW/firewalld 中原有的 443 规则。"
}

# ============================================================
# main
# ============================================================

COMMAND="${1:-install}"

case "${COMMAND}" in

    install)
        install_all
        ;;

    status)
        status
        ;;

    restart)
        restart_service
        ;;

    add-user)
        add_user "${2:-}"
        ;;

    del-user)
        del_user "${2:-}"
        ;;

    list-user|list-users)
        list_users
        ;;

    uninstall)
        uninstall
        ;;

    *)
        echo
        echo "用法："
        echo
        echo "  $0 install"
        echo "  $0 status"
        echo "  $0 restart"
        echo "  $0 add-user 用户名"
        echo "  $0 del-user 用户名"
        echo "  $0 list-user"
        echo "  $0 uninstall"
        echo
        exit 1
        ;;
esac

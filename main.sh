#!/bin/bash

# -----------------------------------------------------
# 脚本名称: BBR3-Pro-Max (XanMod)
# 修复内容: 优化 GPG 密钥导入逻辑，增强 Debian 12 兼容性
# -----------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 1. 现状展示函数
show_status() {
    echo -e "${BLUE}================ 系统现状 ================${NC}"
    echo -e "当前内核版本: ${GREEN}$(uname -r)${NC}"
    
    current_algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    echo -e "当前 TCP 算法: ${GREEN}$current_algo${NC}"
    
    if modinfo tcp_bbr >/dev/null 2>&1; then
        bbr_ver=$(modinfo tcp_bbr | grep -i '^version:' | awk '{print $2}')
        [ -z "$bbr_ver" ] && bbr_ver="1.0 (Standard)"
        echo -e "BBR 模块版本: ${GREEN}$bbr_ver${NC}"
    else
        echo -e "BBR 模块状态: ${RED}未加载${NC}"
    fi
    
    echo -e "队列调度算法: ${GREEN}$(sysctl net.core.default_qdisc | awk '{print $3}')${NC}"
    echo -e "${BLUE}==========================================${NC}"
}

# 2. 环境检查
check_env() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}错误: 请以 root 权限运行此脚本！${NC}"
        exit 1
    fi
    VIRT=$(systemd-detect-virt)
    if [ "$VIRT" == "openvz" ] || [ "$VIRT" == "lxc" ]; then
        echo -e "${YELLOW}警告: 您的虚拟化架构是 $VIRT，更换内核通常会失败。${NC}"
    fi
}

# 3. 安装 BBR3 (XanMod)
install_bbr3() {
    echo -e "${YELLOW}正在检测 CPU 兼容级别...${NC}"
    FLAGS=$(grep -oE 'avx2|avx|sse4_2' /proc/cpuinfo | sort -u)
    if [[ $FLAGS == *"avx2"* ]]; then
        KERNEL_LEVEL="x64v3"
    elif [[ $FLAGS == *"sse4_2"* ]]; then
        KERNEL_LEVEL="x64v2"
    else
        KERNEL_LEVEL="x64v1"
    fi

    echo -e "${GREEN}1. 正在安装必要组件 (wget, gnupg2, curl)...${NC}"
    apt update && apt install -y wget gnupg2 curl lsb-release

    echo -e "${GREEN}2. 正在导入 XanMod GPG 密钥...${NC}"
    # 修复逻辑：双重尝试导入密钥
    rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg
    wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor --yes -o /usr/share/keyrings/xanmod-archive-keyring.gpg || \
    gpg --no-default-keyring --keyring /usr/share/keyrings/xanmod-archive-keyring.gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 86F7D09EE734E623

    echo -e "${GREEN}3. 正在添加 XanMod 官方仓库源...${NC}"
    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-kernel.list
    
    echo -e "${GREEN}4. 正在更新源并安装内核 linux-xanmod-$KERNEL_LEVEL...${NC}"
    apt update
    apt install -y linux-xanmod-$KERNEL_LEVEL

    echo -e "${GREEN}5. 正在配置 BBR3 网络参数...${NC}"
    cat > /etc/sysctl.d/99-bbr3.conf << EOF
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
EOF
    sysctl --system
    
    echo -e "---------------------------------------------------"
    echo -e "${GREEN}安装成功！${NC}"
    echo -e "内核已更新，必须重启才能生效。"
    echo -e "---------------------------------------------------"
}

# --- 主程序 ---
clear
echo -e "${YELLOW}BBR3-Pro-Max (XanMod) 一键管理工具${NC}"
check_env
show_status

echo -e "您可以选择："
echo -e "  ${GREEN}1)${NC} 立即安装 BBR3 (XanMod 内核)"
echo -e "  ${RED}2)${NC} 退出脚本"
echo -n "请选择 [1-2]: "
read choice

case $choice in
    1)
        install_bbr3
        read -p "是否立即重启? (y/n): " res
        [[ "$res" == "y" || "$res" == "Y" ]] && reboot
        ;;
    2)
        echo "已退出。"
        exit 0
        ;;
    *)
        echo "无效选项。"
        ;;
esac

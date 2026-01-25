#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 1. 现状展示函数
show_status() {
    echo -e "${BLUE}================ 系统现状 ================${NC}"
    echo -e "当前内核版本: ${GREEN}$(uname -r)${NC}"
    
    # 获取当前 TCP 算法
    current_algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    echo -e "当前 TCP 算法: ${GREEN}$current_algo${NC}"
    
    # 检查 BBR 模块版本
    if modinfo tcp_bbr >/dev/null 2>&1; then
        bbr_ver=$(modinfo tcp_bbr | grep -i '^version:' | awk '{print $2}')
        if [ -z "$bbr_ver" ]; then bbr_ver="1.0 (Standard)"; fi
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
        echo -e "${RED}注意: 您的虚拟化架构是 $VIRT，更换内核可能会失败。${NC}"
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

    echo -e "${GREEN}准备安装 XanMod-$KERNEL_LEVEL 内核...${NC}"
    apt update && apt install -y wget gnupg2 curl lsb-release
    curl -s https://dl.xanmod.org/archive.key | gpg --dearmor --yes -o /usr/share/keyrings/xanmod-archive-keyring.gpg
    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-kernel.list
    
    apt update && apt install -y linux-xanmod-$KERNEL_LEVEL

    # 写入配置
    cat > /etc/sysctl.d/99-bbr3.conf << EOF
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fastopen = 3
EOF
    sysctl --system
    
    echo -e "${GREEN}安装完成，请重启系统！${NC}"
}

# --- 主程序逻辑 ---

clear
echo -e "${YELLOW}BBR3 (XanMod) 一键管理工具${NC}"
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
        [ "$res" == "y" ] && reboot
        ;;
    2)
        echo "已退出。"
        exit 0
        ;;
    *)
        echo "无效选项。"
        ;;
esac

#!/bin/bash

# =========================================================
# 脚本名称: MTProto Proxy 管理脚本 (菜单版)
# 版本: 2.0 (Go Version)
# 功能: 一键安装、查看连接、日志排查、卸载管理
# =========================================================

# 定义颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查是否为 Root 用户
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# =========================================================
# 核心功能函数
# =========================================================

# 1. 安装基础依赖
check_dependencies() {
    echo -e "${YELLOW}正在检查系统依赖...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y
        apt-get install -y curl wget tar openssl grep
    elif [ -f /etc/redhat-release ]; then
        yum update -y
        yum install -y curl wget tar openssl grep
    fi
}

# 2. 获取公网 IP
get_public_ip() {
    local ip=$(curl -s 4.ipw.cn)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s ifconfig.me)
    fi
    echo $ip
}

# 3. 安装主逻辑
install_mtproto() {
    check_dependencies
    
    echo -e "${GREEN}>>> 开始安装流程${PLAIN}"

    # --- 设置端口 ---
    read -p "请输入代理端口 (默认随机 20000-60000): " input_port
    if [[ -z "$input_port" ]]; then
        PROXY_PORT=$((RANDOM % 40000 + 20000))
    else
        PROXY_PORT=$input_port
    fi
    
    # 检查端口占用
    if netstat -tlunp | grep -q ":$PROXY_PORT "; then
        echo -e "${RED}错误: 端口 $PROXY_PORT 已被占用，请更换其他端口。${PLAIN}"
        return
    fi

    # --- 生成密钥 ---
    # 使用 openssl 生成 16字节(32字符) 的 Hex 密钥
    PROXY_SECRET=$(openssl rand -hex 16)

    # --- 下载程序 ---
    echo -e "${YELLOW}正在检测系统架构...${PLAIN}"
    ARCH=$(uname -m)
    MTG_VERSION="2.1.7"
    DOWNLOAD_URL=""

    if [[ "$ARCH" == "x86_64" ]]; then
        DOWNLOAD_URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/mtg-${MTG_VERSION}-linux-amd64.tar.gz"
    elif [[ "$ARCH" == "aarch64" ]]; then
        DOWNLOAD_URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/mtg-${MTG_VERSION}-linux-arm64.tar.gz"
    else
        echo -e "${RED}不支持的架构: $ARCH${PLAIN}"
        return
    fi

    echo -e "${YELLOW}正在下载主程序...${PLAIN}"
    rm -f mtg.tar.gz
    wget -O mtg.tar.gz "$DOWNLOAD_URL"

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败，请检查网络。${PLAIN}"
        return
    fi

    # --- 解压与安装 ---
    tar -xzf mtg.tar.gz
    # 停止旧服务（如果存在）
    systemctl stop mtg 2>/dev/null
    
    # 移动文件
    mv mtg-${MTG_VERSION}-linux-*/mtg /usr/local/bin/mtg
    chmod +x /usr/local/bin/mtg
    rm -rf mtg.tar.gz mtg-${MTG_VERSION}-linux-*

    # --- 关键：兼容性测试 ---
    echo -e "${YELLOW}正在进行运行测试...${PLAIN}"
    /usr/local/bin/mtg version > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}严重错误: 下载的程序无法在此 VPS 上运行！安装终止。${PLAIN}"
        return
    fi

    # --- 配置 Systemd 服务 ---
    cat <<EOF > /etc/systemd/system/mtg.service
[Unit]
Description=MTProto Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mtg simple-run -n 0.0.0.0:${PROXY_PORT} ${PROXY_SECRET}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    # --- 启动服务 ---
    systemctl daemon-reload
    systemctl enable mtg
    systemctl start mtg

    # --- 配置防火墙 ---
    if command -v ufw > /dev/null; then
        ufw allow $PROXY_PORT/tcp
        ufw allow $PROXY_PORT/udp
    fi
    if command -v iptables > /dev/null; then
        iptables -I INPUT -p tcp --dport $PROXY_PORT -j ACCEPT
        iptables -I INPUT -p udp --dport $PROXY_PORT -j ACCEPT
    fi

    echo -e "${GREEN}安装完成！${PLAIN}"
    show_connection_info
}

# 4. 查看连接信息
show_connection_info() {
    # 从服务文件中读取配置，避免变量丢失
    if [ ! -f /etc/systemd/system/mtg.service ]; then
        echo -e "${RED}未检测到安装信息。${PLAIN}"
        return
    fi

    # 提取端口和密钥
    local cmd=$(grep "ExecStart" /etc/systemd/system/mtg.service)
    local port=$(echo $cmd | grep -oP '0.0.0.0:\K\d+')
    local secret=$(echo $cmd | awk '{print $NF}')
    local ip=$(get_public_ip)

    echo "========================================================"
    echo -e "   ${GREEN}MTProto 代理连接信息${PLAIN}"
    echo "========================================================"
    echo -e "IP 地址: ${YELLOW}$ip${PLAIN}"
    echo -e "端口   : ${YELLOW}$port${PLAIN}"
    echo -e "密钥   : ${YELLOW}$secret${PLAIN}"
    echo "--------------------------------------------------------"
    echo -e "TG 一键链接: "
    echo -e "${GREEN}tg://proxy?server=${ip}&port=${port}&secret=${secret}${PLAIN}"
    echo "========================================================"
}

# 5. 查看运行状态
check_status() {
    echo -e "${YELLOW}>>> 系统服务状态:${PLAIN}"
    systemctl status mtg --no-pager
}

# 6. 查看错误日志
view_log() {
    echo -e "${YELLOW}>>> 最近 20 行日志:${PLAIN}"
    journalctl -u mtg -n 20 --no-pager
}

# 7. 卸载代理
uninstall_mtproto() {
    echo -e "${YELLOW}正在停止服务...${PLAIN}"
    systemctl stop mtg
    systemctl disable mtg
    
    echo -e "${YELLOW}正在删除文件...${PLAIN}"
    rm -f /etc/systemd/system/mtg.service
    rm -f /usr/local/bin/mtg
    systemctl daemon-reload
    
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

# =========================================================
# 菜单主界面
# =========================================================

show_menu() {
    clear
    echo "========================================================"
    echo -e "${GREEN}MTProto Proxy 一键管理脚本 ${PLAIN}"
    echo -e "${YELLOW}注意: 如果连接失败，请检查云服务商网页防火墙是否放行端口${PLAIN}"
    echo "========================================================"
    echo "1. 安装 / 重装代理 (Install/Reinstall)"
    echo "2. 查看连接链接 (Show Link)"
    echo "3. 查看运行状态 (Check Status)"
    echo "4. 查看错误日志 (View Logs)"
    echo "5. 卸载代理 (Uninstall)"
    echo "0. 退出脚本 (Exit)"
    echo "========================================================"
    read -p "请输入数字 [0-5]: " num
    case "$num" in
        1)
            install_mtproto
            ;;
        2)
            show_connection_info
            ;;
        3)
            check_status
            ;;
        4)
            view_log
            ;;
        5)
            uninstall_mtproto
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的数字 [0-5]${PLAIN}"
            ;;
    esac
}

# 启动菜单
show_menu
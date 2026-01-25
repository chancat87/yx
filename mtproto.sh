#!/bin/bash

# =========================================================
# 脚本名称: MTProto + Cloudflare Tunnel 深度集成脚本
# 功能描述: 一键安装 MTG、配置隧道、支持快捷键 m 管理
# =========================================================

# --- 变量与路径定义 ---
MTG_BIN="/usr/local/bin/mtg"
MTG_SERVICE="/etc/systemd/system/mtg.service"
MTG_CONF="/etc/mtg_info"
SHORTCUT_BIN="/usr/local/bin/m"

# 颜色控制
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

# --- 基础环境检查 ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 请使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

# --- 核心功能函数 ---

# 1. 安装服务
install_services() {
    echo -e "${BLUE}开始环境检查与安装...${PLAIN}"
    
    # 安装必要组件
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install -y wget curl tar jq lsof
    elif [ -f /etc/redhat-release ]; then
        yum install -y wget curl tar jq lsof
    fi

    echo -e "${YELLOW}--- 端口与参数自定义 ---${PLAIN}"
    
    # 交互输入端口
    read -p "请输入 MTProto 监听端口 (建议非443，如 8443): " MY_PORT
    while [[ -z "$MY_PORT" ]]; do
        read -p "端口不能为空，请重新输入: " MY_PORT
    done

    read -p "请输入 WebSocket 端口 (用于隧道转发，如 8080): " MY_WS_PORT
    [[ -z "$MY_WS_PORT" ]] && MY_WS_PORT=8080

    read -p "请输入伪装域名 (如 google.com): " MY_DOMAIN
    [[ -z "$MY_DOMAIN" ]] && MY_DOMAIN="google.com"

    read -p "请输入你的 Cloudflare Tunnel Token: " CF_TOKEN
    while [[ -z "$CF_TOKEN" ]]; do
        read -p "Token 不能为空，请重新输入: " CF_TOKEN
    done

    # 下载 MTG (自动识别架构)
    echo -e "${BLUE}正在下载并配置 MTProto 代理...${PLAIN}"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        BIT="amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        BIT="arm64"
    else
        echo -e "${RED}不支持的 CPU 架构: $ARCH${PLAIN}"
        exit 1
    fi

    wget -O mtg.tar.gz "https://github.com/9seconds/mtg/releases/download/v2.1.7/mtg-linux-${BIT}.tar.gz"
    mkdir -p mtg_temp
    tar -xzf mtg.tar.gz -C mtg_temp --strip-components=1
    mv mtg_temp/mtg "$MTG_BIN"
    chmod +x "$MTG_BIN"
    rm -rf mtg.tar.gz mtg_temp

    # 生成密钥
    MY_SECRET=$($MTG_BIN generate-secret --hex "$MY_DOMAIN")

    # 创建 MTG 服务文件
    cat > "$MTG_SERVICE" <<EOF
[Unit]
Description=MTG Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=$MTG_BIN simple-run -b 0.0.0.0:$MY_PORT $MY_SECRET
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    # 安装 Cloudflare Tunnel
    echo -e "${BLUE}正在配置 Cloudflare Tunnel...${PLAIN}"
    if [[ "$BIT" == "amd64" ]]; then
        curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
        dpkg -i cloudflared.deb && rm cloudflared.deb
    else
        curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
        dpkg -i cloudflared.deb && rm cloudflared.deb
    fi

    # 注册隧道服务
    cloudflared service uninstall 2>/dev/null
    cloudflared service install "$CF_TOKEN"

    # 启动所有服务
    systemctl daemon-reload
    systemctl enable mtg
    systemctl restart mtg
    systemctl restart cloudflared

    # 保存配置信息到文件
    cat > "$MTG_CONF" <<EOF
PORT=$MY_PORT
WS_PORT=$MY_WS_PORT
DOMAIN=$MY_DOMAIN
SECRET=$MY_SECRET
EOF

    # 创建管理快捷键 m
    cp "$0" "$SHORTCUT_BIN"
    chmod +x "$SHORTCUT_BIN"

    echo -e "${GREEN}安装成功！${PLAIN}"
    echo -e "你可以直接输入 ${YELLOW}m${PLAIN} 来管理服务。"
    show_info
}

# 2. 显示连接信息
show_info() {
    if [ ! -f "$MTG_CONF" ]; then
        echo -e "${RED}未发现安装记录，请先执行安装。${PLAIN}"
        return
    fi
    source "$MTG_CONF"
    echo -e "\n${BLUE}========== MTProto 连接信息 ==========${PLAIN}"
    echo -e "本地监听端口: ${GREEN}$PORT${PLAIN}"
    echo -e "隧道转发端口: ${GREEN}$WS_PORT${PLAIN}"
    echo -e "伪装域名: ${YELLOW}$DOMAIN${PLAIN}"
    echo -e "代理密钥 (Secret): ${YELLOW}$SECRET${PLAIN}"
    echo -e "-------------------------------------"
    echo -e "MTG 进程状态: $(systemctl is-active mtg)"
    echo -e "CF 隧道状态: $(systemctl is-active cloudflared)"
    echo -e "-------------------------------------"
    echo -e "${BLUE}注意: 请在 CF 网页后台将 Public Hostname 指向:${PLAIN}"
    echo -e "${GREEN}Type: TCP | URL: localhost:$PORT${PLAIN}"
    echo -e "=====================================\n"
}

# 3. 日志管理
view_logs() {
    echo -e "1. 查看 MTProto 日志"
    echo -e "2. 查看 Cloudflare 隧道日志"
    read -p "请输入选择: " log_type
    case $log_type in
        1) journalctl -u mtg -f ;;
        2) journalctl -u cloudflared -f ;;
        *) echo "无效输入" ;;
    esac
}

# 4. 停止/启动/重启
manage_services() {
    local action=$1
    systemctl $action mtg
    systemctl $action cloudflared
    echo -e "${GREEN}服务已执行 $action 操作${PLAIN}"
}

# 5. 卸载
uninstall_all() {
    read -p "确定要彻底删除所有相关组件吗？(y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop mtg cloudflared
        systemctl disable mtg cloudflared
        rm -f "$MTG_BIN" "$MTG_SERVICE" "$MTG_CONF" "$SHORTCUT_BIN"
        cloudflared service uninstall
        echo -e "${GREEN}卸载完成。${PLAIN}"
    fi
}

# --- 主菜单 ---
main_menu() {
    clear
    echo -e "${BLUE}=========================================${PLAIN}"
    echo -e "${BLUE}    MTProto + Cloudflare Tunnel 管理    ${PLAIN}"
    echo -e "${BLUE}=========================================${PLAIN}"
    echo -e "1. ${GREEN}安装${PLAIN} 所有服务"
    echo -e "2. ${YELLOW}启动${PLAIN} 所有服务"
    echo -e "3. ${RED}停止${PLAIN} 所有服务"
    echo -e "4. ${BLUE}重启${PLAIN} 所有服务"
    echo -e "5. 查看 ${GREEN}状态与连接信息${PLAIN}"
    echo -e "6. 查看 ${YELLOW}实时日志${PLAIN}"
    echo -e "7. ${RED}卸载${PLAIN} 脚本与服务"
    echo -e "0. 退出"
    echo -e "${BLUE}=========================================${PLAIN}"
    read -p "请输入数字 [0-7]: " num

    case "$num" in
        1) install_services ;;
        2) manage_services "start" ;;
        3) manage_services "stop" ;;
        4) manage_services "restart" ;;
        5) show_info ;;
        6) view_logs ;;
        7) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误！${PLAIN}"; sleep 1; main_menu ;;
    esac
}

# 脚本入口
check_root
main_menu

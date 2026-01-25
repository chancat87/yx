#!/bin/bash

# =========================================================
# 脚本名称: MTProto + Cloudflare Tunnel 深度集成脚本 (增强版)
# 功能描述: 一键安装、隧道配置、快捷键 m、自动生成 TG 连接
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

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 请使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

# --- 核心功能函数 ---

install_services() {
    echo -e "${BLUE}开始环境检查与安装...${PLAIN}"
    
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install -y wget curl tar jq lsof
    elif [ -f /etc/redhat-release ]; then
        yum install -y wget curl tar jq lsof
    fi

    echo -e "${YELLOW}--- 端口与参数自定义 ---${PLAIN}"
    
    read -p "请输入 MTProto 监听端口 (建议如 18443): " MY_PORT
    while [[ -z "$MY_PORT" ]]; do
        read -p "端口不能为空，请重新输入: " MY_PORT
    done

    read -p "请输入伪装域名 (如 google.com): " MY_DOMAIN
    [[ -z "$MY_DOMAIN" ]] && MY_DOMAIN="google.com"

    read -p "请输入你的 Cloudflare Tunnel Token: " CF_TOKEN
    while [[ -z "$CF_TOKEN" ]]; do
        read -p "Token 不能为空，请重新输入: " CF_TOKEN
    done

    # 下载 MTG
    ARCH=$(uname -m)
    [[ "$ARCH" == "x86_64" ]] && BIT="amd64" || BIT="arm64"

    wget -O mtg.tar.gz "https://github.com/9seconds/mtg/releases/download/v2.1.7/mtg-linux-${BIT}.tar.gz"
    mkdir -p mtg_temp
    tar -xzf mtg.tar.gz -C mtg_temp --strip-components=1
    mv mtg_temp/mtg "$MTG_BIN"
    chmod +x "$MTG_BIN"
    rm -rf mtg.tar.gz mtg_temp

    # 生成密钥
    MY_SECRET=$($MTG_BIN generate-secret --hex "$MY_DOMAIN")

    # 创建 MTG 服务
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
    if [[ "$BIT" == "amd64" ]]; then
        curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    else
        curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
    fi
    dpkg -i cloudflared.deb && rm cloudflared.deb

    cloudflared service uninstall 2>/dev/null
    cloudflared service install "$CF_TOKEN"

    systemctl daemon-reload
    systemctl enable mtg
    systemctl restart mtg
    systemctl restart cloudflared

    # 保存配置
    cat > "$MTG_CONF" <<EOF
PORT=$MY_PORT
DOMAIN=$MY_DOMAIN
SECRET=$MY_SECRET
EOF

    cp "$0" "$SHORTCUT_BIN"
    chmod +x "$SHORTCUT_BIN"

    echo -e "${GREEN}安装成功！${PLAIN}"
    show_tg_link
}

# --- 重点修改：查看连接功能 ---
show_tg_link() {
    if [ ! -f "$MTG_CONF" ]; then
        echo -e "${RED}错误：未找到配置文件。请先安装服务。${PLAIN}"
        return
    fi
    source "$MTG_CONF"
    
    echo -e "\n${BLUE}========== MTProto 连接生成器 ==========${PLAIN}"
    echo -e "注意：由于使用了 Cloudflare 隧道，IP 已经隐藏。"
    echo -e "你需要输入你在 CF 后台绑定的那个域名。"
    read -p "请输入你在 CF 配置的域名 (如 proxy.yourdomain.com): " USER_CF_DOMAIN
    
    if [[ -z "$USER_CF_DOMAIN" ]]; then
        echo -e "${RED}未输入域名，无法生成链接。${PLAIN}"
    else
        TG_LINK="https://t.me/proxy?server=${USER_CF_DOMAIN}&port=443&secret=${SECRET}"
        echo -e "\n${GREEN}你的 Telegram 专用连接为：${PLAIN}"
        echo -e "${YELLOW}${TG_LINK}${PLAIN}"
        echo -e "\n${BLUE}参数详情：${PLAIN}"
        echo -e "服务器: ${USER_CF_DOMAIN}"
        echo -e "端口: 443"
        echo -e "密钥: ${SECRET}"
    fi
    echo -e "========================================\n"
    read -n 1 -s -r -p "按任意键返回菜单..."
}

show_status() {
    if [ ! -f "$MTG_CONF" ]; then
        echo -e "${RED}未发现安装记录。${PLAIN}"
        return
    fi
    source "$MTG_CONF"
    echo -e "\n${BLUE}--- 服务状态 ---${PLAIN}"
    echo -e "MTG 状态: $(systemctl is-active mtg)"
    echo -e "CF  状态: $(systemctl is-active cloudflared)"
    echo -e "本地端口: $PORT"
    echo -e "----------------\n"
}

view_logs() {
    echo -e "1. 查看 MTProto 日志"
    echo -e "2. 查看 Cloudflare 日志"
    read -p "选择: " log_choice
    [[ "$log_choice" == "1" ]] && journalctl -u mtg -f
    [[ "$log_choice" == "2" ]] && journalctl -u cloudflared -f
}

uninstall_all() {
    read -p "确定卸载吗？(y/n): " confirm
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
    echo -e "2. 查看 ${YELLOW}Telegram 点击直连链接${PLAIN}"
    echo -e "3. 查看 ${GREEN}详细运行状态${PLAIN}"
    echo -e "4. ${BLUE}重启${PLAIN} 所有服务"
    echo -e "5. 停止 所有服务"
    echo -e "6. 查看 实时日志"
    echo -e "7. ${RED}卸载${PLAIN} 脚本与服务"
    echo -e "0. 退出"
    echo -e "${BLUE}=========================================${PLAIN}"
    read -p "请输入数字 [0-7]: " num

    case "$num" in
        1) install_services ;;
        2) show_tg_link ;;
        3) show_status ;;
        4) systemctl restart mtg cloudflared && echo "已重启" ;;
        5) systemctl stop mtg cloudflared && echo "已停止" ;;
        6) view_logs ;;
        7) uninstall_all ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

check_root
main_menu

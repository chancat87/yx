#!/bin/bash

# =========================================================
# 脚本名称: MTProto + Cloudflare Tunnel 旗舰版
# 脚本版本: v1.0.2
# 更新说明: 修复 Secret 读取失败问题，增强配置持久化，增加版本号显示
# =========================================================

MTG_BIN="/usr/local/bin/mtg"
MTG_SERVICE="/etc/systemd/system/mtg.service"
MTG_CONF="/etc/mtg_info"
SHORTCUT_BIN="/usr/local/bin/m"
VERSION="v1.0.2"

# 颜色
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 请使用 root 用户运行${PLAIN}" && exit 1
}

# 安装功能
install_services() {
    echo -e "${BLUE}开始安装 (版本: $VERSION)...${PLAIN}"
    
    # 基础依赖
    apt-get update -y && apt-get install -y wget curl tar jq lsof
    
    # 获取参数
    echo -e "${YELLOW}--- 配置自定义参数 ---${PLAIN}"
    read -p "1. 请输入 MTProto 监听端口 (建议如 18443): " MY_PORT
    read -p "2. 请输入伪装域名 (默认 google.com): " MY_DOMAIN
    [[ -z "$MY_DOMAIN" ]] && MY_DOMAIN="google.com"
    read -p "3. 请输入 Cloudflare Tunnel Token: " CF_TOKEN
    
    # 下载 MTG
    ARCH=$(uname -m)
    [[ "$ARCH" == "x86_64" ]] && BIT="amd64" || BIT="arm64"
    wget -O mtg.tar.gz "https://github.com/9seconds/mtg/releases/download/v2.1.7/mtg-linux-${BIT}.tar.gz"
    tar -xzf mtg.tar.gz && mv mtg-*/mtg "$MTG_BIN" && chmod +x "$MTG_BIN"
    rm -rf mtg.tar.gz mtg-*

    # 生成 Secret
    echo -e "${YELLOW}正在生成加密密钥...${PLAIN}"
    MY_SECRET=$($MTG_BIN generate-secret --hex "$MY_DOMAIN")
    
    # 【核心修复】保存到配置文件
    cat > "$MTG_CONF" <<EOF
PORT=$MY_PORT
DOMAIN=$MY_DOMAIN
SECRET=$MY_SECRET
VERSION=$VERSION
EOF

    # 创建 MTG 服务
    cat > "$MTG_SERVICE" <<EOF
[Unit]
Description=MTG Proxy
After=network.target

[Service]
Type=simple
ExecStart=$MTG_BIN simple-run -b 0.0.0.0:$MY_PORT $MY_SECRET
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # 安装 CF Tunnel
    echo -e "${BLUE}配置 Cloudflare 隧道...${PLAIN}"
    if [[ "$BIT" == "amd64" ]]; then
        curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    else
        curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
    fi
    dpkg -i cloudflared.deb && rm cloudflared.deb
    
    cloudflared service uninstall 2>/dev/null
    cloudflared service install "$CF_TOKEN"

    # 启动
    systemctl daemon-reload
    systemctl enable mtg
    systemctl restart mtg
    systemctl restart cloudflared

    # 快捷键
    cp "$0" "$SHORTCUT_BIN" && chmod +x "$SHORTCUT_BIN"
    
    echo -e "${GREEN}安装完成！${PLAIN}"
    show_tg_link
}

# 查看连接 (增强修复版)
show_tg_link() {
    if [ ! -f "$MTG_CONF" ]; then
        echo -e "${RED}错误：未找到配置文件，请先执行选项 1 进行安装。${PLAIN}"
        return
    fi
    
    # 强制重新加载配置
    source "$MTG_CONF"
    
    # 如果 source 失败，则从服务文件尝试提取
    if [[ -z "$SECRET" ]]; then
        SECRET=$(grep -oP 'simple-run -b 0.0.0.0:\d+ \K\S+' "$MTG_SERVICE" 2>/dev/null)
    fi

    echo -e "\n${BLUE}========== Telegram 连接信息 ==========${PLAIN}"
    echo -e "注意：端口请统一使用 ${YELLOW}443${PLAIN} (由 CF 隧道转发)"
    read -p "请输入你在 CF 绑定的域名 (如 aaa.abcai.online): " USER_DOMAIN
    
    if [[ -n "$USER_DOMAIN" && -n "$SECRET" ]]; then
        LINK="https://t.me/proxy?server=${USER_DOMAIN}&port=443&secret=${SECRET}"
        echo -e "\n${GREEN}点击以下链接即可直连：${PLAIN}"
        echo -e "${YELLOW}${LINK}${PLAIN}"
        echo -e "\n--- 手动配置信息 ---"
        echo -e "服务器: ${USER_DOMAIN}"
        echo -e "端口: 443"
        echo -e "密钥: ${SECRET}"
    else
        echo -e "${RED}错误：未能提取到有效的 Secret 密钥。${PLAIN}"
        echo -e "建议执行选项 1 重新安装。"
    fi
    echo -e "=======================================\n"
    read -p "按回车返回菜单..."
}

# 管理菜单
main_menu() {
    clear
    echo -e "${BLUE}=========================================${PLAIN}"
    echo -e "    MTProto + CF 一键管理脚本 [${YELLOW}$VERSION${BLUE}]    "
    echo -e "=========================================${PLAIN}"
    echo -e "1. ${GREEN}安装/重装${PLAIN} 所有服务"
    echo -e "2. ${YELLOW}查看 Telegram 点击直连链接${PLAIN}"
    echo -e "3. 查看 运行状态"
    echo -e "4. 查看 实时日志"
    echo -e "5. ${RED}卸载${PLAIN} 所有组件"
    echo -e "0. 退出"
    echo -e "${BLUE}=========================================${PLAIN}"
    read -p "请输入数字 [0-5]: " num

    case "$num" in
        1) install_services ;;
        2) show_tg_link ;;
        3) 
            echo -e "--- MTG 状态 ---"
            systemctl status mtg --no-pager
            echo -e "\n--- Cloudflare 状态 ---"
            systemctl status cloudflared --no-pager
            read -p "回车返回..." ;;
        4) journalctl -u mtg -f ;;
        5) 
            systemctl stop mtg cloudflared
            systemctl disable mtg cloudflared
            rm -f "$MTG_BIN" "$MTG_SERVICE" "$MTG_CONF" "$SHORTCUT_BIN"
            cloudflared service uninstall 2>/dev/null
            echo -e "${GREEN}卸载完毕！${PLAIN}"
            sleep 2 ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

check_root
main_menu

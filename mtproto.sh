#!/bin/bash

# =========================================================
# 脚本名称: MTProto + Cloudflare Tunnel 旗舰版
# 修复内容: 彻底解决 Secret 显示为空及服务启动失败的问题
# =========================================================

MTG_BIN="/usr/local/bin/mtg"
MTG_SERVICE="/etc/systemd/system/mtg.service"
MTG_CONF="/etc/mtg_info"
SHORTCUT_BIN="/usr/local/bin/m"

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
    echo -e "${BLUE}开始安装...${PLAIN}"
    
    # 基础依赖
    apt-get update -y && apt-get install -y wget curl tar jq lsof
    
    # 获取参数
    read -p "1. 请输入 MTProto 监听端口 (建议 18443): " MY_PORT
    read -p "2. 请输入伪装域名 (默认 google.com): " MY_DOMAIN
    [[ -z "$MY_DOMAIN" ]] && MY_DOMAIN="google.com"
    read -p "3. 请输入 Cloudflare Tunnel Token: " CF_TOKEN
    
    # 下载 MTG
    ARCH=$(uname -m)
    [[ "$ARCH" == "x86_64" ]] && BIT="amd64" || BIT="arm64"
    wget -O mtg.tar.gz "https://github.com/9seconds/mtg/releases/download/v2.1.7/mtg-linux-${BIT}.tar.gz"
    tar -xzf mtg.tar.gz && mv mtg-*/mtg "$MTG_BIN" && chmod +x "$MTG_BIN"
    rm -rf mtg.tar.gz mtg-*

    # 生成 Secret (关键点)
    echo -e "${YELLOW}正在生成密钥...${PLAIN}"
    MY_SECRET=$($MTG_BIN generate-secret --hex "$MY_DOMAIN")
    
    # 写入配置文件 (确保数据持久化)
    cat > "$MTG_CONF" <<EOF
PORT=$MY_PORT
DOMAIN=$MY_DOMAIN
SECRET=$MY_SECRET
EOF

    # 创建 MTG 服务
    cat > "$MTG_SERVICE" <<EOF
[Unit]
Description=MTG Proxy
After=network.target

[Service]
ExecStart=$MTG_BIN simple-run -b 0.0.0.0:$MY_PORT $MY_SECRET
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    # 安装 CF Tunnel
    curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
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
    
    echo -e "${GREEN}安装完成！请输入 m 管理。${PLAIN}"
}

# 查看连接 (修复版)
show_tg_link() {
    if [ ! -f "$MTG_CONF" ]; then
        echo -e "${RED}请先安装服务！${PLAIN}"
        return
    fi
    # 重新加载配置
    source "$MTG_CONF"
    
    # 如果变量还是空的，手动从服务文件抓取一次
    if [[ -z "$SECRET" ]]; then
        SECRET=$(grep -oP 'simple-run -b 0.0.0.0:\d+ \K\S+' "$MTG_SERVICE")
    fi

    echo -e "\n${BLUE}========== Telegram 连接信息 ==========${PLAIN}"
    read -p "请输入你在 CF 后台绑定的域名 (如 aaa.abcai.online): " USER_DOMAIN
    
    if [[ -n "$USER_DOMAIN" && -n "$SECRET" ]]; then
        LINK="https://t.me/proxy?server=${USER_DOMAIN}&port=443&secret=${SECRET}"
        echo -e "\n${GREEN}直接点击下面的链接即可连接：${PLAIN}"
        echo -e "${YELLOW}${LINK}${PLAIN}"
        echo -e "\n配置详情："
        echo -e "服务器: ${USER_DOMAIN}"
        echo -e "端口: 443"
        echo -e "密钥: ${SECRET}"
    else
        echo -e "${RED}错误：无法获取密钥或未输入域名。${PLAIN}"
    fi
    echo -e "=======================================\n"
    read -p "按回车返回菜单..."
}

# 菜单逻辑 (展开显示)
main_menu() {
    clear
    echo -e "${BLUE}=========================================${PLAIN}"
    echo -e "        MTProto + CF 一键管理脚本        "
    echo -e "=========================================${PLAIN}"
    echo -e "1. 安装/重装所有服务"
    echo -e "2. ${GREEN}查看 Telegram 直连链接${PLAIN}"
    echo -e "3. 查看状态"
    echo -e "4. 查看日志"
    echo -e "5. 卸载服务"
    echo -e "0. 退出"
    read -p "请输入数字: " num
    case "$num" in
        1) install_services ;;
        2) show_tg_link ;;
        3) systemctl status mtg cloudflared ;;
        4) journalctl -u mtg -f ;;
        5) 
            systemctl stop mtg cloudflared
            rm -f "$MTG_BIN" "$MTG_SERVICE" "$MTG_CONF" "$SHORTCUT_BIN"
            echo "已卸载"
            ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

check_root
main_menu

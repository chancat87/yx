#!/bin/bash

# =========================================================
#  VPS 多协议代理一键管理脚本 (SOCKS5 + HTTP)
#  基于 GOST v2
# =========================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 检查是否为 Root 用户
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：请使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# 基础变量
SERVICE_NAME="gost"
CONFIG_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GOST_PATH="/usr/bin/gost"

# ---------------------------------------------------------
#  辅助函数
# ---------------------------------------------------------

# 暂停并返回主菜单
function wait_and_return() {
    echo -e ""
    read -n 1 -s -r -p "按任意键回到主菜单..."
    show_menu
}

# 检查系统架构并下载对应版本的 GOST
function download_gost() {
    echo -e "${GREEN}正在检测系统架构...${PLAIN}"
    ARCH=$(uname -m)
    VERSION="2.11.5" # 使用稳定版本
    
    case $ARCH in
        x86_64)
            URL="https://github.com/ginuerzh/gost/releases/download/v${VERSION}/gost-linux-amd64-${VERSION}.gz"
            FILENAME="gost-linux-amd64-${VERSION}.gz"
            ;;
        aarch64)
            URL="https://github.com/ginuerzh/gost/releases/download/v${VERSION}/gost-linux-arm64-${VERSION}.gz"
            FILENAME="gost-linux-arm64-${VERSION}.gz"
            ;;
        *)
            echo -e "${RED}不支持的架构: ${ARCH}${PLAIN}"
            return 1
            ;;
    esac

    echo -e "${GREEN}正在下载 GOST (${ARCH})...${PLAIN}"
    wget -O "$FILENAME" "$URL"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败，请检查网络连接。${PLAIN}"
        return 1
    fi

    echo -e "${GREEN}正在安装...${PLAIN}"
    gzip -d "$FILENAME"
    chmod +x "gost-linux-${ARCH}-${VERSION}"
    mv "gost-linux-${ARCH}-${VERSION}" "$GOST_PATH"
    
    echo -e "${GREEN}GOST 安装完成！${PLAIN}"
}

# ---------------------------------------------------------
#  核心功能函数
# ---------------------------------------------------------

# 1. 安装代理
function install_proxy() {
    echo -e "${SKYBLUE}>>> 开始安装代理服务${PLAIN}"
    
    # 检查是否已安装
    if [[ -f "$GOST_PATH" ]]; then
        echo -e "${YELLOW}检测到 GOST 已安装，跳过下载步骤。${PLAIN}"
    else
        download_gost
        if [[ $? -ne 0 ]]; then wait_and_return; return; fi
    fi

    # 获取配置信息
    echo -e ""
    read -p "请输入代理端口 (默认 1080): " PORT
    [[ -z "$PORT" ]] && PORT="1080"

    echo -e ""
    read -p "请输入用户名 (留空则无密码): " USER
    read -p "请输入密码 (留空则无密码): " PASS

    # 构建启动参数
    if [[ -z "$USER" || -z "$PASS" ]]; then
        EXEC_CMD="$GOST_PATH -L :$PORT"
        AUTH_INFO="无认证"
    else
        EXEC_CMD="$GOST_PATH -L ${USER}:${PASS}@:$PORT"
        AUTH_INFO="${USER}:${PASS}"
    fi

    # 创建 Systemd 服务文件
    cat > "$CONFIG_FILE" <<EOF
[Unit]
Description=GOST Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=$EXEC_CMD
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

    # 开放防火墙端口 (尝试适配 ufw 和 firewalld)
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$PORT"/tcp
        ufw allow "$PORT"/udp
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --zone=public --add-port="$PORT"/tcp --permanent
        firewall-cmd --zone=public --add-port="$PORT"/udp --permanent
        firewall-cmd --reload
    fi

    echo -e ""
    echo -e "${GREEN}====================================${PLAIN}"
    echo -e "${GREEN}  代理安装并启动成功！${PLAIN}"
    echo -e "${GREEN}====================================${PLAIN}"
    echo -e " 协议类型 : ${SKYBLUE}HTTP 和 SOCKS5 (同端口)${PLAIN}"
    echo -e " 端口     : ${SKYBLUE}${PORT}${PLAIN}"
    echo -e " 认证信息 : ${SKYBLUE}${AUTH_INFO}${PLAIN}"
    echo -e "${GREEN}====================================${PLAIN}"
    
    wait_and_return
}

# 2. 卸载代理
function uninstall_proxy() {
    echo -e "${YELLOW}正在停止并移除服务...${PLAIN}"
    systemctl stop "$SERVICE_NAME"
    systemctl disable "$SERVICE_NAME"
    rm -f "$CONFIG_FILE"
    systemctl daemon-reload
    
    echo -e "${YELLOW}正在删除程序文件...${PLAIN}"
    rm -f "$GOST_PATH"
    
    echo -e "${GREEN}卸载完成。${PLAIN}"
    wait_and_return
}

# 3. 启动服务
function start_proxy() {
    systemctl start "$SERVICE_NAME"
    echo -e "${GREEN}服务已启动。${PLAIN}"
    wait_and_return
}

# 4. 停止服务
function stop_proxy() {
    systemctl stop "$SERVICE_NAME"
    echo -e "${YELLOW}服务已停止。${PLAIN}"
    wait_and_return
}

# 5. 重启服务
function restart_proxy() {
    systemctl restart "$SERVICE_NAME"
    echo -e "${GREEN}服务已重启。${PLAIN}"
    wait_and_return
}

# 6. 查看连接数
function view_connections() {
    echo -e "${SKYBLUE}>>> 正在检查代理连接数${PLAIN}"
    
    # 获取当前运行的端口
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}服务未安装。${PLAIN}"
        wait_and_return
        return
    fi
    
    # 从服务文件中提取端口号
    CURRENT_PORT=$(grep "ExecStart" "$CONFIG_FILE" | grep -oE ":[0-9]+" | tail -1 | tr -d ':')
    
    if [[ -z "$CURRENT_PORT" ]]; then
        echo -e "${RED}无法获取端口信息，请确认服务是否正常运行。${PLAIN}"
    else
        echo -e "当前监听端口: ${GREEN}${CURRENT_PORT}${PLAIN}"
        echo -e "---------------------------------"
        
        # 使用 netstat 或 ss 统计连接
        if command -v netstat >/dev/null 2>&1; then
            CONN_COUNT=$(netstat -anp | grep ":${CURRENT_PORT} " | grep ESTABLISHED | wc -l)
        else
            CONN_COUNT=$(ss -anp | grep ":${CURRENT_PORT} " | grep ESTAB | wc -l)
        fi
        
        echo -e "当前活跃连接数 (ESTABLISHED): ${GREEN}${CONN_COUNT}${PLAIN}"
    fi
    
    wait_and_return
}

# 7. 查看服务状态
function check_status() {
    systemctl status "$SERVICE_NAME" --no-pager
    wait_and_return
}

# ---------------------------------------------------------
#  主菜单
# ---------------------------------------------------------
function show_menu() {
    clear
    echo -e "${SKYBLUE}====================================${PLAIN}"
    echo -e "${SKYBLUE}    VPS 代理一键管理脚本 (GOST)     ${PLAIN}"
    echo -e "${SKYBLUE}====================================${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 安装/重装代理 (HTTP+SOCKS5)"
    echo -e "${GREEN}2.${PLAIN} 卸载代理"
    echo -e "------------------------------------"
    echo -e "${GREEN}3.${PLAIN} 启动服务"
    echo -e "${GREEN}4.${PLAIN} 停止服务"
    echo -e "${GREEN}5.${PLAIN} 重启服务"
    echo -e "------------------------------------"
    echo -e "${GREEN}6.${PLAIN} 查看连接数 (监控)"
    echo -e "${GREEN}7.${PLAIN} 查看运行状态 (Systemd)"
    echo -e "------------------------------------"
    echo -e "${GREEN}0.${PLAIN} 退出脚本"
    echo -e ""
    
    read -p "请输入数字 [0-7]: " choice
    case $choice in
        1) install_proxy ;;
        2) uninstall_proxy ;;
        3) start_proxy ;;
        4) stop_proxy ;;
        5) restart_proxy ;;
        6) view_connections ;;
        7) check_status ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效，请重新输入！${PLAIN}"; sleep 1; show_menu ;;
    esac
}

# 启动脚本时直接进入菜单
show_menu
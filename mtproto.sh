#!/bin/bash

# =========================================================
#  VPS 多协议代理一键管理脚本 (GOST v2) - x86_64 专用版
#  功能：HTTP/SOCKS5 代理搭建、连接监控、服务管理
# =========================================================

# --- 基础配置 ---
# 字体颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 核心路径与服务名
GOST_PATH="/usr/bin/gost"
SERVICE_NAME="gost"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GOST_VERSION="2.11.5"
# 锁定 x86_64 下载链接，修复之前的版本错误问题
DOWNLOAD_URL="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-amd64-${GOST_VERSION}.gz"

# --- 辅助函数 ---

# 检查是否为 Root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：请使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

# 暂停并返回主菜单
wait_and_return() {
    echo -e ""
    read -n 1 -s -r -p "按任意键回到主菜单..."
    show_menu
}

# --- 核心功能函数 ---

# 1. 安装代理 (包含修复功能)
install_proxy() {
    echo -e "${SKYBLUE}>>> 开始安装/重装 GOST 代理服务 (x86_64)${PLAIN}"

    # 1.1 停止旧服务
    systemctl stop $SERVICE_NAME >/dev/null 2>&1

    # 1.2 下载并安装二进制文件
    echo -e "${GREEN}正在下载 GOST 程序文件...${PLAIN}"
    # 强制删除旧文件，防止残留
    rm -f "$GOST_PATH" 
    
    wget --no-check-certificate -O gost.gz "$DOWNLOAD_URL"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败！请检查服务器网络连接。${PLAIN}"
        return 1
    fi

    echo -e "${GREEN}正在解压并安装...${PLAIN}"
    gzip -d gost.gz
    mv gost "$GOST_PATH"
    chmod +x "$GOST_PATH"

    # 验证安装是否成功
    if "$GOST_PATH" -V >/dev/null 2>&1; then
        echo -e "${GREEN}程序安装成功！${PLAIN}"
    else
        echo -e "${RED}程序安装失败 (无法执行)，请联系开发者。${PLAIN}"
        rm -f "$GOST_PATH"
        return 1
    fi

    # 1.3 配置参数
    echo -e ""
    echo -e "${YELLOW}请配置代理参数：${PLAIN}"
    read -p "请输入端口 (默认 1080): " PORT
    [[ -z "$PORT" ]] && PORT="1080"

    read -p "请输入用户名 (直接回车表示无密码): " USER
    read -p "请输入密码 (直接回车表示无密码): " PASS

    # 构建启动命令
    if [[ -z "$USER" || -z "$PASS" ]]; then
        EXEC_CMD="$GOST_PATH -L :$PORT"
        AUTH_INFO="无认证"
    else
        EXEC_CMD="$GOST_PATH -L ${USER}:${PASS}@:$PORT"
        AUTH_INFO="${USER}:${PASS}"
    fi

    # 1.4 创建 Systemd 服务文件
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GOST Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=$EXEC_CMD
Restart=always
User=root
# 增加文件描述符限制，防止高并发断连
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    # 1.5 启动服务
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"

    # 1.6 开放防火墙
    echo -e "${GREEN}正在配置防火墙...${PLAIN}"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$PORT"/tcp
        ufw allow "$PORT"/udp
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --zone=public --add-port="$PORT"/tcp --permanent
        firewall-cmd --zone=public --add-port="$PORT"/udp --permanent
        firewall-cmd --reload
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
    fi

    # 1.7 显示结果
    echo -e ""
    echo -e "${GREEN}====================================${PLAIN}"
    echo -e "${GREEN}  代理安装完成并已启动！${PLAIN}"
    echo -e "${GREEN}====================================${PLAIN}"
    echo -e " 协议类型 : ${SKYBLUE}HTTP + SOCKS5 (共用端口)${PLAIN}"
    echo -e " 端口     : ${SKYBLUE}${PORT}${PLAIN}"
    echo -e " 认证信息 : ${SKYBLUE}${AUTH_INFO}${PLAIN}"
    echo -e "${GREEN}====================================${PLAIN}"
    
    # 自动检查一次状态
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e " 服务状态 : ${GREEN}运行中 (Active)${PLAIN}"
    else
        echo -e " 服务状态 : ${RED}启动失败，请检查日志 (选项7)${PLAIN}"
    fi

    wait_and_return
}

# 2. 卸载代理
uninstall_proxy() {
    echo -e "${YELLOW}正在停止服务...${PLAIN}"
    systemctl stop "$SERVICE_NAME"
    systemctl disable "$SERVICE_NAME"
    
    echo -e "${YELLOW}正在清理文件...${PLAIN}"
    rm -f "$SERVICE_FILE"
    rm -f "$GOST_PATH"
    systemctl daemon-reload
    
    echo -e "${GREEN}卸载完成。${PLAIN}"
    wait_and_return
}

# 3. 启动服务
start_proxy() {
    systemctl start "$SERVICE_NAME"
    echo -e "${GREEN}服务已启动。${PLAIN}"
    wait_and_return
}

# 4. 停止服务
stop_proxy() {
    systemctl stop "$SERVICE_NAME"
    echo -e "${YELLOW}服务已停止。${PLAIN}"
    wait_and_return
}

# 5. 重启服务
restart_proxy() {
    systemctl restart "$SERVICE_NAME"
    echo -e "${GREEN}服务已重启。${PLAIN}"
    wait_and_return
}

# 6. 查看连接数
view_connections() {
    echo -e "${SKYBLUE}>>> 正在检查代理连接监控${PLAIN}"
    
    if [[ ! -f "$SERVICE_FILE" ]]; then
        echo -e "${RED}服务未安装，无法查看。${PLAIN}"
        wait_and_return
        return
    fi
    
    # 提取端口
    CURRENT_PORT=$(grep "ExecStart" "$SERVICE_FILE" | grep -oE ":[0-9]+" | tail -1 | tr -d ':')
    
    if [[ -z "$CURRENT_PORT" ]]; then
        echo -e "${RED}无法获取端口信息。${PLAIN}"
    else
        echo -e "当前监听端口: ${GREEN}${CURRENT_PORT}${PLAIN}"
        echo -e "---------------------------------"
        
        # 统计连接数 (优先使用 ss，如果没有则使用 netstat)
        if command -v ss >/dev/null 2>&1; then
            CONN_COUNT=$(ss -anp | grep ":${CURRENT_PORT} " | grep ESTAB | wc -l)
        elif command -v netstat >/dev/null 2>&1; then
            CONN_COUNT=$(netstat -anp | grep ":${CURRENT_PORT} " | grep ESTABLISHED | wc -l)
        else
            echo -e "${RED}未找到 ss 或 netstat 命令，无法统计。${PLAIN}"
            wait_and_return
            return
        fi
        
        echo -e "当前活跃连接数 (ESTABLISHED): ${GREEN}${CONN_COUNT}${PLAIN}"
    fi
    
    wait_and_return
}

# 7. 查看运行状态
check_status() {
    echo -e "${SKYBLUE}>>> Systemd 服务状态日志${PLAIN}"
    systemctl status "$SERVICE_NAME" --no-pager
    wait_and_return
}

# --- 菜单界面 ---

show_menu() {
    check_root
    clear
    echo -e "${SKYBLUE}====================================${PLAIN}"
    echo -e "${SKYBLUE}    VPS 代理一键管理脚本 (GOST)     ${PLAIN}"
    echo -e "${SKYBLUE}    架构: x86_64 专用版             ${PLAIN}"
    echo -e "${SKYBLUE}====================================${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 安装/重装代理 (修复 203 错误)"
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

# 脚本入口
show_menu
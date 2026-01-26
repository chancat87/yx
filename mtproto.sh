#!/bin/bash

# =========================================================
# 脚本名称: MTProto Proxy (无 Systemd / Nohup版)
# 适用环境: 所有 Linux 发行版 (包括严重受限的 LXC/Docker 容器)
# 核心原理: 使用 Python + Nohup 后台运行，绕过系统服务限制
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'
WORKDIR="/opt/mtproto_proxy"

# 检查 Root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 用户运行此脚本。${PLAIN}"
    exit 1
fi

# =========================================================
# 1. 环境安装
# =========================================================
install_env() {
    echo -e "${YELLOW}>>> 正在安装 Python 环境...${PLAIN}"
    
    if [ -f /etc/debian_version ]; then
        apt-get update -y
        # 强制安装，忽略错误
        apt-get install -y git python3 python3-pip curl grep || true
        # 尝试安装依赖库 (如果 apt 失败则忽略，Python 自带库通常够用)
        apt-get install -y python3-cryptography python3-uvloop || true
    elif [ -f /etc/redhat-release ]; then
        yum update -y
        yum install -y git python3 python3-pip curl grep || true
    fi

    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}Python3 安装失败，请尝试手动安装。${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}环境准备完毕。${PLAIN}"
}

# =========================================================
# 2. 安装并启动
# =========================================================
install_and_run() {
    install_env

    # 1. 清理旧进程
    pkill -f "mtprotoproxy.py"
    rm -rf "$WORKDIR"

    # 2. 下载源码
    echo -e "${YELLOW}>>> 正在拉取源码...${PLAIN}"
    git clone https://github.com/alexbers/mtprotoproxy.git "$WORKDIR"
    
    if [ ! -d "$WORKDIR" ]; then
        echo -e "${RED}源码下载失败，请检查网络。${PLAIN}"
        return
    fi

    # 3. 设置端口和密钥
    DEFAULT_PORT=$((RANDOM % 10000 + 20000))
    read -p "请输入端口 (默认 $DEFAULT_PORT): " INPUT_PORT
    PROXY_PORT=${INPUT_PORT:-$DEFAULT_PORT}
    
    PROXY_SECRET=$(head -c 16 /dev/urandom | xxd -ps)

    # 4. 使用 nohup 启动 (关键修改)
    echo -e "${YELLOW}>>> 正在启动服务...${PLAIN}"
    cd "$WORKDIR"
    
    # nohup 也就是 "No Hang Up"，让程序在后台不挂断运行
    # 日志会输出到 log.txt
    nohup python3 mtprotoproxy.py -p $PROXY_PORT -s $PROXY_SECRET > log.txt 2>&1 &
    
    sleep 2
    
    # 5. 检查是否存活
    if pgrep -f "mtprotoproxy.py" > /dev/null; then
        # 保存配置信息到文件，方便下次读取
        echo "PORT=$PROXY_PORT" > "$WORKDIR/config.env"
        echo "SECRET=$PROXY_SECRET" >> "$WORKDIR/config.env"
        
        show_info $PROXY_PORT $PROXY_SECRET
    else
        echo -e "${RED}启动失败！请查看日志:${PLAIN}"
        cat "$WORKDIR/log.txt"
    fi
}

# =========================================================
# 3. 显示信息
# =========================================================
show_info() {
    local port=$1
    local secret=$2
    local ip=$(curl -s 4.ipw.cn || curl -s ifconfig.me)

    # 如果参数为空，尝试从文件读取
    if [[ -z "$port" ]] && [[ -f "$WORKDIR/config.env" ]]; then
        source "$WORKDIR/config.env"
        port=$PORT
        secret=$SECRET
    fi

    echo "========================================================"
    echo -e "   ${GREEN}MTProto 代理 (Nohup版) 运行中${PLAIN}"
    echo "========================================================"
    echo -e "IP 地址: ${YELLOW}$ip${PLAIN}"
    echo -e "端口   : ${YELLOW}$port${PLAIN}"
    echo -e "密钥   : ${YELLOW}$secret${PLAIN}"
    echo "--------------------------------------------------------"
    echo -e "TG 链接: ${GREEN}tg://proxy?server=${ip}&port=${port}&secret=${secret}${PLAIN}"
    echo "========================================================"
    echo -e "${YELLOW}注意: 重启 VPS 后需要重新运行脚本启动 (因为没有 Systemd)${PLAIN}"
}

# =========================================================
# 4. 停止服务
# =========================================================
stop_proxy() {
    pkill -f "mtprotoproxy.py"
    echo -e "${GREEN}服务已停止。${PLAIN}"
}

# =========================================================
# 5. 查看日志
# =========================================================
view_log() {
    if [ -f "$WORKDIR/log.txt" ]; then
        tail -n 20 "$WORKDIR/log.txt"
    else
        echo "暂无日志文件。"
    fi
}

# =========================================================
# 菜单
# =========================================================
show_menu() {
    clear
    echo "========================================================"
    echo -e "${GREEN}MTProto 终极兼容版 (No-Systemd)${PLAIN}"
    echo "========================================================"
    echo "1. 安装并启动 (Install & Start)"
    echo "2. 查看连接信息 (Show Link)"
    echo "3. 停止服务 (Stop)"
    echo "4. 查看运行日志 (View Log)"
    echo "0. 退出"
    echo "========================================================"
    read -p "请输入选项: " num

    case "$num" in
        1) install_and_run ;;
        2) show_info ;;
        3) stop_proxy ;;
        4) view_log ;;
        0) exit 0 ;;
        *) echo "无效输入" ;;
    esac
}

show_menu
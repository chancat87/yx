#!/bin/bash

# --- 颜色定义 ---
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }

# --- 初始化变量 ---
HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')
export SECRET=${SECRET:-$(echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32)}
WORKDIR="$HOME/mtp"
mkdir -p "$WORKDIR"

# --- 手动输入端口函数 ---
input_port() {
    while true; do
        echo -n "请输入你想使用的端口号 (10000-65535): "
        read -r USER_PORT
        if [[ "$USER_PORT" =~ ^[0-9]+$ ]] && [ "$USER_PORT" -ge 1024 ] && [ "$USER_PORT" -le 65535 ]; then
            MTP_PORT=$USER_PORT
            break
        else
            red "错误: 请输入有效的端口号 (1024-65535)！"
        fi
    done
}

# --- 端口配置 (针对 Serv00/CT8) ---
check_port_serv00() {
    # 检查该端口是否已经在自己的端口列表中
    if devil port list | grep -q "$MTP_PORT"; then
        green "端口 $MTP_PORT 已在您的列表中，直接使用。"
    else
        yellow "正在尝试为您申请端口 $MTP_PORT..."
        result=$(devil port add tcp "$MTP_PORT" 2>&1)
        if [[ $result == *"Ok"* ]]; then
            green "成功添加 TCP 端口: $MTP_PORT"
        else
            red "端口申请失败！该端口可能已被他人占用或已达到数量上限。"
            red "错误信息: $result"
            exit 1
        fi
    fi
    devil binexec on >/dev/null 2>&1
}

# --- 获取可用 IP ---
get_ip() {
    IP_LIST=($(devil vhost list | awk '/^[0-9]+/ {print $1}'))
    API_URL="https://status.eooce.com/api"
    AVAILABLE_IPS=()
    for ip in "${IP_LIST[@]}"; do
        RESPONSE=$(curl -s --max-time 2 "${API_URL}/${ip}")
        if [[ -n "$RESPONSE" ]] && [[ $(echo "$RESPONSE" | jq -r '.status') == "Available" ]]; then
            AVAILABLE_IPS+=("$ip")
        fi
    done
    [[ ${#AVAILABLE_IPS[@]} -ge 1 ]] && IP1=${AVAILABLE_IPS[0]}
    [[ ${#AVAILABLE_IPS[@]} -ge 2 ]] && IP2=${AVAILABLE_IPS[1]}
    [[ ${#AVAILABLE_IPS[@]} -ge 3 ]] && IP3=${AVAILABLE_IPS[2]}
}

# --- 运行 mtg ---
run_mtg() {
    cd "$WORKDIR" || exit
    # 自动根据系统下载二进制 (简化逻辑)
    if [ ! -f "mtg" ]; then
        purple "正在下载二进制文件..."
        if [[ "$HOSTNAME" =~ serv00.com|ct8.pl ]]; then
            wget -q -O "mtg" "https://github.com/eooce/test/releases/download/freebsd/mtg-freebsd-amd64"
        else
            arch_raw=$(uname -m)
            [[ "$arch_raw" == "x86_64" ]] && arch="amd64" || arch="arm64"
            wget -q -O "mtg" "https://$arch.ssss.nyc.mn/mtg-linux-$arch"
        fi
    fi
    
    chmod +x mtg
    pgrep -x mtg > /dev/null && pkill -9 mtg
    
    # 启动
    nohup ./mtg run -b 0.0.0.0:"$MTP_PORT" "$SECRET" --stats-bind=127.0.0.1:"$MTP_PORT" >/dev/null 2>&1 &
    
    if pgrep -x "mtg" > /dev/null; then
        green "MTG 已成功启动！"
    else
        red "启动失败，请检查端口是否被占用或 Secret 是否正确。"
        exit 1
    fi
}

# --- 生成链接 ---
show_info() {
    if [[ "$HOSTNAME" =~ serv00.com|ct8.pl ]]; then
        get_ip
        server_ip=${IP1:-$HOSTNAME}
    else
        server_ip=$(curl -s ip.sb)
    fi

    purple "\n--- 您的 TG 代理链接 ---"
    LINKS="tg://proxy?server=$server_ip&port=$MTP_PORT&secret=$SECRET"
    green "$LINKS\n"
    
    # 存入文件
    echo -e "$LINKS" > "$WORKDIR/link.txt"
    
    # 创建重启脚本
    cat > "${WORKDIR}/restart.sh" <<EOF
#!/bin/bash
pkill -9 mtg
cd ${WORKDIR}
nohup ./mtg run -b 0.0.0.0:$MTP_PORT $SECRET --stats-bind=127.0.0.1:$MTP_PORT >/dev/null 2>&1 &
EOF
    chmod +x "${WORKDIR}/restart.sh"
}

# --- 主流程 ---
input_port

if [[ "$HOSTNAME" =~ serv00.com|ct8.pl|useruno.com ]]; then
    check_port_serv00
fi

run_mtg
show_info
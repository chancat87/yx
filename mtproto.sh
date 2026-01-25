#!/bin/bash

# ============================================
# MTProto代理 + Cloudflare隧道 一键安装脚本
# 快捷键: m
# 所有端口均可自定义
# ============================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 输出函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step() { echo -e "${CYAN}➜${NC} $1"; }
log_question() { echo -e "${PURPLE}[?]${NC} $1"; }

# 显示横幅
show_banner() {
    clear
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║                                                      ║"
    echo "║           MTProto + Cloudflare 安装脚本              ║"
    echo "║                快捷键: m                             ║"
    echo "║          所有端口均可自定义配置                      ║"
    echo "║                                                      ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

# 检查端口是否可用
check_port() {
    local port=$1
    local type=$2
    
    if [[ $port -lt 1 || $port -gt 65535 ]]; then
        log_error "端口号必须在 1-65535 之间"
        return 1
    fi
    
    # 检查端口是否被占用
    if ss -tuln | grep -q ":$port "; then
        log_warning "端口 $port 已被占用！"
        echo "当前占用该端口的进程："
        ss -tulnp | grep ":$port " || true
        log_question "是否强制使用此端口？(y/n): "
        read -p "强制使用: " FORCE
        if [[ ! $FORCE =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    return 0
}

# 获取安全的端口输入
get_port_input() {
    local prompt=$1
    local default=$2
    
    while true; do
        log_question "$prompt [默认: $default]: "
        read -p "端口: " port
        port=${port:-$default}
        
        if check_port "$port" "tcp"; then
            echo "$port"
            return 0
        fi
    done
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以root权限运行!"
        echo "请使用: sudo bash $0"
        exit 1
    fi
}

# 修复依赖安装问题
install_dependencies() {
    log_step "安装系统依赖..."
    
    # 更新包列表
    apt-get update -y
    
    # 安装apt-utils解决debconf错误
    if ! dpkg -l | grep -q apt-utils; then
        log_info "安装apt-utils..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y apt-utils
    fi
    
    # 安装基础工具
    log_info "安装基础工具..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl \
        wget \
        gnupg \
        lsb-release \
        ca-certificates \
        software-properties-common \
        vim-common \
        jq \
        net-tools \
        lsof
    
    # 安装Docker
    if ! command -v docker &> /dev/null; then
        log_info "安装Docker..."
        
        # 添加Docker官方GPG密钥
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        
        # 设置Docker仓库
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # 安装Docker
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin
    else
        log_success "Docker已安装"
    fi
    
    log_success "依赖安装完成"
}

# 第一部分：MTProto安装
install_mtproto() {
    log_step "=== MTProto代理安装 ==="
    echo ""
    
    log_info "请输入MTProto代理配置："
    echo ""
    
    # 获取所有端口输入
    MTPORT=$(get_port_input "MTProto外部访问端口" "443")
    
    log_question "是否自动生成密钥? (y/n) [默认y]: "
    read -p "自动生成: " AUTO_KEY
    AUTO_KEY=${AUTO_KEY:-y}
    
    if [[ $AUTO_KEY =~ ^[Yy]$ ]]; then
        MTSECRET=$(head -c 16 /dev/urandom | xxd -ps)
        log_info "生成的密钥: $MTSECRET"
    else
        while true; do
            log_question "请输入32位十六进制密钥: "
            read -p "密钥: " MTSECRET
            if [[ $MTSECRET =~ ^[0-9a-fA-F]{32}$ ]]; then
                break
            else
                log_error "密钥格式错误！必须是32位十六进制"
            fi
        done
    fi
    
    log_question "代理标签 (可选): "
    read -p "标签: " MTTAG
    MTTAG=${MTTAG:-"MTProxy Server"}
    
    log_question "Worker进程数 [默认: 4]: "
    read -p "Worker数: " WORKERS
    WORKERS=${WORKERS:-4}
    
    log_question "最大连接数 [默认: 10000]: "
    read -p "最大连接: " MAX_CONN
    MAX_CONN=${MAX_CONN:-10000}
    
    # 显示配置
    echo ""
    log_info "MTProto配置汇总："
    echo "┌────────────────────────────────────┐"
    echo "│  外部端口: $MTPORT"
    echo "│  密钥: $MTSECRET"
    echo "│  标签: $MTTAG"
    echo "│  Worker数: $WORKERS"
    echo "│  最大连接: $MAX_CONN"
    echo "└────────────────────────────────────┘"
    echo ""
    
    read -p "确认安装MTProto? (y/n): " CONFIRM
    if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
        log_warning "MTProto安装取消"
        return 1
    fi
    
    # 创建配置目录
    mkdir -p /etc/mtproto
    cd /etc/mtproto
    
    # 下载官方配置文件
    log_info "下载MTProto配置文件..."
    curl -sL https://core.telegram.org/getProxySecret -o proxy-secret
    curl -sL https://core.telegram.org/getProxyConfig -o proxy-multi.conf
    
    # 创建Docker Compose文件
    cat > docker-compose.yml << EOF
version: '3'
services:
  mtproto:
    image: telegrammessenger/proxy:latest
    container_name: mtproto-proxy
    restart: always
    network_mode: host
    environment:
      - SECRET=${MTSECRET}
      - PORT=${MTPORT}
      - PROXY_TAG=${MTTAG}
      - WORKERS=${WORKERS}
      - MAX_CONNECTIONS=${MAX_CONN}
      - INTERNAL_IP=0.0.0.0
    volumes:
      - ./proxy-secret:/proxy-secret
      - ./proxy-multi.conf:/proxy-multi.conf
EOF
    
    # 停止并删除可能存在的旧容器
    if docker ps -a --format '{{.Names}}' | grep -q '^mtproto-proxy$'; then
        log_info "停止旧容器..."
        docker stop mtproto-proxy >/dev/null 2>&1 || true
        docker rm mtproto-proxy >/dev/null 2>&1 || true
    fi
    
    # 启动服务
    log_info "启动MTProto服务..."
    docker-compose up -d
    
    # 等待启动
    sleep 5
    
    # 检查状态
    if docker ps | grep -q mtproto-proxy; then
        log_success "MTProto服务启动成功"
        
        # 配置防火墙
        log_info "配置防火墙端口 $MTPORT..."
        if command -v ufw >/dev/null 2>&1; then
            ufw allow $MTPORT/tcp >/dev/null 2>&1 || true
            ufw allow $MTPORT/udp >/dev/null 2>&1 || true
            log_success "UFW防火墙已配置"
        elif command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port=$MTPORT/tcp >/dev/null 2>&1 || true
            firewall-cmd --permanent --add-port=$MTPORT/udp >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            log_success "Firewalld已配置"
        else
            # 使用iptables
            iptables -A INPUT -p tcp --dport $MTPORT -j ACCEPT 2>/dev/null || true
            iptables -A INPUT -p udp --dport $MTPORT -j ACCEPT 2>/dev/null || true
            log_success "iptables规则已添加"
        fi
        
        return 0
    else
        log_error "MTProto启动失败"
        docker-compose logs
        return 1
    fi
}

# 第二部分：Cloudflare隧道配置
setup_cloudflare_tunnel() {
    log_step "=== Cloudflare隧道配置 ==="
    echo ""
    
    log_question "是否配置Cloudflare隧道? (y/n) [默认y]: "
    read -p "配置隧道: " SETUP_TUNNEL
    SETUP_TUNNEL=${SETUP_TUNNEL:-y}
    
    if [[ ! $SETUP_TUNNEL =~ ^[Yy]$ ]]; then
        log_warning "跳过Cloudflare隧道配置"
        CF_ENABLED=false
        return 0
    fi
    
    CF_ENABLED=true
    
    echo ""
    log_info "需要以下信息："
    echo "┌────────────────────────────────────┐"
    echo "│ 1. 您的域名（如：abcai.online）    │"
    echo "│ 2. 子域名前缀（如：mt）            │"
    echo "│ 3. Cloudflare隧道名称              │"
    echo "│ 4. Cloudflare隧道Token             │"
    echo "│ 5. WebSocket转换器端口             │"
    echo "└────────────────────────────────────┘"
    echo ""
    
    # 获取域名信息
    while true; do
        log_question "请输入您的域名 (如: abcai.online): "
        read -p "域名: " CF_DOMAIN
        if [[ -n "$CF_DOMAIN" ]]; then
            break
        else
            log_error "域名不能为空"
        fi
    done
    
    while true; do
        log_question "请输入子域名前缀 (如: mt): "
        read -p "子域名: " CF_SUBDOMAIN
        if [[ -n "$CF_SUBDOMAIN" ]]; then
            break
        else
            log_error "子域名不能为空"
        fi
    done
    
    # 获取WebSocket转换器端口
    WS_PORT=$(get_port_input "WebSocket转换器内部端口" "8080")
    
    # 获取隧道信息
    echo ""
    log_info "Cloudflare隧道信息："
    echo "如何获取Token："
    echo "1. 访问 https://dash.cloudflare.com/"
    echo "2. Zero Trust → Access → Tunnels"
    echo "3. 点击隧道名称 → Configure"
    echo "4. 复制 Token 字段"
    echo ""
    
    while true; do
        log_question "隧道名称: "
        read -p "名称: " CF_TUNNEL_NAME
        if [[ -n "$CF_TUNNEL_NAME" ]]; then
            break
        else
            log_error "隧道名称不能为空"
        fi
    done
    
    while true; do
        log_question "隧道Token: "
        read -p "Token: " CF_TUNNEL_TOKEN
        if [[ -n "$CF_TUNNEL_TOKEN" ]]; then
            break
        else
            log_error "隧道Token不能为空"
        fi
    done
    
    # 显示配置
    echo ""
    log_info "Cloudflare配置汇总："
    echo "┌────────────────────────────────────┐"
    echo "│  域名: ${CF_SUBDOMAIN}.${CF_DOMAIN} │"
    echo "│  隧道名称: $CF_TUNNEL_NAME          │"
    echo "│  WebSocket端口: $WS_PORT            │"
    echo "│  MTProto端口: $MTPORT               │"
    echo "└────────────────────────────────────┘"
    echo ""
    
    read -p "确认配置Cloudflare隧道? (y/n): " CONFIRM
    if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
        log_warning "Cloudflare隧道配置取消"
        CF_ENABLED=false
        return 0
    fi
    
    # 安装cloudflared
    log_info "安装cloudflared..."
    if ! command -v cloudflared &> /dev/null; then
        wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /usr/local/bin/cloudflared
        chmod +x /usr/local/bin/cloudflared
    fi
    
    # 安装WebSocket转换器
    log_info "安装WebSocket转换器..."
    mkdir -p /etc/mtproto-ws
    cd /etc/mtproto-ws
    
    # 停止旧容器
    if docker ps -a --format '{{.Names}}' | grep -q '^mtproto-ws-converter$'; then
        docker stop mtproto-ws-converter >/dev/null 2>&1 || true
        docker rm mtproto-ws-converter >/dev/null 2>&1 || true
    fi
    
    # 创建WebSocket转换器配置
    cat > docker-compose.yml << EOF
version: '3'
services:
  ws-converter:
    image: ymuski/ws-tcp-relay:latest
    container_name: mtproto-ws-converter
    restart: always
    ports:
      - "127.0.0.1:${WS_PORT}:8080"
    environment:
      - LISTEN_PORT=8080
      - TARGET_HOST=127.0.0.1
      - TARGET_PORT=${MTPORT}
EOF
    
    docker-compose up -d
    
    sleep 3
    
    if ! docker ps | grep -q mtproto-ws-converter; then
        log_error "WebSocket转换器启动失败"
        docker-compose logs
        return 1
    fi
    
    log_success "WebSocket转换器启动成功 (端口: $WS_PORT)"
    
    # 创建Cloudflare隧道配置
    log_info "创建隧道配置..."
    mkdir -p /etc/cloudflared
    cd /etc/cloudflared
    
    # 创建配置文件
    cat > config.yaml << EOF
tunnel: $CF_TUNNEL_NAME
credentials-file: /etc/cloudflared/credentials.json

ingress:
  - hostname: ${CF_SUBDOMAIN}.${CF_DOMAIN}
    service: http://localhost:${WS_PORT}
    originRequest:
      connectTimeout: 30s
      tlsTimeout: 30s
      noTLSVerify: false
      keepAlive: true
      keepAliveTimeout: 30s
  
  - service: http_status:404
EOF
    
    # 创建凭据文件（简化版）
    cat > credentials.json << EOF
{"AccountTag":"","TunnelSecret":"","TunnelID":"","TunnelName":"$CF_TUNNEL_NAME"}
EOF
    
    # 保存token
    echo "$CF_TUNNEL_TOKEN" > tunnel-token.txt
    
    # 创建systemd服务
    cat > /etc/systemd/system/cloudflared.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=root
WorkingDirectory=/etc/cloudflared
Environment="TUNNEL_TOKEN=$CF_TUNNEL_TOKEN"
ExecStart=/usr/local/bin/cloudflared tunnel --config /etc/cloudflared/config.yaml run
Restart=always
RestartSec=5
StandardOutput=append:/var/log/cloudflared.log
StandardError=append:/var/log/cloudflared-error.log

[Install]
WantedBy=multi-user.target
EOF
    
    # 启动服务
    systemctl daemon-reload
    systemctl enable cloudflared
    systemctl start cloudflared
    
    sleep 5
    
    if systemctl is-active --quiet cloudflared; then
        log_success "Cloudflare隧道启动成功"
        return 0
    else
        log_error "Cloudflare隧道启动失败"
        journalctl -u cloudflared --no-pager -n 20
        return 1
    fi
}

# 创建快捷键和管理脚本
create_shortcut_and_management() {
    log_step "创建快捷键和管理脚本..."
    
    # 创建主管理脚本（快捷键 m）
    cat > /usr/local/bin/m << 'EOF'
#!/bin/bash

# ============================================
# MTProto + Cloudflare 管理脚本
# 快捷键: m
# ============================================

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

VERSION="1.0.0"
CONFIG_DIR="/etc/mtproto"
CF_CONFIG_DIR="/etc/cloudflared"

# 显示帮助
show_help() {
    echo -e "${BLUE}MTProto + Cloudflare 管理脚本 (v$VERSION)${NC}"
    echo -e "快捷键: ${GREEN}m${NC}"
    echo ""
    echo -e "${YELLOW}使用方法:${NC}"
    echo "  m [命令] [选项]"
    echo ""
    echo -e "${GREEN}管理命令:${NC}"
    echo "  start      启动所有服务"
    echo "  stop       停止所有服务"
    echo "  restart    重启所有服务"
    echo "  status     查看服务状态"
    echo "  logs       查看日志 (mtproto|ws|tunnel)"
    echo "  update     更新所有服务"
    echo "  config     查看/修改配置"
    echo "  info       显示连接信息"
    echo "  backup     备份配置"
    echo "  restore    恢复配置"
    echo "  install    运行安装脚本"
    echo "  uninstall  卸载所有服务"
    echo "  help       显示此帮助"
    echo ""
    echo -e "${PURPLE}快捷命令:${NC}"
    echo "  m          查看状态 (同 m status)"
    echo "  m ls       查看日志最后10行"
    echo "  m ps       查看进程状态"
    echo "  m net      查看网络连接"
    echo "  m test     测试连接"
    echo ""
}

# 显示状态
show_status() {
    echo -e "${BLUE}=== 服务状态 ===${NC}"
    echo ""
    
    # MTProto状态
    echo -e "${YELLOW}1. MTProto代理:${NC}"
    if docker ps --format '{{.Names}}' | grep -q '^mtproto-proxy$'; then
        local mt_port=$(docker inspect mtproto-proxy --format='{{range .Config.Env}}{{println .}}{{end}}' | grep "PORT=" | cut -d= -f2 | head -1)
        local mt_secret=$(docker inspect mtproto-proxy --format='{{range .Config.Env}}{{println .}}{{end}}' | grep "SECRET=" | cut -d= -f2 | head -1)
        echo -e "  ${GREEN}✓ 运行中${NC}"
        echo "  端口: ${mt_port:-未知}"
        echo "  密钥: ${mt_secret:0:8}..."
    else
        echo -e "  ${RED}✗ 未运行${NC}"
    fi
    
    echo ""
    
    # WebSocket转换器状态
    echo -e "${YELLOW}2. WebSocket转换器:${NC}"
    if docker ps --format '{{.Names}}' | grep -q '^mtproto-ws-converter$'; then
        local ws_port=$(docker port mtproto-ws-converter 2>/dev/null | head -1 | cut -d: -f2)
        echo -e "  ${GREEN}✓ 运行中${NC}"
        echo "  端口: ${ws_port:-未知}"
    else
        echo -e "  ${RED}✗ 未运行${NC}"
    fi
    
    echo ""
    
    # Cloudflare隧道状态
    echo -e "${YELLOW}3. Cloudflare隧道:${NC}"
    if systemctl is-active cloudflared >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓ 运行中${NC}"
        if [[ -f "$CF_CONFIG_DIR/config.yaml" ]]; then
            local domain=$(grep "hostname:" "$CF_CONFIG_DIR/config.yaml" | head -1 | cut -d: -f2 | tr -d ' ')
            echo "  域名: $domain"
        fi
    else
        echo -e "  ${RED}✗ 未运行${NC}"
    fi
    
    echo ""
    
    # 系统信息
    echo -e "${YELLOW}4. 系统信息:${NC}"
    echo "  内存: $(free -h | awk '/^Mem:/ {print $3"/"$2}')"
    echo "  磁盘: $(df -h / | awk 'NR==2 {print $4"/"$2 " ("$5")"}')"
    echo "  运行时间: $(uptime -p | sed 's/up //')"
}

# 处理命令
case "$1" in
    # 无参数显示状态
    "")
        show_status
        ;;
    
    # 管理命令
    start)
        echo "启动服务..."
        docker start mtproto-proxy 2>/dev/null && echo -e "${GREEN}✓ MTProto启动${NC}" || echo -e "${RED}✗ MTProto启动失败${NC}"
        docker start mtproto-ws-converter 2>/dev/null && echo -e "${GREEN}✓ WebSocket转换器启动${NC}" || echo "⚠ WebSocket转换器未安装"
        systemctl start cloudflared 2>/dev/null && echo -e "${GREEN}✓ Cloudflare隧道启动${NC}" || echo "⚠ Cloudflare隧道未安装"
        ;;
    
    stop)
        echo "停止服务..."
        docker stop mtproto-ws-converter 2>/dev/null || true
        docker stop mtproto-proxy 2>/dev/null || true
        systemctl stop cloudflared 2>/dev/null || true
        echo -e "${GREEN}✓ 所有服务已停止${NC}"
        ;;
    
    restart)
        echo "重启服务..."
        bash $0 stop
        sleep 3
        bash $0 start
        ;;
    
    status)
        show_status
        ;;
    
    logs)
        case "$2" in
            mtproto)
                docker logs -f mtproto-proxy
                ;;
            ws)
                docker logs -f mtproto-ws-converter 2>/dev/null || echo "WebSocket转换器未安装"
                ;;
            tunnel)
                tail -f /var/log/cloudflared.log
                ;;
            error)
                tail -f /var/log/cloudflared-error.log
                ;;
            "")
                echo "用法: m logs {mtproto|ws|tunnel|error}"
                ;;
        esac
        ;;
    
    update)
        echo "更新服务..."
        docker pull telegrammessenger/proxy:latest
        docker pull ymuski/ws-tcp-relay:latest 2>/dev/null || true
        wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /usr/local/bin/cloudflared
        chmod +x /usr/local/bin/cloudflared
        bash $0 restart
        echo -e "${GREEN}✓ 更新完成${NC}"
        ;;
    
    config)
        echo -e "${BLUE}=== 配置文件位置 ===${NC}"
        echo ""
        echo -e "${YELLOW}MTProto配置:${NC}"
        echo "  目录: $CONFIG_DIR"
        if [[ -f "$CONFIG_DIR/docker-compose.yml" ]]; then
            echo "  端口: $(grep "PORT=" "$CONFIG_DIR/docker-compose.yml" | cut -d= -f2 | head -1)"
            echo "  密钥: $(grep "SECRET=" "$CONFIG_DIR/docker-compose.yml" | cut -d= -f2 | head -1)"
        fi
        
        echo ""
        echo -e "${YELLOW}Cloudflare配置:${NC}"
        echo "  目录: $CF_CONFIG_DIR"
        if [[ -f "$CF_CONFIG_DIR/config.yaml" ]]; then
            echo "  域名: $(grep "hostname:" "$CF_CONFIG_DIR/config.yaml" | head -1 | cut -d: -f2 | tr -d ' ')"
        fi
        ;;
    
    info)
        echo -e "${BLUE}=== 连接信息 ===${NC}"
        echo ""
        
        # 获取MTProto配置
        if [[ -f "$CONFIG_DIR/docker-compose.yml" ]]; then
            local mt_port=$(grep "PORT=" "$CONFIG_DIR/docker-compose.yml" | cut -d= -f2 | head -1 | tr -d ' ')
            local mt_secret=$(grep "SECRET=" "$CONFIG_DIR/docker-compose.yml" | cut -d= -f2 | head -1 | tr -d ' ')
            
            # 获取公网IP
            local public_ip=$(curl -s ifconfig.me 2>/dev/null || echo "未知")
            
            # 获取域名
            local cf_domain=""
            if [[ -f "$CF_CONFIG_DIR/config.yaml" ]]; then
                cf_domain=$(grep "hostname:" "$CF_CONFIG_DIR/config.yaml" | head -1 | cut -d: -f2 | tr -d ' ')
            fi
            
            if [[ -n "$cf_domain" ]]; then
                echo -e "${GREEN}通过Cloudflare访问:${NC}"
                echo "  地址: $cf_domain"
                echo "  端口: 443"
                echo "  密钥: $mt_secret"
                echo ""
                echo -e "${YELLOW}分享链接:${NC}"
                echo "  tg://proxy?server=$cf_domain&port=443&secret=$mt_secret"
            else
                echo -e "${GREEN}直接访问:${NC}"
                echo "  地址: $public_ip"
                echo "  端口: $mt_port"
                echo "  密钥: $mt_secret"
                echo ""
                echo -e "${YELLOW}分享链接:${NC}"
                echo "  tg://proxy?server=$public_ip&port=$mt_port&secret=$mt_secret"
            fi
            
            echo ""
            echo -e "${PURPLE}二维码链接:${NC}"
            local share_link="tg://proxy?server=${cf_domain:-$public_ip}&port=${cf_domain:+443:$mt_port}&secret=$mt_secret"
            echo "  https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=${share_link//:/%3A}"
        else
            echo "未找到MTProto配置"
        fi
        ;;
    
    backup)
        echo "备份配置..."
        local backup_dir="/root/mtproto-backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$backup_dir"
        
        cp -r "$CONFIG_DIR" "$backup_dir/" 2>/dev/null || true
        cp -r "$CF_CONFIG_DIR" "$backup_dir/" 2>/dev/null || true
        cp /etc/systemd/system/cloudflared.service "$backup_dir/" 2>/dev/null || true
        
        echo -e "${GREEN}✓ 配置已备份到: $backup_dir${NC}"
        ;;
    
    restore)
        if [[ -z "$2" ]]; then
            echo "用法: m restore <备份目录>"
            echo "可用备份:"
            ls -d /root/mtproto-backup-* 2>/dev/null || echo "无备份"
            exit 1
        fi
        
        local backup_dir="$2"
        if [[ ! -d "$backup_dir" ]]; then
            echo -e "${RED}错误: 备份目录不存在${NC}"
            exit 1
        fi
        
        echo "从 $backup_dir 恢复配置..."
        cp -r "$backup_dir/mtproto" "$CONFIG_DIR" 2>/dev/null || true
        cp -r "$backup_dir/cloudflared" "$CF_CONFIG_DIR" 2>/dev/null || true
        cp "$backup_dir/cloudflared.service" /etc/systemd/system/ 2>/dev/null || true
        
        systemctl daemon-reload
        bash $0 restart
        
        echo -e "${GREEN}✓ 配置已恢复${NC}"
        ;;
    
    install)
        echo "运行安装脚本..."
        bash /usr/local/bin/mtproto-install.sh
        ;;
    
    uninstall)
        echo -e "${RED}警告: 这将卸载所有服务并删除配置！${NC}"
        read -p "确认卸载? (y/n): " confirm
        if [[ $confirm == "y" || $confirm == "Y" ]]; then
            echo "卸载服务..."
            
            bash $0 stop
            
            docker rm -f mtproto-proxy 2>/dev/null || true
            docker rm -f mtproto-ws-converter 2>/dev/null || true
            
            systemctl disable cloudflared 2>/dev/null || true
            systemctl stop cloudflared 2>/dev/null || true
            rm -f /etc/systemd/system/cloudflared.service
            
            rm -rf "$CONFIG_DIR" "$CF_CONFIG_DIR" /etc/mtproto-ws
            
            rm -f /usr/local/bin/m
            rm -f /usr/local/bin/mtproto-install.sh
            
            echo -e "${GREEN}✓ 所有服务已卸载${NC}"
        else
            echo "卸载取消"
        fi
        ;;
    
    # 快捷命令
    ls)
        echo -e "${BLUE}=== 最近日志 ===${NC}"
        echo ""
        echo -e "${YELLOW}MTProto最后10行:${NC}"
        docker logs --tail 10 mtproto-proxy 2>/dev/null || echo "无日志"
        echo ""
        echo -e "${YELLOW}Cloudflare隧道最后10行:${NC}"
        tail -10 /var/log/cloudflared.log 2>/dev/null || echo "无日志"
        ;;
    
    ps)
        echo -e "${BLUE}=== 进程状态 ===${NC}"
        echo ""
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -10
        ;;
    
    net)
        echo -e "${BLUE}=== 网络连接 ===${NC}"
        echo ""
        if [[ -f "$CONFIG_DIR/docker-compose.yml" ]]; then
            local mt_port=$(grep "PORT=" "$CONFIG_DIR/docker-compose.yml" | cut -d= -f2 | head -1 | tr -d ' ')
            echo "MTProto端口 ($mt_port) 连接:"
            ss -tunap | grep ":$mt_port " || echo "无连接"
        fi
        ;;
    
    test)
        echo -e "${BLUE}=== 连接测试 ===${NC}"
        echo ""
        
        if [[ -f "$CONFIG_DIR/docker-compose.yml" ]]; then
            local mt_port=$(grep "PORT=" "$CONFIG_DIR/docker-compose.yml" | cut -d= -f2 | head -1 | tr -d ' ')
            local public_ip=$(curl -s ifconfig.me 2>/dev/null || echo "未知")
            
            echo -e "${YELLOW}测试本地端口 $mt_port:${NC}"
            if nc -z localhost $mt_port 2>/dev/null; then
                echo -e "${GREEN}✓ 端口开放${NC}"
            else
                echo -e "${RED}✗ 端口未开放${NC}"
            fi
            
            echo ""
            echo -e "${YELLOW}测试公网连接:${NC}"
            if timeout 5 curl -s "http://$public_ip" >/dev/null 2>&1; then
                echo -e "${GREEN}✓ 服务器可达${NC}"
            else
                echo -e "${RED}✗ 服务器不可达${NC}"
            fi
        fi
        ;;
    
    help|--help|-h)
        show_help
        ;;
    
    *)
        echo -e "${RED}未知命令: $1${NC}"
        echo "使用 'm help' 查看帮助"
        ;;
esac
EOF
    
    # 使脚本可执行
    chmod +x /usr/local/bin/m
    
    # 创建安装脚本别名
    ln -sf /usr/local/bin/m /usr/local/bin/mtproto-install.sh
    
    log_success "快捷键已创建: m"
    echo ""
    echo -e "${YELLOW}使用以下命令管理服务:${NC}"
    echo "  m           # 查看状态"
    echo "  m start     # 启动服务"
    echo "  m stop      # 停止服务"
    echo "  m restart   # 重启服务"
    echo "  m logs      # 查看日志"
    echo "  m info      # 显示连接信息"
    echo "  m help      # 查看帮助"
    echo ""
}

# 显示安装结果
show_installation_result() {
    log_step "=== 安装完成 ==="
    echo ""
    
    # 获取公网IP
    PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "未知")
    
    # 获取配置信息
    if [[ -f "/etc/mtproto/docker-compose.yml" ]]; then
        MTPORT=$(grep "PORT=" /etc/mtproto/docker-compose.yml | cut -d= -f2 | tr -d ' ' | head -1)
        MTSECRET=$(grep "SECRET=" /etc/mtproto/docker-compose.yml | cut -d= -f2 | tr -d ' ' | head -1)
        
        echo -e "${GREEN}✅ MTProto配置完成${NC}"
        echo "┌────────────────────────────────────┐"
        echo "│  服务器: $PUBLIC_IP"
        echo "│  端口: $MTPORT"
        echo "│  密钥: $MTSECRET"
        echo "└────────────────────────────────────┘"
        echo ""
        
        # 如果有Cloudflare配置
        if [[ -f "/etc/cloudflared/config.yaml" ]]; then
            CF_DOMAIN=$(grep "hostname:" /etc/cloudflared/config.yaml | cut -d: -f2 | tr -d ' ' | head -1)
            if [[ -n "$CF_DOMAIN" ]]; then
                echo -e "${GREEN}✅ Cloudflare隧道配置完成${NC}"
                echo "┌────────────────────────────────────┐"
                echo "│  访问地址: https://$CF_DOMAIN"
                echo "│  MTProto端口: 443"
                echo "└────────────────────────────────────┘"
                echo ""
            fi
        fi
        
        # 生成分享链接
        if [[ -n "$CF_DOMAIN" ]]; then
            SHARE_LINK="tg://proxy?server=$CF_DOMAIN&port=443&secret=$MTSECRET"
        else
            SHARE_LINK="tg://proxy?server=$PUBLIC_IP&port=$MTPORT&secret=$MTSECRET"
        fi
        
        echo -e "${YELLOW}📲 分享链接:${NC}"
        echo "$SHARE_LINK"
        echo ""
        
        # 二维码链接
        QR_URL="https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=${SHARE_LINK//:/%3A}"
        echo -e "${YELLOW}📱 二维码链接:${NC}"
        echo "$QR_URL"
        echo ""
    fi
    
    echo -e "${BLUE}🔧 管理命令:${NC}"
    echo "  m status    # 查看服务状态"
    echo "  m restart   # 重启所有服务"
    echo "  m logs      # 查看日志"
    echo "  m info      # 显示连接信息"
    echo "  m test      # 测试连接"
    echo "  m help      # 查看所有命令"
    echo ""
    
    echo -e "${YELLOW}⚠️  重要提示:${NC}"
    echo "1. 如果配置了Cloudflare隧道，请确保DNS已设置"
    echo "2. 域名代理状态应为橙色云朵"
    echo "3. 首次连接可能需要等待DNS生效（1-10分钟）"
    echo "4. 确保防火墙已开放端口 $MTPORT"
    echo ""
}

# 主函数
main() {
    show_banner
    check_root
    install_dependencies
    
    # 安装MTProto
    log_step "开始安装MTProto代理..."
    if install_mtproto; then
        log_success "MTProto安装成功"
    else
        log_error "MTProto安装失败"
        exit 1
    fi
    
    # 配置Cloudflare隧道
    log_step "开始配置Cloudflare隧道..."
    if setup_cloudflare_tunnel; then
        log_success "Cloudflare隧道配置成功"
    else
        log_warning "Cloudflare隧道未配置或配置失败"
    fi
    
    # 创建快捷键和管理脚本
    create_shortcut_and_management
    
    # 显示结果
    show_installation_result
    
    echo -e "${GREEN}🎉 安装完成！使用快捷键 'm' 管理服务${NC}"
    echo ""
}

# 执行主函数
main "$@"

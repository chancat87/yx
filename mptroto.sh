#!/bin/bash

# ============================================
# MTProto + Cloudflare Tunnel 配置脚本
# 适用于已有CF隧道和域名的用户
# ============================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 输出函数
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
step() { echo -e "${CYAN}➜${NC} $1"; }

# 显示横幅
show_banner() {
    clear
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║                                                      ║"
    echo "║          MTProto + Cloudflare Tunnel 配置            ║"
    echo "║                 (已有隧道和域名)                     ║"
    echo "║                                                      ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用root权限运行此脚本"
        echo "使用: sudo bash $0"
        exit 1
    fi
}

# 获取用户配置
get_config() {
    echo ""
    step "请输入您的配置信息："
    echo ""
    
    # 获取MTProto配置
    read -p "MTProto端口 [默认: 443]: " MTPORT
    MTPORT=${MTPORT:-443}
    
    read -p "是否自动生成MTProto密钥？(y/n) [默认: y]: " GEN_KEY
    GEN_KEY=${GEN_KEY:-y}
    
    if [[ $GEN_KEY =~ ^[Yy]$ ]]; then
        SECRET=$(head -c 16 /dev/urandom | xxd -ps)
        info "生成的密钥: $SECRET"
    else
        read -p "请输入MTProto密钥 (32位十六进制): " SECRET
        if [[ ! $SECRET =~ ^[0-9a-fA-F]{32}$ ]]; then
            error "密钥格式错误！必须是32位十六进制字符"
            exit 1
        fi
    fi
    
    read -p "MTProto标签 [默认: MTProxy over CF]: " TAG
    TAG=${TAG:-"MTProxy over CF"}
    
    # 获取Cloudflare配置
    echo ""
    step "Cloudflare配置："
    read -p "您的域名 (例如: example.com): " DOMAIN
    read -p "用于MTProto的子域名 (例如: mt, 将创建 mt.example.com): " SUBDOMAIN
    
    # 检查隧道
    echo ""
    step "检查现有Cloudflare隧道..."
    if command -v cloudflared &> /dev/null; then
        TUNNELS=$(cloudflared tunnel list 2>/dev/null | grep -v "NAME" | awk '{print $1}')
        if [[ -n "$TUNNELS" ]]; then
            info "找到以下隧道："
            echo "$TUNNELS"
            read -p "使用现有隧道？(输入隧道名或按回车创建新隧道): " EXISTING_TUNNEL
        fi
    fi
    
    # 确认配置
    echo ""
    echo -e "${YELLOW}配置摘要：${NC}"
    echo "────────────────────────────────"
    echo "MTProto端口: $MTPORT"
    echo "MTProto密钥: $SECRET"
    echo "MTProto标签: $TAG"
    echo "域名: $DOMAIN"
    echo "子域名: ${SUBDOMAIN}.${DOMAIN}"
    if [[ -n "$EXISTING_TUNNEL" ]]; then
        echo "使用隧道: $EXISTING_TUNNEL"
    else
        echo "创建新隧道"
    fi
    echo "────────────────────────────────"
    echo ""
    
    read -p "确认配置？(y/n) [默认: y]: " CONFIRM
    CONFIRM=${CONFIRM:-y}
    
    if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
        info "重新配置..."
        get_config
    fi
}

# 安装依赖
install_dependencies() {
    step "安装依赖..."
    
    if command -v apt &> /dev/null; then
        apt update
        apt install -y docker.io curl wget jq xxd ufw
    elif command -v yum &> /dev/null; then
        yum install -y docker curl wget jq xxd firewalld
        systemctl start docker
        systemctl enable docker
    else
        error "不支持的包管理器"
        exit 1
    fi
    
    # 安装cloudflared（如果不存在）
    if ! command -v cloudflared &> /dev/null; then
        info "安装cloudflared..."
        wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /usr/local/bin/cloudflared
        chmod +x /usr/local/bin/cloudflared
    fi
    
    success "依赖安装完成"
}

# 配置防火墙
setup_firewall() {
    step "配置防火墙..."
    
    # 开放MTProto端口（本地访问）
    if command -v ufw &> /dev/null; then
        ufw allow from 127.0.0.1 to any port $MTPORT
        ufw allow from ::1 to any port $MTPORT
        info "UFW已配置"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="127.0.0.1" port port='"$MTPORT"' protocol="tcp" accept'
        firewall-cmd --permanent --add-rich-rule='rule family="ipv6" source address="::1" port port='"$MTPORT"' protocol="tcp" accept'
        firewall-cmd --reload
        info "Firewalld已配置"
    fi
    
    success "防火墙配置完成"
}

# 安装MTProto代理
install_mtproto() {
    step "安装MTProto代理..."
    
    # 创建配置目录
    mkdir -p /etc/mtproto-cf
    
    # 下载官方配置
    cd /etc/mtproto-cf
    curl -sL https://core.telegram.org/getProxySecret -o proxy-secret
    curl -sL https://core.telegram.org/getProxyConfig -o proxy-multi.conf
    
    # 创建Docker Compose文件
    cat > docker-compose.yml << EOF
version: '3.8'
services:
  mtproto:
    image: telegrammessenger/proxy:latest
    container_name: mtproto-cf-proxy
    restart: always
    network_mode: "host"
    environment:
      - SECRET=${SECRET}
      - PROXY_TAG=${TAG}
      - WORKERS=4
      - MAX_CONNECTIONS=10000
      - INTERNAL_IP=127.0.0.1
      - PORT=${MTPORT}
    volumes:
      - ./proxy-secret:/proxy-secret
      - ./proxy-multi.conf:/proxy-multi.conf
EOF
    
    # 启动MTProto
    docker-compose up -d
    
    # 检查运行状态
    sleep 3
    if docker ps | grep -q mtproto-cf-proxy; then
        success "MTProto代理启动成功"
    else
        error "MTProto代理启动失败"
        docker-compose logs
        exit 1
    fi
}

# 配置Cloudflare隧道
setup_cloudflare_tunnel() {
    step "配置Cloudflare隧道..."
    
    # 登录Cloudflare（如果需要）
    if [[ ! -f ~/.cloudflared/cert.pem ]]; then
        info "请访问以下链接登录Cloudflare："
        cloudflared tunnel login
    fi
    
    # 使用现有隧道或创建新隧道
    if [[ -n "$EXISTING_TUNNEL" ]]; then
        TUNNEL_NAME="$EXISTING_TUNNEL"
        info "使用现有隧道: $TUNNEL_NAME"
    else
        TUNNEL_NAME="mtproto-$(date +%s)"
        info "创建新隧道: $TUNNEL_NAME"
        cloudflared tunnel create $TUNNEL_NAME
    fi
    
    # 获取隧道UUID
    TUNNEL_UUID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
    if [[ -z "$TUNNEL_UUID" ]]; then
        error "获取隧道ID失败"
        exit 1
    fi
    
    info "隧道ID: $TUNNEL_UUID"
    
    # 创建隧道配置文件
    TUNNEL_CONFIG="/etc/mtproto-cf/tunnel.yml"
    cat > $TUNNEL_CONFIG << EOF
tunnel: $TUNNEL_UUID
credentials-file: /root/.cloudflared/$TUNNEL_UUID.json

ingress:
  # MTProto WebSocket端点
  - hostname: ${SUBDOMAIN}.${DOMAIN}
    path: /mtproto
    service: http://localhost:8080
    originRequest:
      connectTimeout: 30s
      tlsTimeout: 30s
      noTLSVerify: false
      keepAlive: true
      keepAliveTimeout: 30s
  
  # 健康检查端点
  - hostname: ${SUBDOMAIN}.${DOMAIN}
    path: /health
    service: http://localhost:8080/health
  
  # 默认404响应
  - service: http_status:404
EOF
    
    # 创建路由（DNS记录）
    info "创建DNS记录..."
    cloudflared tunnel route dns $TUNNEL_UUID ${SUBDOMAIN}.${DOMAIN}
    
    success "Cloudflare隧道配置完成"
}

# 安装WebSocket转换器
install_websocket_converter() {
    step "安装WebSocket转换器..."
    
    # 创建WebSocket转换服务目录
    mkdir -p /etc/ws-converter
    
    # 创建Docker Compose文件
    cat > /etc/ws-converter/docker-compose.yml << EOF
version: '3.8'
services:
  ws-converter:
    image: ymuski/ws-tcp-relay:latest
    container_name: mtproto-ws-converter
    restart: always
    ports:
      - "127.0.0.1:8080:8080"
    environment:
      - LISTEN_PORT=8080
      - TARGET_HOST=127.0.0.1
      - TARGET_PORT=${MTPORT}
      - LOG_LEVEL=info
    healthcheck:
      test: ["CMD", "netstat", "-an", "|", "grep", "8080"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF
    
    # 启动WebSocket转换器
    cd /etc/ws-converter
    docker-compose up -d
    
    # 检查运行状态
    sleep 2
    if docker ps | grep -q mtproto-ws-converter; then
        success "WebSocket转换器启动成功"
    else
        error "WebSocket转换器启动失败"
        docker-compose logs
        exit 1
    fi
}

# 创建健康检查端点
create_health_check() {
    step "创建健康检查服务..."
    
    # 简单的Python健康检查服务
    cat > /etc/mtproto-cf/health_server.py << 'EOF'
#!/usr/bin/env python3
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import subprocess

class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            # 检查MTProto服务
            mtproto_ok = False
            try:
                result = subprocess.run(['docker', 'ps', '--filter', 'name=mtproto-cf-proxy', '--format', '{{.Names}}'], 
                                      capture_output=True, text=True)
                mtproto_ok = 'mtproto-cf-proxy' in result.stdout
            except:
                mtproto_ok = False
            
            # 检查WebSocket转换器
            ws_ok = False
            try:
                result = subprocess.run(['docker', 'ps', '--filter', 'name=mtproto-ws-converter', '--format', '{{.Names}}'],
                                      capture_output=True, text=True)
                ws_ok = 'mtproto-ws-converter' in result.stdout
            except:
                ws_ok = False
            
            status = {
                'status': 'healthy' if (mtproto_ok and ws_ok) else 'unhealthy',
                'services': {
                    'mtproto': 'running' if mtproto_ok else 'stopped',
                    'websocket_converter': 'running' if ws_ok else 'stopped'
                },
                'timestamp': __import__('datetime').datetime.now().isoformat()
            }
            
            self.send_response(200 if status['status'] == 'healthy' else 503)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(status, indent=2).encode())
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == '__main__':
    server = HTTPServer(('127.0.0.1', 8081), HealthHandler)
    server.serve_forever()
EOF
    
    # 创建systemd服务
    cat > /etc/systemd/system/mtproto-health.service << EOF
[Unit]
Description=MTProto Health Check Server
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/mtproto-cf/health_server.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    
    # 启动健康检查服务
    systemctl daemon-reload
    systemctl enable mtproto-health
    systemctl start mtproto-health
    
    # 配置Nginx代理健康检查（可选）
    if command -v nginx &> /dev/null; then
        cat > /etc/nginx/sites-available/mtproto-health << EOF
server {
    listen 8080;
    server_name localhost;
    
    location /health {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host \$host;
    }
    
    location /mtproto {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
    }
}
EOF
        ln -sf /etc/nginx/sites-available/mtproto-health /etc/nginx/sites-enabled/
        systemctl restart nginx
    fi
    
    success "健康检查服务已启动"
}

# 启动隧道服务
start_tunnel_service() {
    step "启动Cloudflare隧道服务..."
    
    # 创建systemd服务
    cat > /etc/systemd/system/cloudflared-tunnel.service << EOF
[Unit]
Description=Cloudflare Tunnel for MTProto
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --config /etc/mtproto-cf/tunnel.yml run
Restart=always
RestartSec=10
User=root
StandardOutput=append:/var/log/cloudflared.log
StandardError=append:/var/log/cloudflared-error.log

[Install]
WantedBy=multi-user.target
EOF
    
    # 启动服务
    systemctl daemon-reload
    systemctl enable cloudflared-tunnel
    systemctl start cloudflared-tunnel
    
    # 检查状态
    sleep 3
    if systemctl is-active --quiet cloudflared-tunnel; then
        success "Cloudflare隧道服务启动成功"
    else
        error "Cloudflare隧道服务启动失败"
        systemctl status cloudflared-tunnel
        exit 1
    fi
}

# 创建管理脚本
create_management_scripts() {
    step "创建管理脚本..."
    
    # 主管理脚本
    cat > /usr/local/bin/mtproto-cf-manage << 'EOF'
#!/bin/bash

case "$1" in
    start)
        docker start mtproto-cf-proxy mtproto-ws-converter 2>/dev/null
        systemctl start cloudflared-tunnel mtproto-health 2>/dev/null
        echo "所有服务已启动"
        ;;
    stop)
        docker stop mtproto-ws-converter mtproto-cf-proxy 2>/dev/null
        systemctl stop cloudflared-tunnel mtproto-health 2>/dev/null
        echo "所有服务已停止"
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    status)
        echo "=== MTProto 服务状态 ==="
        echo ""
        echo "1. MTProto代理:"
        docker ps --filter name=mtproto-cf-proxy --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        echo "2. WebSocket转换器:"
        docker ps --filter name=mtproto-ws-converter --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        echo "3. Cloudflare隧道:"
        systemctl is-active cloudflared-tunnel >/dev/null && echo "✓ 运行中" || echo "✗ 未运行"
        echo ""
        echo "4. 健康检查服务:"
        systemctl is-active mtproto-health >/dev/null && echo "✓ 运行中" || echo "✗ 未运行"
        echo ""
        echo "=== 连接信息 ==="
        if [[ -f /etc/mtproto-cf/docker-compose.yml ]]; then
            grep -A2 "SECRET=" /etc/mtproto-cf/docker-compose.yml | head -2
        fi
        ;;
    logs)
        case "$2" in
            mtproto)
                docker logs -f mtproto-cf-proxy
                ;;
            ws)
                docker logs -f mtproto-ws-converter
                ;;
            tunnel)
                tail -f /var/log/cloudflared.log
                ;;
            health)
                journalctl -u mtproto-health -f
                ;;
            *)
                echo "用法: $0 logs {mtproto|ws|tunnel|health}"
                ;;
        esac
        ;;
    update)
        echo "更新MTProto镜像..."
        docker pull telegrammessenger/proxy:latest
        docker pull ymuski/ws-tcp-relay:latest
        
        echo "重启服务..."
        $0 restart
        echo "更新完成"
        ;;
    config)
        echo "配置文件位置:"
        echo "  MTProto配置: /etc/mtproto-cf/"
        echo "  WebSocket配置: /etc/ws-converter/"
        echo "  隧道配置: /etc/mtproto-cf/tunnel.yml"
        echo "  健康检查: /etc/mtproto-cf/health_server.py"
        ;;
    *)
        echo "MTProto + Cloudflare 管理脚本"
        echo "用法: $0 {start|stop|restart|status|logs|update|config}"
        echo ""
        echo "命令:"
        echo "  start     启动所有服务"
        echo "  stop      停止所有服务"
        echo "  restart   重启所有服务"
        echo "  status    查看服务状态"
        echo "  logs      查看日志 (mtproto|ws|tunnel|health)"
        echo "  update    更新所有镜像"
        echo "  config    查看配置文件位置"
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/mtproto-cf-manage
    
    # 监控脚本
    cat > /usr/local/bin/mtproto-cf-monitor << 'EOF'
#!/bin/bash

echo "=== MTProto + Cloudflare 监控面板 ==="
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 获取公网IP
PUBLIC_IP=$(curl -s ifconfig.me)
echo "服务器IP: $PUBLIC_IP"

# 获取配置信息
if [[ -f /etc/mtproto-cf/docker-compose.yml ]]; then
    SECRET=$(grep "SECRET=" /etc/mtproto-cf/docker-compose.yml | cut -d= -f2)
    PORT=$(grep "PORT=" /etc/mtproto-cf/docker-compose.yml | cut -d= -f2)
    echo "MTProto端口: $PORT"
    echo "MTProto密钥: $SECRET"
fi

echo ""
echo "=== 服务状态 ==="

# MTProto连接数
MT_CONNECTIONS=$(ss -tunap 2>/dev/null | grep ":$PORT" | grep -c ESTAB)
echo "活跃连接数: $MT_CONNECTIONS"

# Docker容器状态
echo ""
echo "容器状态:"
docker ps --filter "name=mtproto" --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}" 2>/dev/null || echo "Docker未运行"

# 系统资源
echo ""
echo "系统资源:"
free -h | awk 'NR==1{print "内存:"} NR==2{printf "  已用: %s / %s (%.1f%%)\n", $3, $2, $3/$2*100}'
df -h / | awk 'NR==2{printf "磁盘: %s / %s (%.1f%%)\n", $3, $2, $3/$2*100}'

# 流量统计（需要安装iftop）
if command -v iftop &> /dev/null && [[ -n "$PORT" ]]; then
    echo ""
    echo "端口 $PORT 流量统计:"
    echo "  ↑ $(ss -tin src :$PORT 2>/dev/null | grep -o 'bytes_sent:[0-9]*' | cut -d: -f2 | awk '{sum+=$1} END {if(sum>0) printf "%.2f MB", sum/1024/1024; else print "0 MB"}')"
    echo "  ↓ $(ss -tin dst :$PORT 2>/dev/null | grep -o 'bytes_acked:[0-9]*' | cut -d: -f2 | awk '{sum+=$1} END {if(sum>0) printf "%.2f MB", sum/1024/1024; else print "0 MB"}')"
fi

echo ""
echo "=== Cloudflare 隧道 ==="
if systemctl is-active cloudflared-tunnel >/dev/null 2>&1; then
    echo "状态: ✓ 运行中"
    echo "日志: tail -f /var/log/cloudflared.log"
else
    echo "状态: ✗ 未运行"
fi
EOF
    
    chmod +x /usr/local/bin/mtproto-cf-monitor
    
    success "管理脚本已创建"
    info "使用命令: mtproto-cf-manage"
    info "监控面板: mtproto-cf-monitor"
}

# 显示配置信息
show_final_config() {
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}              配置完成！请保存以下信息              ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
    echo ""
    
    # 获取公网IP
    PUBLIC_IP=$(curl -s ifconfig.me)
    
    echo -e "${CYAN}════════ MTProto 配置信息 ════════${NC}"
    echo "服务器: ${SUBDOMAIN}.${DOMAIN}"
    echo "端口: 443 (通过Cloudflare)"
    echo "密钥: $SECRET"
    echo "标签: $TAG"
    echo ""
    
    echo -e "${CYAN}════════ 分享链接 ════════${NC}"
    SHARE_LINK="tg://proxy?server=${SUBDOMAIN}.${DOMAIN}&port=443&secret=$SECRET"
    echo "$SHARE_LINK"
    echo ""
    
    echo -e "${CYAN}════════ QR码链接 ════════${NC}"
    QR_URL="https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=$SHARE_LINK"
    echo "$QR_URL"
    echo ""
    
    echo -e "${CYAN}════════ 客户端配置 ════════${NC}"
    echo "1. Telegram → 设置 → 高级 → 连接类型"
    echo "2. 使用自定义代理"
    echo "3. 类型: MTProto"
    echo "4. 服务器: ${SUBDOMAIN}.${DOMAIN}"
    echo "5. 端口: 443"
    echo "6. 密钥: $SECRET"
    echo ""
    
    echo -e "${CYAN}════════ 管理命令 ════════${NC}"
    echo "启动/停止: mtproto-cf-manage {start|stop|restart}"
    echo "查看状态: mtproto-cf-manage status"
    echo "查看日志: mtproto-cf-manage logs {mtproto|ws|tunnel|health}"
    echo "监控面板: mtproto-cf-monitor"
    echo "更新服务: mtproto-cf-manage update"
    echo ""
    
    echo -e "${CYAN}════════ 文件位置 ════════${NC}"
    echo "配置目录: /etc/mtproto-cf/"
    echo "隧道配置: /etc/mtproto-cf/tunnel.yml"
    echo "Docker配置: /etc/mtproto-cf/docker-compose.yml"
    echo "WebSocket配置: /etc/ws-converter/"
    echo "日志文件: /var/log/cloudflared.log"
    echo ""
    
    echo -e "${CYAN}════════ 健康检查 ════════${NC}"
    echo "访问: https://${SUBDOMAIN}.${DOMAIN}/health"
    echo ""
    
    echo -e "${YELLOW}════════ 重要提示 ════════${NC}"
    echo "1. 确保Cloudflare DNS代理已开启（橙色云朵）"
    echo "2. 首次连接可能需要等待DNS生效（最多10分钟）"
    echo "3. 如果连接失败，检查防火墙是否开放端口"
    echo "4. 定期备份配置: /etc/mtproto-cf/"
    echo "5. 监控流量使用，避免超出Cloudflare限额"
    echo ""
    
    # 测试连接
    echo -e "${CYAN}════════ 连接测试 ════════${NC}"
    info "正在测试隧道连接..."
    sleep 5
    if curl -s -I "https://${SUBDOMAIN}.${DOMAIN}/health" --max-time 10 | grep -q "200\|404"; then
        success "隧道连接正常！"
    else
        warning "隧道连接测试失败，请稍后手动检查"
        info "运行: mtproto-cf-manage logs tunnel"
    fi
}

# 主函数
main() {
    show_banner
    check_root
    get_config
    install_dependencies
    setup_firewall
    install_mtproto
    install_websocket_converter
    setup_cloudflare_tunnel
    create_health_check
    start_tunnel_service
    create_management_scripts
    show_final_config
    
    echo ""
    success "✅ MTProto + Cloudflare 配置完成！"
    echo ""
    info "现在可以通过 ${SUBDOMAIN}.${DOMAIN} 访问您的MTProto代理"
    info "首次使用请等待DNS生效（约1-10分钟）"
}

# 执行主函数
main "$@"

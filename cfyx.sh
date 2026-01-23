#!/bin/bash

# ==================================================
#   TG@sddzn 节点优选生成器 (全自动/全量版)
# ==================================================

INSTALL_PATH="/usr/local/bin/cfy"

# --- 1. 安装与自更新逻辑 ---
if [ "$0" != "$INSTALL_PATH" ]; then
    echo "正在安装/更新 [TG@sddzn 节点优选生成器]..."
    
    # 检查 root 权限
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ 错误: 需要管理员权限。请使用 'sudo bash ...' 运行。"
        exit 1
    fi

    # 写入文件
    if [[ "$(basename "$0")" == "bash" || "$(basename "$0")" == "sh" ]]; then
        # 如果是 curl | bash 运行的
        cat /proc/self/fd/0 > "$INSTALL_PATH"
    else
        # 如果是本地文件运行的
        cp "$0" "$INSTALL_PATH"
    fi

    chmod +x "$INSTALL_PATH"
    echo "✅ 安装成功! 输入 'cfy' 即可直接运行。"
    echo "---"
    # 安装完成后立即执行新脚本
    exec "$INSTALL_PATH"
    exit 0
fi

# --- 2. 核心程序 ---

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# 检查必要命令
check_deps() {
    for cmd in jq curl base64 grep sed; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}❌ 错误: 缺少命令 '$cmd'。请先安装它 (apt install $cmd)。${NC}"
            exit 1
        fi
    done
}

# 获取 GitHub IP (核心修复)
get_github_ips() {
    # --- 配置区域 ---
    # 直接在此处定义 URL，确保绝对有效
    local url="https://raw.githubusercontent.com/hc990275/yx/main/3.txt"
    # ----------------
    
    echo -e "${YELLOW}正在从 GitHub 拉取优选 IP 列表...${NC}"
    echo -e "  -> 目标地址: $url"
    
    # 获取内容：
    # 1. curl -L: 跟随重定向
    # 2. tr -d '\r': 删除 Windows 回车符 (关键，防止格式错误)
    # 3. sed '/^$/d': 删除空行
    local raw_content
    raw_content=$(curl -s -L --max-time 10 "$url" | tr -d '\r' | sed '/^$/d')
    
    if [ -z "$raw_content" ]; then
        echo -e "${RED}❌ 获取失败！内容为空或网络连接超时。${NC}"
        echo -e "${RED}   请检查服务器是否能连接 raw.githubusercontent.com${NC}"
        return 1
    fi

    # 存入全局数组
    declare -g -a ip_list
    mapfile -t ip_list <<< "$raw_content"

    # 再次检查数量
    local count=${#ip_list[@]}
    if [ "$count" -eq 0 ]; then
        echo -e "${RED}❌ 解析失败: 未发现有效 IP。${NC}"
        return 1
    fi

    echo -e "${GREEN}✅ 成功获取 $count 个 IP 地址。${NC}"
    return 0
}

main() {
    local url_file="/etc/sing-box/url.txt"
    declare -a valid_urls valid_ps_names
    
    echo -e "${GREEN}=================================================="
    echo -e "      TG@sddzn 节点优选生成器 (全量版)"
    echo -e "==================================================${NC}"

    # --- 步骤 1: 读取本地种子节点 ---
    if [ -f "$url_file" ]; then
        # 逐行读取文件
        while IFS= read -r url || [ -n "$url" ]; do
            # 简单校验是否以 vmess:// 开头
            if [[ "$url" == vmess://* ]]; then
                # 解码获取备注名，用于显示
                decoded_json=$(echo "${url#"vmess://"}" | base64 -d 2>/dev/null)
                if [ $? -eq 0 ] && [ -n "$decoded_json" ]; then
                    ps=$(echo "$decoded_json" | jq -r .ps 2>/dev/null)
                    if [ -n "$ps" ]; then 
                        valid_urls+=("$url"); valid_ps_names+=("$ps")
                    fi
                fi
            fi
        done < "$url_file"
    fi

    # --- 步骤 2: 选择模板 (自动或手动) ---
    local selected_url
    if [ ${#valid_urls[@]} -gt 0 ]; then
        if [ ${#valid_urls[@]} -eq 1 ]; then
            selected_url=${valid_urls[0]}
            echo -e "${YELLOW}检测到单节点，自动使用模板: ${valid_ps_names[0]}${NC}"
        else
            echo -e "${YELLOW}请选择一个节点作为模板:${NC}"
            for i in "${!valid_ps_names[@]}"; do 
                printf "%3d) %s\n" "$((i+1))" "${valid_ps_names[$i]}"
            done
            local choice
            while true; do
                read -p "请输入编号: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#valid_urls[@]} ]; then
                    selected_url=${valid_urls[$((choice-1))]}
                    break
                else 
                    echo -e "${RED}无效输入.${NC}"
                fi
            done
        fi
    else
        echo -e "${YELLOW}未找到有效配置文件，请手动输入 vmess:// 链接:${NC}"
        read selected_url
    fi

    # 解码原始数据备用
    local base64_part=${selected_url#"vmess://"}
    local original_json=$(echo "$base64_part" | base64 -d)
    local original_ps=$(echo "$original_json" | jq -r .ps)
    
    # --- 步骤 3: 获取 IP 并生成 (全自动) ---
    get_github_ips || exit 1
    
    local num_to_generate=${#ip_list[@]}
    
    echo "---"
    echo -e "${YELLOW}正在为全部 $num_to_generate 个 IP 生成配置...${NC}"
    
    # 循环生成
    for ((i=0; i<$num_to_generate; i++)); do
        local current_ip=${ip_list[$i]}
        
        # 构造新名字: 原名_TG@sddzn_IP
        local new_ps="${original_ps}_TG@sddzn_${current_ip}"
        
        # 使用 jq 替换 add(地址) 和 ps(备注)
        # 确保 IP 必须存在，否则 jq 可能会报错
        if [ -n "$current_ip" ]; then
            local modified_json=$(echo "$original_json" | jq --arg ip "$current_ip" --arg ps "$new_ps" '.add = $ip | .ps = $ps' -c)
            
            # Base64 编码 (tr -d '\n' 确保单行)
            local new_base64=$(echo -n "$modified_json" | base64 | tr -d '\n')
            echo "vmess://${new_base64}"
        fi
    done
    
    echo "---"
    echo -e "${GREEN}完成! 共生成 $num_to_generate 个节点。${NC}"
}

check_deps
main

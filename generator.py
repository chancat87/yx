import os
import re
import requests
from datetime import datetime

# ================= 主逻辑 =================
def main():
    print(f"[{datetime.now().strftime('%H:%M:%S')}] >>> VLESS节点生成器启动...")
    
    # 1. 配置加载
    regions_env = os.environ.get("TARGET_REGIONS", "SG,HK,US,JP")
    target_regions = [r.strip().upper() for r in regions_env.split(",") if r.strip()]
    per_region_count = int(os.environ.get("PER_REGION_COUNT", "50"))
    ip_list_url = "https://raw.githubusercontent.com/hc990275/yx/main/cfyxip.txt"
    output_file = "deip.txt"
    
    print(f"[*] 目标地区: {target_regions}")
    print(f"[*] 每个地区预期数量: {per_region_count}")
    
    # 2. 获取VLESS模板
    vless_template = os.environ.get("VLESS_TEMPLATE", "").strip()
    if not vless_template:
        print("[FATAL] VLESS_TEMPLATE 变量缺失！请在 GitHub Secrets 中配置。")
        return
    
    # 3. 解析模板，提取IP和端口
    pattern = r'vless://[^@]+@([^:]+):(\d+)'
    match = re.search(pattern, vless_template)
    if not match:
        print("[FATAL] 无法解析VLESS模板，请检查格式是否正确")
        print(f"[DEBUG] 模板内容: {vless_template[:50]}...")
        return
    
    template_ip = match.group(1)
    template_port = match.group(2)
    print(f"[*] 模板IP: {template_ip}, 模板端口: {template_port}")
    
    # 4. 获取并解析 IP 库
    print("[*] 正在获取远程 IP 列表...")
    try:
        resp = requests.get(ip_list_url, timeout=15)
        resp.raise_for_status()
        lines = resp.text.splitlines()
        print(f"[*] 成功下载 IP 列表，共 {len(lines)} 行")
    except Exception as e:
        print(f"[FATAL] 无法下载 IP 列表: {e}")
        return
    
    # 5. 按地区分类IP
    region_map = {r: [] for r in target_regions}
    all_regions_in_file = set()
    
    for line in lines:
        line = line.strip()
        if "#" in line and ":" in line:
            try:
                content, region_code = line.split("#", 1)
                region_code = region_code.strip().upper()
                all_regions_in_file.add(region_code)
                
                if region_code in region_map:
                    addr, port = content.split(":", 1)
                    region_map[region_code].append({
                        "add": addr.strip(), 
                        "port": port.strip()
                    })
            except Exception:
                continue
    
    # 6. 生成VLESS节点
    final_nodes = []
    print("[*] 筛选统计:")
    
    for rg in target_regions:
        match_count = len(region_map.get(rg, []))
        print(f"    - {rg}: 发现 {match_count} 个可用 IP")
        
        # 取前 N 个IP
        selected = region_map[rg][:per_region_count]
        
        for i, item in enumerate(selected):
            # 替换IP
            node_link = vless_template.replace(template_ip, item["add"])
            # 替换端口（注意冒号，避免误替换）
            node_link = node_link.replace(f":{template_port}", f":{item['port']}")
            # 替换节点名（# 后面的部分）
            node_link = re.sub(r'#.*$', f'#{rg}{i+1:02d}', node_link)
            
            final_nodes.append(node_link)
    
    # 7. 写入文件
    with open(output_file, "w", encoding="utf-8") as f:
        if final_nodes:
            f.write("\n".join(final_nodes))
            print(f"[SUCCESS] 裂变成功！共生成 {len(final_nodes)} 个VLESS节点。")
            print(f"[*] 输出文件: {output_file}")
        else:
            print("[WARNING] 本次未匹配到任何节点。")
            print(f"[*] 文件中存在的地区代码示例: {list(all_regions_in_file)[:10]}...")
            f.write(f"# No nodes matched at {datetime.now()}\n# Target: {target_regions}")
    
    print(f"[{datetime.now().strftime('%H:%M:%S')}] >>> 任务完成。")

if __name__ == "__main__":
    main()

import base64
import json
import os
import subprocess
import requests
from datetime import datetime

# ================= 辅助函数 =================
def decode_vmess(vmess_str):
    try:
        vmess_str = vmess_str.strip()
        if vmess_str.startswith("vmess://"):
            vmess_str = vmess_str[8:]
        padding = len(vmess_str) % 4
        if padding:
            vmess_str += "=" * (4 - padding)
        decoded = base64.b64decode(vmess_str).decode('utf-8')
        return json.loads(decoded)
    except Exception as e:
        print(f"[ERROR] 模板解析失败: {e}")
        return None

def encode_vmess(vmess_obj):
    try:
        # V2Ray/Clash 要求紧凑 JSON，移除 indent 避免解析失败
        json_str = json.dumps(vmess_obj, ensure_ascii=False, separators=(',', ':'))
        encoded = base64.b64encode(json_str.encode('utf-8')).decode('utf-8')
        return f"vmess://{encoded}"
    except Exception as e:
        print(f"[ERROR] 节点加密失败: {e}")
        return None

# ================= 主逻辑 =================
def main():
    print(f"[{datetime.now().strftime('%H:%M:%S')}] >>> 工具启动...")
    
    # 1. 配置加载 (已移除所有键值对的多余空格)
    regions_env = os.environ.get("TARGET_REGIONS", "SG,HK,US,JP")
    target_regions = [r.strip().upper() for r in regions_env.split(",") if r.strip()]
    per_region_count = int(os.environ.get("PER_REGION_COUNT", "50"))
    ip_list_url = "https://raw.githubusercontent.com/hc990275/yx/main/cfyxip.txt"
    output_file = "deip.txt"

    print(f"[*] 目标地区: {target_regions}")
    print(f"[*] 每个地区预期数量: {per_region_count}")

    # 2. 模式检查 (强制更新逻辑)
    force_update = os.environ.get("FORCE_UPDATE", "false").lower() == "true"
    if not force_update and os.path.exists(output_file):
        try:
            # 修复: '--fo rmat=%ad' -> '--format=%ad'
            last_commit_date = subprocess.check_output(
                ['git', 'log', '-1', '--format=%ad', '--date=short', output_file],
                stderr=subprocess.DEVNULL
            ).decode('utf-8').strip()
            if last_commit_date == datetime.now().strftime("%Y-%m-%d"):
                print(f"[#] 仓库文件今日已更新过 ({last_commit_date})，定时任务跳过。")
                return
        except Exception:
            pass

    # 3. 解析模板
    template_raw = os.environ.get("VMESS_TEMPLATE", "").strip()
    if not template_raw:
        print("[FATAL] VMESS_TEMPLATE 变量缺失！请在 GitHub Secrets 中配置。")
        return

    base_obj = decode_vmess(template_raw)
    if not base_obj:
        return

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

    region_map = {r: [] for r in target_regions}
    all_regions_in_file = set()

    for line in lines:
        line = line.strip()
        # 修复: 移除分隔符后的空格 "# " -> "#"  ": " -> ":"
        if "#" in line and ":" in line:
            try:
                content, region_code = line.split("#", 1)
                region_code = region_code.strip().upper()
                all_regions_in_file.add(region_code)
                
                if region_code in region_map:
                    addr, port = content.split(":", 1)
                    # 修复: 字典键移除空格 "add " -> "add"
                    region_map[region_code].append({"add": addr.strip(), "port": port.strip()})
            except Exception:
                continue

    # 5. 生成结果
    final_nodes = []
    print("[*] 筛选统计:")
    for rg in target_regions:
        match_count = len(region_map.get(rg, []))
        print(f"    - {rg}: 发现 {match_count} 个可用 IP")
        
        selected = region_map[rg][:per_region_count]
        for i, item in enumerate(selected):
            node = base_obj.copy()
            node.update({
                "add": item["add"],
                "port": item["port"],
                "ps": f"{rg}{i+1:02d}"
            })
            encoded = encode_vmess(node)
            if encoded:
                final_nodes.append(encoded)

    # 6. 最终写入
    with open(output_file, "w", encoding="utf-8") as f:
        if final_nodes:
            f.write("\n".join(final_nodes))
            print(f"[SUCCESS] 裂变成功！共生成 {len(final_nodes)} 个节点。")
        else:
            print("[WARNING] 本次未匹配到任何节点。")
            print(f"[*] 文件中存在的地区代码示例: {list(all_regions_in_file)[:10]}...")
            f.write(f"# No nodes matched at {datetime.now()}\n# Target: {target_regions}")

    print(f"[{datetime.now().strftime('%H:%M:%S')}] >>> 任务完成。")

# 修复: if name == "main" -> if __name__ == "__main__"
if __name__ == "__main__":
    main()

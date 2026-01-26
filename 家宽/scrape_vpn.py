import os
import sys
import requests
from bs4 import BeautifulSoup
import datetime
import re

# -----------------------------------------------------------
# 1. 获取环境变量 (核心修改：不从代码中读取 URL)
# -----------------------------------------------------------
TARGET_URL = os.getenv('VPN_SOURCE_URL')

if not TARGET_URL:
    print("❌ 错误: 未检测到 'VPN_SOURCE_URL' 环境变量。")
    print("请在 GitHub 仓库 Settings -> Secrets and variables -> Actions 中添加 Repository secret。")
    sys.exit(1)

# -----------------------------------------------------------
# 2. 配置部分
# -----------------------------------------------------------

# 国家名称映射 (英文 -> 简体中文)
COUNTRY_MAP = {
    "Japan": "日本",
    "Republic of Korea": "韩国",
    "United States": "美国",
    "United Kingdom": "英国",
    "Germany": "德国",
    "France": "法国",
    "Netherlands": "荷兰",
    "Singapore": "新加坡",
    "Canada": "加拿大",
    "Russia": "俄罗斯",
    "India": "印度",
    "Australia": "澳大利亚",
    "China": "中国",
    "Hong Kong": "中国香港",
    "Taiwan": "中国台湾",
    "Brazil": "巴西",
    "Vietnam": "越南",
    "Thailand": "泰国",
    "Indonesia": "印度尼西亚",
    "Turkey": "土耳其"
}

def translate_country(english_name):
    """将英文国家名转换为中文"""
    clean_name = english_name.strip()
    return COUNTRY_MAP.get(clean_name, clean_name)

def parse_uptime_to_minutes(uptime_str):
    """
    解析时间字符串，用于排序。
    例如: '60 days' -> 86400, '5 mins' -> 5
    """
    uptime_str = uptime_str.lower().strip()
    
    # 提取数字
    match = re.search(r'(\d+)', uptime_str)
    if not match:
        return float('inf') # 无法解析的放到最后
    
    value = int(match.group(1))
    
    if 'day' in uptime_str:
        return value * 24 * 60
    elif 'hour' in uptime_str:
        return value * 60
    elif 'min' in uptime_str:
        return value
    elif 'sec' in uptime_str:
        return 0 # 秒级视为0分钟
    
    return value

def scrape_and_generate_readme():
    print(f"🚀 开始抓取任务...")
    
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
    }

    try:
        response = requests.get(TARGET_URL, headers=headers, timeout=20)
        response.raise_for_status()
        soup = BeautifulSoup(response.text, 'html.parser')
    except Exception as e:
        print(f"❌ 请求失败: {e}")
        sys.exit(1)

    # 定位表格
    table = soup.find('table', class_='table table-success table-striped text-nowrap')
    if not table:
        print("❌ 错误: 未找到目标表格，网页结构可能已变更。")
        sys.exit(1)

    vpn_nodes = []
    
    tbody = table.find('tbody')
    rows = tbody.find_all('tr') if tbody else []

    print(f"📊 发现原始数据行数: {len(rows)}")

    for row in rows:
        cols = row.find_all('td')
        # 网页结构: # (th), Location (td), IP (td), Uptime (td), Ping (td)
        if len(cols) >= 4:
            location_raw = cols[0].get_text(strip=True)
            ip_address = cols[1].get_text(strip=True)
            uptime_str = cols[2].get_text(strip=True)
            ping = cols[3].get_text(strip=True)

            location_cn = translate_country(location_raw)
            uptime_minutes = parse_uptime_to_minutes(uptime_str)

            vpn_nodes.append({
                "location": location_cn,
                "ip": ip_address,
                "uptime_str": uptime_str,
                "uptime_minutes": uptime_minutes, # 排序键值
                "ping": ping
            })

    # -----------------------------------------------------------
    # 3. 排序逻辑：在线时间短的在上面 (升序排序)
    # -----------------------------------------------------------
    vpn_nodes.sort(key=lambda x: x['uptime_minutes'])

    # -----------------------------------------------------------
    # 4. 生成 README.md
    # -----------------------------------------------------------
    current_time = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    # 注意：这里我们隐藏 URL 的具体路径，只显示域名，或者是 "Source URL"
    # 或者如果你想在 README 里公开这个链接，可以使用 f"[{TARGET_URL}]({TARGET_URL})"
    # 既然你在 Action 变量里隐藏了，这里我也做个脱敏处理，或者你可以选择直接显示
    
    md_content = f"# 家宽 L2TP/IPsec VPN 列表\n\n"
    md_content += f"> **更新时间**: {current_time} (UTC+0)\n"
    md_content += f"> **节点数量**: {len(vpn_nodes)}\n\n"
    md_content += f"**排序规则**：按在线时间倒序（新上线的节点在最上方）。\n\n"
    
    md_content += "| 地区 | IP 地址 | 在线时间 | 延迟 (Ping) |\n"
    md_content += "| :--- | :--- | :--- | :--- |\n"

    for node in vpn_nodes:
        # 加粗显示运行时间少于 1 天 (1440分钟) 的节点
        uptime_display = node['uptime_str']
        if node['uptime_minutes'] < 1440:
            uptime_display = f"**{uptime_display}** 🆕"

        md_content += f"| {node['location']} | `{node['ip']}` | {uptime_display} | {node['ping']} |\n"

    # 获取脚本所在目录
    script_dir = os.path.dirname(os.path.abspath(__file__))
    readme_path = os.path.join(script_dir, 'README.md')

    with open(readme_path, 'w', encoding='utf-8') as f:
        f.write(md_content)

    print(f"✅ 成功生成 README.md，路径: {readme_path}")

if __name__ == "__main__":
    scrape_and_generate_readme()

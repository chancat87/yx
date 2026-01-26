import os
import requests
from bs4 import BeautifulSoup
import json
import datetime

# 获取环境变量中的目标 URL
TARGET_URL = os.getenv('TARGET_URL')

# 国家名称中英文映射字典 (根据常见 VPN 地区预设，可按需添加)
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
    "Indonesia": "印度尼西亚"
}

def translate_country(english_name):
    """
    将英文国家名转换为中文。
    如果字典中不存在，则返回原始英文名。
    """
    clean_name = english_name.strip()
    return COUNTRY_MAP.get(clean_name, clean_name)

def scrape_data():
    if not TARGET_URL:
        print("错误: 未找到 TARGET_URL 环境变量。")
        return

    print(f"正在抓取: {TARGET_URL}")
    
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
    }

    try:
        response = requests.get(TARGET_URL, headers=headers, timeout=15)
        response.raise_for_status()
        html_content = response.text
    except Exception as e:
        print(f"请求失败: {e}")
        return

    soup = BeautifulSoup(html_content, 'html.parser')

    # 定位表格
    # 根据源码，表格类名为: table table-success table-striped text-nowrap
    table = soup.find('table', class_='table table-success table-striped text-nowrap')
    
    if not table:
        print("错误: 未找到目标表格，网页结构可能已变更。")
        return

    results = []
    
    # 获取表格主体 tbody
    tbody = table.find('tbody')
    if not tbody:
        print("错误: 表格中没有 tbody。")
        return

    # 遍历每一行
    rows = tbody.find_all('tr')
    print(f"发现 {len(rows)} 行数据。")

    for row in rows:
        cols = row.find_all('td')
        # 确保列数足够 (源码中除去序号th，有4个td: Location, IP, Uptime, Ping)
        # 但是注意：第一列是 th (序号)，后面是 td
        if len(cols) >= 4:
            location_raw = cols[0].get_text(strip=True)
            ip_address = cols[1].get_text(strip=True)
            uptime = cols[2].get_text(strip=True)
            ping = cols[3].get_text(strip=True)

            # 翻译国家名称
            location_cn = translate_country(location_raw)

            data_point = {
                "地区": location_cn,
                "IP地址": ip_address,
                "在线时间": uptime,
                "延迟": ping,
                "抓取时间": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            }
            results.append(data_point)

    # 输出结果到 JSON 文件
    output_file = 'vpn_nodes.json'
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(results, f, ensure_ascii=False, indent=4)
    
    print(f"成功抓取 {len(results)} 个节点信息，已保存至 {output_file}")
    
    # 为了方便在 GitHub Actions 日志中查看，打印出来
    print(json.dumps(results, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    scrape_data()

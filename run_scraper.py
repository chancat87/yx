import os
import re
import requests
from bs4 import BeautifulSoup
import datetime

# 如果环境变量不存在，使用默认 URL (方便测试)
URL = os.environ.get("VPN_SOURCE_URL", "https://ipspeed.info/free-l2tpipsec.php")
FILE_NAME = "家宽/非219IP.md"

def get_new_data():
    """
    基于 HTML 表格结构的精准抓取
    结构: <tr> <th>序号</th> <td>地区</td> <td>IP</td> ... </tr>
    """
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }
    valid_lines = []
    
    try:
        print(f"正在抓取: {URL}")
        resp = requests.get(URL, headers=headers, timeout=30)
        resp.encoding = 'utf-8'
        
        soup = BeautifulSoup(resp.text, 'html.parser')
        
        # 1. 找到页面中的表格
        # table-success table-striped 是该网站特有的类名，或者直接找第一个 table
        table = soup.find('table')
        if not table:
            print("错误: 未找到表格结构")
            return []

        # 2. 遍历所有表格行
        # tbody 下的 tr
        rows = table.find_all('tr')
        
        for row in rows:
            cols = row.find_all('td')
            # 根据源码:
            # <th>1</th> (序号, 可能在 th 里)
            # <td>Japan</td> (索引 0)
            # <td>219.100.37.176</td> (索引 1)
            
            if len(cols) >= 2:
                location = cols[0].get_text(strip=True)
                ip = cols[1].get_text(strip=True)
                
                # 简单的 IP 校验
                if re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', ip):
                    
                    # --- 核心过滤: 排除 219 开头 ---
                    if not ip.startswith("219."):
                        # 格式化为: | IP | 地区 |
                        line_str = f"| {ip} | {location} |"
                        valid_lines.append(line_str)
                        print(f"提取成功: {ip} ({location})")
                    else:
                        # print(f"跳过 219 IP: {ip}")
                        pass
                
        return valid_lines

    except Exception as e:
        print(f"抓取异常: {e}")
        return []

def load_old_data():
    """读取历史数据，用于持久化"""
    if not os.path.exists(FILE_NAME):
        return []
    
    old_lines = []
    # 读取文件，排除表头
    with open(FILE_NAME, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            # 只要是以 "| 数字" 开头的行，我们认为是数据行
            if line.startswith("|") and re.search(r'\|\s*\d', line):
                old_lines.append(line)
    return old_lines

def main():
    os.makedirs("家宽", exist_ok=True)

    new_data = get_new_data()
    old_data = load_old_data()
    
    print(f"新抓取: {len(new_data)} 条")
    print(f"历史库: {len(old_data)} 条")

    if not new_data and not old_data:
        print("无任何数据，退出")
        return

    # --- 合并策略: 新数据在前 (倒序) ---
    combined = new_data + old_data
    
    # --- 去重策略: 保留第一次出现的 (即保留最新的) ---
    seen = set()
    unique_data = []
    for item in combined:
        # 以 "IP" 为去重键，防止地区名变化导致重复 (可选)
        # 这里简单起见，如果整行内容一样就去重
        if item not in seen:
            seen.add(item)
            unique_data.append(item)
    
    print(f"去重后总数: {len(unique_data)} 条")

    # 写入文件
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(FILE_NAME, "w", encoding="utf-8") as f:
        f.write(f"# 非 219 IP 永久记录库\n\n")
        f.write(f"> 更新时间: {timestamp} (UTC) | 有效数据: {len(unique_data)}\n\n")
        f.write(f"| IP 地址 | 地区信息 |\n")
        f.write(f"| :--- | :--- |\n")
        for line in unique_data:
            f.write(f"{line}\n")
    
    print("文件写入完成")

if __name__ == "__main__":
    main()

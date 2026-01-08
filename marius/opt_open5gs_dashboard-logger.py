#!/usr/bin/env python3
import time
import subprocess
import re
import urllib.request
import pymongo
import os
from datetime import datetime

# --- Config ---
MONGO_URI = "mongodb://127.0.0.1:27017/"
INTERFACE = "ogstun"
INTERVAL = 1
LOG_FILE = "/var/log/open5gs/smf.log"

# Global State
active_sessions = {} # { "10.45.0.2": "24288..." }

def run_cmd(cmd):
    subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def setup_iptables():
    run_cmd("iptables -N OGS_ACCT 2>/dev/null")
    run_cmd(f"iptables -C FORWARD -i {INTERFACE} -j OGS_ACCT 2>/dev/null || iptables -I FORWARD -i {INTERFACE} -j OGS_ACCT")
    run_cmd(f"iptables -C FORWARD -o {INTERFACE} -j OGS_ACCT 2>/dev/null || iptables -I FORWARD -o {INTERFACE} -j OGS_ACCT")

def process_log_line(line):
    global active_sessions
    
    # 1. Match Connection: SUPI[imsi-12345] ... IPv4[10.45.0.2]
    m_add = re.search(r'SUPI\[(?:imsi-)?(\d+)\].*IPv4\[([0-9\.]+)\]', line)
    if m_add:
        imsi = m_add.group(1)
        ip = m_add.group(2)
        active_sessions[ip] = imsi
        return

    # 2. Match Release
    if "Release" in line and "SUPI" in line:
        m_rel = re.search(r'SUPI\[(?:imsi-)?(\d+)\]', line)
        if m_rel:
            imsi_rel = m_rel.group(1)
            ips_to_remove = [k for k,v in active_sessions.items() if v == imsi_rel]
            for k in ips_to_remove:
                del active_sessions[k]

def sync_iptables_rules():
    try:
        current = subprocess.check_output("iptables -L OGS_ACCT -n", shell=True).decode()
        for ip in active_sessions.keys():
            if f" {ip} " not in current:
                run_cmd(f"iptables -A OGS_ACCT -s {ip} -j RETURN")
                run_cmd(f"iptables -A OGS_ACCT -d {ip} -j RETURN")
    except: pass

def read_traffic_counters():
    stats = {}
    try:
        out = subprocess.check_output("iptables -L OGS_ACCT -v -n -x", shell=True).decode()
        for line in out.split('\n'):
            parts = line.split()
            if len(parts) < 8: continue
            try:
                bytes_count = int(parts[1])
                src, dst = parts[7], parts[8]
                if src in active_sessions:
                    imsi = active_sessions[src]
                    if imsi not in stats: stats[imsi] = {"rx": 0, "tx": 0}
                    stats[imsi]["tx"] += bytes_count
                if dst in active_sessions:
                    imsi = active_sessions[dst]
                    if imsi not in stats: stats[imsi] = {"rx": 0, "tx": 0}
                    stats[imsi]["rx"] += bytes_count
            except: continue
    except: pass
    return stats

def parse_metric(url, key):
    total = 0
    try:
        with urllib.request.urlopen(url, timeout=0.5) as r:
            for line in r.read().decode().split('\n'):
                if key in line and not line.startswith('#'):
                    try: total += int(float(line.split()[-1]))
                    except: pass
    except: pass
    return total

def get_infra_counts():
    return {
        "ue_4g": parse_metric("http://127.0.0.2:9090/metrics", "mme_session"),
        "enb":   parse_metric("http://127.0.0.2:9090/metrics", "enb"),
        "ue_5g": parse_metric("http://127.0.0.5:9090/metrics", "fivegs_amffunction_rm_registeredsubnbr"),
        "gnb":   parse_metric("http://127.0.0.5:9090/metrics", "gnb")
    }

def main():
    client = pymongo.MongoClient(MONGO_URI)
    db = client["open5gs_dashboard"]
    history_col = db["history"]
    traffic_col = db["imsi_traffic"]
    
    history_col.create_index("timestamp", expireAfterSeconds=604800)
    setup_iptables()
    
    # Bootstrap from logs
    print("Bootstrapping...")
    try:
        if os.path.exists(LOG_FILE):
            cmd = f"tail -n 50000 {LOG_FILE}"
            lines = subprocess.check_output(cmd, shell=True).decode('utf-8', errors='ignore').split('\n')
            for line in lines: process_log_line(line)
    except: pass

    f = open(LOG_FILE, 'r')
    f.seek(0, 2)
    cur_inode = os.fstat(f.fileno()).st_ino
    last_run = time.time()
    last_counters = {} 

    print("Logger Running.")
    while True:
        start_time = time.time()

        # 1. Log Processing
        while True:
            line = f.readline()
            if not line: break
            process_log_line(line)
        
        # Log Rotation
        try:
            if os.stat(LOG_FILE).st_ino != cur_inode:
                f.close(); f = open(LOG_FILE, 'r'); cur_inode = os.fstat(f.fileno()).st_ino
        except: pass

        # 2. Sync
        sync_iptables_rules()
        current_counters = read_traffic_counters()
        
        # 3. Update DB with IP AND Traffic
        # First, ensure all active IPs are recorded even if 0 traffic
        for ip, imsi in active_sessions.items():
            data = current_counters.get(imsi, {"rx": 0, "tx": 0})
            traffic_col.update_one(
                {"imsi": imsi}, 
                {"$set": {
                    "ip": ip,              # <--- SAVING IP TO DB HERE
                    "status": "Connected", # <--- EXPLICIT STATUS
                    "total_rx": data["rx"], 
                    "total_tx": data["tx"],
                    "last_seen": datetime.now()
                }}, 
                upsert=True
            )

        # Mark disconnected users as Idle in DB (optional cleanup)
        # We find anyone in DB who is NOT in active_sessions and set status=Idle
        # This keeps the UI clean
        all_active_imsis = list(active_sessions.values())
        if all_active_imsis:
            traffic_col.update_many(
                {"imsi": {"$nin": all_active_imsis}},
                {"$set": {"status": "Idle", "ip": "-"}}
            )

        # 4. History & Rates
        time_diff = start_time - last_run
        if time_diff < 0.1: time_diff = 0.1
        
        imsi_rates = {}
        glob_rx = 0; glob_tx = 0
        
        for imsi, data in current_counters.items():
            if imsi in last_counters:
                dr = (data["rx"] - last_counters[imsi]["rx"]) * 8 / time_diff
                dt = (data["tx"] - last_counters[imsi]["tx"]) * 8 / time_diff
                imsi_rates[imsi] = {"rx_bps": int(max(0, dr)), "tx_bps": int(max(0, dt))}
                glob_rx += max(0, dr); glob_tx += max(0, dt)

        infra = get_infra_counts()
        history_col.insert_one({
            "timestamp": datetime.now(),
            "rx_bps": int(glob_rx), "tx_bps": int(glob_tx),
            "ue_4g": infra["ue_4g"], "ue_5g": infra["ue_5g"],
            "enb": infra["enb"], "gnb": infra["gnb"],
            "streams": imsi_rates
        })
        
        last_counters = current_counters
        last_run = start_time
        elapsed = time.time() - start_time
        time.sleep(max(0, INTERVAL - elapsed))

if __name__ == "__main__":
    main()

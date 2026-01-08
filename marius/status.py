#!/usr/bin/env python3
import cgitb
import cgi
import subprocess
import urllib.request
import re
import os
import sys
import pymongo
import json
from datetime import datetime
from pysnmp.hlapi import * # Enable Debugging
cgitb.enable()
sys.stdout.reconfigure(encoding='utf-8')

MONGO_URI = "mongodb://127.0.0.1:27017/"
LOG_FILES = {
    "SMF": "/var/log/open5gs/smf.log", 
    "AMF": "/var/log/open5gs/amf.log",
    "MME": "/var/log/open5gs/mme.log"
}

# --- CONFIGURATION ---
BTS_IP = "192.168.1.20" 
BTS_COMMUNITY = "public" 

# Log Rules: Regex -> Human Message
TRIGGER_RULES = [
    {"pattern": r"Cannot find SUCI|Registration reject \[11\]", "msg": "⚠️ <b>Unknown SIM:</b> UE not in Database.", "solution": "Check IMSI in WebUI.", "color": "#ff9800", "prio": 2},
    {"pattern": r"No SMF Instance", "msg": "🚨 <b>SMF Failure:</b> AMF cannot contact SMF.", "solution": "Restart open5gs-smfd.", "color": "#ff5252", "prio": 1},
    {"pattern": r"Authentication failure|Authentication reject", "msg": "⛔ <b>Auth Failed:</b> Key (K) or OPc mismatch.", "solution": "Verify SIM secrets.", "color": "#ff5252", "prio": 1},
    {"pattern": r"HTTP response error \[(400|504)\]", "msg": "🔥 <b>Core Error:</b> HTTP 400/504.", "solution": "Check Disk/Restart Services.", "color": "#ff5252", "prio": 1},
    {"pattern": r"SCTP shutdown", "msg": "🔌 <b>Radio Disconnect:</b> eNB/gNB disconnected.", "solution": "Check radio connectivity.", "color": "#ff9800", "prio": 2},
    {"pattern": r"UE Context Release", "msg": "🔌 <b>UE Context Release:</b> No issue, UE going to idle", "solution": "none", "color": "#ff9800", "prio": 2}
]

METRICS_ENDPOINTS = [
    {"name": "MME (4G)", "ip": "127.0.0.2", "port": 9090, "key": "mme_session", "proc": "open5gs-mmed"},
    {"name": "AMF (5G)", "ip": "127.0.0.5", "port": 9090, "key": "fivegs_amffunction_rm_registeredsubnbr", "proc": "open5gs-amfd"},
    {"name": "SMF (Sess)", "ip": "127.0.0.4", "port": 9090, "key": "fivegs_smffunction_sm_sessionnbr", "proc": "open5gs-smfd"},
    {"name": "UPF (Tun)",  "ip": "127.0.0.7", "port": 9090, "key": "fivegs_upffunction_upf_sessionnbr", "proc": "open5gs-upfd"}
]

# --- FUNCTIONS ---
def get_db(): return pymongo.MongoClient(MONGO_URI, serverSelectionTimeoutMS=500)

def fmt_bytes(b):
    if not b: return "0 B"
    b = float(b)
    if b < 1024: return f"{b:.0f} B"
    if b < 1024**2: return f"{b/1024:.1f} KB"
    if b < 1024**3: return f"{b/1024**2:.1f} MB"
    return f"{b/1024**3:.2f} GB"

def handle_post(form):
    if "action" in form and form["action"].value == "rename":
        client = get_db()
        client["open5gs_dashboard"]["sim_names"].update_one(
            {"imsi": form["imsi"].value}, 
            {"$set": {"name": form["nickname"].value}}, upsert=True)
        rng = form.getvalue("current_range", "10m")
        print(f"Content-Type: text/html\nLocation: status.py?range={rng}\n\n")
        sys.exit()

def get_history(time_range):
    limit, step = 600, 1
    if time_range == "1h": limit, step = 3600, 6
    elif time_range == "24h": limit, step = 86400, 144
    elif time_range == "7d": limit, step = 604800, 1000
    client = get_db()
    data = list(client["open5gs_dashboard"]["history"].find().sort("timestamp", -1).limit(limit))
    return list(reversed(data))[::step]

def check_proc(name):
    try: subprocess.check_output(f"pgrep -f {name}", shell=True); return True
    except: return False

def get_mongo_status():
    try:
        client = get_db()
        client.admin.command('ping')
        return "UP"
    except: return "DOWN"

def get_process_list():
    try:
        cmd = "ps -e -o cmd | grep -E 'open5gs|mongod' | grep -v grep | sort"
        output = subprocess.check_output(cmd, shell=True).decode('utf-8')
        processes = []
        for line in output.split('\n'):
            if line.strip(): processes.append(line.split()[0].split('/')[-1])
        return processes
    except: return []

def analyze_logs():
    alerts = []
    seen = set()
    for name, filepath in LOG_FILES.items():
        if os.access(filepath, os.R_OK):
            try:
                cmd = f"tail -n 100 {filepath}"
                out = subprocess.check_output(cmd, shell=True).decode('utf-8', errors='ignore')
                for line in reversed(out.split('\n')):
                    for rule in TRIGGER_RULES:
                        if re.search(rule["pattern"], line):
                            # Dedup based on rule message + first 20 chars of log (timestamp)
                            key = rule["msg"] + line[:20] 
                            if key not in seen:
                                alerts.append({
                                    "html": f'<div class="alert" style="border-left:5px solid {rule["color"]}"><div style="color:{rule["color"]};font-weight:bold;">{rule["msg"]}</div><div class="log-line">{line[:120]}...</div><div class="solution">💡 {rule["solution"]}</div></div>',
                                    "prio": rule["prio"]
                                })
                                seen.add(key)
            except: pass
    alerts.sort(key=lambda x: x["prio"])
    return [a["html"] for a in alerts]

def get_service_status(svc):
    url = f"http://{svc['ip']}:{svc['port']}/metrics"
    try:
        proxy = urllib.request.ProxyHandler({})
        opener = urllib.request.build_opener(proxy)
        with opener.open(urllib.request.Request(url), timeout=1.0) as r:
            data = r.read().decode('utf-8')
            total = 0.0
            found = False
            for line in data.split('\n'):
                if svc['key'] in line and not line.startswith('#'):
                    try: val = float(line.split()[-1]); total += val; found = True
                    except: pass
            if found: return str(int(total))
            if check_proc(svc['proc']): return "Active (No Key)"
    except:
        if check_proc(svc['proc']): return "Active (No API)"
    return "DOWN"

def get_bts_snmp():
    data = {"status": "DOWN", "name": "Nokia BTS", "uptime": "-", "color": "#ff5252"}
    try:
        for oid_name, oid_val in [("name", "1.3.6.1.2.1.1.1.0"), ("uptime", "1.3.6.1.2.1.1.3.0")]:
            errorIndication, errorStatus, errorIndex, varBinds = next(
                getCmd(SnmpEngine(), CommunityData(BTS_COMMUNITY, mpModel=1),
                       UdpTransportTarget((BTS_IP, 161), timeout=0.5, retries=0),
                       ContextData(), ObjectType(ObjectIdentity(oid_val)))
            )
            if not errorIndication and not errorStatus:
                val = str(varBinds[0][1])
                data["status"] = "ONLINE"; data["color"] = "#00e676"
                if oid_name == "name": 
                    if "AirScale" in val: data["name"] = "Nokia AirScale"
                    elif "Flexi" in val: data["name"] = "Nokia Flexi"
                    else: data["name"] = val[:20]
                if oid_name == "uptime":
                    seconds = int(val) / 100
                    d = int(seconds // 86400); h = int((seconds % 86400) // 3600)
                    data["uptime"] = f"{d}d {h}h"
    except: pass
    return data

def get_subs():
    client = get_db()
    db_dash = client["open5gs_dashboard"]
    subs = list(client["open5gs"]["subscribers"].find({}, {"imsi": 1, "security.k": 1}))
    names = {d["imsi"]: d["name"] for d in db_dash["sim_names"].find()}
    traffic = {d["imsi"]: d for d in db_dash["imsi_traffic"].find()}
    final = []
    for s in subs:
        imsi = s["imsi"]
        traf_data = traffic.get(imsi, {})
        final.append({
            "imsi": imsi, "key": s.get("security", {}).get("k", "")[:6] + "...",
            "name": names.get(imsi, ""), "ip": traf_data.get("ip", "-"),
            "status": traf_data.get("status", "Idle"),
            "rx": traf_data.get("total_rx", 0), "tx": traf_data.get("total_tx", 0)
        })
    return final

# --- RENDER ---
form = cgi.FieldStorage()
handle_post(form)
selected_range = form.getvalue("range", "10m")
history = get_history(selected_range)
subs = get_subs()
bts = get_bts_snmp()
log_alerts = analyze_logs()
procs = get_process_list()
mongo_stat = get_mongo_status()

# Chart Data Prep
labels = [d["timestamp"].strftime("%H:%M:%S") if selected_range in ["10m","1h"] else d["timestamp"].strftime("%m-%d %H") for d in history]
tx_data = [d["tx_bps"] for d in history]
rx_data = [d["rx_bps"] for d in history]
gnb_data = [d.get("gnb", 0) for d in history]
enb_data = [d.get("enb", 0) for d in history]
ue_data = [d.get("ue_4g", 0) + d.get("ue_5g", 0) for d in history]
imsi_datasets = []
imsi_names = {s["imsi"]: (s["name"] if s["name"] else s["imsi"]) for s in subs}
colors = ['#FF6384', '#36A2EB', '#FFCE56', '#4BC0C0', '#9966FF', '#FF9F40']
temp = {s["imsi"]: [] for s in subs}
for rec in history:
    streams = rec.get("streams", {})
    for imsi in temp.keys():
        val = streams[imsi].get("tx_bps", 0) + streams[imsi].get("rx_bps", 0) if imsi in streams else 0
        temp[imsi].append(val)
idx = 0
for imsi, dp in temp.items():
    if max(dp) > 0:
        imsi_datasets.append({"label": imsi_names.get(imsi, imsi), "data": dp, "borderColor": colors[idx%len(colors)], "borderWidth": 1, "pointRadius": 0, "tension": 0.4})
        idx += 1

print("Content-Type: text/html; charset=utf-8\n")
print(f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Open5GS Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script><meta http-equiv="refresh" content="30">
<style>
body {{ font-family: 'Segoe UI', sans-serif; background: #121212; color: #eee; padding: 20px; font-size: 14px; }}
.grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(400px, 1fr)); gap: 20px; }}
.box {{ background: #1e1e1e; padding: 15px; border-radius: 8px; border: 1px solid #333; }}
.box-click {{ cursor: pointer; transition: transform 0.2s; }}
.box-click:hover {{ transform: scale(1.02); border-color: #00bcd4; }}
table {{ width: 100%; border-collapse: collapse; }}
th, td {{ padding: 8px; border-bottom: 1px solid #333; text-align: left; }}
th {{ background: #252525; color: #bbb; border-bottom: 2px solid #444; }}
input[type="text"] {{ background: #333; border: 1px solid #555; color: white; padding: 4px; }}
button {{ background: #4caf50; border: none; color: white; padding: 5px 10px; cursor: pointer; }}
.val-up {{ color: #00e676; font-weight: bold; float: right; }}
.val-warn {{ color: #ff9800; font-weight: bold; float: right; }}
.val-down {{ color: #ff5252; font-weight: bold; float: right; }}
.conn {{ color: #00e676; font-weight: bold; }}
.idle {{ color: #666; }}
.traf {{ font-family: monospace; color: #00bcd4; }}
a.btn {{ display: inline-block; padding: 8px 15px; background: #333; color: #eee; text-decoration: none; border-radius: 4px; border: 1px solid #555; margin-right: 5px; font-size: 12px; }}
a.btn.active {{ background: #00bcd4; color: #000; border-color: #00bcd4; font-weight: bold; }}
a.btn-adv {{ float: right; background: #222; }}
.modal {{ display: none; position: fixed; z-index: 1000; left: 0; top: 0; width: 100%; height: 100%; background-color: rgba(0,0,0,0.9); }}
.modal-content {{ background-color: #1e1e1e; margin: 3% auto; padding: 20px; border: 1px solid #888; width: 95%; height: 90%; border-radius: 8px; position: relative; }}
.close {{ color: #aaa; float: right; font-size: 28px; font-weight: bold; cursor: pointer; position: absolute; right: 20px; top: 10px; z-index: 1001; }}
.proc-item {{ color: #00e676; margin-bottom: 3px; font-size: 13px; font-family: monospace; }}
.alert {{ background: #252525; padding: 10px; margin-bottom: 10px; border-radius: 4px; }}
.log-line {{ font-family: monospace; font-size: 12px; color: #bbb; margin-top: 5px; }}
.solution {{ margin-top: 5px; font-weight: bold; color: #fff; background: #444; display: inline-block; padding: 2px 6px; border-radius: 3px; font-size: 12px; }}
</style></head><body>

<div id="graphModal" class="modal"><div class="modal-content"><span class="close" onclick="closeModal()">&times;</span><h2 id="modalTitle" style="margin-top:0; color:#00bcd4;">Expanded View</h2><div style="height: 90%; width: 100%;"><canvas id="bigChart"></canvas></div></div></div>

<div style="margin-bottom: 20px; display: flex; align-items: center; justify-content: space-between;">
    <div>
        <h1 style="display:inline-block; margin-right: 20px; margin-top:0;">Open5GS Dashboard</h1>
        <a href="?range=10m" class="btn {'active' if selected_range=='10m' else ''}">10m</a>
        <a href="?range=1h" class="btn {'active' if selected_range=='1h' else ''}">1h</a>
        <a href="?range=24h" class="btn {'active' if selected_range=='24h' else ''}">24h</a>
        <a href="?range=7d" class="btn {'active' if selected_range=='7d' else ''}">7d</a>
    </div>
    <a href="metrics.py" class="btn btn-adv" target="_blank">📊 Advanced Metrics</a>
</div>

<div class="grid" style="margin-bottom:20px;">
    <div class="box" style="border-left: 5px solid {bts['color']}">
        <h3 style="margin-top:0">Hardware Status</h3>
        <div style="margin-bottom:15px; display:flex; justify-content:space-between;">
             <div><span style="font-weight:bold; color:{bts['color']}">{bts['status']}</span> <span style="color:#aaa">{bts['name']}</span></div>
             <div style="color:#888">{bts['uptime']}</div>
        </div>
        <div style="border-top:1px solid #333; padding-top:10px;">
            <div style="display:flex; justify-content:space-between;"><span>MongoDB</span><span class="{'val-up' if mongo_stat=='UP' else 'val-down'}">{mongo_stat}</span></div>
            <div style="margin-top:10px; height:100px; overflow-y:auto;">
                {''.join([f'<div class="proc-item">&#10003; {p}</div>' for p in procs])}
            </div>
        </div>
    </div>
    
    <div class="box">
        <h3 style="margin-top:0">Core Services</h3>
        <div style="display:flex; flex-direction:column; gap:8px;">
""")
for svc in METRICS_ENDPOINTS:
    val = get_service_status(svc)
    cls = "val-up"
    if val == "DOWN": cls = "val-down"
    elif "Active" in val: cls = "val-warn"
    print(f'<div style="background:#252525; padding:8px; border-radius:4px; display:flex; justify-content:space-between;"><span>{svc["name"]}</span><span class="{cls}">{val}</span></div>')
print(f"""
        </div>
    </div>

    <div class="box">
        <h3 style="margin-top:0">Smart Log Alerts</h3>
        <div style="height:200px; overflow-y:auto;">
             {''.join(log_alerts) if log_alerts else '<div style="color:#666; text-align:center; padding:20px;">No Critical Issues Detected</div>'}
        </div>
    </div>
</div>

<div class="grid" style="margin-bottom:20px;">
    <div class="box box-click" onclick="openModal('total')"><h2>Network Throughput</h2><div style="height:200px;"><canvas id="c1"></canvas></div></div>
    <div class="box box-click" onclick="openModal('infra')"><h2>Infrastructure</h2><div style="height:200px;"><canvas id="c3"></canvas></div></div>
    <div class="box box-click" onclick="openModal('users')"><h2>User Throughput</h2><div style="height:200px;"><canvas id="c2"></canvas></div></div>
</div>

<div class="box"><h3>Subscribers</h3><table><thead><tr><th>IMSI</th><th>Name</th><th>IP</th><th>Down</th><th>Up</th><th>Status</th><th>Save</th></tr></thead><tbody>
""")
for s in subs:
    st = "conn" if s["status"]=="Connected" else "idle"
    print(f"""<tr><td class="{st}">{s['imsi']}</td>
    <form method="POST"><input type="hidden" name="action" value="rename">
    <input type="hidden" name="current_range" value="{selected_range}">
    <input type="hidden" name="imsi" value="{s['imsi']}">
    <td><input type="text" name="nickname" value="{s['name']}" placeholder="..."></td>
    <td style="font-family:monospace">{s['ip']}</td><td class="traf">⬇ {fmt_bytes(s['rx'])}</td><td class="traf">⬆ {fmt_bytes(s['tx'])}</td>
    <td class="{st}">{s['status']}</td><td><button type="submit">💾</button></td></form></tr>""")
print(f"""</tbody></table></div>
<script>
const labels = {json.dumps(labels)};
const txData = {json.dumps(tx_data)};
const rxData = {json.dumps(rx_data)};
const userData = {json.dumps(imsi_datasets)};
const gnbData = {json.dumps(gnb_data)};
const enbData = {json.dumps(enb_data)};
const ueData = {json.dumps(ue_data)};

const cfg={{maintainAspectRatio:false, scales:{{x:{{grid:{{color:'#333'}}, ticks:{{maxTicksLimit: 10}}}}, y:{{grid:{{color:'#333'}}}}}}}};
const totalConfig = {{
    type:'line',
    data:{{labels:labels,datasets:[{{label:'Tx',data:txData,borderColor:'#00e676',pointRadius:0}},{{label:'Rx',data:rxData,borderColor:'#00bcd4',pointRadius:0}}]}},
    options:cfg
}};
const infraConfig = {{
    type:'line',
    data:{{
        labels:labels,
        datasets:[
            {{label:'5G gNBs', data:gnbData, borderColor:'#e91e63', backgroundColor:'rgba(233,30,99,0.1)', fill:true, pointRadius:0, stepper:true}},
            {{label:'4G eNBs', data:enbData, borderColor:'#ff9800', backgroundColor:'rgba(255,152,0,0.1)', fill:true, pointRadius:0, stepper:true}},
            {{label:'Total UEs', data:ueData, borderColor:'#2196f3', borderDash:[5,5], pointRadius:0}}
        ]
    }},
    options:{{...cfg, elements: {{ line: {{ tension: 0 }} }} }} 
}};
const userConfig = {{type:'line', data:{{labels:labels,datasets:userData}}, options:{{...cfg,plugins:{{legend:{{display:true,position:'right',labels:{{color:'#aaa',boxWidth:10}}}}}}}}}};

new Chart(document.getElementById('c1'), totalConfig);
new Chart(document.getElementById('c2'), userConfig);
new Chart(document.getElementById('c3'), infraConfig);

let bigChartInstance = null;
function openModal(type) {{
    document.getElementById('graphModal').style.display = "block";
    const ctx = document.getElementById('bigChart').getContext('2d');
    if (bigChartInstance) {{ bigChartInstance.destroy(); }}
    let conf = totalConfig;
    if (type === 'users') conf = userConfig;
    if (type === 'infra') conf = infraConfig;
    bigChartInstance = new Chart(ctx, conf);
}}
function closeModal() {{ document.getElementById('graphModal').style.display = "none"; }}
window.onclick = function(e) {{ if (e.target == document.getElementById('graphModal')) closeModal(); }}
</script></body></html>""")

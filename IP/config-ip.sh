#!/usr/bin/env bash

set -euo pipefail

NETPLAN_DIR="/etc/netplan"

# Ensure script is run with sudo/root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script as root or with sudo." >&2
  exit 1
fi

# 1. Detect and display available network interfaces (excluding loopback)
echo "Detecting available network interfaces..."
mapfile -t INTERFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$')

if [ ${#INTERFACES[@]} -eq 0 ]; then
  echo "Error: No active network interfaces found." >&2
  exit 1
fi

echo ""
echo "Select the network interface to apply the IP range to:"
select INTERFACE in "${INTERFACES[@]}" "Quit"; do
  if [ "$INTERFACE" = "Quit" ]; then
    echo "Operation cancelled."
    exit 0
  elif [ -n "$INTERFACE" ]; then
    echo "Selected interface: $INTERFACE"
    break
  else
    echo "Invalid selection. Please try again."
  fi
done

# 2. Locate the active Netplan configuration file
NETPLAN_FILE=$(find "$NETPLAN_DIR" -maxdepth 1 \( -name "*.yaml" -o -name "*.yml" \) | head -n 1)

if [ -z "$NETPLAN_FILE" ]; then
  echo "Error: No Netplan YAML configuration file found in $NETPLAN_DIR" >&2
  exit 1
fi

echo "Using Netplan file: $NETPLAN_FILE"

# 3. Extract current IP and CIDR prefix (e.g., 10.133.211.91/24)
IP_CIDR=$(ip -o -4 addr show dev "$INTERFACE" 2>/dev/null | awk '{print $4}' | head -n 1)

if [ -z "$IP_CIDR" ]; then
  echo "Error: Could not retrieve an active IPv4 address for interface '$INTERFACE'." >&2
  exit 1
fi

START_IP=$(echo "$IP_CIDR" | cut -d'/' -f1)
PREFIX=$(echo "$IP_CIDR" | cut -d'/' -f2)

echo "Found base IP: $START_IP/$PREFIX on $INTERFACE"

# Helper functions to convert IPv4 string <-> 32-bit integer
ip2int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  echo "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
}

int2ip() {
  local ui32=$1
  echo "$(( (ui32 >> 24) & 0xff )).$(( (ui32 >> 16) & 0xff )).$(( (ui32 >> 8) & 0xff )).$(( ui32 & 0xff ))"
}

START_INT=$(ip2int "$START_IP")

# 4. Build array of 20 IPs (base IP + next 19)
IP_LIST=()
for i in $(seq 0 19); do
  CURR_INT=$(( START_INT + i ))
  CURR_IP=$(int2ip "$CURR_INT")
  IP_LIST+=("        - ${CURR_IP}/${PREFIX}")
done

# 5. Create a backup of the Netplan file before modifying
BACKUP_FILE="${NETPLAN_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
cp "$NETPLAN_FILE" "$BACKUP_FILE"
echo "Created backup: $BACKUP_FILE"
echo

# 6. Generate formatted YAML addresses block
ADDRESSES_YAML=$(printf "%s\n" "${IP_LIST[@]}")

# Python helper to insert/replace the addresses block in YAML with correct formatting
python3 - "$NETPLAN_FILE" "$INTERFACE" "$ADDRESSES_YAML" << 'EOF'
import sys
import re

file_path, interface, new_addresses = sys.argv[1], sys.argv[2], sys.argv[3]

with open(file_path, 'r') as f:
    content = f.read()

# Pattern to locate interface section and its addresses block
pattern = rf"({interface}:\n(?:[ \t]+[^\n]+\n)*?)[ \t]+addresses:\n(?:[ \t]+- [^\n]+\n)+"

replacement = f"\\1      addresses:\n{new_addresses}\n"

if re.search(rf"{interface}:", content):
    if re.search(pattern, content):
        updated = re.sub(pattern, replacement, content, count=1)
    else:
        # If no addresses key exists yet under interface, append it
        iface_pattern = rf"({interface}:\n)"
        updated = re.sub(iface_pattern, f"\\1      addresses:\n{new_addresses}\n", content, count=1)
    
    with open(file_path, 'w') as f:
        f.write(updated)
    print("Netplan YAML successfully updated.")
else:
    print(f"Error: Interface '{interface}' was not found in {file_path}", file=sys.stderr)
    sys.exit(1)
EOF

# 7. Apply Netplan configuration
echo "Applying Netplan configuration..."
echo
echo "The Netplan configuration file around "$INTERFACE "looks like"
cat /etc/netplan/*.yaml |grep -A 23 $INTERFACE
echo
netplan try

echo "Successfully configured range $START_IP - $(int2ip $((START_INT + 19))) on interface $INTERFACE."
echo "These are the IP's configured on interface "$INTERFACE
echo
ip address show dev $INTERFACE


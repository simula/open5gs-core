#!/usr/bin/bash

# This script creates a copy/paste output for you to add to the IP configuration file for netplan
# in addition to configuring all of the yaml files needed for Open5GS.
# Copyright Clayton Milos (2025)

LOCAL_DEFAULTS="IP/IPs.txt.local"
IPS_FILE="IP/IPs.txt"

if [ ! -f "$LOCAL_DEFAULTS" ]; then
    echo "Error: Defaults file '$LOCAL_DEFAULTS' not found!" >&2
    exit 1
fi

mkdir -p IP

# -------------------------------------------------------------------
# 1. Prompt for Installation Type
# -------------------------------------------------------------------
echo
echo "Select installation mode:"
options=(
    "Full System with UPF"
    "Full System without UPF"
    "UPF Only"
    "Quit"
)

select opt in "${options[@]}"; do
    case $REPLY in
        1)
            INSTALL_MODE="FULL_WITH_UPF"
            break
            ;;
        2)
            INSTALL_MODE="FULL_NO_UPF"
            break
            ;;
        3)
            INSTALL_MODE="UPF_ONLY"
            break
            ;;
        4)
            echo "Configuration cancelled."
            exit 0
            ;;
        *)
            echo "Invalid option. Please choose 1, 2, 3, or 4."
            ;;
    esac
done

echo -e "\nStarting configuration for mode: $INSTALL_MODE\n"

# -------------------------------------------------------------------
# 2. Select Variables based on Installation Mode
# -------------------------------------------------------------------
if [ "$INSTALL_MODE" = "UPF_ONLY" ]; then
    # Elements relevant only to UPF / Tunnel settings
    TARGET_KEYS=("UPF_IP" "SMF_IP" "TUNSUBNETV4" "TUNGWV4" "TUNSUBNETV6" "TUNGWV6" "MCC" "MNC" "REGION")
elif [ "$INSTALL_MODE" = "FULL_NO_UPF" ]; then
    # All control plane keys, excluding UPF-specific IP
    TARGET_KEYS=($(awk -F'=' '{print $1}' "$LOCAL_DEFAULTS" \vert{} grep -v '^UPF_IP$' | sort -u))
else
    # Full list from IPs.txt.local
    TARGET_KEYS=($(awk -F'=' '{print $1}' "$LOCAL_DEFAULTS" | sort -u))
fi

# Clear or initialize IPs.txt
> "$IPS_FILE"

# -------------------------------------------------------------------
# 3. Prompt for Each IP / Variable with Fallback to Defaults
# -------------------------------------------------------------------
echo "Press [Enter] to accept the default value shown in brackets."
echo "------------------------------------------------------------"

for KEY in "${TARGET_KEYS[@]}"; do
    # Get default value from IPs.txt.local
    DEFAULT_VAL=$(grep -E "^${KEY}=" "$LOCAL_DEFAULTS" | head -n 1 | cut -d'=' -f2-)

    # Prompt user
    read -p "Enter value for $KEY [$DEFAULT_VAL]: " USER_VAL

    # Fallback to default if user input is blank
    FINAL_VAL="${USER_VAL:-$DEFAULT_VAL}"

    # Write key-value to IPs.txt
    echo "${KEY}=${FINAL_VAL}" >> "$IPS_FILE"
done

echo -e "\nSaved configuration to $IPS_FILE\n"

# -------------------------------------------------------------------
# 4. Backup Existing Configurations
# -------------------------------------------------------------------
TIMESTAMP=$(/bin/date "+%Y-%m-%d-%H%M")
echo "Backing up old directories with timestamp: $TIMESTAMP"
[ -d /etc/open5gs ] && cp -r /etc/open5gs "/etc/open5gs-$TIMESTAMP"
[ -d /etc/freeDiameter ] && cp -r /etc/freeDiameter "/etc/freeDiameter-$TIMESTAMP"

# -------------------------------------------------------------------
# 5. Process YAML Files
# -------------------------------------------------------------------
echo "Preparing yaml files..."
mkdir -p yamls
rm -f yamls/*.yaml

for substitute in yamls/*.template; do
    [ -e "$substitute" ] || continue
    subname=$(basename "$substitute" .template)
    
    # Mode filtering for YAML templates
    if [ "$INSTALL_MODE" = "UPF_ONLY" ] && [ "$subname" != "upf" ]; then
        continue
    fi

    if [ "$INSTALL_MODE" = "FULL_NO_UPF" ] && [ "$subname" = "upf" ]; then
        continue
    fi

    echo "Creating $subname.yaml configuration."
    cp "$substitute" "yamls/$subname.yaml"

    while IFS='=' read -r NODENAME NODEVALUE; do
        [ -z "$NODENAME" ] && continue
        sed -i "s|${NODENAME}|${NODEVALUE}\vert{}g" "yamls/$subname.yaml"
    done < "$IPS_FILE"

    echo "Done for $subname. Copying to /etc/open5gs."
    mkdir -p /etc/open5gs
    cp "yamls/$subname.yaml" "/etc/open5gs/$subname.yaml"
done
echo "Yaml files completed."
echo

# -------------------------------------------------------------------
# 6. Process freeDiameter Files (Skipped for UPF_ONLY)
# -------------------------------------------------------------------
if [ "$INSTALL_MODE" != "UPF_ONLY" ]; then
    echo "Preparing freeDiameter files..."
    mkdir -p freeDiameter
    rm -f freeDiameter/*.conf

    for substitutes in freeDiameter/*.template; do
        [ -e "$substitutes" ] || continue
        subsname=$(basename "$substitutes" .template)
        echo "Creating $subsname Diameter configuration."
        cp "$substitutes" "freeDiameter/$subsname.conf"

        while IFS='=' read -r NODENAME NODEVALUE; do
            [ -z "$NODENAME" ] && continue
            sed -i "s|${NODENAME}|${NODEVALUE}\vert{}g" "freeDiameter/$subsname.conf"
        done < "$IPS_FILE"

        echo "Done for $subsname. Copying to /etc/freeDiameter."
        mkdir -p /etc/freeDiameter
        cp "freeDiameter/$subsname.conf" "/etc/freeDiameter/$subsname.conf"
    done
    echo "freeDiameter files completed."
    echo
fi

# -------------------------------------------------------------------
# 7. Restart Services
# -------------------------------------------------------------------
echo "Restarting daemons..."
if [ -f control-scripts/5g-services.sh ]; then

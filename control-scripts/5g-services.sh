#!/usr/bin/bash

# Define services in the specific order of dependency
SERVICES=(
    "open5gs-hssd" "open5gs-nrfd" "open5gs-udmd" "open5gs-nssfd" 
    "open5gs-seppd" "open5gs-pcrfd" "open5gs-pcfd" "open5gs-upfd" 
    "open5gs-sgwud" "open5gs-sgwcd" "open5gs-udrd" "open5gs-bsfd" 
    "open5gs-scpd" "open5gs-smfd" "open5gs-ausfd" "open5gs-amfd" 
    "open5gs-mmed"
)

# Function to display status
check_status() {
    echo -e "\n--- Open5GS Service Status ---"
    for svc in "${SERVICES[@]}"; do
        # Extract the short name (e.g., hssd) and capitalize for display
        SHORT_NAME=$(echo $svc | cut -d'-' -f2 | tr '[:lower:]' '[:upper:]')
        printf "%-10s: " "$SHORT_NAME"
        systemctl status "$svc" | grep "Active:" | xargs # xargs cleans up whitespace
    done
}

# Main logic
case "$1" in
    restart)
        echo "Restarting Open5GS services in dependency order..."
        for svc in "${SERVICES[@]}"; do
            echo "Restarting $svc..."
            sudo systemctl restart "$svc"
        done
	sleep 2
        check_status
        ;;
    status)
        check_status
        ;;
    *)
        echo "Usage: $0 {restart|status}"
        exit 1
        ;;
esac

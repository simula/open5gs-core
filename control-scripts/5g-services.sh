#!/usr/bin/bash

# Define services in the specific order of dependency
SERVICES=(
    "open5gs-hssd" "open5gs-nrfd" "open5gs-udmd" "open5gs-nssfd" 
    "open5gs-seppd" "open5gs-pcrfd" "open5gs-pcfd" "open5gs-upfd" 
    "open5gs-sgwud" "open5gs-sgwcd" "open5gs-udrd" "open5gs-bsfd" 
    "open5gs-scpd" "open5gs-smfd" "open5gs-ausfd" "open5gs-amfd" 
    "open5gs-mmed"
)

# ANSI Color Codes
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color / Reset

# Helper function to normalize service name (e.g., "upfd" -> "open5gs-upfd")
resolve_service_name() {
    local input="$1"
    if [[ "$input" =~ ^open5gs- ]]; then
        echo "$input"
    else
        echo "open5gs-$input"
    fi
}

# Function to display status with colors
check_status() {
    local target_services=("$@")
    
    # Default to all services if no specific target passed
    if [ ${#target_services[@]} -eq 0 ]; then
        target_services=("${SERVICES[@]}")
    fi

    echo -e "\n--- Open5GS Service Status ---"
    for svc in "${target_services[@]}"; do
        SHORT_NAME=$(echo "$svc" | cut -d'-' -f2 | tr '[:lower:]' '[:upper:]')
        
        # Query active status directly from systemctl
        STATUS_LINE=$(systemctl status "$svc" 2>/dev/null | grep "Active:" | xargs)

        if [ -z "$STATUS_LINE" ]; then
            COLOR_STATUS="${RED}Active: not-found (service missing)${NC}"
        elif [[ "$STATUS_LINE" =~ active\ \(running\) ]]; then
            COLOR_STATUS="${GREEN}${STATUS_LINE}${NC}"
        elif [[ "$STATUS_LINE" =~ inactive|failed ]]; then
            COLOR_STATUS="${RED}${STATUS_LINE}${NC}"
        elif [[ "$STATUS_LINE" =~ activating|deactivating ]]; then
            COLOR_STATUS="${ORANGE}${STATUS_LINE}${NC}"
        else
            COLOR_STATUS="$STATUS_LINE"
        fi

        printf "%-10s: %b\n" "$SHORT_NAME" "$COLOR_STATUS"
    done
}

# Helper function to execute a systemctl action on all or a specific service
manage_service() {
    local action="$1"
    local target="$2"

    if [ -n "$target" ]; then
        # Action on a single service
        local full_svc
        full_svc=$(resolve_service_name "$target")
        echo "${action^}ing $full_svc..."
        sudo systemctl "$action" "$full_svc"
        sleep 1
        check_status "$full_svc"
    else
        # Action on all services
        echo "${action^}ing all Open5GS services..."
        for svc in "${SERVICES[@]}"; do
            echo "${action^}ing $svc..."
            sudo systemctl "$action" "$svc"
        done
        sleep 2
        check_status
    fi
}

# Main logic
ACTION="$1"
TARGET="$2"

case "$ACTION" in
    start)
        manage_service "start" "$TARGET"
        ;;
    stop)
        manage_service "stop" "$TARGET"
        ;;
    restart)
        manage_service "restart" "$TARGET"
        ;;
    status)
        if [ -n "$TARGET" ]; then
            check_status "$(resolve_service_name "$TARGET")"
        else
            check_status
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status} [service_name|short_name]"
        echo "Examples:"
        echo "  $0 start                       # Starts all services"
        echo "  $0 stop open5gs-upfd           # Stops UPF service using full name"
        echo "  $0 restart upfd                # Restarts UPF service using short name"
        echo "  $0 status amfd                 # Checks status of AMF service"
        exit 1
        ;;
esac

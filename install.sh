#!/usr/bin/bash

# Installer script for Open5GS on Ubuntu 26.04

# List of all Open5GS control plane / core services (excluding UPF)
CORE_SERVICES=(
  "open5gs-mmed"
  "open5gs-sgwcd"
  "open5gs-smfd"
  "open5gs-amfd"
  "open5gs-ausfd"
  "open5gs-udmd"
  "open5gs-pcrfd"
  "open5gs-nrfd"
  "open5gs-scpd"
  "open5gs-seppd"
  "open5gs-udrd"
  "open5gs-hssd"
  "open5gs-bsfd"
  "open5gs-webui"
)

echo "Select installation mode:"
options=(
  "Install Core System without UPF"
  "Install just the UPF"
  "Install Full System (Core + UPF)"
  "Quit"
)

select opt in "${options[@]}"; do
  case $REPLY in
    1)
      INSTALL_MODE="CORE_ONLY"
      break
      ;;
    2)
      INSTALL_MODE="UPF_ONLY"
      break
      ;;
    3)
      INSTALL_MODE="FULL"
      break
      ;;
    4)
      echo "Installation cancelled."
      exit 0
      ;;
    *)
      echo "Invalid option. Please choose 1, 2, 3, or 4."
      ;;
  esac
done

echo "Starting installation for mode: $INSTALL_MODE"

# -------------------------------------------------------------------
# 1. Install MongoDB (Skipped if UPF_ONLY)
# -------------------------------------------------------------------
if [ "$INSTALL_MODE" != "UPF_ONLY" ]; then
  echo "--> Installing MongoDB..."
  sudo apt update
  sudo apt install -y gnupg
  sudo curl -fsSL https://pgp.mongodb.com/server-8.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor
  sudo echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list

  sudo apt update
  sudo apt install -y mongodb-org=8.0.20 mongodb-org-database=8.0.20 mongodb-org-server=8.0.20 mongodb-mongosh mongodb-org-mongos=8.0.20 mongodb-org-tools=8.0.20 --allow-downgrades
  sudo systemctl start mongod
  sudo systemctl enable mongod
fi

# -------------------------------------------------------------------
# 2. Install Open5GS Base Packages
# -------------------------------------------------------------------
echo "--> Installing Open5GS repository and base packages..."
sudo add-apt-repository -y ppa:open5gs/latest
sudo apt update

if [ "$INSTALL_MODE" = "UPF_ONLY" ]; then
  # Install only the UPF package
  sudo apt install -y open5gs-upf
else
  # Installs all Open5GS daemons by default
  sudo apt install -y open5gs
fi

# -------------------------------------------------------------------
# 3. Install Web UI (Skipped if UPF_ONLY)
# -------------------------------------------------------------------
if [ "$INSTALL_MODE" != "UPF_ONLY" ]; then
  echo "--> Installing WebUI..."
  sudo apt install -y ca-certificates curl gnupg
  sudo mkdir -p /etc/apt/keyrings
  sudo curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  NODE_MAJOR=20
  sudo echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list
  sudo apt update
  sudo apt install nodejs -y
  curl -fsSL https://open5gs.org/open5gs/assets/webui/install | sudo -E bash -
fi

# -------------------------------------------------------------------
# 4. Enable/Disable Services Based on Selection
# -------------------------------------------------------------------
echo "--> Configuring systemd services..."

if [ "$INSTALL_MODE" = "CORE_ONLY" ]; then
  # Disable UPF, ensure core services are running
  sudo systemctl stop open5gs-upfd
  sudo systemctl disable open5gs-upfd
  
  for service in "${CORE_SERVICES[@]}"; do
    sudo systemctl enable --now "$service" 2>/dev/null || true
  done

elif [ "$INSTALL_MODE" = "UPF_ONLY" ]; then
  # Ensure UPF is active, disable all core services (if present)
  sudo systemctl enable --now open5gs-upfd
  
  for service in "${CORE_SERVICES[@]}"; do
    sudo systemctl stop "$service" 2>/dev/null || true
    sudo systemctl disable "$service" 2>/dev/null || true
  done

elif [ "$INSTALL_MODE" = "FULL" ]; then
  # Enable UPF and all core services
  sudo systemctl enable --now open5gs-upfd
  
  for service in "${CORE_SERVICES[@]}"; do
    sudo systemctl enable --now "$service" 2>/dev/null || true
  done
fi

echo "All done with the binaries, now run the configure script."

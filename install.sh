#!/usr/bin/bash

# Installer script for Open5GS on Ubuntu 22.04
# It should work on other non-ancient versions of Ubuntu as well

# Install the repositories
sudo apt update
sudo apt install gnupg
curl -fsSL https://pgp.mongodb.com/server-8.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg] https://repo.mongodb.org/apt/ubuntu `cat /etc/os-release |grep VERSION_CODENAME|cut -d "=" -f2`/mongodb-org/8.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list

# Install MongoDB
sudo apt update
sudo apt install -y mongodb-org
sudo systemctl start mongod
sudo systemctl enable mongod

# Install Open5GS
sudo add-apt-repository ppa:open5gs/latest
sudo apt update
sudo apt install open5gs

# Install the Web interface for provisioning
sudo apt install -y ca-certificates curl gnupg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
NODE_MAJOR=20
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list
sudo apt update
sudo apt install nodejs -y
curl -fsSL https://open5gs.org/open5gs/assets/webui/install | sudo -E bash -

echo All done with the binaries, now run the configure script


